# FOTA Package Generation — Step 2b (source abstraction + download + wire) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Wire the FOTA screen's "Create FOTA package" so the app turns selected/local firmware into a ready `.otapkg.json` — pulling release binaries from a **selectable GitHub repo** (behind a swappable source interface) or from two local `.bin` files — feeding the Step-2a builder and dropping the result into the unified selected-package slot.

**Architecture:** A thin `OtaFwSource` interface lets the catalog source be swapped and the GitHub repo be chosen (default `meshcore-dev/MeshCore`, overridable); the existing `OtaGithubSource` implements it with a `repo` parameter. A standalone downloader fetches an asset (unzipping a `.zip` to its inner `.bin`). The screen's Create button downloads current+target (or takes two local bins), calls the Step-2a `buildOtaPkgJson`, and loads the parsed `OtaPkg` into the same slot the manual picker fills.

**Tech Stack:** Dart/Flutter, `package:http` (present), `package:archive` (added in 2a), `package:file_selector` (present). Reuses Step-2a `lib/ota/ota_pkg_builder.dart` + `packages/hpatchlite_dart`.

## Global Constraints

- **Build first, then 2b:** Step 2a (the delta engine + builder) is complete and merged on this branch; this plan depends on `buildOtaPkgJson`/`OtaBuildParams` from `lib/ota/ota_pkg_builder.dart` and `OtaPkg.fromJsonString` from `lib/ota/otapkg.dart`.
- **Selectable repo:** the GitHub source takes a `repo` (owner/repo) parameter, default `meshcore-dev/MeshCore`, branch `main`; an empty/blank custom value falls back to the default. Custom repos are assumed to share the same release-tag + asset-naming + `variants/*/platformio.ini` structure.
- **Pluggable source behind an interface:** the picker depends on the `OtaFwSource` interface, never the concrete class, so future non-GitHub sources plug in. (The device-centric `OtaFwDevice{type,id,name,firmwares}` JSON model from the spec is intentionally DEFERRED to a later phase per the maintainer; this phase keeps the existing `OtaFwCatalog` as the interface's return type.)
- **Web-safety:** no `dart:io` in any web-reachable file (downloader uses `package:http`; unzip uses `package:archive`). On web, GitHub release-asset binary download is CORS-blocked → the download throws a clear error and the **local-bin path is the web fallback** (it works on web via `file_selector`).
- **Unified selected-package slot:** a created package becomes the screen's `_pkg` exactly as the manual `.otapkg.json` picker sets it — same send flow, shown under its generated filename.
- **UI strings are Slovak literals** (no ARB), consistent with the OTA module.
- **Build params for generated packages** match the firmware defaults used by `ota_export_pkg.py` / the working `fw.otapkg.json`: channel `#fkotanrf` idx `1`, radio `869.618 / 62.5 / SF8 / CR5`; scope/path come from the screen's existing scope control. (Radio configurability is a future nicety.)
- **On-device `ota verify` (dry-run) is the HARD GATE before any real `ota flash`** — it is a manual hardware step (not automatable here); it is the only check that confirms the encoder's emitted framing decodes on a non-Dart decoder. Note it in the work-log; do not claim end-to-end success without it.
- **Run tests** with the portable Flutter toolchain: PowerShell `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path`, then `flutter test test/ota`, `flutter analyze lib`, and `flutter build web` where noted.
- **Commits** autonomous on `feature/nrf-ota-sender`; never `dev`/`main`. Trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01DGscgD7gWZkVT5x8uoW2tV`.

---

### Task 1: `OtaFwSource` interface + selectable repo on `OtaGithubSource`

**Files:**
- Create: `lib/ota/ota_fw_source.dart`
- Modify: `lib/ota/ota_github_source.dart`
- Test: `test/ota/ota_github_source_test.dart` (extend)

**Interfaces:**
- Consumes: `OtaFwRole`, `OtaFwCatalog` (from `ota_fw_catalog.dart`).
- Produces:
  - `abstract class OtaFwSource { Future<OtaFwCatalog> loadCatalog(OtaFwRole role, {bool refresh}); }`
  - `OtaGithubSource implements OtaFwSource`, now `OtaGithubSource({String repo, String branch, http.Client? client})` with defaults `repo = 'meshcore-dev/MeshCore'`, `branch = 'main'`. Existing methods (`fetchReleases`, `fetchNrfBoardNamesLower`, `loadCatalog`) unchanged in signature.

- [ ] **Step 1: Write the failing test**

Append to `test/ota/ota_github_source_test.dart` inside `main()`:

```dart
  test('OtaGithubSource is an OtaFwSource and targets a custom repo', () async {
    String? seenReleasesUrl;
    final src = OtaGithubSource(
      repo: 'myfork/MeshCore',
      client: MockClient((req) async {
        final u = req.url.toString();
        if (u.contains('/releases')) {
          seenReleasesUrl = u;
          return http.Response('[]', 200);
        }
        return http.Response('[]', 200);
      }),
    );
    expect(src, isA<OtaFwSource>());
    await src.fetchReleases();
    expect(seenReleasesUrl, contains('myfork/MeshCore'));
  });

  test('defaults to meshcore-dev/MeshCore when repo not given', () async {
    String? seenUrl;
    final src = OtaGithubSource(client: MockClient((req) async {
      seenUrl = req.url.toString();
      return http.Response('[]', 200);
    }));
    await src.fetchReleases();
    expect(seenUrl, contains('meshcore-dev/MeshCore'));
  });
```

Add the import at the top of the test file: `import 'package:meshcore_open/ota/ota_fw_source.dart';`

- [ ] **Step 2: Run test to verify it fails**

Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; flutter test test/ota/ota_github_source_test.dart`
Expected: FAIL — `OtaFwSource` not found / `repo` named param not defined.

- [ ] **Step 3: Write minimal implementation**

Create `lib/ota/ota_fw_source.dart`:

```dart
import 'ota_fw_catalog.dart';

/// Source-agnostic firmware catalog provider. Lets the backing source (GitHub,
/// or a future alternative) be swapped without touching the picker.
abstract class OtaFwSource {
  Future<OtaFwCatalog> loadCatalog(OtaFwRole role, {bool refresh = false});
}
```

In `lib/ota/ota_github_source.dart`:
1. Add `import 'ota_fw_source.dart';`.
2. Change the class declaration to `class OtaGithubSource implements OtaFwSource {`.
3. Replace the `static const _repo = ...;` / `static const _branch = ...;` constants with instance fields + constructor params:

```dart
  final String repo;
  final String branch;
  final http.Client _client;
  OtaGithubSource({
    this.repo = 'meshcore-dev/MeshCore',
    this.branch = 'main',
    http.Client? client,
  }) : _client = client ?? http.Client();
```

4. Replace every use of `_repo` with `repo` and `_branch` with `branch` in the URL strings (in `fetchReleases`, `fetchNrfBoardNamesLower`). Keep `loadCatalog` annotated `@override`.

- [ ] **Step 4: Run test to verify it passes**

Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; flutter test test/ota/ota_github_source_test.dart`
Expected: PASS (existing source tests + 2 new).

- [ ] **Step 5: Commit**

```bash
git add lib/ota/ota_fw_source.dart lib/ota/ota_github_source.dart test/ota/ota_github_source_test.dart
git commit -m "feat(fotanrf): OtaFwSource interface + selectable repo on OtaGithubSource"
```

---

### Task 2: Picker consumes `OtaFwSource` via a factory + custom-repo field

**Files:**
- Modify: `lib/screens/ota_fw_picker.dart`
- Modify: `lib/screens/ota_screen.dart` (the one picker instantiation)
- Test: `test/ota/ota_fw_picker_test.dart` (adapt)

**Interfaces:**
- Consumes: `OtaFwSource` (Task 1), `OtaGithubSource`.
- Produces: `OtaFwPicker({required OtaFwSource Function(String repo) sourceFactory, String initialRepo, void Function(OtaFwSelection)? onSelection})`. `OtaFwSelection` unchanged.

- [ ] **Step 1: Write the failing test**

Replace the body of `test/ota/ota_fw_picker_test.dart`'s widget pump to use a factory. The full updated file:

```dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshcore_open/ota/ota_github_source.dart';
import 'package:meshcore_open/ota/ota_fw_source.dart';
import 'package:meshcore_open/screens/ota_fw_picker.dart';

OtaFwSource _source(String repo) {
  final releases = jsonEncode([
    {'tag_name': 'repeater-v1.17.0', 'assets': [
      {'name': 'ProMicro_repeater-v1.17.0-def.zip', 'browser_download_url': 'https://e/p-1.17.zip'}]},
    {'tag_name': 'repeater-v1.16.0', 'assets': [
      {'name': 'ProMicro_repeater-v1.16.0-abc.zip', 'browser_download_url': 'https://e/p-1.16.zip'}]},
  ]);
  final trees = jsonEncode({'tree': [
    {'path': 'variants/promicro/platformio.ini', 'type': 'blob'}]});
  return OtaGithubSource(repo: repo, client: MockClient((req) async {
    final u = req.url.toString();
    if (u.contains('/releases')) return http.Response(releases, 200);
    if (u.contains('/git/trees/')) return http.Response(trees, 200);
    if (u.contains('variants/promicro/platformio.ini')) {
      return http.Response('-D NRF52_PLATFORM', 200);
    }
    return http.Response('nf', 404);
  }));
}

void main() {
  testWidgets('loads via the factory and applies defaults', (tester) async {
    OtaFwSelection? sel;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: OtaFwPicker(sourceFactory: _source, onSelection: (s) => sel = s),
      ),
    ));
    await tester.pumpAndSettle();
    expect(sel, isNotNull);
    expect(sel!.device, 'ProMicro');
    expect(sel!.targetVersion, '1.17.0');
    expect(sel!.currentVersion, '1.16.0');
    expect(sel!.packageFileName,
        'ProMicro_repeater_v1.16.0_to_v1.17.0.otapkg.json');
    // the custom-repo field is present, defaulting to meshcore-dev/MeshCore
    expect(find.widgetWithText(TextField, 'meshcore-dev/MeshCore'), findsNothing);
    expect(find.text('meshcore-dev/MeshCore'), findsWidgets);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; flutter test test/ota/ota_fw_picker_test.dart`
Expected: FAIL — `sourceFactory` named param not defined.

- [ ] **Step 3: Write minimal implementation**

In `lib/screens/ota_fw_picker.dart`:
1. Change the import from the concrete source to `import '../ota/ota_fw_source.dart';` (keep whatever catalog import exists).
2. Change the widget fields/constructor:

```dart
class OtaFwPicker extends StatefulWidget {
  final OtaFwSource Function(String repo) sourceFactory;
  final String initialRepo;
  final void Function(OtaFwSelection)? onSelection;
  const OtaFwPicker({
    super.key,
    required this.sourceFactory,
    this.initialRepo = 'meshcore-dev/MeshCore',
    this.onSelection,
  });
  @override
  State<OtaFwPicker> createState() => _OtaFwPickerState();
}
```

3. In the state, add a repo controller and build the source from it:

```dart
  late final TextEditingController _repoController =
      TextEditingController(text: widget.initialRepo);

  OtaFwSource _buildSource() {
    final repo = _repoController.text.trim();
    return widget.sourceFactory(repo.isEmpty ? widget.initialRepo : repo);
  }
```

Replace the existing `widget.source.loadCatalog(_role)` call in `_load()` with `_buildSource().loadCatalog(_role)`. Dispose `_repoController` in `dispose()`.

4. Add a repo `TextField` at the top of the built column (above the Role dropdown), and reload on submit:

```dart
      TextField(
        controller: _repoController,
        decoration: const InputDecoration(
          labelText: 'GitHub repo (owner/repo)',
          border: OutlineInputBorder(),
          isDense: true,
        ),
        onSubmitted: (_) => _load(),
      ),
      const SizedBox(height: 8),
```

(Place this inside the loaded/`build` column; when loading or on error the existing loading/error rows already render, so the field can live in the loaded branch above the Role dropdown. If you prefer it always visible, render it above the loading/error switch — either is acceptable as long as the test's `find.text('meshcore-dev/MeshCore')` passes after `pumpAndSettle`.)

In `lib/screens/ota_screen.dart`, update the single instantiation:
- Remove the `final OtaGithubSource _ghSource = OtaGithubSource();` field.
- Change the picker usage to:

```dart
              OtaFwPicker(
                sourceFactory: (repo) => OtaGithubSource(repo: repo),
                onSelection: (s) => setState(() => _fwSelection = s),
              ),
```
- Add `import '../ota/ota_github_source.dart';` to `ota_screen.dart` if not already imported (it currently imports it for `_ghSource`; keep the import).

- [ ] **Step 4: Run the picker test, then the full OTA suite + analyze**

Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; flutter test test/ota/ota_fw_picker_test.dart`
Expected: PASS.
Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; flutter test test/ota`
Expected: PASS (all).
Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; flutter analyze lib`
Expected: `No issues found!`

- [ ] **Step 5: Commit**

```bash
git add lib/screens/ota_fw_picker.dart lib/screens/ota_screen.dart test/ota/ota_fw_picker_test.dart
git commit -m "feat(fotanrf): picker consumes OtaFwSource via factory + custom-repo field"
```

---

### Task 3: Asset downloader (`.zip` → inner `.bin`, CORS-aware)

**Files:**
- Create: `lib/ota/ota_asset_download.dart`
- Test: `test/ota/ota_asset_download_test.dart`

**Interfaces:**
- Produces:
  - `class OtaDownloadException implements Exception { OtaDownloadException(String message); }`
  - `Future<Uint8List> downloadFirmwareBin(String url, {http.Client? client})` — GETs [url]; if it ends with `.zip`, unzips and returns the single inner non-merged `.bin`; otherwise returns the raw bytes. Throws `OtaDownloadException` on HTTP error, on a zip with no usable `.bin`, or on a network/CORS failure.

- [ ] **Step 1: Write the failing test**

Create `test/ota/ota_asset_download_test.dart`:

```dart
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshcore_open/ota/ota_asset_download.dart';

void main() {
  test('returns raw bytes for a .bin url', () async {
    final body = Uint8List.fromList([1, 2, 3, 4]);
    final c = MockClient((_) async => http.Response.bytes(body, 200));
    final got = await downloadFirmwareBin('https://e/fw.bin', client: c);
    expect(got, body);
  });

  test('extracts the inner non-merged .bin from a .zip', () async {
    final fw = Uint8List.fromList(List.generate(50, (i) => i));
    final archive = Archive()
      ..addFile(ArchiveFile('Device_repeater-merged.bin', 3, [9, 9, 9]))
      ..addFile(ArchiveFile('Device_repeater.bin', fw.length, fw))
      ..addFile(ArchiveFile('readme.txt', 2, [65, 66]));
    final zipBytes = ZipEncoder().encode(archive)!;
    final c = MockClient(
        (_) async => http.Response.bytes(Uint8List.fromList(zipBytes), 200));
    final got = await downloadFirmwareBin('https://e/fw.zip', client: c);
    expect(got, fw); // not the -merged.bin, not the txt
  });

  test('throws OtaDownloadException on HTTP error', () async {
    final c = MockClient((_) async => http.Response('nope', 404));
    expect(() => downloadFirmwareBin('https://e/fw.bin', client: c),
        throwsA(isA<OtaDownloadException>()));
  });

  test('throws when a .zip has no usable .bin', () async {
    final archive = Archive()
      ..addFile(ArchiveFile('only.uf2', 2, [1, 2]));
    final zipBytes = ZipEncoder().encode(archive)!;
    final c = MockClient(
        (_) async => http.Response.bytes(Uint8List.fromList(zipBytes), 200));
    expect(() => downloadFirmwareBin('https://e/fw.zip', client: c),
        throwsA(isA<OtaDownloadException>()));
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; flutter test test/ota/ota_asset_download_test.dart`
Expected: FAIL — `ota_asset_download.dart` not found.

- [ ] **Step 3: Write minimal implementation**

Create `lib/ota/ota_asset_download.dart`:

```dart
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;

class OtaDownloadException implements Exception {
  final String message;
  OtaDownloadException(this.message);
  @override
  String toString() => 'OtaDownloadException: $message';
}

/// Download a firmware binary from [url]. If [url] is a `.zip`, return the inner
/// non-merged `.bin`; otherwise return the response bytes. On web, GitHub
/// release-asset downloads are CORS-blocked and surface here as an exception —
/// callers should fall back to local-file selection.
Future<Uint8List> downloadFirmwareBin(String url, {http.Client? client}) async {
  final c = client ?? http.Client();
  http.Response res;
  try {
    res = await c.get(Uri.parse(url));
  } catch (e) {
    throw OtaDownloadException('download failed (CORS on web?): $e');
  }
  if (res.statusCode != 200) {
    throw OtaDownloadException('GET $url → HTTP ${res.statusCode}');
  }
  final bytes = res.bodyBytes;
  if (!url.toLowerCase().endsWith('.zip')) return bytes;

  final archive = ZipDecoder().decodeBytes(bytes);
  for (final f in archive.files) {
    if (!f.isFile) continue;
    final name = f.name.toLowerCase();
    if (name.endsWith('.bin') && !name.contains('merged')) {
      return Uint8List.fromList(f.content as List<int>);
    }
  }
  throw OtaDownloadException('zip has no usable (non-merged) .bin');
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; flutter test test/ota/ota_asset_download_test.dart`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/ota/ota_asset_download.dart test/ota/ota_asset_download_test.dart
git commit -m "feat(fotanrf): firmware asset downloader (.zip -> inner .bin, CORS-aware)"
```

---

### Task 4: Wire "Create FOTA package" (GitHub + local bins) into the screen

**Files:**
- Modify: `lib/screens/ota_screen.dart`
- Test: `test/ota/ota_screen_smoke_test.dart` (extend)

**Interfaces:**
- Consumes: `OtaFwSelection` (currentAsset/targetAsset with `downloadUrl`), `downloadFirmwareBin` (Task 3), `buildOtaPkgJson` + `OtaBuildParams` (Step 2a), `OtaPkg.fromJsonString`, `OtaScope`.
- Produces: nothing new (UI wiring). The Create button becomes enabled; a local-bin entry is added.

**Behaviour:** Create-from-GitHub downloads the selection's current + target assets, generates the package, and loads it into `_pkg`. A separate "local bins" action picks two `.bin` files and does the same. Both set the unified slot. On web, the GitHub download may throw (CORS) → the error shows in the log and the user uses local bins.

- [ ] **Step 1: Write the failing test**

Extend `test/ota/ota_screen_smoke_test.dart` with:

```dart
  testWidgets('Create FOTA package button is enabled once a selection exists',
      (tester) async {
    // The button is disabled with no selection; this asserts the new
    // local-bin entry is present (the always-available web fallback).
    await tester.pumpWidget(const MaterialApp(
      home: OtaScreen(headerTarget: 'Broadcast'),
    ));
    expect(find.text('Vyrob z lokálnych .bin'), findsOneWidget);
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; flutter test test/ota/ota_screen_smoke_test.dart`
Expected: FAIL — 'Vyrob z lokálnych .bin' not found.

- [ ] **Step 3: Write minimal implementation**

In `lib/screens/ota_screen.dart`:

1. Add imports:

```dart
import '../ota/ota_asset_download.dart';
import '../ota/ota_pkg_builder.dart';
```

2. Add the build-params helper + the two create flows to `_OtaScreenState`:

```dart
  OtaBuildParams _buildParams() => OtaBuildParams(
        channelName: '#fkotanrf',
        channelIdx: 1,
        freqMHz: 869.618,
        bwKHz: 62.5,
        sf: 8,
        cr: 5,
        scope: _scope.name,
        path: _pathController.text.trim(),
      );

  Future<void> _loadGeneratedPkg(Uint8List oldFw, Uint8List newFw, String label) async {
    _append('Generujem patch ($label)…');
    final json = buildOtaPkgJson(oldFw: oldFw, newFw: newFw, p: _buildParams());
    final pkg = OtaPkg.fromJsonString(json);
    setState(() {
      _pkg = pkg;
      _scope = pkg.scope;
      _pathController.text = pkg.pathHex;
    });
    _append('Hotovo: patch=${pkg.patchLen}B '
        'chunkov=${(pkg.patchLen / kOtaChunkData).ceil()}');
  }

  Future<void> _createFromGithub() async {
    final sel = _fwSelection;
    if (sel == null) return;
    final cur = sel.currentAsset, tgt = sel.targetAsset;
    if (cur == null || tgt == null) {
      _append('ERROR: chýba asset pre current alebo target.');
      return;
    }
    setState(() => _busy = true);
    try {
      _append('Sťahujem current: ${cur.name}…');
      final oldFw = await downloadFirmwareBin(cur.downloadUrl);
      _append('Sťahujem target: ${tgt.name}…');
      final newFw = await downloadFirmwareBin(tgt.downloadUrl);
      await _loadGeneratedPkg(oldFw, newFw, sel.packageFileName);
    } catch (e) {
      _append('ERROR: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _createFromLocalBins() async {
    setState(() => _busy = true);
    try {
      const group = XTypeGroup(label: 'firmware', extensions: ['bin']);
      _append('Vyber STARÝ (current) .bin…');
      final oldFile = await openFile(acceptedTypeGroups: [group]);
      if (oldFile == null) return;
      _append('Vyber NOVÝ (target) .bin…');
      final newFile = await openFile(acceptedTypeGroups: [group]);
      if (newFile == null) return;
      final oldFw = await oldFile.readAsBytes();
      final newFw = await newFile.readAsBytes();
      await _loadGeneratedPkg(oldFw, newFw, '${oldFile.name} → ${newFile.name}');
    } catch (e) {
      _append('ERROR: $e');
    } finally {
      setState(() => _busy = false);
    }
  }
```

3. In the `ExpansionTile` children (the "Priprav z GitHubu" section), replace the disabled Create button with an enabled one, and add the local-bin entry after it:

```dart
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: (_busy || _fwSelection == null) ? null : _createFromGithub,
                  icon: const Icon(Icons.build),
                  label: Text(_fwSelection == null
                      ? 'Create FOTA package'
                      : 'Create FOTA package: ${_fwSelection!.packageFileName}'),
                ),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: OutlinedButton.icon(
                  onPressed: _busy ? null : _createFromLocalBins,
                  icon: const Icon(Icons.folder_zip),
                  label: const Text('Vyrob z lokálnych .bin'),
                ),
              ),
```

(`Uint8List` is already imported via `dart:typed_data` at the top of the file; `XTypeGroup`/`openFile` via the existing `file_selector` import.)

- [ ] **Step 4: Run the smoke test, full OTA suite, analyze, and web build**

Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; flutter test test/ota/ota_screen_smoke_test.dart`
Expected: PASS.
Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; flutter test test/ota`
Expected: PASS (all).
Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; flutter analyze lib`
Expected: `No issues found!`
Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; flutter build web`
Expected: `√ Built build\web` (confirms no `dart:io` reached the web graph through the new wiring).

- [ ] **Step 5: Commit**

```bash
git add lib/screens/ota_screen.dart test/ota/ota_screen_smoke_test.dart
git commit -m "feat(fotanrf): wire Create FOTA package (GitHub download + local bins) into the screen"
```

---

## On-device verification (manual, after this plan)

Not automatable here, but REQUIRED before trusting a generated package on hardware (the hard gate from the 2a review): connect a companion, generate a package for a real reverse FW pair, send it, run `ota verify` (dry-run) on the repeater, and confirm it reconstructs to the target `new_sha256` before any `ota flash`. Optionally also cross-check one app-generated diff through the PC reference `hpatchi`/`hdiffi.exe` (spec §6.3).

## Self-Review

- **Spec coverage (§5):** §5.1 source abstraction + selectable repo → Task 1 (`OtaFwSource` + `repo` param); picker consumes the interface → Task 2 (factory). The device-centric `OtaFwDevice` model is explicitly DEFERRED (Global Constraints) per the maintainer's "next phase" — not a gap. §5.2 download (`.zip`→bin, CORS fallback) → Task 3 + the local-bin fallback in Task 4. §5.3 wire Create → builder → unified slot → Task 4. §6.5 on-device verify → documented manual gate (not automatable).
- **Placeholder scan:** none — every code step is complete; the parenthetical placement notes are concrete guidance, not TODOs.
- **Type consistency:** `OtaFwSource.loadCatalog`, `OtaGithubSource({repo,branch,client})`, `OtaFwPicker({sourceFactory,initialRepo,onSelection})`, `downloadFirmwareBin(url,{client})`, `OtaDownloadException`, `buildOtaPkgJson({oldFw,newFw,p})`, `OtaBuildParams`, `OtaPkg.fromJsonString` are used identically across tasks. `OtaScope.name` ('zerohop'/'flood'/'direct') matches `OtaBuildParams.scope` expectations.
