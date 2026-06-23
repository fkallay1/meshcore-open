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

- **2026-06-23 (E2E na HW — OTA cez appku FUNGUJE)** — Toolchain nainštalovaný (pozri §6b).
  Companion firmvér nahraný na Xiao nRF52840 (`Xiao_nrf52_companion_radio_usb`, COM3); pôvodne tam bol
  repeater/bridge text-CLI firmvér. Appka beží ako **web** (`flutter build web` → statický server
  `localhost:8085`, Web Serial v Chrome — náš kód má `usb_serial_service_web.dart`). **Connect na
  companion cez appku ide, OTA odoslanie cez appku FUNGUJE** (užívateľ potvrdil). E2E overené aj
  cez `ota_sender_mcpy.py` (companion-relay = byte-exact to isté čo appka): chunky+META+SIG dorazia
  na repeater (COM5, RSSI −18), CRC OK.
  - **KĽÚČOVÉ: mesh beží na `869.618/SF8`** (default firmvéru), NIE 869.525/SF7 — `.otapkg` musí mať
    tieto rádio params (appka podľa nich nastaví companion). `fw.otapkg.json` aj `fw_reverse.otapkg.json`
    v `../MeshCore/test_nrf-ota/` regenerované na 869.618/SF8.
  - **base-FW kontrola repeatera funguje správne:** forward patch (base=lora_old C24A73E0) repeater
    odmietol, lebo beží `lora_new` (B10CF39F) → `CHYBA=0x7`. Pre úspešný apply slúži **reverzný**
    patch `fw_reverse.otapkg.json` (base=lora_new=čo beží).
  - **Companion z PC (build env):** `Xiao_nrf52_companion_radio_usb`; flash `pio run -e ... -t upload
    --upload-port COM3` (1200-touch → bootloader COM6 → DFU, auto). Web app test = užívateľ klikne v
    prehliadači (Web Serial gesto), ja browser neriadim.
  - **ZNÁMY FIRMVÉROVÝ BUG (rieš v MeshCore session, NIE tu):** po `ota clear` + opätovnom odoslaní sa
    pakety nespracujú cez OTA logiku, zobrazia sa len ako RAW. Firmvér: `../MeshCore/examples/simple_repeater/`
    — gate `MyMesh.cpp:883–887` (`if dtype!=OTA_MAGIC return`), `ota clear` v `nrfota/OtaMesh.cpp:52`,
    receiver `nrfota/OtaReceiver.cpp`, stav `nrfota/OtaState.h`. Hypotéza: `ota clear` odregistruje OTA
    kanál / zhodí armed flag → GRP_DATA sa nematchne na kanál → RAW. Oprava: bezstavový OTA routing.

- **2026-06-23** — Brainstorming → spec → plán hotové (v `fkclaude/docs/superpowers/`; pôvodne
  omylom v `docs/fotanrf/`, opravené per konvencia). Rozhodnutia: fork
  meshcore-open; transporty BLE/USB/WiFi (reuse); `.otapkg` pre-signed+raw; Ed25519 cez pointycastle;
  fáza B = FFI hdiff neskôr. **Naklonované** `fkallay1/meshcore-open` → `D:\FkDev\FkProj\VSC\meshcore-open`,
  `upstream=zjs81/meshcore-open`, vetva `feature/nrf-ota-sender`. CLAUDE.md naviazaná, fkclaude/ +
  tieto poznámky + pamäť nastavené.

- **2026-06-23 (exekúcia plánu Task 1→11)** — Flutter STÁLE nenainštalovaný → Dart kód napísaný,
  ale `flutter pub get/test/analyze` ODLOŽENÉ. Čo prebehlo:
  - **Task 1** ✓ pubspec +`file_picker ^8.1.2`,`flutter_secure_storage ^9.2.2` (po pointycastle);
    README derivative note. (`pub get`/`analyze` odložené.)
  - **Task 2** ✓ **REÁLNE OVERENÉ** — `emit_ota_golden.py` (v MeshCore `test_nrf-ota/tools/`) spustený
    cez **PlatformIO penv** (`D:\FkDev\.platformio\penv\Scripts\python.exe`, má pycryptodome 3.23.0).
    `test/fixtures/ota_golden.json` (META=102B, SIG=99B, chunk=157B, APPLY=33B) + `test_ed25519_seed.hex`.
    Byte-skontrolované: META `1000`+patch_size LE, SIG `1300`, frame `3e0100a007`+ts+META.
  - **Task 3–8** ✓ kód napísaný: `lib/ota/ota_types.dart` (CRC16, OtaJob, konšt.),
    CMD62 builder v `meshcore_protocol.dart`, `ota_payload_builder.dart`, `otapkg.dart`,
    `ota_sender.dart`, `lib/services/ota_key_store.dart` + testy. Testy ZATIAĽ NESPUSTENÉ.
  - **Task 9** ✓ **REÁLNE OVERENÉ** — `ota_export_pkg.py` (MeshCore) + pytest roundtrip
    `test_export_pkg.py` **PASSED** (hdiffi.exe prítomný).
  - **Task 10** ✓ `ota_screen.dart` + hub dlaždica (v `isAdmin` bloku, index 5) + smoke test.
  - **Task 11** ✓ OTA quick-commands `ota status`/`ota verify` v `repeater_cli_screen.dart`
    (cez `default: return key` fallback, žiadne ARB zmeny) + `fkclaude/docs/e2e-checklist.md`.
  - **Odchýlky od plánu (overené proti upstream kódu):**
    1. `Contact` má `.name`, NIE `.advName` → `ota_screen` používa `repeater.name`.
    2. `MeshCoreConnector` NEMÁ `setChannel(idx,name,psk)` → adapter `_ConnectorOtaSink.setChannel`
       posiela `c.sendFrame(buildSetChannelFrame(idx,name,psk))`.
    3. otapkg_test „corrupted hash" test prepísaný: poškodzuje deklarovaný `patch_sha256`
       (trafí `OtaPkgException`), nie `patch_len` (ten by hodil `TypeError`).
  - **Commity:** meshcore-open 9 commitov na `feature/nrf-ota-sender`; MeshCore 2 commity
    (emitter + export tool). Pushnuté: pozri §6 ďalší riadok po push.

