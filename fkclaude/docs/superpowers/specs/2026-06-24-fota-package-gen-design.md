# FOTA package generation — design spec (Step 2)

> **Status:** design / approved-pending-review
> **Date:** 2026-06-24
> **Fork:** `fkallay1/meshcore-open`, branch `feature/nrf-ota-sender`
> **Author:** Fedor Kallay (+ Claude)
> **Builds on:** `2026-06-24-fota-package-prep-design.md` (Step 1 selection UI, done). This is the
> Step-2 "generation" half: turn two firmware `.bin`s into a ready `.otapkg.json` in-app.

## 1. Goal

Generate the `.otapkg.json` **entirely in Dart**, on every platform (web / Android / iPhone /
desktop), with **no server, no native toolchain, and the firmware device side untouched**. The
delta is produced by a pure-Dart port of HPatchLite's inplace-lite codec; correctness is verified
offline (Dart applier round-trip + reference golden) and on-device (`ota verify` dry-run).

This wires the (currently disabled) **`Create FOTA package`** button from Step 1: from either the
GitHub selection (download two release binaries) or two locally-picked `.bin`s, produce the package
and drop it into the unified "selected package" slot that already drives the send flow.

## 2. Why pure-Dart (decision record)

- **In-place is mandatory.** nRF52840 has 1 MB flash; the ~712 kB app + SoftDevice + bootloader
  leave no room for a second full firmware copy, so the flasher rewrites the app region in place
  (new overwrites old as it streams, with a small `extraSafeSize` ring buffer). This in-place
  safety is exactly what makes the delta format non-trivial — and is why HPatchLite `inplaceB` was
  chosen. "Simpler" formats (bsdiff, plain copy/insert) are **not** in-place-safe, so adopting one
  would mean rewriting and re-validating the hard-won on-device flasher (firmware tech doc §8.x) —
  a bad trade.
- **Platforms.** A `.wasm` of `hdiffi` runs only on Flutter **web** (native Flutter has no JS/wasm
  host; it would need FFI). A generation **service** covers all platforms but needs hosting and is
  unreachable from a phone on `localhost`. The only **single-codebase, all-platforms, no-infra**
  option is **pure Dart**.
- **Risk is bounded and measurable**, because the device applier and the patch *format* are fixed
  and small: we port the tiny applier to Dart too and verify the encoder's output by round-trip
  (apply → must equal `new.bin`), cross-checked against reference `hdiffi.exe` patches and the
  on-device dry-run. We do **not** need to reproduce `hdiffi`'s optimal matcher — a simpler matcher
  that emits a *valid* (correct, in-place-safe) patch is enough; DEFLATE recovers most of the size.

## 3. The format (reverse-engineered from the on-device applier)

Source of truth: `../MeshCore/examples/simple_repeater/nrfota/hpatchlite/hpatch_lite.c` and
`hpatch_lite.h` (the applier the device runs). The encoder must emit exactly what
`hpatchi_inplace_open` + `hpatch_lite_patch` decode:

**Inplace-lite header** (`hpatchi_inplace_open`, `hpi_kInplaceHeadSize` bytes then 3 size fields):
- `'h'`, `'I'` (2-byte type tag)
- `compressType` byte (`0` = no compression — our raw diff is uncompressed; outer DEFLATE is separate)
- packed byte: high 2 bits = version code (must be `2` = inplace), low 3 bits = `newSize` byte count,
  mid 3 bits = `uncompressSize` byte count
- `extraSafeSize` byte count
- then little-endian `newSize`, `uncompressSize` (= raw-diff length here, since uncompressed),
  `extraSafeSize` (each as many bytes as its count) — note `_hpi_readSize` reads low byte first.

**Body** (`hpatch_lite_patch`): a 7-bit varint `coverCount`, then per cover:
- varint `cover_length`
- a tag byte: low 5 bits + bit5(continue) encode the `oldPos` delta magnitude; bit6 = sign
  (subtract from / add to running `oldPosBack`); bit7 = `isNotNeedSubDiff`
- varint `cover_newPos` delta (added to running `newPosBack`)
- the gap `cover_newPos - newPosBack` is emitted **inline as literal bytes** in the diff stream
  (this is the "ADD literal" data); then `cover_length` bytes are **copied from old** at `oldPos`
  (pure copy when `isNotNeedSubDiff=1`; with byte-wise additive sub-diff bytes when `=0`).

**Our encoder simplification:** always `isNotNeedSubDiff = 1` (pure old-copies + literal gaps, no
sub-diff). Matcher = **rolling-hash greedy** (find runs in old that appear in new), not a suffix
array. Slightly larger raw diff than `hdiffi`, but valid; DEFLATE closes most of the gap.

**`extraSafeSize`:** computed so the patch is in-place-safe for the device applier's delayed-write
ring buffer. The exact minimal formula is in sisong/HPatchLite `create_inplaceB_lite_diff` — a
plan-time research item (fetch + study). A correct (possibly conservative) value is acceptable as
long as it stays within the device's bounded `temp_cache` (the device cannot allocate an arbitrary
ring buffer), and is verified on-device.

