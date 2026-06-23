import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

void main() {
  test('buildSendChannelDataFrame matches python META frame (zerohop, idx=1)', () {
    final g = jsonDecode(File('test/fixtures/ota_golden.json').readAsStringSync());
    final meta = _hex(g['meta_hex'] as String);
    final ts = g['inputs']['ts'] as int;
    final data = BytesBuilder()
      ..add(_u32le(ts))
      ..add(meta);
    final frame = buildSendChannelDataFrame(1, 0, Uint8List(0), 0x07A0, data.toBytes());
    expect(_toHex(frame), g['channel_data_frame_hex'] as String);
  });
}

Uint8List _u32le(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);
Uint8List _hex(String s) => Uint8List.fromList(
    [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
String _toHex(Uint8List b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
