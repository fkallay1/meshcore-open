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

- **2026-06-24 (HW E2E na TELEFÓNE cez BLE — doručenie OTA FUNGUJE; nájdený firmware APPLY bug)** —
  Debug APK (`flutter build apk --debug`) nainštalované cez adb na Android 13 (arm64). BLE companion
  flashnutý na Xiao (`Xiao_nrf52_companion_radio_ble`, COM3, **BLE PIN 123456**). Testovacie balíky
  pushnuté na `/sdcard/Download/` (`fw.otapkg.json` forward, `fw_reverse.otapkg.json` reverse).
  - **VÝSLEDOK (overené živým COM5 logom repeatera):** **telefón → BLE → companion → LoRa → repeater
    funguje.** Dorazia chunky 0–3 (CRC OK), META aj SIG, správny kanál (`#fkotanrf`/A4), rádio
    869.618/SF8, **base FW sedí** (B10CF39F=`lora_new`). Forward patch správne **odmietnutý**
    (`err=0x7` base mismatch). Keď sa session kompletizuje načerstvo a príde APPLY → **flash prebehol**.
  - **FIRMWARE BUG (NIE appka) — APPLY na už-VERIFIED session sa ignoruje:** keď najprv „Odoslať patch"
    (session sa skompletizuje + VERIFIED) a potom „Odoslať + APPLY", chunky/META/SIG (DUP) dorazia, ale
    **APPLY už neflashne**. Appka APPLY posiela správne (samostatný GRP_DATA paket `0x12`+sha32,
    `buildApply`, vždy pri applyAfter, vlastný rastúci ts → anti-dedup). Príčina je na repeateri:
    `../MeshCore/.../nrfota/OtaReceiver.cpp` — `try_verify_header()` má `if (total_chunks>0) return;`
    (už promované) + DUP chunky zrejme zhodia `OTA_ST_VERIFIED` a re-verify sa preskočí → `ota_apply()`
    odmietne (nie je VERIFIED). **Fix patrí do FW repa** (hand-off pripravený). App-strana je hotová,
    netreba meniť.
  - **Toolchain fakty (HW test):** adb je `D:\FkDev\00_Downloads\scrcpy-win64-v4.0\adb.exe` (nie v PATH);
    `flutter devices` vidí telefón (id `f161f715`). pio = `D:\FkDev\.platformio\penv\Scripts\pio.exe`;
    flash BLE: `pio run -d ../MeshCore -e Xiao_nrf52_companion_radio_ble -t upload --upload-port COM3`
    (pozor: ak Web Serial v Chrome drží COM3 → `Access denied`, najprv Disconnect). **COM3=companion,
    COM5=repeater.** Pri čítaní COM5 **DTR musí byť ON** (DTR off potlačí CDC výstup zariadenia).
    Repeater serial CLI má quirk: line terminátor necháva `\r` v args, takže `ota status` cez raw serial
    je nespoľahlivé (lepšie cez mesh admin CLI alebo to čítať z heartbeatu/živého logu).
  - **CORS na mobile:** neplatí (natívna appka nie je prehliadač) → auto-download z GitHubu na telefóne
    pôjde priamo (na webe treba „Stiahni FW" browser-download + pick). Mobil = reálna platforma.

- **2026-06-24 (po-2b ladenie: device list, triedenie/hľadanie, CORS web flow)** — Po HW teste na webe:
  - **Device list bol takmer prázdny — FIX:** `platformioIsNrf` hľadal len doslovný `NRF52_PLATFORM`,
    ktorý je v `[nrf52_base]` v KOREŇOVOM `platformio.ini`, nie v súboroch variantov. **34 nRF variantov**
    dedí `extends = nrf52_base` → teraz sa deteguje `nrf52_base` (alebo literál). promicro + ostatné OK.
  - **t1000-e nie je bug:** repeater release ho neobsahuje (Seeed T1000-E = tracker, nemá repeater FW).
  - **Triedenie** zariadení teraz **case-insensitive** (bol ASCII chaos). **Device picker = `DropdownMenu`
    s `enableFilter`** → píš a filtruje (34+ dosiek).
  - **Repo zdroj = dropdown** (meshcore-dev/MeshCore, fkallay1/MeshCore, Custom…). Custom odhalí voľné pole.
  - **CORS = problém IBA webu** (browser blokuje cross-origin *čítanie* binárky z `objects.githubusercontent.com`;
    download/navigácia OK; natívne appky CORS nemajú → mobil/desktop auto-download funguje priamo).
    **Web guided flow:** „⬇ Stiahni FW (current+target)" appka spustí browser-download presných súborov
    (`triggerBrowserDownload`, web-only cez `package:web`, conditional import), potom „Create FOTA package"
    otvorí multi-file picker a spáruje vybrané súbory na current/target podľa názvu. Lokálny picker berie
    `.bin` aj `.zip` (`extractFirmwareBinFromZip`). Proxy NETREBA (mobil = reálne použitie, web = testovanie).
  - Stav: `flutter test test/ota` 49/49, `flutter analyze lib` clean, `flutter build web` BUILDS.

- **2026-06-24 (FOTA package gen — STEP 2b hotový: source abstrakcia + download + wire)** —
  „Create FOTA package" zapojené → celá in-app príprava `.otapkg.json` HOTOVÁ. Subagent-driven TDD,
  4 tasky. Verified: `flutter test test/ota` **48/48**, `flutter analyze lib` clean, **`flutter build
  web` BUILDS**. Final whole-branch review (opus) = **Ready to merge: Yes** (žiadne Critical/Important).
  - **`OtaFwSource` interface** (`lib/ota/ota_fw_source.dart`) + `OtaGithubSource implements OtaFwSource`
    s **voliteľným `repo`** parametrom (default `meshcore-dev/MeshCore`, prepisateľný). Picker
    (`ota_fw_picker.dart`) konzumuje interface cez `sourceFactory(repo)` + **vždy viditeľné** custom-repo
    pole (funguje aj v error stave → typo v repo sa dá opraviť). Device-centric model ODLOŽENÝ.
  - **Downloader** (`lib/ota/ota_asset_download.dart`): `downloadFirmwareBin(url)` → GET; `.zip` → vnútorný
    **non-merged `.bin`** (cez `archive`); CORS/HTTP/zlý-zip → `OtaDownloadException`. Web-safe (žiadne
    `dart:io`).
  - **Wire** (`ota_screen.dart`): „Create FOTA package" (GitHub: stiahne current+target → builder →
    `_pkg` slot) + „Vyrob z lokálnych .bin" (2 lokálne `.bin`, vždy dostupné = web fallback pri CORS).
    Orientácia **current→target = old→new** (forward update) overená end-to-end. Zjednotený slot = rovnaký
    send flow ako manuálny picker.
  - **Build params generovaného balíka:** `#fkotanrf` idx1, `869.618/62.5/SF8/CR5`, scope/path z UI
    (rádio konfigurovateľnosť = future).
  - **HARD GATE (stále platí):** on-device `ota verify` (dry-run) na reálnom reverse-FW páre pred prvým
    `ota flash` — jediný non-Dart dekód encoder framingu. Manuálny HW krok.
  - **Follow-up (Minor, 2a-scope):** `buildOtaPkgJson` volá `createInplaceLiteDiff` 2× (self-check +
    staging) — pre veľký FW na UI isolate by stálo za dedup + `compute()` offload.

