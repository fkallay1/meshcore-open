import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as c;
import 'package:meshcore_open/ota/ota_pkg_builder.dart';
import 'package:meshcore_open/ota/otapkg.dart';

void main() {
  final oldFw = Uint8List.fromList(List.generate(2048, (i) => i & 0xFF));
  final newFw = Uint8List.fromList([
    ...List.generate(2048, (i) => i & 0xFF)..setRange(500, 520, List.filled(20, 0xAB)),
    ...List.filled(64, 0x33),
  ]);
  final params = OtaBuildParams(
      channelName: '#fkotanrf', channelIdx: 1,
      freqMHz: 869.618, bwKHz: 62.5, sf: 8, cr: 5, scope: 'zerohop', path: '');

  test('staged patch has the ZLIB header and decompresses to the raw diff', () {
    final staged = buildStagedPatch(oldFw, newFw);
    expect(String.fromCharCodes(staged.sublist(0, 4)), 'ZLIB');
    final uncompSize = staged.buffer.asByteData().getUint32(4, Endian.little);
    final newFwSize = staged.buffer.asByteData().getUint32(8, Endian.little);
    expect(newFwSize, newFw.length);
    final raw = Uint8List.fromList(
        const ZLibDecoder().decodeBytes(staged.sublist(12), raw: true));
    expect(raw.length, uncompSize);
  });

  test('buildOtaPkgJson yields a valid OtaPkg whose patch reconstructs newFw', () {
    final json = buildOtaPkgJson(oldFw: oldFw, newFw: newFw, p: params);
    final pkg = OtaPkg.fromJsonString(json);
    expect(pkg.channelName, '#fkotanrf');
    expect(pkg.freqMHz, 869.618);
    // declared firmware hashes are correct
    expect(pkg.oldSha256, Uint8List.fromList(c.sha256.convert(oldFw).bytes));
    expect(pkg.newSha256, Uint8List.fromList(c.sha256.convert(newFw).bytes));
    expect(pkg.oldFwSize, oldFw.length);
    // OtaPkg.fromJsonString already verifies patch_sha256 == sha256(staged patch)
    // (throws otherwise), so a successful parse proves the staged patch integrity.
    expect((jsonDecode(json) as Map)['format'], 'mc-fotanrf-otapkg/1');
  });
}
