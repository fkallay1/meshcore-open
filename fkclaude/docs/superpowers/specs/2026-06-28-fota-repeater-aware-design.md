# FOTA repeater-aware: auto Direct path + Get missing Chunks (Úloha B, design)

> Dátum: 2026-06-28. Vetva `feature/nrf-fota-sender`. Nadväzuje na Úlohu A
> (`2026-06-28-fota-selection-apply-cancel-design.md`). Wire protokol sa NEMENÍ.

## 1. Cieľ

Keď je FOTA obrazovka spustená **z hubu konkrétneho repeatera** (prihlásený admin),
využiť to, že repeater je známy `Contact`:

- **3a — auto Direct path:** ak je k repeateru známa direct cesta, predvyplniť
  scope=Direct + path z tejto cesty (mirror toho, čo by inak musel používateľ
  prepisovať ručne). Cesta sa číta **live** z connectora, nie zo statického snapshotu.
- **3b — Get missing Chunks:** v Selection dialógu tlačidlo, ktoré pošle repeateru
  `fota missall`, počká na odpoveď (timeout 10 s) a naplní ňou Selection pole.

Z **FOTA → Broadcast** (Settings vstup) repeater známy nie je → obe funkcie sa skryjú.

## 2. Kontext / zistené fakty

- Dnes `FotaScreen({required String headerTarget})` — pozná len názov. Rozšíri sa o
  `Contact? repeater` + `String? password` (Broadcast vstup ich nechá `null`).
- `repeater_hub_screen.dart` spúšťa `FotaScreen(headerTarget: repeater.name)` v admin
  bloku (má `repeater` aj `password`) — doplní ich.
- `Contact.pathBytesForDisplay` (`lib/models/contact.dart:143`) vracia aktuálne path
  bajty: `pathOverride==null` → `path` (z device); `pathOverride>=0` →
  `pathOverrideBytes`; flood (`pathOverride<0` alebo prázdne) → `Uint8List(0)`.
  Path bajty = jednotlivé hop-hashe po 1 bajte (hashsize 1, default mesh).
- **Časovanie cesty (obava z brainstormingu):** po prihlásení cez flood je cesta najprv
  neznáma; companion ju zistí neskôr. Preto FotaScreen **nesmie** čítať `widget.repeater`
  (snapshot z času navigácie), ale resolvovať čerstvý záznam z `connector.contacts` podľa
  `publicKeyHex` (rovnaký vzor ako `repeater_cli_screen._resolveRepeater`). Tým je cesta
  vždy aktuálna v momente, keď ju používateľ použije.
- `RepeaterCommandService` (`lib/services/repeater_command_service.dart`):
  `sendCommand(Contact, String, {retries})` → `Future<String>` (odpoveď repeatera).
  Vyžaduje, aby obrazovka počúvala `connector.receivedFrames` a volala
  `handleResponse(repeater, text)` na text-message rámcoch (vzor:
  `repeater_cli_screen._setupMessageListener` + `_handleTextMessageResponse`).
- `fota missall` odpoveď: `FOTA miss=N/T: <rozsahy> [H] [S] [+N]` — `parseFotaSelection`
  (Úloha A) ju už znesie bez úprav.

## 3. Pure helper — path bajty → Direct path string

`lib/fota/models/fota_types.dart` (append):

```dart
/// Convert raw contact path bytes (one hop-hash per byte, hashsize 1) to the
/// comma-separated hex form the Direct scope path field expects, e.g.
/// [0x3f, 0xa1] → "3f,a1". Empty input → "" (no known direct path → flood).
String fotaDirectPathFromBytes(Uint8List pathBytes) =>
    pathBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(',');
```

Testovateľné bez UI. (hashsize ostáva 1 — direct cesty z mesh contactu sú 1-bajtové
hopy; `_pathHashSize` sa pri auto-aplikovaní nastaví na 1.)

## 4. FotaScreen — repeater kontext (3a)

### 4.1 Signatúra
```dart
const FotaScreen({
  super.key,
  required this.headerTarget,
  this.repeater,   // null = Broadcast
  this.password,   // login pre admin session (drží sa pre command service)
});
final Contact? repeater;
final String? password;
```
`repeater_hub_screen.dart`: `FotaScreen(headerTarget: repeater.name, repeater: repeater, password: password)`.

### 4.2 Live resolve
Pridať `Contact? _resolveRepeater(MeshCoreConnector c)` — ak `widget.repeater==null`
vráti `null`; inak nájde v `c.contacts` záznam s rovnakým `publicKeyHex` (fallback na
`widget.repeater` ak nie je v zozname). Použiť pri čítaní cesty a pri `fota missall`.

### 4.3 Auto Direct + „Použiť cestu" (rieši časovanie)
- **Pri otvorení** (`initState`): ak `widget.repeater != null` a aktuálny resolve má
  neprázdne `pathBytesForDisplay` → `_scope = FotaScope.direct`,
  `_pathController.text = fotaDirectPathFromBytes(bytes)`, `_pathHashSize = 1`.
  (initState číta connector cez `context.read` — `WidgetsBinding.addPostFrameCallback`
  ak treba kontext po prvom buildе.)
