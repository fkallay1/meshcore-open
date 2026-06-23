# fcl_readme_nrf-ota-flutterapp — pracovné poznámky (Fedor Kallay)

Pracovný/údržbový denník pre **nRF-OTA sender** vo Flutter appke (fork `fkallay1/meshcore-open`).
Čítaj na začiatku session. Dvojča pre firmvér je `../MeshCore/fkclaude/`.

> **TL;DR:** Forkli sme `zjs81/meshcore-open` (Flutter, MIT) a pridávame nRF52840 LoRa
> **delta-patch OTA odosielač** + OTA admin quick-commands. Appka cez BLE/USB/WiFi posiela
> companionu rovnaké `CMD_*` rámce ako `meshcore_py`; OTA je byte-exact port `ota_sender.py`.

---

## 1. Čo to je a prečo fork

Cieľ: z telefónu (BLE/USB/WiFi → companion) spustiť LoRa delta-patch update nRF52840 repeatera
+ admin terminál do repeatera. Namiesto písania od nuly **forkujeme meshcore-open**, ktorý už má
transporty, connection UI a repeater CLI. Naša práca = pridať OTA modul + jeden frame (CMD 62).

**Dva režimy appky:** (1) OTA odosielač, (2) admin/debug terminál (companion panel + relay
textových príkazov do repeatera — reuse `repeater_cli_screen`).

## 2. Kde je čo

| | |
|---|---|
| **Spec** | `fkclaude/docs/superpowers/specs/2026-06-23-mc-fotanrf-flutterapp-design.md` |
| **Plán** (task-by-task, TDD) | `fkclaude/docs/superpowers/plans/2026-06-23-nrf-ota-sender.md` |
| **Konvencie + cross-ref** | `CLAUDE.md` → sekcia „FK fork — nRF-OTA sender" |
| **Firmvér / wire formát** | `../MeshCore` (súrodenec na disku) |

OTA referenčný kód (čítaj absolútnou cestou):
- **`../MeshCore/test_nrf-ota/ota_sender.py`** — autoritatívny wire formát (META 102B / SIG 99B /
  chunk / APPLY, CRC16/CCITT-FALSE, framing). Toto portujeme byte-for-byte.
- `../MeshCore/test_nrf-ota/ota_sender_mcpy.py` — companion-relay variant (CMD 62, ts4+payload).
- `../MeshCore/examples/companion_radio/MyMesh.cpp` — companion `CMD_*` kódy.
- `D:\FkDev\FkProj\VSC\meshcore_py` — referenčná impl protokolu (overuj framing 1:1).
- `../MeshCore/fkclaude/fcl_readme_tech_nrf-ota.md` — hĺbkový popis OTA systému.

## 3. Architektúra (fork + OTA stĺpec)

Reuse `MeshCoreConnector` (BLE/USB/TCP, `sendFrame`, `setChannel`, `repeater_cli_screen`).
Pridávame navrch:
- `meshcore_protocol.dart` **+1** `buildSendChannelDataFrame` (`cmdSendChannelData=62`).
- `lib/ota/`: `ota_types.dart` (konšt., `OtaJob`, CRC16), `ota_payload_builder.dart`
  (META/SIG/chunk/APPLY + Ed25519 cez **pointycastle**), `otapkg.dart` (.otapkg.json parser),
  `ota_sender.dart` (session: setRadio→setChannel→chunky→META/SIG→APPLY, hend poradie, ts++).
- `lib/services/ota_key_store.dart` (Ed25519 seed z DER + secure storage).
- `lib/screens/ota_screen.dart` (výber .otapkg, progress, send/apply) + vstup z `repeater_hub`.
- OTA quick-commands (`ota status`/`ota verify`) v `repeater_cli_screen`.

**Hranica `PatchSource`/`OtaJob`** je zachovaná pre **fázu B** (on-device hdiff cez FFI HPatchLite)
— vtedy sa vymení len `PatchSource`, vrstvy nad ním ostanú.

## 4. Kľúčové fakty (aby som ich znova nehľadal)

