# FOTA odosielacia obrazovka — výber chunkov/H/S + APPLY + Cancel (design)

> Dátum: 2026-06-28. Vetva `feature/nrf-fota-sender`. Fork-only feature, izolovaná v
> `lib/fota/`. Wire protokol sa NEMENÍ — len skladba toho, čo a kedy sa odošle.

## 1. Cieľ a kontext

Dnes FOTA obrazovka (`lib/fota/screens/fota_screen.dart`) cez `FotaSender.send`
(`lib/fota/services/fota_sender.dart`) vždy odošle **celý** patch: všetky chunky
`0..total-1`, potom header (META + SIG), prípadne APPLY. Pri doposielaní (repeater
hlási, ktoré chunky/H/S mu chýbajú) je to plytvanie — pošle sa všetko znova.

Táto úloha (**Úloha A**) pridáva tri nezávislé, lokálne veci do FOTA modulu:

1. **Výber na odoslanie** — možnosť poslať len vybranú podmnožinu chunkov + H (META)
   a/alebo S (SIG), zadanú ako textový zoznam.
2. **Tretie tlačidlo „APPLY"** — pošle len samotný APPLY paket.
3. **Cancel sending** — zrušenie práve bežiaceho prenosu.

Žiadna nová závislosť, žiadna zmena signatúry `FotaScreen` ani dotknutie upstream
súborov mimo FOTA modulu.

### Mimo rozsahu (Úloha B — samostatný spec/plán)
Repeater-aware funkcie, ktoré vyžadujú, aby `FotaScreen` poznal `Contact` repeatera
+ heslo (dnes má len `headerTarget` string):
- **3a:** auto-predvyplnenie scope=Direct + path z `Contact.outPath`, keď je obrazovka
  spustená z repeater hubu a cesta je známa.
- **3b:** tlačidlo „Get missing Chunks" v Selection dialógu → pošle `fota missall` cez
  `RepeaterCommandService` (timeout 10 s) → odpoveď naplní Selection pole.

Poznámka k 3b (overené vo firmvéri `../MeshCore/.../nrffota/FotaMesh.cpp` +
`FotaReceiver.cpp`): príkaz `fota miss`/`fota missall` vracia reply v tvare
`FOTA miss=N[/total] [H] [S] <rozsahy chunkov>` (napr. `FOTA miss=14/41 H S 3 7 19-22 +5`).
Formát zoznamu (`H`, `S`, jednotlivé čísla, rozsahy `19-22`, oddelené medzerou, `+N` =
ešte N ďalších) je **zámerne zhodný** s gramatikou Selection poľa nižšie — preto sa B
napojí takmer bez transformácie (len odlúpiť prefix `FOTA miss=N/total` a suffix `+N`).

## 2. Parser výberu — pure funkcia (`lib/fota/models/fota_types.dart`)

Nová data trieda + parser, plne testovateľný bez UI.

```dart
class FotaSelection {
  final List<int> chunks; // zoradené, bez duplikátov; konkrétne chunk id
  final bool meta;        // H — pošli META paket
  final bool sig;         // S — pošli SIG paket
  const FotaSelection(this.chunks, {required this.meta, required this.sig});
}

/// Parsuje zoznam oddelený medzerami (case-insensitive). Tokeny:
///   N        → chunk N
///   A-B      → chunky A..B vrátane (aj zostupné B-A zvládne, znormalizuje)
///   H        → META, S → SIG
/// Validácia: každý chunk id musí byť v rozsahu 0..totalChunks-1.
/// Hodí [FormatException] pri: neznámom tokene, nečíselnom rozsahu, chunku mimo
/// rozsahu, a pri prázdnom výbere (žiadny chunk a ani H ani S).
FotaSelection parseFotaSelection(String input, {required int totalChunks});
```

Príklady (`totalChunks = 41`):
- `"0 5 7-12 H S"` → chunks `[0,5,7,8,9,10,11,12]`, meta=true, sig=true
- `"H"` → chunks `[]`, meta=true, sig=false
- `"3 7 19-22"` → chunks `[3,7,19,20,21,22]`, meta=false, sig=false
- `"99"` → `FormatException('chunk 99 mimo rozsahu 0..40')`
- `""` → `FormatException` (prázdny výber)
- `"x"` → `FormatException('neznámy token: "x"')`

