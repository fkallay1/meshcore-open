import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/ota/ota_deflate_web.dart'; // direct import bypasses the conditional export

void main() {
  test('web deflate output is RAW deflate (no zlib header)', () {
    final data = Uint8List.fromList(List.generate(256, (i) => i));
    final out = deflateRaw512(data);
    expect(out[0], isNot(0x78)); // 0x78 = zlib header first byte
  });

  test('web deflate stays within a 512-byte window (device-decodable)', () {
    // 4 KB highly-redundant buffer: with an UNCAPPED window an LZ77 pass would
    // emit a back-reference of distance ~2-4 KB (> 512). Decoding with a
    // 512-window decoder then THROWS — catching the exact device failure mode.
    final data = Uint8List(4096)..fillRange(0, 4096, 0xAB);
    final compressed = deflateRaw512(data);
    // Device-equivalent decoder: raw deflate, 512-byte window (windowBits 9).
    final decoded = Uint8List.fromList(
        ZLibCodec(raw: true, windowBits: 9).decode(compressed));
    expect(decoded, equals(data));
  });

  test('web deflate round-trips a mixed/less-redundant 3 KB buffer under 512 window', () {
    final data = Uint8List(3000);
    for (var i = 0; i < data.length; i++) {
      data[i] = ((i * 31 + (i ~/ 7)) & 0xFF);
    }
    final compressed = deflateRaw512(data);
    final decoded = Uint8List.fromList(
        ZLibCodec(raw: true, windowBits: 9).decode(compressed));
    expect(decoded, equals(data));
  });
}
