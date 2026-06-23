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