Robustnosť pre Úlohu B: parser ignoruje tokeny `FOTA`, `miss=…`/`miss` a `+N` keby do
poľa prenikli z odpovede repeatera? — **Nie.** Čisté: B si odpoveď oseká sama pred
vložením do poľa. Parser ostáva striktný (chytá preklepy používateľa).

## 3. Sender (`lib/fota/services/fota_sender.dart`)

### 3.1 Selekcia
Do `FotaSendConfig` pridať `final FotaSelection? selection;` (default `null`).

- `selection == null` → **presne dnešné správanie** (pošli všetky chunky + header +
  prípadne APPLY; `headerEvery`, `cycles` fungujú ako dnes). Žiadny existujúci test
  sa nemení.
- `selection != null` → v každom cykle:
  1. pošli len vybrané chunky (vo vzostupnom poradí indexov),
  2. ak `selection.meta` → `snd(meta)`,
  3. ak `selection.sig` → `snd(sig)`,
  4. ak `cfg.applyAfter` → `snd(buildApply(patchSha))`.
  `headerEvery` sa v selection móde **ignoruje** (H/S sú zadané explicitne). `cycles`
  sa **rešpektuje** (celý vybraný set sa zopakuje N-krát, obalený v existujúcom
  `for (cycle)` loope). `cycleDelayMs`, `delayMs`, `tsBase` (ts++) — bez zmeny.

`grandTotal` pre `onProgress` v selection móde =
`(selection.chunks.length + (meta?1:0) + (sig?1:0)) * cycles`.

Poradie chunky → H → S → APPLY zachováva existujúci „hend" princíp (chunky najprv).

### 3.2 Cancel
`FotaSender` dostane zrušiteľnosť:

```dart
class FotaSender {
  bool _cancelled = false;
  void cancel() => _cancelled = true;
  // v send(): pred každým snd() (a na vrchu každej iterácie loopu)
  //   if (_cancelled) throw FotaCancelled();
}

class FotaCancelled implements Exception {}
```

`send` kontroluje `_cancelled` pred odoslaním každého paketu. Pri zrušení vyhodí
`FotaCancelled`, ktoré volajúci (UI) zachytí a zobrazí „Zrušené". Už odoslané pakety
ostávajú odoslané (LoRa broadcast sa nedá vziať späť) — to je v poriadku, repeater
kumuluje, čo dorazilo.

### 3.3 APPLY-only
Bez zmeny v senderi: APPLY-only sa rieši v UI ako tenký priamy send jediného paketu
(viď §4.3). `FotaSender.send` netreba rozširovať o „len apply" režim — bolo by to
viac stavu za málo úžitku.

## 4. UI (`lib/fota/screens/fota_screen.dart`)

### 4.1 Stav
```dart
bool _selectionMode = false;                 // false = All, true = Selection
final _selectionController = TextEditingController();
FotaSender? _activeSender;                    // pre Cancel; null keď nebeží
```