## 4. Reusable library vs app code (isolation)

**Generic, reusable Dart package** — `packages/hpatchlite_dart/` (path package, **pure Dart, zero
deps**, depends only on `dart:typed_data`; no Flutter, no `dart:io`). Publishable to pub.dev later.
Public API:
- `Uint8List createInplaceLiteDiff(Uint8List oldData, Uint8List newData, {int? maxExtraSafeSize})`
  — produces the raw inplace-lite diff (compressType=0) the device applier accepts.
- `Uint8List applyInplaceLiteDiff(Uint8List diff, Uint8List oldData)` — the ported applier
  (`hpatch_lite_patch` semantics), used for verification and usable standalone.
- (internal) varint codec, cover model, rolling-hash matcher, extraSafeSize calc.

The app depends on it via `hpatchlite_dart: { path: packages/hpatchlite_dart }` in `pubspec.yaml`.

**MeshCore-specific glue stays in the app** — `lib/ota/ota_pkg_builder.dart`:
- DEFLATE the raw diff (raw, **512-byte window** to match the device `puff_stream`, level 9) and
  wrap as staged `['ZLIB'][uncompSize u32le][newFwSize u32le][deflate]` (byte-compatible with
  `ota_sender.py::make_patch`).
- Compute `old_sha256`, `new_sha256`, `patch_sha256` (= sha256 of the staged blob), sizes.
- Assemble the `.otapkg.json` (reuse the existing `OtaPkg`/`mc-fotanrf-otapkg/1` schema, raw/unsigned
  by default; the app already signs raw packages at send time) with channel/radio/scope from the UI.
- Filename `<device>_<role>_v<current>_to_v<target>.otapkg.json` (from Step-1 `otaPackageFileName`).

## 5. Download + source abstraction + wiring (the 2b half)

### 5.1 Source abstraction (pluggable, selectable repo)

The firmware catalog read is wrapped behind a **source-agnostic interface** so the backing source
can be swapped, and so the GitHub repo is **selectable** (not hardcoded to `meshcore-dev/MeshCore`).

```dart
abstract class OtaFwSource {
  /// "GetFotaDevicesList" — the source-agnostic device/firmware catalog.
  Future<List<OtaFwDevice>> getDevices();
}

class OtaFwDevice {            // one nRF board
  final OtaFwRole type;        // repeater | roomServer
  final String id;            // stable key (e.g. asset device-prefix, lowercased)
  final String name;          // display name
  final List<OtaFwFirmware> firmwares; // available versions, newest-first
}
class OtaFwFirmware {
  final String version;        // e.g. "1.17.0"  (the "firmware name")
  final String url;            // direct download link for this device+version asset
}
```

- **`GithubOtaFwSource implements OtaFwSource`** — parameterized by **`repo` (owner/repo)** and
  `branch`, **default `meshcore-dev/MeshCore` / `main`, overridable to a custom repo** (assumed to
  have the same release-tag + asset-naming + `variants/*/platformio.ini` structure). This is the
  Step-1 `ota_github_source.dart` reshaped to (a) take the repo as a parameter and (b) emit the
  `OtaFwDevice`/`OtaFwFirmware` model above.
- The custom-repo string is entered in the UI (a field on the FOTA prepare section / app settings),
  persisted; empty → default. Future non-GitHub source *types* plug in via the same interface
  (out of scope now; the interface is what makes them cheap later).
- The picker (`ota_fw_picker.dart`) consumes `OtaFwSource` instead of the concrete class; defaults
  (device=promicro, target=newest, current=second-newest) operate on the `OtaFwDevice` model.

### 5.2 Download

- **Local-bin path (all platforms incl. web):** user picks two `.bin` files (`file_selector`,
  already a dep) → straight into the builder. Fully offline, works everywhere.
- **Source path:** download the selected device's current + target `OtaFwFirmware.url`. If the asset
  is a `.zip`, extract the inner non-merged `.bin` (`archive` package — **new dep**, pure Dart,
  web-safe).
- **Web CORS:** GitHub release-asset downloads (redirect to `objects.githubusercontent.com`) do not
  send permissive CORS, so in-browser binary download is blocked. Resolution: on web, the
  auto-download may fail → fall back to the local-bin path (which works on web) with a clear
  message; native/desktop download directly. (A CORS proxy is an optional later enhancement; not
  required for a usable web flow because local-bin generation works.)

### 5.3 Wire `Create FOTA package`

On tap → obtain old+new bytes (downloaded or local) → `ota_pkg_builder` → load the resulting
`OtaPkg` into the unified selected-package slot (same as the manual picker), under the generated
filename, ready to send. Progress + errors go to the existing FOTA log area.

## 6. Verification strategy (the de-risking backbone)

