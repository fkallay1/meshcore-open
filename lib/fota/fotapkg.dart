import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as c;
import 'fota_types.dart';

class FotaPkgException implements Exception {
  final String message;
  FotaPkgException(this.message);
  @override
  String toString() => 'FotaPkgException: $message';
}

class FotaPkg {
  final String channelName;
  final int channelIdx;
  final double freqMHz, bwKHz;
  final int sf, cr;
  final FotaScope scope;
  final String pathHex;
  final Uint8List oldSha256, newSha256, patchSha256, patch;
  final int oldFwSize, patchLen, keyId;
  final Uint8List? meta, sig; // present iff pre-signed

  FotaPkg({
    required this.channelName,
    required this.channelIdx,
    required this.freqMHz,
    required this.bwKHz,
    required this.sf,
    required this.cr,
    required this.scope,
    required this.pathHex,
    required this.oldSha256,
    required this.newSha256,
    required this.patchSha256,
    required this.patch,
    required this.oldFwSize,
    required this.patchLen,
    required this.keyId,
    this.meta,
    this.sig,
  });

  factory FotaPkg.fromJsonString(String s) {
    final Map j;
    try {
      j = jsonDecode(s) as Map;
    } catch (e) {
      throw FotaPkgException('invalid JSON: $e');
    }
    // Accept the new FOTA magic and the legacy OTA magic (pre-rename packages).
    if (j['format'] != 'mc-fotanrf-fotapkg/1' &&
        j['format'] != 'mc-fotanrf-otapkg/1') {
      throw FotaPkgException('unsupported format: ${j['format']}');
    }
    final fw = j['fw'];
    if (fw is! Map) throw FotaPkgException('missing fw block');
    final patch = _b64(j['patch_b64'], 'patch_b64');
    final patchLen = (fw['patch_len'] as num).toInt();
    if (patch.length != patchLen) {
      throw FotaPkgException('patch_len $patchLen != actual ${patch.length}');
    }
    final patchSha = Uint8List.fromList(c.sha256.convert(patch).bytes);
    final declared = _hex(fw['patch_sha256'], 'patch_sha256');
    if (!_eq(patchSha, declared)) throw FotaPkgException('patch sha256 mismatch');

    final ch = j['channel'] as Map, radio = j['radio'] as Map;
    final signed = j['signed'];
    return FotaPkg(
      channelName: ch['name'] as String,
      channelIdx: (ch['idx'] as num).toInt(),
      freqMHz: (radio['freq'] as num).toDouble(),
      bwKHz: (radio['bw'] as num).toDouble(),
      sf: (radio['sf'] as num).toInt(),
      cr: (radio['cr'] as num).toInt(),
      scope: _scope(j['scope'] as String?),
      pathHex: (j['path'] as String?) ?? '',
      oldSha256: _hex(fw['old_sha256'], 'old_sha256'),
      newSha256: _hex(fw['new_sha256'], 'new_sha256'),
      patchSha256: patchSha,
      patch: patch,
      oldFwSize: (fw['old_fw_size'] as num).toInt(),
      patchLen: patchLen,
      keyId: signed is Map ? (signed['key_id'] as num).toInt() : 1,
      meta: signed is Map ? _b64(signed['meta_b64'], 'meta_b64') : null,
      sig: signed is Map ? _b64(signed['sig_b64'], 'sig_b64') : null,
    );
  }

  FotaJob toJob() => FotaJob(
        patch: patch,
        oldSha256: oldSha256,
        newSha256: newSha256,
        oldFwSize: oldFwSize,
        keyId: keyId,
        presignedMeta: meta,
        presignedSig: sig,
      );

  static FotaScope _scope(String? s) {
    switch (s) {
      case 'flood':
        return FotaScope.flood;
      case 'direct':
        return FotaScope.direct;
      case 'zerohop':
      case null:
        return FotaScope.zerohop;
      default:
        throw FotaPkgException('unknown scope: $s');
    }
  }

  static Uint8List _b64(dynamic v, String f) {
    if (v is! String) throw FotaPkgException('missing $f');
    try {
      return Uint8List.fromList(base64.decode(v));
    } catch (e) {
      throw FotaPkgException('bad base64 in $f');
    }
  }

  static Uint8List _hex(dynamic v, String f) {
    if (v is! String || v.length.isOdd) throw FotaPkgException('bad hex in $f');
    return Uint8List.fromList(
        [for (var i = 0; i < v.length; i += 2) int.parse(v.substring(i, i + 2), radix: 16)]);
  }

  static bool _eq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}