### 4.2 Tlačidlo „Výber na odoslanie"
Nad dvojicu Odoslať pridať `OutlinedButton`:
- text: **„Výber na odoslanie: All"** (default) / **„Výber na odoslanie: Selection"**.
- klik (keď `!_busy`) → `showDialog` (AlertDialog):
  - dva `RadioListTile<bool>`: **„Všetko (Select All)"** (false) /
    **„Len výber nižšie (Only Selection below)"** (true),
  - `TextField` (`_selectionController`) na zoznam; helper s príkladom `0 5 7-12 H S`
    a počtom chunkov balíka (napr. „balík má 41 chunkov: 0..40"); pole je
    enabled aj pri „All" (nech sa text nezahodí), ale použije sa len pri Selection,
  - akcie **Zrušiť** / **Potvrdiť**.
  - Potvrdiť: ulož `_selectionMode` podľa vybraného radia + text (text drží
    `_selectionController`, netreba kopírovať). Zatvor dialóg, `setState`.

### 4.3 Tlačidlá odoslania (tri)
Riadok: `Odoslať patch` | `APPLY` | `Odoslať + APPLY`.
- **Odoslať patch** → `_send(apply: false)`.
- **Odoslať + APPLY** → `_send(apply: true)` (deepOrange, ako dnes).
- **APPLY** (nové, medzi nimi) → `_sendApplyOnly()`: pošle jediný APPLY paket cez
  `FotaSender` so selekciou „žiadne chunky, žiadne H/S, applyAfter=true". Realizácia:
  buď samostatná tenká metóda, ktorá použije `FotaSelection([], meta:false, sig:false)`
  + `applyAfter:true` (sender pošle len APPLY), alebo priamy `snd(buildApply)`.
  **Zvolené:** `selection: FotaSelection(const [], meta:false, sig:false)` +
  `applyAfter:true` — drží jednu cestu cez sender (vrátane Cancel, tsBase, setChannel).
  APPLY tlačidlo je nezávislé od `_selectionMode` (vždy len APPLY).

APPLY paket je nevratný reboot repeatera → potvrdzovací dialóg pred odoslaním
(„Naozaj poslať APPLY? Repeater sa reštartuje."). Platí pre `APPLY` aj `Odoslať + APPLY`.

### 4.4 `_send` zmeny
Na začiatku, ak `_selectionMode`:
```dart
final total = (pkg.patchLen / kFotaChunkData).ceil();
FotaSelection sel;
try {
  sel = parseFotaSelection(_selectionController.text, totalChunks: total);
} on FormatException catch (e) {
  _append('ERROR: $e'); return;     // nič sa nepošle
}
```
inak `sel = null`. Predať `selection: sel` do `FotaSendConfig`.

Sender vytvoriť a uložiť: `_activeSender = FotaSender(_ConnectorFotaSink(c));`
v `finally` `_activeSender = null`. `FotaCancelled` zachytiť samostatne →
`_append('Zrušené.')` (nie ako ERROR).

### 4.5 Cancel UI
Kým `_busy`: namiesto/pod `LinearProgressIndicator` zobraziť
`TextButton`/`OutlinedButton` **„Zrušiť odosielanie"** → `_activeSender?.cancel()`.
Tlačidlá Odoslať/APPLY/Výber sú počas behu disabled (ako dnes cez `_busy`).

## 5. Testovanie (TDD)

`test/fota/models/fota_types_test.dart` (alebo nový `fota_selection_test.dart`):
- parser: jednotlivé čísla, rozsahy (vrátane zostupných), H/S kombinácie,
  case-insensitivita, viacnásobné medzery, duplikáty (zlúčia sa), zoradenie,
  chunk mimo rozsahu → `FormatException`, prázdny vstup → `FormatException`,
  neznámy token → `FormatException`.

`test/fota/services/fota_sender_test.dart` (rozšíriť):
- `selection: null` → identické správanie ako dnes (regresný guard).
- selection len chunky → pošlú sa presne tie chunky vo vzostupnom poradí, žiadny
  META/SIG/APPLY.
- selection chunky + H + S → poradie chunky → META → SIG.
- selection + `applyAfter:true` → … → APPLY na konci.
- selection + `cycles:2` → set sa zopakuje 2×; `headerEvery` v selection ignorované.
- `cancel()` po prvom pakete → `FotaCancelled`, počet odoslaných paketov == 1
  (cez fake `FotaFrameSink`, ktorý cancel zavolá v callbacku po N. pakete).
- APPLY-only selekcia (`[]`, meta:false, sig:false, applyAfter:true) → presne 1
  APPLY paket.

`test/fota/screens/fota_screen_smoke_test.dart` (rozšíriť):
- existujúci smoke ostáva zelený (default „All", tri tlačidlá prítomné).

Akceptačné: `flutter test test/fota` všetko PASS, `flutter analyze lib test/fota` clean
(okrem 2 známych pre-existujúcich warningov v `fota_asset_download_test.dart`).

## 6. Dotknuté súbory
- `lib/fota/models/fota_types.dart` — `FotaSelection` + `parseFotaSelection` + `FotaCancelled` (alebo do sendera).
- `lib/fota/services/fota_sender.dart` — `FotaSendConfig.selection`, selection vetva v `send`, `cancel()`.
- `lib/fota/screens/fota_screen.dart` — Výber tlačidlo + dialóg, tretie APPLY tlačidlo, potvrdenia, Cancel UI, `_send` parsovanie.
- `test/fota/...` — nové + rozšírené testy.

Žiadne ARB/l10n zmeny (FOTA modul používa literálové stringy ako zvyšok modulu).
