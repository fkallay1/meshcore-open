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

/// A PlatformIO variant is nRF52 if it extends the shared `nrf52_base` — every
/// nRF variant does, and the `NRF52_PLATFORM` define lives in that base in the
/// ROOT platformio.ini, not in each variant file (so checking only the variant
/// file for the define misses almost all of them, e.g. promicro). Also accept a
/// literal define for the few variants that repeat it directly.
bool platformioIsNrf(String iniContent) =>
    iniContent.contains('nrf52_base') || iniContent.contains('NRF52_PLATFORM');

/// Normalize a board/asset name for comparison: lowercase and drop `-`/`_`
/// separators. Asset names don't always match the variant folder name's
/// separators (e.g. variant folder `t1000-e` ships as asset `t1000e`).
String _normBoard(String s) => s.toLowerCase().replaceAll(RegExp(r'[-_]'), '');

bool deviceIsNrf(String device, Set<String> nrfBoardNamesLower) {
  final d = _normBoard(device);
  return nrfBoardNamesLower.any((b) => d.startsWith(_normBoard(b)));
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
  final sorted = devices.toList()
    ..sort((a, b) => a.toLowerCase().compareTo(b.toLowerCase()));
  return OtaFwCatalog(role: role, releases: forRole, devices: sorted);
}
