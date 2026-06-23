# mc_fotanrf_flutterapp — design spec

**Dátum:** 2026-06-23
**Autor:** Fedor Kallay (návrh s Claude Code)
**Status:** návrh na review

Flutter (Android-first) appka, ktorá sa pripojí na **MeshCore companion** **rovnakými
spôsobmi ako štandardná MeshCore appka — BLE, USB serial aj WiFi** (`Xiao_nrf52_companion_radio_usb`
a ESP32 companion varianty) a slúži ako:

1. **nRF-OTA odosielač** — z telefónu spustí LoRa delta-patch update repeatera
   (replika `test_nrf-ota/ota_sender_mcpy.py`, ale cez BLE namiesto USB serial).
2. **Admin/debug terminál** — companion `CMD_*` panel **a** relay textových admin
   príkazov do vzdialeného repeatera, so zobrazením odpovedí.

Projekt je **samostatné repo** vedľa MeshCore: `D:\FkDev\FkProj\VSC\mc_fotanrf_flutterapp`.

## 0. Východisko — fork `zjs81/meshcore-open` (MIT)

**Nestaviame od nuly.** Forkneme [`zjs81/meshcore-open`](https://github.com/zjs81/meshcore-open)
(Flutter 3.38 / Dart 3.10, MIT, v9.5.0) — zrelú MeshCore appku, ktorá už má hotové takmer
všetko, na čom by sme inak stavali. Naša práca = **pridať OTA + jeden chýbajúci frame**.

| Potreba | Stav v meshcore-open | Naša práca |
|---------|----------------------|------------|
| BLE / USB / WiFi transport | ✅ `lib/connector/meshcore_connector{,_usb,_tcp}.dart` | — (reuse) |
| Connection UI (scan/usb/tcp) | ✅ `scanner_screen` / `usb_screen` / `tcp_screen` | — (reuse) |
| Admin terminál do repeatera | ✅ `repeater_cli_screen` + `RepeaterCommandService` (login + txt + history + quick-cmds) | pridať OTA quick-cmds (`ota status`/`verify`) |
| `setRadio` / `setChannel` | ✅ `cmdSetRadioParams=11`, `cmdSetChannel=32`, `setChannel(idx,name,psk)` | — (reuse) |
| Companion panel / stats | ✅ `companion_radio_stats_screen`, `device_query` | — (reuse) |
| **`CMD_SEND_CHANNEL_DATA=62`** | ❌ konštanty končia na 61 | **pridať `buildSendChannelDataFrame`** |
| **OTA payloady + session** | ❌ | **pridať `lib/ota/`** (META/SIG/chunk/APPLY, OtaSender) |
| **`.otapkg` + Ed25519** | ❌ | **pridať** (OtaPkg parser, podpis) |
| **OTA obrazovka** | ❌ | **pridať** `ota_screen` (z `repeater_hub`) |

**Scaffold:** FK už forkol meshcore-open do svojho GitHub repa. Klonujeme **z FK forku**
(`origin`) a pridáme `upstream` = `zjs81/meshcore-open` → `git pull upstream` na novinky.
**Zachovávame pôvodný názov appky** (`meshcore_open` v `pubspec.yaml`, package, atď.) — NIE
premenovať na fork-názov — aby diffy voči upstreamu ostali minimálne (ľahké preberanie zmien
aj prípadný contribute back). OTA píšeme do oddelených súborov → konflikt len na 1 riadku.

**Licencia/attribution:** zachováme `LICENSE` (MIT, © 2025 zjs81), doplníme náš © a v README
označíme derivative.

**Connection rozhranie „ako štandardná appka"** (požiadavka FK) = splnené z definície, lebo
appka JE odvodená od štandardnej MeshCore appky — scan/usb/tcp obrazovky reusujeme 1:1.

---

## 1. Kľúčové fakty o transporte

**Ten istý binárny frame protokol beží cez všetky tri transporty** — preto `meshcore_py`
funguje cez serial aj BLE bez zmeny logiky. Appka podporuje (ako štandardná MeshCore appka):

| Transport | Companion HW | Dart implementácia | Pozn. |
|-----------|--------------|--------------------|-------|
| **BLE (NUS)** | nRF52 (Xiao) + ESP32 | `flutter_blue_plus` | Nordic UART Service, **MITM párovanie cez 6-cif. PIN** (`SerialBLEInterface.cpp`) |
| **USB serial** | nRF52 (USB CDC) + ESP32 | `usb_serial` (Android USB-OTG) | 115200 baud; framing `BaseSerialInterface` |
| **WiFi (TCP)** | ESP32 (`SerialWifiInterface`) | `dart:io Socket` | TCP socket na companion IP:port |

Companion si **AES-128-ECB + HMAC + LoRa routing rieši sám**; appka NEROBÍ transportné krypto
na žiadnom z transportov. Rozdiel medzi transportmi je len **ako sa frame dostane dnu/von** —
preto sú schované za jedno `CompanionTransport` rozhranie (§3) a všetky vrstvy nad ním
(`CompanionCommands`, `OtaSender`, terminál) sú transport-agnostické.

**Companion CMD kódy** (z `examples/companion_radio/MyMesh.cpp`, overené 2026-06-23):

| CMD | kód | účel | odpoveď |
|-----|-----|------|---------|
| `CMD_APP_START` | 1 | handshake po connecte | `RESP_CODE_SELF_INFO` = 5 |
| `CMD_DEVICE_QUERY` | 22 | verzia/typ zariadenia | `RESP_CODE_DEVICE_INFO` = 13 |
| `CMD_GET_CONTACTS` | 4 | zoznam kontaktov | `RESP_CODE_CONTACTS_START`/`CONTACT`/`END` = 2/3/4 |
| `CMD_SET_RADIO_PARAMS` | 11 | freq/bw/sf/cr | OK/ERROR |
| `CMD_SET_CHANNEL` | 32 | idx + meno kanála | OK/ERROR |
| `CMD_SEND_CHANNEL_DATA` | 62 | GRP_DATA datagram (OTA transport) | OK/ERROR |
| `CMD_SEND_LOGIN` | 26 | login do repeatera (admin) | (async push) |
| `CMD_SEND_TXT_MSG` | 2 | text príkaz vzdialenému repeateru | `RESP_CODE_SENT` = 6 |
| `CMD_REBOOT` | 19 | reboot companion | — |

> Presný byte-layout každého rámca sa pri implementácii overí **1:1 proti
> `D:\FkDev\FkProj\VSC\meshcore_py`** (je priamo vedľa). meshcore_py je referenčná
> implementácia toho istého protokolu.

**OTA transport frame** (`CMD_SEND_CHANNEL_DATA`, z `ota_sender_mcpy.py`):

```
[62][channel_idx][path_len][path...][data_type 2B LE][data...]
   kde data = [ts 4B LE][ota_payload]      a   data_type = OTA_MAGIC = 0x07A0
   limit: len(data) ≤ 165  (GRP_DATA)
   scope→(path_len,path): zerohop=(0,""), flood=(0xFF,""), direct=(N, N×1B hash)
```

---

## 2. OTA protokol (zjednotený formát v0 — z `ota_sender.py`)

Konštanty (musia byť **bajtovo zhodné** s firmware, inak repeater odmietne):

```
OTA_MAGIC       = 0x07A0      OTA_PROT_INF_V0 = 0x00      OTA_CHUNK_DATA = 144
OTA_PKT_HEADER  = 0x10   CHUNK = 0x11   APPLY = 0x12   HDR_SIG = 0x13
OTA_PKT_STATUS  = 0x20   NACK  = 0x21   (spätný kanál)
OTA_ST_VERIFIED = 0x04   OTA_ST_ERROR = 0x80
```

Payloady (čistý Dart port):

- **META (102B)** = `[0x10][0x00] + patch_size(4B LE) + patch_sha256(32B) + new_sha256(32B) + old_sha256(32B)`
- **SIG (99B)** = `[0x13][0x00] + old_sha256(32B) + key_id(1B) + signature(64B)`
  — Ed25519 podpis nad 102B META; bez kľúča = 64×`0x00`.
- **CHUNK** = `[0x11] + idx(2B LE) + crc16(data)(2B LE) + old_fw_size(4B LE) + old_sha256_prefix(4B) + data(≤144B)`
  — CRC16/CCITT-FALSE (init 0xFFFF, poly 0x1021).
- **APPLY** = `[0x12] + patch_sha256(32B)`

Poradie odoslania (default ako `ota_sender_mcpy.py`): `packetorder=hend` → chunky, potom
META+SIG, potom voliteľne APPLY (ak `--reboot`). `ts` rastie o 1 každý paket (anti-dedup).
`delay` medzi paketmi (default 0.3 s).

---

## 3. Architektúra — naše OTA vrstvy na existujúcom connectore

meshcore-open už má transport + protokol + UI. **Pridávame len OTA stĺpec** navrch jeho
`MeshCoreConnector` (ktorý už abstrahuje BLE/USB/TCP a vystavuje `sendFrame`).

```
   [REUSE: meshcore-open]                    [NOVÉ: naše OTA]
   scanner/usb/tcp_screen                    ota_screen  (z repeater_hub)
   repeater_cli_screen ──────┐                   │
                             │              OtaSender   ← session: setRadio→setChannel→
   MeshCoreConnector         │                   │         chunky→META/SIG→APPLY, pacing
   (BLE/USB/TCP, sendFrame,  │              OtaPayloadBuilder  ← META/SIG/chunk/APPLY,
    setRadio, setChannel,    │                   │              crc16, Ed25519, sha256
    sendLogin, sendText) ◄───┼───────────── PatchSource  ← OtaJob{patch,old_sha,new_sha,
        │                    │              (A: OtaPkg;       old_fw_size,[meta,sig]}
        │                    │               B: FFI hdiff)
   meshcore_protocol.dart    │
   (+ buildSendChannelDataFrame  ← JEDINÝ nový frame, cmd 62)
        │
   transport impls (flutter_blue_plus / usb_serial / dart:io Socket)
```

| Modul | Reuse / Nové | Zodpovednosť |
|-------|--------------|--------------|
| `MeshCoreConnector` (+`_usb`/`_tcp`) | **reuse** | transport (BLE/USB/TCP), `sendFrame`, `setRadio`, `setChannel(idx,name,psk)`, `sendLogin`, `sendText`, parsing odpovedí |
| `meshcore_protocol.dart` | **+1 fn** | doplniť `buildSendChannelDataFrame(idx, pathLen, path, dataType, data)` (cmd 62) + `cmdSendChannelData=62` |
| `OtaPayloadBuilder` | **nové** | čistý Dart: META/SIG/chunk/APPLY, CRC16, Ed25519 podpis (`cryptography`), SHA256 |
| `PatchSource` | **nové** | interface → `OtaJob`. Fáza A: `OtaPkgPatchSource`. Fáza B: `FfiHdiffPatchSource` |
| `OtaSender` | **nové** | session: `setRadio` → `setChannel` → (chunky → META/SIG → APPLY), scope→path, pacing, progress |
| `ota_screen` | **nové** | vyber `.otapkg`, prehľad (old/new sha, počet chunkov), tlačidlá Send / Send+APPLY, progress bar, log |
| terminál (`repeater_cli_screen`) | **reuse +** | pridať OTA quick-commands (`ota status`, `ota verify`) k existujúcim |

**Tok OTA:** `PatchSource → OtaJob → OtaPayloadBuilder → [payloads] → OtaSender` zabalí každý
ako `[ts4][payload]` → `buildSendChannelDataFrame(0x07A0,…)` → `MeshCoreConnector.sendFrame`
→ (BLE/USB/TCP) → companion šifruje + LoRa TX.

> Companion `CMD_*` kódy (§1) overím proti `meshcore-open` (Dart, vedľa nás) aj `meshcore_py` —
> obe sú referenčné implementácie toho istého protokolu.

---

## 4. Fáza A — zdroj patchu: `.otapkg.json`

PC vygeneruje balík; appka ho načíta (file picker / share). Podporuje **pre-signed aj raw**
(rozhodnutie 2026-06-23):

```jsonc
{
  "format": "mc-fotanrf-otapkg/1",
  "created": "2026-06-23T12:00:00Z",
  "channel": { "name": "#fkotanrf", "idx": 1 },
  "radio":   { "freq": 869.618, "bw": 62.5, "sf": 8, "cr": 5 },
  "scope":   "zerohop",                 // zerohop | flood | direct
  "path":    "",                        // direct: hex hashe hopov (1B each)
  "fw": {
    "old_sha256": "<hex64>",
    "new_sha256": "<hex64>",
    "old_fw_size": 442000,
    "patch_sha256": "<hex64>",          // staged patch sha (appka si overí)
    "patch_len": 1234
  },
  "patch_b64": "<base64 staged patch>", // formát [ZLIB][uncomp 4B][new_fw 4B][deflate]
  "signed": {                           // VOLITEĽNÉ — ak prítomné → pre-signed
    "key_id": 1,
    "meta_b64": "<102B>",
    "sig_b64":  "<99B>"
  }
}
```

- `signed` **prítomné** → appka použije META/SIG priamo (replayer, kľúč netreba).
- `signed` **chýba** → appka zostaví META z `fw.*` a **podpíše** importovaným Ed25519
  kľúčom (key_id z nastavení appky). Ak kľúč nie je importovaný → SIG nulový (warning, ako
  v `ota_sender_mcpy.py`).
- Chunky appka vždy reže z `patch_b64` (kľúč na to netreba).

**PC export nástroj:** nový `test_nrf-ota/ota_export_pkg.py --old --new [--privkey --keyid]
--out fw.otapkg.json`. Znovupoužije `make_patch` + `build_meta_payload`/`build_sig_payload`
z `ota_sender.py`. S `--privkey` doplní `signed{}`. **Toto je jediná zmena v MeshCore repe.**

**Ed25519 kľúč v appke** (pre raw režim): import DER/PEM cez file picker → `flutter_secure_storage`.
Pozn.: `test_nrf-ota/test_key.der` je gitignored.

---

## 5. Fáza B (neskôr) — on-device patch

Len výmena `PatchSource` za `FfiHdiffPatchSource`:
- HPatchLite `hdiffi` (create-diff, inplaceB) skompilovaný cez **Dart FFI** (Android `.so` cez NDK).
- zlib `raw DEFLATE wbits=-9` → Dart `ZLibCodec(raw:true, windowBits:9, level:9)`.
- staged formát `[ZLIB][uncomp 4B][new_fw 4B][deflate]` (zhodný s `make_patch`).
- vstup: dva `.bin` z file pickera; výstup: `OtaJob` (sha256 počíta on-device).

Žiadny prepis vrstiev nad `PatchSource`. iOS sa rieši až tu (FFI build friction).

---

## 6. Terminál

**Repeater relay = reuse `repeater_cli_screen` + `RepeaterCommandService`** (už hotové vo
forku): login → text príkaz → odpoveď + history + quick-commands. **Pridáme** len OTA
quick-commands (`ota status`, `ota verify`) k existujúcim (`advert`, `get radio`, `ver`…).
OTA `flash`/`reboot` ostáva primárne cez APPLY paket z OTA obrazovky.

**Companion panel/stats** = reuse `companion_radio_stats_screen` + existujúce `deviceQuery`/
`getContacts`/`setRadio`/`setChannel`. Raw hex frame send je voliteľné navyše (nice-to-have).

---

## 7. Závislosti (pubspec)

**Zdedené z meshcore-open** (netreba pridávať): `flutter_blue_plus` (BLE), USB connector,
TCP (`dart:io`), `provider` (stav), `crypto` (SHA256), **`pointycastle`** (Ed25519), `path_provider`.

**Pridáme len:** `file_picker` (výber `.otapkg` + kľúča) · `flutter_secure_storage` (Ed25519 kľúč).
Stav riešime cez **Provider** (zladené s forkom, NIE Riverpod). Ed25519 cez **pointycastle**
`Ed25519Signer`/`Ed25519` (existujúca dep) — RFC8032, zhodu s pycryptodome overí golden vektor.
Fáza B pridá `ffi` + natívnu HPatchLite knižnicu.

---

## 8. Súborový layout

Forknutý strom meshcore-open ostáva; **pridávame** (✚) / **upravujeme** (✎):

```
lib/
  connector/
    meshcore_connector.dart        ← reuse
    meshcore_protocol.dart         ✎ + buildSendChannelDataFrame, cmdSendChannelData=62
  screens/
    scanner_screen / usb_screen / tcp_screen   ← reuse (connection UI)
    repeater_cli_screen.dart       ✎ + OTA quick-commands
    repeater_hub_screen.dart       ✎ + vstup na OTA obrazovku
    ota_screen.dart                ✚ výber .otapkg, progress, send/apply
  ota/                             ✚ NOVÝ modul
    ota_payload_builder.dart       ✚ META/SIG/chunk/APPLY + crc16 + Ed25519
    patch_source.dart              ✚ PatchSource interface + OtaPkgPatchSource
    otapkg.dart                    ✚ .otapkg.json model + parse
    ota_sender.dart                ✚ session orchestrácia
    ota_types.dart                 ✚ OtaJob, scope enum, konštanty
  services/
    repeater_command_service.dart  ← reuse (login + txt relay)
    ota_key_store.dart             ✚ import/uloženie Ed25519 kľúča (secure storage)
test/
  ota_payload_builder_test.dart    ✚ golden vektory z Pythonu (byte-for-byte)
  ota_frame_test.dart              ✚ buildSendChannelDataFrame vs meshcore_py
  otapkg_test.dart                 ✚
```

---

## 9. Testovanie / korektnosť

**Najsilnejšia poistka:** `OtaPayloadBuilder` musí produkovať **bajtovo zhodný** výstup ako
`ota_sender.py`. Vygenerujeme golden vektory z Pythonu (META/SIG/chunk/APPLY pre známy
patch+kľúč) a Dart unit testy ich porovnajú byte-for-byte. Podobne frame encoding proti
existujúcim `test_nrf-ota/tests/test_mcpy_frame.py` / `test_grpdata_framing.py`.

BLE párovanie, OTA session a relay sa overia **na HW** (manuálne, ako zvyšok OTA systému).

---

## 10. Riziká / otvorené

- **Flutter SDK nie je nainštalovaný** na dev stroji — projekt forkneme, ale build/run
  vyžaduje doinštalovať Flutter + Android toolchain (portable, viď nižšie).
- **MITM PIN párovanie + BLE MTU** — **už rieši meshcore-open** (funkčná appka); preberáme
  jeho BLE connector tak, ako je. Riziko ↓ oproti vlastnej implementácii.
- **Ed25519 cez pointycastle** musí dať RFC8032 podpis zhodný s pycryptodome `eddsa 'rfc8032'`.
  Overiť golden vektorom (známy META + test_key → očakávaný 64B podpis).
- **Veľkosť forku** — `meshcore_connector.dart` má ~7000 riadkov; OTA píšeme ako oddelený
  `lib/ota/` modul s minimom zásahov do connectora (len `buildSendChannelDataFrame`).
- **Upstream drift** — ponecháme `upstream` remote; OTA v oddelených súboroch → `git pull`
  konfliktuje len na 1 riadku v `meshcore_protocol.dart`.
- iOS + FFI = až fáza B.

---

## Príloha A — zavrhnutá alternatíva: scaffold od nuly

Pred objavením `meshcore-open` sme zvažovali **postaviť appku od nuly**. Zaznamenané pre
prípad, že by sme sa k tomu raz vrátili (napr. ak by sa fork ukázal príliš veľký/zviazaný).

**Prečo sme to nevybrali:** meshcore-open (MIT) má hotové transporty, connection UI a
repeater CLI — od nuly by sme duplikovali stovky hodín odladenej práce (BLE párovanie, MTU,
USB-OTG, reconnection, parsing protokolu, 25+ obrazoviek). Fork = napísať len OTA modul.

**Plánovaná vrstvová štruktúra (od nuly), ak by sa k tomu vrátilo:**

```
lib/
  main.dart  app.dart
  transport/  companion_transport.dart   ← interface {connect, disconnect,
              ble_transport.dart            sendFrame(bytes), Stream<Uint8List> frames}
              usb_transport.dart          ← BLE: flutter_blue_plus + NUS + MITM PIN
              wifi_transport.dart         ← USB: usb_serial (USB-OTG)
              nus_uuids.dart              ← WiFi: dart:io Socket (TCP)
  proto/      companion_commands.dart     ← typové CMD_* enkódery/dekódery
              resp_codes.dart                (setRadio/setChannel/sendChannelData/
              frames.dart                     deviceQuery/getContacts/login/sendText)
  ota/        ota_payload_builder.dart    ← (identické ako vo fork pláne)
              patch_source.dart  otapkg.dart  ota_sender.dart  ota_types.dart
  terminal/   companion_console.dart  repeater_relay.dart
  ui/         connect_screen.dart  ota_screen.dart  terminal_screen.dart  widgets/
  state/      providers.dart
```

**Vlastné závislosti (od nuly):** `flutter_blue_plus`, `usb_serial`, `dart:io` Socket,
`pointycastle` (Ed25519), `crypto`, `provider`/`flutter_riverpod`, `file_picker`,
`flutter_secure_storage`, `convert`.

**Kľúčový rozdiel:** vo fork verzii `transport/` + `proto/` + connection UI + terminál
**zaniká** (= reuse meshcore-open `connector/` + `screens/`); ostáva identický `ota/` modul.
Hranica „PatchSource → OtaPayloadBuilder → OtaSender" je v oboch verziách rovnaká, takže OTA
kód je prenosný medzi fork aj from-scratch verziou.
```
