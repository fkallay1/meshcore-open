import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as c;
import 'package:hpatchlite_dart/hpatchlite_dart.dart';
import '../helpers/fota_deflate.dart';

class FotaBuildException implements Exception {
  final String message;
  FotaBuildException(this.message);
  @override
  String toString() => 'FotaBuildException: $message';
}

class FotaBuildParams {
  final String channelName;
  final int channelIdx;
  final double freqMHz, bwKHz;
  final int sf, cr;
  final String scope, path;
  FotaBuildParams({
    required this.channelName,
    required this.channelIdx,
    required this.freqMHz,
    required this.bwKHz,
    required this.sf,
    required this.cr,
    this.scope = 'zerohop',
    this.path = '',
  });
}

Uint8List _u32le(int v) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);

/// raw inplace diff -> raw DEFLATE (512-byte window, windowBits=9) ->
/// staged ZLIB blob: ['Z','L','I','B'][uncompSize u32le][newFwSize u32le][deflate].
///
/// Calls [deflateRaw512] (platform-conditional via fota_deflate.dart):
/// - Native: dart:io ZLibCodec(raw:true, windowBits:9) — exact 512-byte window.
/// - Web: archive Deflate(windowBits:9) — verified exact 512-byte window
///   (see fota_deflate_web.dart and test/fota/fota_deflate_web_test.dart).
/// Output is decodable by the device puff_stream (512-byte window).
Uint8List buildStagedPatch(Uint8List oldFw, Uint8List newFw) {
  final raw = createInplaceLiteDiff(oldFw, newFw);
  // deflateRaw512: raw DEFLATE, 512-byte LZ77 window (windowBits=9).
  // On native uses dart:io ZLibCodec (exact); on web uses archive Deflate
  // (best-effort 512-byte window — see fota_deflate_web.dart).
  final deflate = deflateRaw512(raw);
  final b = BytesBuilder()
    ..add(ascii.encode('ZLIB'))
    ..add(_u32le(raw.length))
    ..add(_u32le(newFw.length))
    ..add(deflate);
  return b.toBytes();
}

String buildFotaPkgJson(
    {required Uint8List oldFw,
    required Uint8List newFw,
    required FotaBuildParams p}) {
  // self-check: never emit a silently-wrong package
  final raw = createInplaceLiteDiff(oldFw, newFw);
  final applied = applyInplaceLiteDiff(raw, oldFw);
  if (applied.length != newFw.length) {
    throw FotaBuildException(
        'self-check failed: length ${applied.length} != ${newFw.length}');
  }
  for (var i = 0; i < newFw.length; i++) {
    if (applied[i] != newFw[i]) {
      throw FotaBuildException('self-check failed at byte $i');
    }
  }
  final staged = buildStagedPatch(oldFw, newFw);
  final pkg = {
    'format': 'mc-fotanrf-fotapkg/1',
    'created': '1970-01-01T00:00:00Z',
    'channel': {'name': p.channelName, 'idx': p.channelIdx},
    'radio': {'freq': p.freqMHz, 'bw': p.bwKHz, 'sf': p.sf, 'cr': p.cr},
    'scope': p.scope,
    'path': p.path,
    'fw': {
      'old_sha256': _hex(c.sha256.convert(oldFw).bytes),
      'new_sha256': _hex(c.sha256.convert(newFw).bytes),
      'old_fw_size': oldFw.length,
      'patch_sha256': _hex(c.sha256.convert(staged).bytes),
      'patch_len': staged.length,
    },
    'patch_b64': base64.encode(staged),
  };
  return const JsonEncoder.withIndent('  ').convert(pkg);
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
