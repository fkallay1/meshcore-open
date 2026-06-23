# FOTA Package Preparation — Step 1 (Selection UI) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a firmware-selection section to the top of the `FOTA → …` screen that pulls the nRF
device list and Repeater/Room-Server firmware versions dynamically from GitHub and lets the user
pick a device + Current FW + Target FW, with sensible defaults and a resolved-asset preview.

**Architecture:** A pure-Dart catalog layer (models + parsing + asset-selection logic, no IO) is
unit-tested in isolation; a thin GitHub IO source (injectable `http.Client`) fetches releases and
nRF variant definitions and feeds the catalog; a stateless picker widget renders the dropdowns and
reports the selection upward. The existing `.otapkg.json` file-picker stays as a parallel input.

**Tech Stack:** Dart/Flutter, `package:http` (already a dependency), `dart:convert`. No new
dependencies in Step 1. Provider is **not** needed here — the source is injected for testability.

## Global Constraints

- **Isolation discipline:** all new OTA logic lives in NEW files under `lib/ota/` and a new widget
  file under `lib/screens/`. The only upstream-ish file touched is the fork-owned
  `lib/screens/ota_screen.dart`. Do not touch other upstream files.
- **UI strings are Slovak literals** (no ARB changes), consistent with the rest of the OTA module.
- **No new dependencies** in Step 1. `http` is already in `pubspec.yaml`.
- **No network in tests:** every test injects a fake `http.Client` or calls pure functions on
  literal fixtures. The existing `test/ota` suite must stay green.
- **Repo facts:** GitHub repo `meshcore-dev/MeshCore`, default branch `main`. Release tag prefixes:
  `repeater-v<ver>` and `room-server-v<ver>`. Asset filename pattern:
  `<Device>_<roleInfix>-v<ver>-<commit>[<suffix>].<ext>` where `roleInfix` ∈ {`repeater`,
  `room_server`}. nRF boards are PIO variants whose `variants/<name>/platformio.ini` contains the
  token `NRF52_PLATFORM`.
- **Defaults on open:** role = Repeater, device = `promicro`, Target FW = newest release, Current FW
  = second-newest release.
- **Asset priority:** standalone `.bin` (NOT `*-merged.bin`) > `.zip` (inner non-merged bin, handled
  in Step 2) > none. `.uf2` is never selected. (Step 1 only *resolves/labels* assets; downloading
  and unzipping happen in Step 2.)
