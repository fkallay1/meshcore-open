# nRF-OTA Flutter — on-device E2E checklist

Pre-reqs: companion (Xiao nRF52 / ESP32) flashed; OTA repeater (`ProMicro_repeater_ota`)
running; `agc_reset_interval = 0` (see fcl_readme_tech_nrf-ota §8.4); a `fw.otapkg.json`
built on PC via `ota_export_pkg.py`.

1. Connect to the companion (BLE: pair with 6-digit PIN / USB / WiFi). Confirm "connected".
2. Open repeater → Hub → "OTA update". Pick the `.otapkg.json`. Verify the summary
   (chunk count, channel, radio, signed=yes/no) matches the PC export log.
3. (raw pkg only) Import the Ed25519 key once if signed=no.
4. Tap "Odoslať patch" (no APPLY). Watch the progress bar reach 100%.
5. In the repeater CLI screen, run `ota status` → expect recv count rising to total, then
   VERIFIED. Run `ota verify` (dry-run) → expect SHA OK.
6. Tap "Odoslať + APPLY" (or send `ota flash` from CLI). Repeater reboots into the new build;
   confirm the new build number.
7. Repeat over USB and WiFi transports to confirm transport-agnostic behaviour.
8. Record pass/fail + build numbers (mirrors the Python E2E history in fcl_readme_tech_nrf-ota §10).