## 6b. VERIFIKÁCIA — HOTOVÁ A ZELENÁ (2026-06-23)

Portable Flutter **nainštalovaný** pod `D:\FkDev\Tools` (Flutter 3.44.3 / Dart 3.12.2, JDK 17,
android-sdk: platform-36, build-tools 36.0.0, NDK 29.0.14206865). Výsledky:
- **`flutter test test/ota` → 13/13 PASS.** Vrátane **golden-gate `buildSig`**: Ed25519 podpis
  z **pinenacl** je byte-identický s pycryptodome `rfc8032` (golden `sig_hex`). ✅
- **`flutter analyze` (OTA súbory) → No issues found.** ✅

### Zmeny deps oproti pôvodnému plánu (predpoklady plánu boli mylné — odhalil `pub get`/test)
- **Ed25519:** `pointycastle 4.0.0` Ed25519 VÔBEC NEMÁ (len OID v databáze). → `OtaPayloadBuilder.signMeta`
  prepísané na **`pinenacl ^0.6.0`** (TweetNaCl, synchrónne, Dart3). `ed25519_edwards` zamietnuté
  (SDK `<3.0.0`). API: `nacl.SigningKey(seed: seed32).sign(meta).signature`.
- **Výber súboru:** `file_picker` (každá verzia → `win32 ^5`) koliduje s upstream `package_info_plus`
  (`win32 ^6`). win32 override rozbil `file_picker_windows` (HRESULT). → **`file_selector ^1.1.0`**
  (`file_selector_android` endorsed; `file_selector_windows` win32 nepoužíva). Override ODSTRÁNENÝ.
  `ota_screen._pickPkg` teraz `openFile(acceptedTypeGroups:[XTypeGroup(extensions:['json','otapkg'])])`.
- **Secure storage:** `flutter_secure_storage ^9.2.2 → ^10.3.1` (10.x ťahá `fss_windows 4.2.x` =
  `win32 ^6`, kompatibilné). API `read/write/delete` rovnaké.
- `pubspec.lock` je **gitignored**. Desktop `generated_plugin_registrant.*` sa regenerovali (nové pluginy).

### Toolchain fakty (aby som znova nehľadal)
- **Python s pycryptodome = PlatformIO penv:** `D:\FkDev\.platformio\penv\Scripts\python.exe`
  (pycryptodome 3.23.0). Default `python` (platformio python3) NEMÁ pip.
- **Flutter portable:** `D:\FkDev\Tools\flutter\bin`. Aktivácia session: `. "$env:DEV_ROOT\Tools\flutter-env.ps1"`.
  VS Code: `D:\FkDev\VSCode\data\user-data\User\settings.json` má `dart.flutterSdkPath` +
  `terminal.integrated.env.windows` (cez `${env:DEV_ROOT}`).
- **APK build vyžaduje Windows „Developer Mode"** (symlink support pre pluginy) — `start ms-settings:developers`.
  Bez neho `flutter build apk`/`run` zlyhá; `flutter test` (pure Dart) beží aj bez neho.

## 7. Otvorené / pozor

- Flutter SDK ešte nie je nainštalovaný → `flutter test`/`analyze` kroky prejdú až potom.
- pointycastle Ed25519 presné názvy tried potvrdí golden gate (Task 5).
- `Contact` getter-y (advName/publicKeyHex) over proti `repeater_hub_screen.dart` (Task 10).
- Kolízia channel indexu: OTA použije idx z .otapkg — môže prepísať user kanál; v OTA obrazovke
  zobrazené, „safe index" picker je budúce vylepšenie.
- `agc_reset_interval=0` na repeateri počas OTA flash (viď `../MeshCore/fkclaude/fcl_readme_tech_nrf-ota.md` §8.4).