1. **Dart applier vs reference (proves the applier):** take patches produced by the repo's
   `hdiffi.exe` (raw inplace diff) for known `old/new.bin` pairs → `applyInplaceLiteDiff` must
   reconstruct `new.bin` (sha256 match). Fixtures captured from `../MeshCore/test_nrf-ota/`.
2. **Dart encoder round-trip (proves the encoder):** `createInplaceLiteDiff(old,new)` →
   `applyInplaceLiteDiff(diff, old)` must equal `new` (sha256). Run on several real firmware pairs
   (small + large delta) and synthetic edge cases (empty, identical, single-byte change, append,
   truncate).
3. **Cross-check encoder output is reference-decodable:** decompress is N/A (raw), but optionally
   apply the Dart-generated diff with the reference `hpatchi`/`hdiffi.exe` toolchain on PC to
   confirm format compatibility beyond our own applier.
4. **DEFLATE window:** confirm the staged DEFLATE decompresses under a **512-byte window** (the
   device `puff_stream` limit) — back-reference distances must stay ≤ 512.
5. **On-device:** final confirmation via `ota verify` (dry-run, reconstructs in RAM, no flash) on
   real HW, then a real `ota flash`.

## 7. Components / files

| File | Responsibility |
|---|---|
| `packages/hpatchlite_dart/pubspec.yaml` | pure-Dart package manifest (no Flutter, no deps) |
| `packages/hpatchlite_dart/lib/hpatchlite_dart.dart` | public API (`createInplaceLiteDiff`, `applyInplaceLiteDiff`) |
| `packages/hpatchlite_dart/lib/src/*.dart` | varint codec, cover model, rolling-hash matcher, extraSafeSize, applier |
| `packages/hpatchlite_dart/test/*` | applier-vs-reference + encoder round-trip + edge cases |
| `lib/ota/ota_pkg_builder.dart` (app) | DEFLATE(512) + staged ZLIB wrap + sha/sizes + `.otapkg.json` assembly |
| `lib/ota/ota_asset_download.dart` (app) | fetch asset, `.zip`→inner `.bin`, CORS-aware |
| `lib/ota/ota_fw_source.dart` (app) | `OtaFwSource` interface + `OtaFwDevice`/`OtaFwFirmware` model |
| `lib/ota/ota_github_source.dart` (app, modify) | reshape to `implements OtaFwSource`, repo as parameter (selectable/custom) |
| `lib/screens/ota_fw_picker.dart` (app, modify) | consume `OtaFwSource`; repo/custom-source selector |
| `lib/screens/ota_screen.dart` (app, modify) | wire `Create FOTA package` → builder → selected-package slot |
| app `pubspec.yaml` (modify) | add `hpatchlite_dart` path dep + `archive` |

## 8. Decomposition (two implementation plans)

- **Plan 2a — Dart delta engine + builder (the core, build first).** The `hpatchlite_dart` package
  (encoder + applier + extraSafeSize) and `ota_pkg_builder.dart`, with the full offline verification
  suite (§6 items 1–4). No UI, no network. This is where the risk lives and it is independently
  testable; everything else is plumbing.
- **Plan 2b — source abstraction + download + wiring.** The `OtaFwSource` interface +
  `OtaFwDevice`/`OtaFwFirmware` model (§5.1), reshape `ota_github_source.dart` to implement it with
  a **selectable/custom repo**, adapt the picker; `ota_asset_download.dart` (zip handling, CORS
  fallback); wire `Create FOTA package` into the existing screen/slot; on-device verification
  (§6.5). (Additional non-GitHub source *types* remain future — the interface makes them cheap.)

Build **2a first**, then **2b**.

## 9. Error handling

- Mismatched/garbage inputs (not a valid firmware pair) → builder surfaces a clear error; never
  produce a silently-wrong package (the round-trip self-check in the builder can assert
  `apply(diff,old)==new` before emitting, failing loudly otherwise).
- `extraSafeSize` exceeding the device's `temp_cache` budget → encoder reports it (the package would
  be unflashable); cap/parameterize `maxExtraSafeSize`.
- Web GitHub download CORS failure → explicit message + local-bin fallback.
- `.zip` without an inner non-merged `.bin` → device-not-OTA-able-via-GitHub message; use local bin.

## 10. Out of scope (later)

- Pre-signed packages from the app (signing already exists at send time for raw packages).
- FFI/wasm native acceleration (only if the Dart matcher is ever too slow for large firmware —
  unlikely for delta sizes seen here).
- CORS proxy for web GitHub binary download (local-bin path makes web usable without it).
- Persistent catalog cache / refresh button (carried over from Step-1 notes).

## 11. Open questions (resolved at plan/impl time)

- Exact minimal `extraSafeSize` algorithm from `create_inplaceB_lite_diff` (study sisong/HPatchLite).
- Whether `package:archive` can emit raw DEFLATE bounded to a 512-byte window; if not, a small
  custom 512-window deflate or a verified alternative. (For tiny patches the window rarely binds.)
- Exact `.zip` internal layout for nRF release assets (verify it carries a raw `.bin`).