- **2026-06-24 (FOTA package gen — STEP 2a hotový: pure-Dart hpatchlite engine + builder)** —
  Generovanie `.otapkg.json` priamo v Darte (web/Android/iPhone, bez servera, device strana
  NETKNUTÁ). Subagent-driven TDD, 5 taskov. Verified: `flutter test test/ota` **41/41**,
  package `dart test` 12/12, `flutter analyze lib` clean, **`flutter build web` BUILDS**. Final
  whole-branch review (opus) = **Ready to merge: Yes** (žiadne Critical/Important).
  - **Nová reusable knižnica `packages/hpatchlite_dart/`** (pure Dart, **zero runtime deps**,
    publikovateľná). API: `createInplaceLiteDiff(old,new,{maxExtraSafeSize=0x4000})` +
    `applyInplaceLiteDiff(diff,old)`. Súbory: `src/codec.dart` (varint MSB-first + inplace header
    `hI`/compressType/packed/extraBytes, LE veľkosti, version code 2), `src/applier.dart` (port
    device `hpatch_lite.c`; device-verný `newPosBack==newSize`, podporuje aj sub-diff covery),
    `src/encoder.dart` (rolling-hash matcher, **pure-copy covery + literálne medzery**, terminálny
    zero-length cover, `extraSafeSize=max(0,max(newPos-oldPos))`, match len ak `newPos-oldPos≤budget`).
  - **App glue `lib/ota/ota_pkg_builder.dart`:** raw diff → DEFLATE (raw, **512 B okno**) → staged
    `['ZLIB'][uncomp u32le][newFw u32le][deflate]` (byte-layout ako `ota_sender.py`) → `.otapkg.json`
    (reuse `OtaPkg` schémy), so self-checkom `apply(diff,old)==new` pred emitnutím. Dep `archive`.
  - **Web-safe DEFLATE (dôležité):** `dart:io` NESMIE byť vo web import grafe → conditional export
    `ota_deflate.dart` → `_io.dart` (native `dart:io ZLibCodec(windowBits:9)`) / `_web.dart`
    (`archive Deflate(windowBits:9)`). **Overené že `archive Deflate(windowBits:9)` reálne capuje
    okno na 512** (max distance ≤250 podľa archive-4.0.9 zdroja; round-trip cez 512-window dekodér
    v `test/ota/ota_deflate_web_test.dart`). Vzor `if (dart.library.js_interop)` ako TCP/USB v projekte.
  - **Verifikačný reťazec (nie kruhový):** golden patch z `hdiffi.exe` cvičí sub-diff path (ktorý
    encoder NEemituje) → kotví applier proti C toolchainu; encoder round-trip používa ten overený
    applier ako oracle + in-place safety sim. `hdiffi.exe` v1.0.2 berie len `-inplace` (= inplace
    formát, version 2, extraSafeSize=0), nie `-inplaceB` — `ota_sender.py` má rovnaký fallback.
  - **HARD GATE pre 2b (pred prvým reálnym flashom):** on-device `ota verify` (dry-run) — jediný
    check, ktorý zatvorí poslednú medzeru (encoder framing dekódovaný NON-Dart dekodérom). Voliteľne
    aj PC cross-check: encoder-vyrobený diff cez referenčné `hpatchi`/`hdiffi.exe` (spec §6.3).
  - **Drobnosti do 2b (Minor):** `buildOtaPkgJson` volá `createInplaceLiteDiff` 2× (dá sa dedupnúť
    keď sa builder dotýka pri wire-i); matcher cap 8 kandidátov/hash = kompresia, nie korektnosť.