- **Run tests with the portable Flutter toolchain:** prepend `D:\FkDev\Tools\flutter\bin` to PATH
  (PowerShell: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path`).
- **Commits:** autonomous on `feature/nrf-ota-sender`; never on `dev`/`main`. Co-Author + Session
  trailers per global rules.

---

### Task 1: Catalog models + asset-name parsing + asset-selection logic (pure, no IO)

**Files:**
- Create: `lib/ota/ota_fw_catalog.dart`
- Test: `test/ota/ota_fw_catalog_test.dart`

**Interfaces:**
- Produces:
  - `enum OtaFwRole { repeater, roomServer }`
  - `String otaRoleInfix(OtaFwRole r)` → `'repeater'` | `'room_server'`
  - `class OtaReleaseAsset { final String name; final String downloadUrl; }`
  - `class OtaAssetInfo { final String device; final OtaFwRole role; final String version; final String ext; final bool isMerged; }`
  - `OtaAssetInfo? parseOtaAssetName(String name)`
  - `OtaReleaseAsset? selectOtaAsset(List<OtaReleaseAsset> assets, String device, OtaFwRole role)`
  - `String otaPackageFileName({required String device, required OtaFwRole role, required String currentVersion, required String targetVersion})`
  - `int compareOtaVersionsDesc(String a, String b)`

- [ ] **Step 1: Write the failing test**

Create `test/ota/ota_fw_catalog_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/ota/ota_fw_catalog.dart';

void main() {
  group('parseOtaAssetName', () {
    test('parses a repeater zip', () {
      final info = parseOtaAssetName('ProMicro_repeater-v1.16.0-07a3ca9.zip');
      expect(info, isNotNull);
      expect(info!.device, 'ProMicro');
      expect(info.role, OtaFwRole.repeater);
      expect(info.version, '1.16.0');
      expect(info.ext, 'zip');
      expect(info.isMerged, false);
    });

    test('parses a room_server bin with underscored device', () {
      final info = parseOtaAssetName('Heltec_v3_room_server-v1.16.0-07a3ca9.bin');
      expect(info!.device, 'Heltec_v3');
      expect(info.role, OtaFwRole.roomServer);
      expect(info.ext, 'bin');
      expect(info.isMerged, false);
    });

    test('flags merged bins', () {
      final info = parseOtaAssetName('Heltec_v3_room_server-v1.16.0-07a3ca9-merged.bin');
      expect(info!.isMerged, true);
    });

    test('returns null for non-matching names', () {
      expect(parseOtaAssetName('README.txt'), isNull);
    });
  });

  group('selectOtaAsset', () {
    final assets = [
      OtaReleaseAsset(name: 'ProMicro_repeater-v1.16.0-abc.uf2', downloadUrl: 'u'),
      OtaReleaseAsset(name: 'ProMicro_repeater-v1.16.0-abc.zip', downloadUrl: 'z'),
      OtaReleaseAsset(name: 'Heltec_v3_repeater-v1.16.0-abc-merged.bin', downloadUrl: 'm'),
      OtaReleaseAsset(name: 'Heltec_v3_repeater-v1.16.0-abc.bin', downloadUrl: 'b'),
    ];
    test('prefers a non-merged bin over zip/uf2', () {
      final a = selectOtaAsset(assets, 'Heltec_v3', OtaFwRole.repeater);
      expect(a!.downloadUrl, 'b');
    });
    test('falls back to zip when no standalone bin', () {
      final a = selectOtaAsset(assets, 'ProMicro', OtaFwRole.repeater);
      expect(a!.downloadUrl, 'z'); // never the .uf2
    });
    test('never selects a merged bin or a uf2', () {
      final onlyBad = [
        OtaReleaseAsset(name: 'X_repeater-v1.0.0-abc-merged.bin', downloadUrl: 'm'),
        OtaReleaseAsset(name: 'X_repeater-v1.0.0-abc.uf2', downloadUrl: 'u'),
      ];
      expect(selectOtaAsset(onlyBad, 'X', OtaFwRole.repeater), isNull);
    });
  });

  test('otaPackageFileName carries device + both versions', () {
    final n = otaPackageFileName(
      device: 'ProMicro', role: OtaFwRole.repeater,
      currentVersion: '1.16.0', targetVersion: '1.17.0');
    expect(n, 'ProMicro_repeater_v1.16.0_to_v1.17.0.otapkg.json');
  });

  test('compareOtaVersionsDesc orders newest first', () {
    final v = ['1.16.0', '1.17.0', '1.16.2']..sort(compareOtaVersionsDesc);
    expect(v, ['1.17.0', '1.16.2', '1.16.0']);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; flutter test test/ota/ota_fw_catalog_test.dart`
Expected: FAIL — `ota_fw_catalog.dart` / symbols not found (compile error).

- [ ] **Step 3: Write minimal implementation**

Create `lib/ota/ota_fw_catalog.dart`:

```dart
import 'dart:math' as math;

enum OtaFwRole { repeater, roomServer }

String otaRoleInfix(OtaFwRole r) =>
    r == OtaFwRole.repeater ? 'repeater' : 'room_server';

class OtaReleaseAsset {
  final String name;
  final String downloadUrl;
  const OtaReleaseAsset({required this.name, required this.downloadUrl});
}

class OtaAssetInfo {
  final String device;
  final OtaFwRole role;
  final String version;
  final String ext;
  final bool isMerged;
  const OtaAssetInfo({
    required this.device,
    required this.role,
    required this.version,
    required this.ext,
    required this.isMerged,
  });
}

/// Parse `<Device>_<roleInfix>-v<ver>-<commit>[<suffix>].<ext>`. Returns null if
/// the name does not match a known OTA firmware role.
OtaAssetInfo? parseOtaAssetName(String name) {
  for (final role in OtaFwRole.values) {
    final marker = '_${otaRoleInfix(role)}-v';
    final i = name.indexOf(marker);
    if (i <= 0) continue;
    final device = name.substring(0, i);
    final rest = name.substring(i + marker.length); // "1.16.0-07a3ca9[suffix].ext"
    final dot = rest.lastIndexOf('.');
    if (dot < 0) continue;
    final ext = rest.substring(dot + 1).toLowerCase();
    final stem = rest.substring(0, dot); // "1.16.0-07a3ca9[suffix]"
    final dash = stem.indexOf('-');
    final version = dash < 0 ? stem : stem.substring(0, dash);
    final isMerged = stem.toLowerCase().contains('merged');
    return OtaAssetInfo(
        device: device, role: role, version: version, ext: ext, isMerged: isMerged);
  }
  return null;
}

/// Pick the best downloadable asset for [device]+[role]:
/// non-merged `.bin` > non-merged `.zip` > none. `.uf2` and `*-merged.*` ignored.
OtaReleaseAsset? selectOtaAsset(
    List<OtaReleaseAsset> assets, String device, OtaFwRole role) {
  OtaReleaseAsset? zip;
  for (final a in assets) {
    final info = parseOtaAssetName(a.name);
    if (info == null) continue;
    if (info.role != role) continue;
    if (info.device.toLowerCase() != device.toLowerCase()) continue;
    if (info.isMerged) continue;
    if (info.ext == 'bin') return a; // best
    if (info.ext == 'zip') zip ??= a; // fallback
  }
  return zip;
}

String otaPackageFileName({
  required String device,
  required OtaFwRole role,
  required String currentVersion,
  required String targetVersion,
}) =>
    '${device}_${otaRoleInfix(role)}_v${currentVersion}_to_v$targetVersion.otapkg.json';

/// Newest-first comparator for dotted numeric versions ("1.17.0" before "1.16.2").
int compareOtaVersionsDesc(String a, String b) {
  final pa = a.split('.').map((x) => int.tryParse(x) ?? 0).toList();
  final pb = b.split('.').map((x) => int.tryParse(x) ?? 0).toList();
  final n = math.max(pa.length, pb.length);
  for (var i = 0; i < n; i++) {
    final va = i < pa.length ? pa[i] : 0;
    final vb = i < pb.length ? pb[i] : 0;
    if (va != vb) return vb - va;
  }
  return 0;
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; flutter test test/ota/ota_fw_catalog_test.dart`
Expected: PASS (all cases).

- [ ] **Step 5: Commit**

```bash
git add lib/ota/ota_fw_catalog.dart test/ota/ota_fw_catalog_test.dart
git commit -m "feat(fotanrf): OTA fw catalog — asset parse/select/filename/version logic"
```

---

### Task 2: nRF detection + device-list build (pure, no IO)

**Files:**
- Modify: `lib/ota/ota_fw_catalog.dart` (append functions + `OtaRelease`/`OtaFwCatalog`)
- Test: `test/ota/ota_fw_catalog_test.dart` (append a group)

**Interfaces:**
- Consumes: everything from Task 1.
- Produces:
  - `bool platformioIsNrf(String iniContent)`
  - `bool deviceIsNrf(String device, Set<String> nrfBoardNamesLower)`
  - `class OtaRelease { final OtaFwRole role; final String version; final String tag; final List<OtaReleaseAsset> assets; }`
  - `class OtaFwCatalog { final OtaFwRole role; final List<OtaRelease> releases; final List<String> devices; OtaReleaseAsset? assetFor(String device, String version); }`
  - `OtaFwCatalog buildOtaCatalog({required OtaFwRole role, required List<OtaRelease> releases, required Set<String> nrfBoardNamesLower})`

- [ ] **Step 1: Write the failing test**

Append to `test/ota/ota_fw_catalog_test.dart` (inside `main()`):

```dart
  group('nRF detection', () {
    test('platformioIsNrf detects the NRF52_PLATFORM token', () {
      expect(platformioIsNrf('build_flags = -D NRF52_PLATFORM\n  -D X'), true);
      expect(platformioIsNrf('build_flags = -D ESP32_PLATFORM'), false);
    });
    test('deviceIsNrf matches a board-name prefix, case-insensitively', () {
      final nrf = {'promicro', 'ikoka_nano_nrf', 'xiao_nrf52'};
      expect(deviceIsNrf('ProMicro', nrf), true);
      expect(deviceIsNrf('ikoka_nano_nrf_30dbm', nrf), true); // power-variant suffix
      expect(deviceIsNrf('Heltec_v3', nrf), false);
    });
  });

  group('buildOtaCatalog', () {
    OtaRelease rel(String ver, List<String> assetNames) => OtaRelease(
          role: OtaFwRole.repeater,
          version: ver,
          tag: 'repeater-v$ver',
          assets: [
            for (final n in assetNames) OtaReleaseAsset(name: n, downloadUrl: '$n#u'),
          ],
        );
    final releases = [
      rel('1.16.0', [
        'ProMicro_repeater-v1.16.0-abc.zip',
        'Heltec_v3_repeater-v1.16.0-abc.bin', // not nRF → excluded
        'xiao_c3_repeater-v1.16.0-abc.bin', // not nRF → excluded
      ]),
      rel('1.17.0', ['ProMicro_repeater-v1.17.0-def.zip']),
    ];
    final nrf = {'promicro', 'xiao_nrf52'};

    test('devices are nRF ∩ have-usable-asset, releases newest-first', () {
      final cat = buildOtaCatalog(
          role: OtaFwRole.repeater, releases: releases, nrfBoardNamesLower: nrf);
      expect(cat.devices, ['ProMicro']); // Heltec_v3 + xiao_c3 filtered out
      expect(cat.releases.map((r) => r.version).toList(), ['1.17.0', '1.16.0']);
    });

    test('assetFor resolves the right download url per device+version', () {
      final cat = buildOtaCatalog(
          role: OtaFwRole.repeater, releases: releases, nrfBoardNamesLower: nrf);
      expect(cat.assetFor('ProMicro', '1.17.0')!.downloadUrl,
          'ProMicro_repeater-v1.17.0-def.zip#u');
      expect(cat.assetFor('ProMicro', '9.9.9'), isNull);
    });
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; flutter test test/ota/ota_fw_catalog_test.dart`
Expected: FAIL — `platformioIsNrf`/`OtaRelease`/`buildOtaCatalog` not defined.

- [ ] **Step 3: Write minimal implementation**

Append to `lib/ota/ota_fw_catalog.dart`:

```dart
bool platformioIsNrf(String iniContent) => iniContent.contains('NRF52_PLATFORM');

bool deviceIsNrf(String device, Set<String> nrfBoardNamesLower) {
  final d = device.toLowerCase();
  return nrfBoardNamesLower.any((b) => d.startsWith(b));
}

class OtaRelease {
  final OtaFwRole role;
  final String version;
  final String tag;
  final List<OtaReleaseAsset> assets;
  const OtaRelease({
    required this.role,
    required this.version,
    required this.tag,
    required this.assets,
  });
}

class OtaFwCatalog {
  final OtaFwRole role;
  final List<OtaRelease> releases; // newest-first
  final List<String> devices; // sorted, nRF ∩ usable
  const OtaFwCatalog(
      {required this.role, required this.releases, required this.devices});

  OtaRelease? _release(String version) {
    for (final r in releases) {
      if (r.version == version) return r;
    }
    return null;
  }

  OtaReleaseAsset? assetFor(String device, String version) {
    final r = _release(version);
    if (r == null) return null;
    return selectOtaAsset(r.assets, device, role);
  }
}

OtaFwCatalog buildOtaCatalog({
  required OtaFwRole role,
  required List<OtaRelease> releases,
  required Set<String> nrfBoardNamesLower,
}) {
  final forRole = releases.where((r) => r.role == role).toList()
    ..sort((a, b) => compareOtaVersionsDesc(a.version, b.version));

  final devices = <String>{};
  for (final r in forRole) {
    for (final a in r.assets) {
      final info = parseOtaAssetName(a.name);
      if (info == null || info.role != role || info.isMerged) continue;
      if (info.ext != 'bin' && info.ext != 'zip') continue; // ignore uf2 etc.
      if (!deviceIsNrf(info.device, nrfBoardNamesLower)) continue;
      devices.add(info.device);
    }
  }
  final sorted = devices.toList()..sort();
  return OtaFwCatalog(role: role, releases: forRole, devices: sorted);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; flutter test test/ota/ota_fw_catalog_test.dart`
Expected: PASS (Task 1 + Task 2 groups).

- [ ] **Step 5: Commit**

```bash
git add lib/ota/ota_fw_catalog.dart test/ota/ota_fw_catalog_test.dart
git commit -m "feat(fotanrf): OTA catalog — nRF detection + device-list build"
```

---

### Task 3: GitHub IO source (injectable http client, in-memory cache)

**Files:**
- Create: `lib/ota/ota_github_source.dart`
- Test: `test/ota/ota_github_source_test.dart`

**Interfaces:**
- Consumes: `OtaFwRole`, `OtaRelease`, `OtaReleaseAsset`, `OtaFwCatalog`, `buildOtaCatalog`,
  `platformioIsNrf` from Tasks 1–2.
- Produces:
  - `class OtaGithubSource { OtaGithubSource({http.Client? client}); Future<List<OtaRelease>> fetchReleases({bool refresh}); Future<Set<String>> fetchNrfBoardNamesLower({bool refresh}); Future<OtaFwCatalog> loadCatalog(OtaFwRole role, {bool refresh}); }`

**Notes:** Step 1 uses an **in-memory** cache (per source instance). SharedPreferences-backed
persistence across launches is intentionally deferred to Step 2, where the refresh UX is finalized
(recorded so it is not a silent gap). Default branch constant is `main`.

- [ ] **Step 1: Write the failing test**

Create `test/ota/ota_github_source_test.dart`:

```dart
import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:meshcore_open/ota/ota_fw_catalog.dart';
import 'package:meshcore_open/ota/ota_github_source.dart';

http.Client _fake(Map<String, String> routes) {
  return http.MockClient((req) async {
    final url = req.url.toString();
    for (final entry in routes.entries) {
      if (url.contains(entry.key)) {
        return http.Response(entry.value, 200,
            headers: {'content-type': 'application/json'});
      }
    }
    return http.Response('not found: $url', 404);
  });
}

void main() {
  final releasesJson = jsonEncode([
    {
      'tag_name': 'repeater-v1.17.0',
      'assets': [
        {
          'name': 'ProMicro_repeater-v1.17.0-def.zip',
          'browser_download_url': 'https://example/ProMicro-1.17.0.zip'
        }
      ]
    },
    {
      'tag_name': 'repeater-v1.16.0',
      'assets': [
        {
          'name': 'ProMicro_repeater-v1.16.0-abc.zip',
          'browser_download_url': 'https://example/ProMicro-1.16.0.zip'
        },
        {
          'name': 'xiao_c3_repeater-v1.16.0-abc.bin',
          'browser_download_url': 'https://example/xiao_c3-1.16.0.bin'
        }
      ]
    },
    {
      'tag_name': 'room-server-v1.16.0',
      'assets': [
        {
          'name': 'ProMicro_room_server-v1.16.0-abc.zip',
          'browser_download_url': 'https://example/ProMicro-room.zip'
        }
      ]
    }
  ]);

  final treesJson = jsonEncode({
    'tree': [
      {'path': 'variants/promicro/platformio.ini', 'type': 'blob'},
      {'path': 'variants/xiao_c3/platformio.ini', 'type': 'blob'},
      {'path': 'README.md', 'type': 'blob'},
    ]
  });

  test('fetchReleases parses tags into role+version+assets', () async {
    final src = OtaGithubSource(client: _fake({'/releases': releasesJson}));
    final rels = await src.fetchReleases();
    expect(rels.where((r) => r.role == OtaFwRole.repeater).length, 2);
    expect(rels.where((r) => r.role == OtaFwRole.roomServer).length, 1);
    final r = rels.firstWhere((r) => r.version == '1.17.0');
    expect(r.assets.single.downloadUrl, 'https://example/ProMicro-1.17.0.zip');
  });

  test('fetchNrfBoardNamesLower keeps only NRF52_PLATFORM variants', () async {
    final src = OtaGithubSource(
        client: _fake({
      '/git/trees/': treesJson,
      'variants/promicro/platformio.ini': '-D NRF52_PLATFORM',
      'variants/xiao_c3/platformio.ini': '-D ESP32 stuff',
    }));
    final nrf = await src.fetchNrfBoardNamesLower();
    expect(nrf.contains('promicro'), true);
    expect(nrf.contains('xiao_c3'), false);
  });

  test('loadCatalog yields nRF-only devices for the chosen role', () async {
    final src = OtaGithubSource(
        client: _fake({
      '/releases': releasesJson,
      '/git/trees/': treesJson,
      'variants/promicro/platformio.ini': '-D NRF52_PLATFORM',
      'variants/xiao_c3/platformio.ini': '-D ESP32',
    }));
    final cat = await src.loadCatalog(OtaFwRole.repeater);
    expect(cat.devices, ['ProMicro']); // xiao_c3 is esp32 → excluded
    expect(cat.releases.map((r) => r.version).toList(), ['1.17.0', '1.16.0']);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; flutter test test/ota/ota_github_source_test.dart`
Expected: FAIL — `ota_github_source.dart` not found.

- [ ] **Step 3: Write minimal implementation**

Create `lib/ota/ota_github_source.dart`:

```dart
import 'dart:convert';
import 'package:http/http.dart' as http;
import 'ota_fw_catalog.dart';

/// Fetches MeshCore firmware releases + nRF variant definitions from GitHub and
/// builds an [OtaFwCatalog]. Pure-IO; all parsing/selection lives in the catalog.
class OtaGithubSource {
  static const _repo = 'meshcore-dev/MeshCore';
  static const _branch = 'main';

  final http.Client _client;
  OtaGithubSource({http.Client? client}) : _client = client ?? http.Client();

  List<OtaRelease>? _releases;
  Set<String>? _nrf;

  Future<String> _get(String url) async {
    final res = await _client.get(Uri.parse(url),
        headers: {'Accept': 'application/vnd.github+json'});
    if (res.statusCode != 200) {
      throw OtaGithubException('GET $url → HTTP ${res.statusCode}');
    }
    return res.body;
  }

  OtaFwRole? _roleForTag(String tag) {
    if (tag.startsWith('repeater-v')) return OtaFwRole.repeater;
    if (tag.startsWith('room-server-v')) return OtaFwRole.roomServer;
    return null;
  }

  Future<List<OtaRelease>> fetchReleases({bool refresh = false}) async {
    if (_releases != null && !refresh) return _releases!;
    final body =
        await _get('https://api.github.com/repos/$_repo/releases?per_page=100');
    final list = (jsonDecode(body) as List).cast<Map<String, dynamic>>();
    final out = <OtaRelease>[];
    for (final r in list) {
      final tag = r['tag_name'] as String? ?? '';
      final role = _roleForTag(tag);
      if (role == null) continue;
      final version = tag.substring(tag.indexOf('-v') + 2);
      final assets = <OtaReleaseAsset>[];
      for (final a in (r['assets'] as List? ?? const [])) {
        final m = a as Map<String, dynamic>;
        assets.add(OtaReleaseAsset(
          name: m['name'] as String,
          downloadUrl: m['browser_download_url'] as String,
        ));
      }
      out.add(OtaRelease(role: role, version: version, tag: tag, assets: assets));
    }
    return _releases = out;
  }

  Future<Set<String>> fetchNrfBoardNamesLower({bool refresh = false}) async {
    if (_nrf != null && !refresh) return _nrf!;
    final treesBody = await _get(
        'https://api.github.com/repos/$_repo/git/trees/$_branch?recursive=1');
    final tree = (jsonDecode(treesBody)['tree'] as List).cast<Map<String, dynamic>>();
    final re = RegExp(r'^variants/([^/]+)/platformio\.ini$');
    final names = <String>{};
    for (final node in tree) {
      final path = node['path'] as String? ?? '';
      final m = re.firstMatch(path);
      if (m == null) continue;
      final ini = await _get(
          'https://raw.githubusercontent.com/$_repo/$_branch/$path');
      if (platformioIsNrf(ini)) names.add(m.group(1)!.toLowerCase());
    }
    return _nrf = names;
  }

  Future<OtaFwCatalog> loadCatalog(OtaFwRole role, {bool refresh = false}) async {
    final releases = await fetchReleases(refresh: refresh);
    final nrf = await fetchNrfBoardNamesLower(refresh: refresh);
    return buildOtaCatalog(
        role: role, releases: releases, nrfBoardNamesLower: nrf);
  }
}

class OtaGithubException implements Exception {
  final String message;
  OtaGithubException(this.message);
  @override
  String toString() => 'OtaGithubException: $message';
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; flutter test test/ota/ota_github_source_test.dart`
Expected: PASS. (`http.MockClient` comes from `package:http/testing.dart`; add that import if the
analyzer flags `MockClient` — see Step 5 note.)

> If `MockClient` is unresolved, add to the test's imports:
> `import 'package:http/testing.dart';`
> Re-run Step 4 until PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/ota/ota_github_source.dart test/ota/ota_github_source_test.dart
git commit -m "feat(fotanrf): OTA GitHub source — releases + nRF variants → catalog"
```

---

### Task 4: Firmware-selection picker widget

**Files:**
- Create: `lib/screens/ota_fw_picker.dart`
- Test: `test/ota/ota_fw_picker_test.dart`

**Interfaces:**
- Consumes: `OtaGithubSource`, `OtaFwCatalog`, `OtaFwRole`, `otaPackageFileName`,
  `OtaReleaseAsset` from Tasks 1–3.
- Produces:
  - `class OtaFwSelection { final String device; final OtaFwRole role; final String currentVersion; final String targetVersion; final OtaReleaseAsset? currentAsset; final OtaReleaseAsset? targetAsset; String get packageFileName; }`
  - `class OtaFwPicker extends StatefulWidget { const OtaFwPicker({super.key, required this.source, this.onSelection}); final OtaGithubSource source; final void Function(OtaFwSelection)? onSelection; }`

**Behaviour:** on first build it loads the Repeater catalog; defaults device→`promicro`
(case-insensitive match, else first device), target→newest, current→second-newest (else newest).
Renders 4 dropdowns (Role / Device / Current FW / Target FW) and a resolved-asset preview line.
Loading and error states render plain text. Every selection change calls `onSelection`.

- [ ] **Step 1: Write the failing test**

Create `test/ota/ota_fw_picker_test.dart`:

```dart
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshcore_open/ota/ota_github_source.dart';
import 'package:meshcore_open/screens/ota_fw_picker.dart';

OtaGithubSource _source() {
  final releases = jsonEncode([
    {'tag_name': 'repeater-v1.17.0', 'assets': [
      {'name': 'ProMicro_repeater-v1.17.0-def.zip', 'browser_download_url': 'https://e/p-1.17.zip'}]},
    {'tag_name': 'repeater-v1.16.0', 'assets': [
      {'name': 'ProMicro_repeater-v1.16.0-abc.zip', 'browser_download_url': 'https://e/p-1.16.zip'}]},
  ]);
  final trees = jsonEncode({'tree': [
    {'path': 'variants/promicro/platformio.ini', 'type': 'blob'}]});
  return OtaGithubSource(client: MockClient((req) async {
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
  testWidgets('loads catalog and applies defaults (device/current/target)',
      (tester) async {
    OtaFwSelection? sel;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: OtaFwPicker(source: _source(), onSelection: (s) => sel = s),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('ProMicro'), findsWidgets); // device dropdown value
    expect(sel, isNotNull);
    expect(sel!.device, 'ProMicro');
    expect(sel!.targetVersion, '1.17.0'); // newest
    expect(sel!.currentVersion, '1.16.0'); // second-newest
    expect(sel!.packageFileName,
        'ProMicro_repeater_v1.16.0_to_v1.17.0.otapkg.json');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; flutter test test/ota/ota_fw_picker_test.dart`
Expected: FAIL — `ota_fw_picker.dart` not found.

- [ ] **Step 3: Write minimal implementation**

Create `lib/screens/ota_fw_picker.dart`:

```dart
import 'package:flutter/material.dart';
import '../ota/ota_fw_catalog.dart';
import '../ota/ota_github_source.dart';

class OtaFwSelection {
  final String device;
  final OtaFwRole role;
  final String currentVersion;
  final String targetVersion;
  final OtaReleaseAsset? currentAsset;
  final OtaReleaseAsset? targetAsset;
  const OtaFwSelection({
    required this.device,
    required this.role,
    required this.currentVersion,
    required this.targetVersion,
    required this.currentAsset,
    required this.targetAsset,
  });

  String get packageFileName => otaPackageFileName(
        device: device,
        role: role,
        currentVersion: currentVersion,
        targetVersion: targetVersion,
      );
}

class OtaFwPicker extends StatefulWidget {
  final OtaGithubSource source;
  final void Function(OtaFwSelection)? onSelection;
  const OtaFwPicker({super.key, required this.source, this.onSelection});
  @override
  State<OtaFwPicker> createState() => _OtaFwPickerState();
}

class _OtaFwPickerState extends State<OtaFwPicker> {
  OtaFwRole _role = OtaFwRole.repeater;
  OtaFwCatalog? _cat;
  String? _error;
  bool _loading = true;

  String? _device;
  String? _current;
  String? _target;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cat = await widget.source.loadCatalog(_role);
      if (!mounted) return;
      setState(() {
        _cat = cat;
        _applyDefaults(cat);
        _loading = false;
      });
      _emit();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _applyDefaults(OtaFwCatalog cat) {
    _device = cat.devices.firstWhere(
      (d) => d.toLowerCase() == 'promicro',
      orElse: () => cat.devices.isNotEmpty ? cat.devices.first : '',
    );
    final versions = cat.releases.map((r) => r.version).toList();
    _target = versions.isNotEmpty ? versions.first : null;
    _current = versions.length > 1 ? versions[1] : _target;
  }

  void _emit() {
    final cat = _cat;
    if (cat == null || _device == null || _current == null || _target == null) {
      return;
    }
    widget.onSelection?.call(OtaFwSelection(
      device: _device!,
      role: _role,
      currentVersion: _current!,
      targetVersion: _target!,
      currentAsset: cat.assetFor(_device!, _current!),
      targetAsset: cat.assetFor(_device!, _target!),
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(8),
        child: Row(children: [
          SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 8),
          Text('Načítavam firmware z GitHubu…'),
        ]),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: Row(children: [
          Expanded(child: Text('GitHub chyba: $_error')),
          TextButton(onPressed: _load, child: const Text('Skúsiť znova')),
        ]),
      );
    }
    final cat = _cat!;
    final versions = cat.releases.map((r) => r.version).toList();
    final targetAsset =
        (_device != null && _target != null) ? cat.assetFor(_device!, _target!) : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      DropdownButtonFormField<OtaFwRole>(
        initialValue: _role,
        decoration: const InputDecoration(
            labelText: 'Rola firmvéru', border: OutlineInputBorder(), isDense: true),
        items: const [
          DropdownMenuItem(value: OtaFwRole.repeater, child: Text('Repeater')),
          DropdownMenuItem(value: OtaFwRole.roomServer, child: Text('Room Server')),
        ],
        onChanged: (v) {
          if (v == null) return;
          setState(() => _role = v);
          _load();
        },
      ),
      const SizedBox(height: 8),
      DropdownButtonFormField<String>(
        initialValue: _device,
        isExpanded: true,
        decoration: const InputDecoration(
            labelText: 'Zariadenie', border: OutlineInputBorder(), isDense: true),
        items: [
          for (final d in cat.devices) DropdownMenuItem(value: d, child: Text(d)),
        ],
        onChanged: (v) {
          setState(() => _device = v);
          _emit();
        },
      ),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: _current,
            isExpanded: true,
            decoration: const InputDecoration(
                labelText: 'Current FW',
                border: OutlineInputBorder(),
                isDense: true),
            items: [
              for (final v in versions)
                DropdownMenuItem(value: v, child: Text('v$v')),
            ],
            onChanged: (v) {
              setState(() => _current = v);
              _emit();
            },
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: _target,
            isExpanded: true,
            decoration: const InputDecoration(
                labelText: 'Target FW',
                border: OutlineInputBorder(),
                isDense: true),
            items: [
              for (final v in versions)
                DropdownMenuItem(value: v, child: Text('v$v')),
            ],
            onChanged: (v) {
              setState(() => _target = v);
              _emit();
            },
          ),
        ),
      ]),
      const SizedBox(height: 6),
      Text(
        targetAsset == null
            ? 'Pre toto zariadenie/verziu nie je vhodný asset (bin/zip).'
            : 'Asset: ${targetAsset.name}',
        style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
      ),
    ]);
  }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; flutter test test/ota/ota_fw_picker_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/screens/ota_fw_picker.dart test/ota/ota_fw_picker_test.dart
git commit -m "feat(fotanrf): OTA firmware picker widget (role/device/current/target + defaults)"
```

---

### Task 5: Mount the picker at the top of the FOTA screen

**Files:**
- Modify: `lib/screens/ota_screen.dart`
- Test: `test/ota/ota_screen_smoke_test.dart` (extend)

**Interfaces:**
- Consumes: `OtaFwPicker`, `OtaFwSelection`, `OtaGithubSource`.
- Produces: nothing new (UI wiring). The existing `.otapkg.json` picker and send flow are unchanged.

**Behaviour:** Show the `OtaFwPicker` in an `ExpansionTile` titled `Priprav z GitHubu` at the very
top, above the `Vyber .otapkg.json` button. Step 1 keeps the `Create FOTA package` action disabled
(wired in Step 2); store the latest `OtaFwSelection` in state for Step 2. The picker must not break
the existing screen when offline — it shows its own error row.

- [ ] **Step 1: Write the failing test**

Extend `test/ota/ota_screen_smoke_test.dart` — add this test inside `main()`:

```dart
  testWidgets('FOTA screen shows the GitHub prepare section', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: OtaScreen(headerTarget: 'Broadcast'),
    ));
    expect(find.text('Priprav z GitHubu'), findsOneWidget);
    expect(find.text('Vyber .otapkg.json'), findsOneWidget);
  });
```

- [ ] **Step 2: Run test to verify it fails**

Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; flutter test test/ota/ota_screen_smoke_test.dart`
Expected: FAIL — `Priprav z GitHubu` not found.

- [ ] **Step 3: Write minimal implementation**

In `lib/screens/ota_screen.dart`:

1. Add imports near the top (after the existing `import '../ota/otapkg.dart';`):

```dart
import '../ota/ota_github_source.dart';
import 'ota_fw_picker.dart';
```

2. Add fields to `_OtaScreenState` (next to `OtaPkg? _pkg;`):

```dart
  final OtaGithubSource _ghSource = OtaGithubSource();
  OtaFwSelection? _fwSelection;
```

3. In `build`, insert the prepare section as the FIRST child of the outer
`Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [ … ])`, immediately before the
existing `ElevatedButton.icon(... 'Vyber .otapkg.json' ...)`:

```dart
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 8),
            title: const Text('Priprav z GitHubu'),
            children: [
              OtaFwPicker(
                source: _ghSource,
                onSelection: (s) => setState(() => _fwSelection = s),
              ),
              const SizedBox(height: 8),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  // Wired in Step 2 (download + generate). Disabled for now.
                  onPressed: null,
                  icon: const Icon(Icons.build),
                  label: Text(_fwSelection == null
                      ? 'Create FOTA package'
                      : 'Create FOTA package: ${_fwSelection!.packageFileName}'),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
```

- [ ] **Step 4: Run the focused test, then the whole OTA suite**

Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; flutter test test/ota/ota_screen_smoke_test.dart`
Expected: PASS.

Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; flutter test test/ota`
Expected: PASS (all OTA tests, previous + new).

Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; flutter analyze lib`
Expected: `No issues found!`

- [ ] **Step 5: Commit**

```bash
git add lib/screens/ota_screen.dart test/ota/ota_screen_smoke_test.dart
git commit -m "feat(fotanrf): mount GitHub firmware picker atop the FOTA screen (Step 1)"
```

---

## Step 2 preview (separate plan, not part of this one)

Recorded so the boundary is explicit; each gets resolved when Step 2 starts (spec §11):
- Wire the `Create FOTA package` button: download current+target assets (handle `.zip` → inner
  non-merged `.bin`), then generate the `.otapkg.json` and load it into the existing send flow under
  its generated filename (the unified "selected package" slot).
- Port the `hdiffi`/HPatchLite inplace delta (pure-Dart vs wasm vs FFI vs service — decide then).
- Web binary-download CORS mitigation.
- Persistent (SharedPreferences) catalog cache + explicit refresh control.
- New dependency `archive` for zip extraction.

## Self-Review

- **Spec coverage:** §3 data sources → Task 3 (releases + nRF variants; persistent cache explicitly
  deferred & noted). §4 role/device model → Tasks 1–2. §5 asset priority → Task 1 (`selectOtaAsset`).
  §6 defaults → Task 4. §8 components/isolation → new files only, `ota_screen.dart` minimally
  touched. §10 testing → pure unit tests + fake-client source tests + widget smoke. §7 generation
  and §9 download/CORS errors are Step-2 scope (out of this plan, flagged above).
- **Placeholder scan:** none — every code step is complete; the only `onPressed: null` is an
  intentional disabled control whose wiring is a named Step-2 task.
- **Type consistency:** `OtaFwRole`, `OtaReleaseAsset`, `OtaRelease`, `OtaFwCatalog.assetFor`,
  `OtaGithubSource.loadCatalog`, `OtaFwSelection.packageFileName`, `OtaFwPicker(source:onSelection:)`
  are used identically across Tasks 1→5.