- **Transport rámce sú identické cez BLE/USB/TCP** — connector `sendFrame(Uint8List)` to rieši.
- **CMD_SEND_CHANNEL_DATA=62** chýba v meshcore-open (konšt. končia na 61) — to je jediný nový frame.
  Layout: `[62][channel_idx][path_len][path][data_type u16le=0x07A0][data]`, `data=[ts u32le][ota_payload]`, `len(data)≤165`.
- **Radio jednotky:** companion očakáva `int(freq_MHz*1000)` a `int(bw_kHz*1000)` (4B LE) →
  `869.618→869618`, `62.5→62500`. (`buildSetRadioParamsFrame(freqVal,bwVal,sf,cr)` — názov `freqHz` je zavádzajúci.)
- **Ed25519:** `pointycastle ^4.0.0` (už dep). Musí dať RFC8032 podpis zhodný s pycryptodome
  `eddsa 'rfc8032'` — overené golden vektorom (`test/fixtures/ota_golden.json`).
- **State = Provider** (`Provider.of<MeshCoreConnector>(context, listen:false)`), nie Riverpod.
- **Nové deps:** `file_picker`, `flutter_secure_storage`. Už sú: `pointycastle`, `crypto`, `provider`, `path_provider`.
- **`.otapkg.json`** z PC (`ota_export_pkg.py`) podporuje **pre-signed** (`signed{}` → kľúč netreba)
  aj **raw** (appka podpíše importovaným kľúčom). Kanál `#fkotanrf`, default scope `zerohop`.
- Companion `CMD_SET_RADIO_PARAMS=11`, `CMD_SET_CHANNEL=32`, `CMD_SEND_CHANNEL_DATA=62`,
  `CMD_SEND_LOGIN=26`, `CMD_SEND_TXT_MSG=2`.

## 5. Portable Flutter toolchain (ešte nenainštalované)

Upstream CLAUDE.md používa `~/flutter/bin/flutter` (portable SDK). Setup (pod `D:\FkDev\tools\`):
- Flutter stable zip → `D:\FkDev\tools\flutter`, `flutter\bin` do PATH.
- Android „command line tools only" zip → `D:\FkDev\tools\android-sdk\cmdline-tools\latest\`,
  `ANDROID_SDK_ROOT=...\android-sdk`. `sdkmanager "platform-tools" "platforms;android-34" "build-tools;34.0.0"` + `--licenses`.
- JDK zip → `JAVA_HOME` (alebo `flutter config --jdk-dir`).
- `flutter config --android-sdk ...android-sdk` → `flutter doctor` (zelený).
- Build na fyzickom telefóne cez USB (USB debugging). Fáza B (FFI) pridá `ndk;...`.
- VS Code: rozšírenia Dart + Flutter (integrovaný hot reload/debug).

## 6. Stav / work-log

- **2026-06-23** — Brainstorming → spec → plán hotové (v `fkclaude/docs/superpowers/`; pôvodne
  omylom v `docs/fotanrf/`, opravené per konvencia). Rozhodnutia: fork
  meshcore-open; transporty BLE/USB/WiFi (reuse); `.otapkg` pre-signed+raw; Ed25519 cez pointycastle;
  fáza B = FFI hdiff neskôr. **Naklonované** `fkallay1/meshcore-open` → `D:\FkDev\FkProj\VSC\meshcore-open`,
  `upstream=zjs81/meshcore-open`, vetva `feature/nrf-ota-sender`. CLAUDE.md naviazaná, fkclaude/ +
  tieto poznámky + pamäť nastavené. **Ďalší krok:** nainštalovať portable Flutter (`flutter doctor`
  zelený), potom exekúcia plánu (Task 1→11, subagent-driven), testy reálne pobežia.

## 7. Otvorené / pozor

- Flutter SDK ešte nie je nainštalovaný → `flutter test`/`analyze` kroky prejdú až potom.
- pointycastle Ed25519 presné názvy tried potvrdí golden gate (Task 5).
- `Contact` getter-y (advName/publicKeyHex) over proti `repeater_hub_screen.dart` (Task 10).
- Kolízia channel indexu: OTA použije idx z .otapkg — môže prepísať user kanál; v OTA obrazovke
  zobrazené, „safe index" picker je budúce vylepšenie.
- `agc_reset_interval=0` na repeateri počas OTA flash (viď `../MeshCore/fkclaude/fcl_readme_tech_nrf-ota.md` §8.4).