- **2026-06-24 (FOTA package prep — STEP 1 hotový: výber FW z GitHubu)** — Príprava `.otapkg.json`
  priamo v appke, cez subagent-driven TDD (spec + plán v `fkclaude/docs/superpowers/`). Step 1 =
  výberové UI; Step 2 (download + hdiff port + generovanie json) je samostatný plán. Verified:
  `flutter test test/ota` **36/36**, `flutter analyze lib` clean. Final whole-branch review (opus) =
  **Ready to merge: Yes.**
  - **Nové súbory:** `lib/ota/ota_fw_catalog.dart` (pure: parse názvov assetov, výber bin>zip>nič
    (nikdy uf2/merged), filename `<device>_<role>_v<cur>_to_v<tgt>.otapkg.json`, version sort, nRF
    detekcia `NRF52_PLATFORM`, `buildOtaCatalog`), `lib/ota/ota_github_source.dart` (IO: releases cez
    `api.github.com`, variant `platformio.ini` cez `raw.githubusercontent.com`, injectable
    `http.Client`, in-memory cache, `_getApi`/`_getRaw` split, anchored tag regex
    `^(?:repeater|room-server)-v(.+)$`), `lib/screens/ota_fw_picker.dart` (StatefulWidget: 4 dropdowny
    Rola/Zariadenie/Current/Target, defaulty role=Repeater, device=`promicro`, target=najnovší,
    current=predposledný; preview current+target assetu; injektovaný source).
  - **Zmena:** `lib/screens/ota_screen.dart` — navrch ExpansionTile „Priprav z GitHubu" s pickerom +
    tlačidlo „Create FOTA package" (zatiaľ `onPressed: null`, drží `_fwSelection` pre Step 2).
  - **Pre Step 2 (menované, nezabudnúť):**
    1. Zapojiť „Create FOTA package": download current+target assetu (`.zip` → vnútorný non-merged
       `.bin`), generovať `.otapkg.json`, načítať do zjednoteného „selected package" slotu.
    2. Port hdiffi/HPatchLite inplace delta (pure-Dart vs wasm vs FFI vs service — rozhodnúť).
    3. Web binárny download CORS mitigácia (api/objects.githubusercontent.com neposiela CORS).
    4. Perzistentný (SharedPreferences) cache katalógu + explicitné Refresh tlačidlo.
    5. Dep `archive` na zip extrakciu. Overiť že `.zip` reálne obsahuje raw `.bin` (nie len uf2).
    6. (review nice-to-have) bounded concurrency pri fetchovaní variant `platformio.ini` ak by
       `Future.wait` všetkých naraz robil problém; `_getRaw` 404 test; case-insensitive dedup zariadení.