- **Live info + refresh:** keď `repeater != null`, v scope sekcii zobraziť riadok
  „Cesta k <repeater>: `<hex>`" (alebo „flood / neznáma" ak prázdne), čítaný cez
  `context.watch<MeshCoreConnector>()` → vždy aktuálny. Vedľa tlačidlo
  **„Použiť cestu (Direct)"** → nastaví scope=Direct + path z aktuálnych bajtov,
  hashsize=1. Tým: ak sa cesta zistí až po prihlásení (flood→direct), používateľ ju
  jedným klikom natiahne; vidí, či je už direct alebo ešte flood.
- **Pozor na adopt:** `_adoptPkgScope` (po načítaní balíka) prepíše scope/path podľa
  balíka. To je zámerné (balík môže odporúčať vlastný scope). „Použiť cestu" je dostupné
  vždy → po načítaní balíka sa dá Direct k repeateru znova natiahnuť. Auto pri otvorení
  beží PRED načítaním balíka, takže nekoliduje.

## 5. FotaScreen — Get missing Chunks (3b)

### 5.1 Command service + listener
V `initState` (keď `widget.repeater != null`): vytvoriť
`_commandService = RepeaterCommandService(connector)` a `_frameSub =
connector.receivedFrames.listen(...)` ktorý na `respCodeContactMsgRecv`/`...V3` rámci
spraví `parseContactMessageText` → ak `senderPrefix` sedí s repeaterom →
`_commandService.handleResponse(repeater, parsed.text)`. (1:1 vzor z `repeater_cli`.)
V `dispose`: `_frameSub?.cancel(); _commandService?.dispose();`.

### 5.2 Tlačidlo v Selection dialógu
V `_openSelectionDialog`, len ak `widget.repeater != null`, pridať pod textové pole
tlačidlo **„Get missing Chunks"** + lokálny `bool loading`:
```
onPressed: loading ? null : () async {
  setLocal(() { loading = true; error = null; });
  try {
    final rep = _resolveRepeater(read<MeshCoreConnector>())!;
    final resp = await _commandService!
        .sendCommand(rep, 'fota missall', retries: 1)
        .timeout(const Duration(seconds: 10));
    _selectionController.text = resp.trim();
    setLocal(() { mode = true; loading = false; });
  } on TimeoutException {
    setLocal(() { error = 'Repeater neodpovedal do 10 s.'; loading = false; });
  } catch (e) {
    setLocal(() { error = '$e'; loading = false; });
  }
}
```
- Naplní `_selectionController` celou odpoveďou (`FOTA miss=2/33: 12 29`); parser ju
  pri Potvrdiť znesie (Úloha A). Prepne `mode=Selection`.
- Pri prázdnej/`miss=0` odpovedi: necháme text tak; Potvrdiť potom buď prejde (ak sú
  H/S) alebo nahlási prázdny výber — používateľ vidí, že nič nechýba.
- `loading` zobrazí malý `CircularProgressIndicator` v tlačidle; `error` cez existujúci
  červený text v dialógu (Úloha A).

### 5.3 Connection guard
Ak `!connector.isConnected` → tlačidlo disabled (alebo `error` „Nepripojené."). `fota
missall` ide cez aktívnu admin session (login spravený pred vstupom do hubu).

## 6. Testovanie (TDD)

- `test/fota/models/fota_selection_test.dart` (rozšíriť): `fotaDirectPathFromBytes`
  — `[0x3f,0xa1]→"3f,a1"`, `[0x00]→"00"`, `[]→""`, round-trip cez `fotaScopePath`
  (`scope=direct`, hashsize 1) dá späť tie bajty.
- `test/fota/screens/fota_screen_smoke_test.dart` (rozšíriť):
  - `FotaScreen(headerTarget:'X')` (Broadcast, repeater null) → žiadne „Použiť cestu"
    ani „Get missing Chunks" (smoke v no-package stave: aspoň že sa renderuje a build
    nepadne s repeater==null).
  - widget test s `repeater` + fake `MeshCoreConnector` provider, kde contact má path
    `[0x3f,0xa1]` → po otvorení je scope Direct a path pole „3f,a1". (Ak je vloženie
    fake connectora do smoke testu prácne, pokryť `fotaDirectPathFromBytes` unit-testom
    a auto-aplikáciu overiť na HW — pozn. v pláne.)
- `fota missall` request/response je integračné (companion) → HW test; unit-test len
  parsovania odpovede (už v Úlohe A).

## 7. Dotknuté súbory
- `lib/fota/models/fota_types.dart` — `fotaDirectPathFromBytes`.
- `lib/fota/screens/fota_screen.dart` — repeater/password param, `_resolveRepeater`,
  auto Direct + „Použiť cestu" riadok, command service + listener, „Get missing Chunks".
- `lib/screens/repeater_hub_screen.dart` — odovzdať `repeater` + `password` do `FotaScreen`
  (jediný dotknutý upstream súbor, +2 named args).
- `test/fota/...` — helper test + smoke rozšírenie.

Žiadne ARB/l10n zmeny. Žiadna nová závislosť (`RepeaterCommandService`, `Contact`,
`parseContactMessageText` už existujú).

## 8. Mimo rozsahu
- Import Ed25519 kľúča (DER seed) do telefónu pre podpisovanie raw balíkov — samostatná
  téma; GitHub-prepare vetva sa môže presunúť inam.
- Zmena `_pathHashSize` heuristiky pre viacbajtové hopy (mesh default je 1 B/hop).
