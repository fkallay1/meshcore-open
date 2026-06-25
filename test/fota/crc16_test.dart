import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/fota/fota_types.dart';

void main() {
  test('crc16Ccitt matches python crc16 golden', () {
    final g = jsonDecode(File('test/fixtures/fota_golden.json').readAsStringSync());
    final data = _hex(g['inputs']['chunk_data_hex'] as String);
    expect(crc16Ccitt(data), g['crc16_of_chunk_data'] as int);
  });
  test('crc16Ccitt of empty is 0xFFFF', () {
    expect(crc16Ccitt(Uint8List(0)), 0xFFFF);
  });
}

Uint8List _hex(String s) => Uint8List.fromList(
    [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