- **2026-06-23 (UI: FOTA Broadcast + reuse OTA obrazovky + send-mode/timing voľby)** — OTA sa dá
  spustiť aj BEZ prihlásenia na repeater. Zmeny (verified: `flutter analyze lib` clean,
  `flutter test test/ota` 16/16, `flutter build web` OK):
  - **`ota_screen.dart` refaktor** — konštruktor `OtaScreen({required String headerTarget})`
    namiesto `repeater`+`password` (password sa aj tak nikde v tele nepoužíval; OTA je channel
    GRP_DATA broadcast, login netreba). Hlavička = `FOTA → <headerTarget>`. Obrazovka + celý send
    flow je teraz reusnutý pre oba vstupy, líši sa len header.
  - **Nové send-mode voľby** (mirror `ota_sender.py` CLI): scope dropdown **ZeroHop (default) /
    Flood / Direct(+path hex)**; pri `direct` sa zobrazí path TextField. Pri načítaní balíka sa
    prevezme `pkg.scope`/`pkg.pathHex` (default zerohop), user môže prepísať.
  - **Časovanie paketov** (mirror py): `delayMs` (--delay), `cycles` (--cycles, fire-and-forget
    opakovanie celého broadcastu, prijímač kumuluje), `headerEvery` (--header-every, redundancia
    META+SIG po N chunkoch). Pridané do `OtaSendConfig` + `OtaSender.send` (spätne kompatibilné:
    defaulty cycles=1/headerEvery=0 → identické správanie, staré testy prešli). `cycleDelayMs` tiež.
  - **Vstupy:** (1) repeater admin hub — dlaždica premenovaná `OTA update` → **`Setup FOTA Update`**,
    header `FOTA → <repeater.name>`. (2) **Settings → nová sekcia `FOTA Broadcast` za ACTIONS**,
    položka **`Setup FOTA Broadcast`**, header `FOTA → Broadcast`.
  - **Dotknuté súbory:** `lib/ota/ota_sender.dart` (+timing), `lib/screens/ota_screen.dart` (reuse+UI),
    `lib/screens/repeater_hub_screen.dart` (tile rename+call), `lib/screens/settings_screen.dart`
    (+sekcia+import), `test/ota/ota_screen_smoke_test.dart` (+Broadcast test), `test/ota/ota_sender_test.dart`
    (+cycles/headerEvery testy). Žiadne ARB zmeny (UI stringy literály ako zvyšok OTA modulu).

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
  - **VYRIEŠENÉ (2026-06-23) — bol to bug TEJTO appky, NIE firmvéru:** po `ota clear` + re-sende sa
    pakety zobrazili len ako RAW. Root cause: `ota_screen.dart` volal `OtaSender.send` BEZ `tsBase` →
    default `0` (`lib/ota/ota_sender.dart:35`). Sender robí `ts += 1` per paket, takže každá session
    štartovala ts od nuly (1,2,3,…). Pre nezmenený patch je `ota_payload` identický → šifrovaný plaintext
    `[ts4][ota_payload]` byte-identický pri každej session → rovnaký `packet_hash` (SHA256 typ‖payload,
    `MeshCore/src/Packet.cpp:41`) → MeshCore seen-table (160 položiek, `src/helpers/SimpleMeshTables.h`)
    to zahodí ako duplikát v `Mesh.cpp:227` ešte pred `onGroupDataRecv` → `logRxRaw` vypíše len `[OTA] RAW`.
    `ota clear` čistí len OTA receiver, NIE seen-table. Pôvodná hypotéza („`ota clear` odregistruje kanál")
    bola NESPRÁVNA — `_ota_ready` ostáva true, `searchChannelsByHash`/`MACThenDecrypt` bezstavové; firmware
    dedup robí korektne svoju prácu (dostáva reálne identické pakety). **Fix:** `ota_screen.dart` →
    `tsBase: DateTime.now().millisecondsSinceEpoch ~/ 1000` (epoch sekundy, uint32, ako `int(time.time())`
    v py senderoch). Stačí wall-clock, lebo rozostup re-sendov je ≥1 s. Firmvér nezmenený.

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
