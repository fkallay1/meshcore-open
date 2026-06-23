# FOTA package preparation — design spec

> **Status:** design / approved-pending-review
> **Date:** 2026-06-24
> **Fork:** `fkallay1/meshcore-open`, branch `feature/nrf-ota-sender`
> **Author:** Fedor Kallay (+ Claude)
> **Related:** builds on `2026-06-23-mc-fotanrf-flutterapp-design.md` (OTA sender) and the
> 2026-06-24 work-log entry (FOTA Broadcast + reuse OTA screen).

## 1. Goal

Let the FOTA screen **prepare the `.otapkg.json` itself**, instead of requiring a pre-made package
from the PC tool (`ota_export_pkg.py`). Two input paths:

- **(a) Local files** — pick two firmware `.bin` files (current → target) from disk.
- **(b) GitHub releases** — pick a device + two firmware versions from dropdowns populated
  dynamically from `github.com/meshcore-dev/MeshCore`, then download + generate.

The selection UI sits **at the top of the `FOTA → …` screen, above the existing `.otapkg.json`
file-picker**, which stays as a third (manual) input path.

This spec covers **path (b)** end-to-end plus the shared generation pipeline. Path (a) reuses the
same generation pipeline with locally-picked bins. Delivered in two build steps:

- **Step 1 — selection UI:** GitHub browsing + the device / current-FW / target-FW dropdowns.
- **Step 2 — generation:** the `Create FOTA package` button → download bins → delta patch →
  `.otapkg.json` loaded straight into the existing send flow. Includes porting the `hdiffi`
  delta step (`HPatchLite` inplace) to run inside the app.

## 2. Out of scope (separate follow-up specs)

- **Web Bluetooth (BLE on web).** `flutter_blue_plus` has no web support; `app.meshcore.nz` uses
  `navigator.bluetooth` via JS interop. A web BLE transport is its own subsystem → own spec.
  Not a blocker: web FOTA already works over Web Serial (USB).
- **"Only FOTA" connection mode.** Toggle on the entry/scanner screen (default off) that stops the
  app from draining companion messages, so another client (e.g. the official MeshCore app) keeps
  receiving them. Touches scanner + connector sync, not the FOTA screen → own (small) spec.

Recommended order: **this spec → "Only FOTA" → Web BLE.**

## 3. Data sources (web-friendly; GitHub API used only where necessary)

| Need | Source | Transport | CORS on web |
|---|---|---|---|
| Release list, tags, asset names + download URLs | `api.github.com/repos/meshcore-dev/MeshCore/releases` | **1 API call** (paginated as needed) | OK (`*`) |
| nRF board set (which devices are nRF52) | `variants/*/platformio.ini` | git-trees **1 API call** to enumerate dirs, then `raw.githubusercontent.com` per file (not API-rate-limited) | OK (`*`) |
| Firmware binaries | `releases/download/<tag>/<asset>` (== asset `browser_download_url`) | **direct**, no API | **blocked** (redirects to `objects.githubusercontent.com`, no CORS) → Step-2 web concern |

Notes:
- Unauthenticated GitHub API limit is 60 req/h — hence "API only where necessary": the releases
  call already returns every asset's `browser_download_url`, so no per-asset API call is needed.
- nRF board detection result is **cached** (in-memory + SharedPreferences with a short TTL) so the
  variant fetches happen at most once per refresh.
- Binary download on **web** is CORS-blocked; resolved in Step 2 (options: a small CORS proxy, or
  restrict path (b) downloads to mobile/desktop while web keeps Web-Serial + manual `.otapkg`).

## 4. Role & device model

- **Firmware role** selectable: **Repeater** (default) or **Room Server**. Maps to release tag
  prefix: `repeater-v*` / `room-server-v*`. (Asset infix is `_repeater` / `_room_server`.)
- **Device list** = (nRF52 boards from PIO variants) ∩ (devices that have a usable asset in the
  selected release). Device name ↔ asset mapping via the filename prefix before `_<role>-v…`.
  - Asset filename pattern observed: `<Device>_<role>-v<ver>-<commit>[<variant>].<ext>`
    e.g. `ProMicro_repeater-v1.16.0-07a3ca9.zip`, `ikoka_nano_nrf_30dbm_room_server-v1.16.0-….uf2`.
- **Versions** = release tags for the selected role, newest-first.

## 5. Asset selection priority (per device + role + version)

Within the matching release, among assets whose prefix matches the device:

1. Standalone **`.bin`** that is **NOT** `*-merged.bin`.
2. Else **`.zip`** → download, unzip, take the inner **non-merged `.bin`**.
3. **`.uf2` is never used** (different format; ESP32-future uses plain `.bin`).

