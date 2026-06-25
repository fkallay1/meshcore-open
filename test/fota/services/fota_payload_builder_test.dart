import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/fota/services/fota_payload_builder.dart';

void main() {
  late Map g;
  setUpAll(() => g = jsonDecode(File('test/fixtures/fota_golden.json').readAsStringSync()));

  test('buildMeta matches python (102B)', () {
    final b = FotaPayloadBuilder();
    final meta = b.buildMeta(g['inputs']['patch_size'], _h(g['inputs']['patch_sha256']),
        _h(g['inputs']['new_sha256']), _h(g['inputs']['old_sha256']));
    expect(meta.length, 102);
    expect(_x(meta), g['meta_hex']);
  });

  test('buildSig matches python (99B) — pointycastle == pycryptodome rfc8032', () {
    final b = FotaPayloadBuilder();
    final meta = _h(g['meta_hex']);
    final sig = b.buildSig(meta, _h(g['seed_hex']), g['inputs']['key_id']);
    expect(sig.length, 99);
    expect(_x(sig), g['sig_hex']);
  });

  test('buildChunk matches python', () {
    final b = FotaPayloadBuilder();
    final chunk = b.buildChunk(g['inputs']['chunk_idx'], _h(g['inputs']['chunk_data_hex']),
        g['inputs']['old_fw_size'], _h(g['inputs']['old_sha256']).sublist(0, 4));
    expect(_x(chunk), g['chunk_hex']);
  });

  test('buildApply matches python (33B)', () {
    final b = FotaPayloadBuilder();
    final apply = b.buildApply(_h(g['inputs']['patch_sha256']));
    expect(_x(apply), g['apply_hex']);
  });
}

Uint8List _h(String s) => Uint8List.fromList(
    [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
String _x(Uint8List b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