If neither (1) nor (2) exists → device marked **not OTA-able** for that version (greyed out).

**Impl-time verification:** confirm the `.zip` actually contains a raw application `.bin` (not only
`.uf2`). If a device's zip lacks a bin, it is treated as not OTA-able and logged.

## 6. Defaults (on screen open)

- **Role:** Repeater.
- **Device:** `promicro`.
- **Target FW:** newest release.
- **Current FW:** second-newest release.

(Semantics: current = `old` = what is running/flashed; target = `new`. Default is a forward update
to the latest.)

## 7. Generation pipeline (Step 2)

Mirrors `ota_sender.py::make_patch` + `ota_export_pkg.py`, byte-compatible with the existing
`.otapkg.json` schema (`mc-fotanrf-otapkg/1`) so it feeds the current `OtaPkg`/`OtaSender` unchanged.

1. Obtain `old.bin` (current) and `new.bin` (target) — from GitHub (download → maybe unzip) or
   local file-picker.
2. **Delta:** `hdiffi -inplaceB` equivalent (HPatchLite inplace format — mandatory for the nRF52840
   in-place flasher). Then DEFLATE (raw, `wbits=-9`, 512-B window) and wrap in the `ZLIB` staged
   header `[b'ZLIB'][uncomp_size u32le][new_fw_size u32le][deflate…]`.
   - **Porting:** the `hdiffi`/HPatchLite diff is C++. Step-2 sub-decision (own mini-investigation):
     pure-Dart port, wasm, FFI (mobile/desktop), or a generation service. Picked when Step 2 starts.
3. Compute `old_sha256`, `new_sha256`, `patch_sha256`, `old_fw_size`, `patch_len`.
4. Build the `.otapkg.json` (raw / unsigned by default — the app already signs raw packages with
   the imported key at send time via `OtaKeyStore`; pre-signed remains a later option).
5. **Output filename** carries device + both versions for batch clarity:
   `<Device>_<role>_<currentVer>_to_<targetVer>.otapkg.json`
   e.g. `ProMicro_repeater_v1.16.0_to_v1.17.0.otapkg.json`.
6. Load the generated package straight into the existing send flow (same as picking a file today).

## 8. Components / isolation

New files (OTA logic stays out of upstream files):

| File | Responsibility |
|---|---|
| `lib/ota/ota_github_source.dart` | Fetch + parse releases & nRF variants; build device/version model; resolve + download assets (incl. zip extraction). Caching. |
| `lib/ota/uf2.dart` | *(only if ever needed)* — **not** in this spec; UF2 path is dropped. |
| `lib/ota/ota_pkg_builder.dart` | Delta + DEFLATE + `ZLIB` stage + SHAs + `.otapkg.json` assembly + filename. |
| `lib/ota/hdiff/…` | The ported HPatchLite inplace diff (Step 2; structure TBD by the port decision). |

Reuse / minimal touch:
- `lib/screens/ota_screen.dart` — add the selection section at the top (above the file-picker).
- `lib/ota/otapkg.dart`, `ota_sender.dart`, `ota_types.dart`, `services/ota_key_store.dart` — unchanged.
- `http` package (already a dep) for fetches; `archive` (new dep) for zip extraction.

## 9. Error handling

- Network/API failure → inline error in the FOTA log area; dropdowns keep last good cached data.
- GitHub rate-limit (HTTP 403 + `X-RateLimit-Remaining: 0`) → clear message + retry-after hint.
- Device not OTA-able (no bin/zip, or zip has no bin) → greyed out with reason.
- Web binary download CORS failure → explicit message pointing to Web-Serial/manual-`.otapkg`
  fallback (until the Step-2 proxy decision).
- Generation failure (diff/deflate) → surfaced with the failing stage.

## 10. Testing

- **Pure-Dart unit tests** (no network): parse a captured `releases` JSON fixture → assert device
  list, version ordering, asset-priority selection (bin over zip, skip `*-merged.bin`, skip uf2),
  filename construction, nRF filtering from a captured `platformio.ini` fixture.
- **Generation golden:** reuse `test/fixtures/` — generated `.otapkg.json` from sample bins must
  match the PC `ota_export_pkg.py` output byte-for-byte (Step 2; extends existing golden gate).
- **Widget smoke:** selection section renders with defaults (role=Repeater, device=promicro),
  no Provider required (network behind an injectable source so tests pass a fake).
- Existing `test/ota` suite stays green.

## 11. Open questions (resolved at Step 2)

- hdiff port strategy (pure-Dart vs wasm vs FFI vs service).
- Web binary-download CORS mitigation.
- Exact `.zip` internal layout (verify it contains a raw `.bin`).
