import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:hpatchlite_dart/src/codec.dart';

void main() {
  test('varint round-trips MSB-first with continuation', () {
    for (final v in [0, 1, 31, 127, 128, 300, 16384, 1 << 20, 0x7FFFFFF]) {
      final b = BytesBuilder();
      writeVarint(b, v);
      final r = ByteReader(b.toBytes());
      expect(readVarint(r, 0, true), v, reason: 'value $v');
    }
  });

  test('value 0 encodes as a single 0x00 byte', () {
    final b = BytesBuilder();
    writeVarint(b, 0);
    expect(b.toBytes(), Uint8List.fromList([0x00]));
  });

  test('inplace header round-trips newSize + extraSafeSize', () {
    final bytes = encodeInplaceHeader(newSize: 1056, extraSafeSize: 40);
    expect(bytes[0], 0x68); // 'h'
    expect(bytes[1], 0x49); // 'I'
    expect(bytes[2], 0); // compressType_no
    expect(bytes[3] >> 6, 2); // inplace version code
    final h = readInplaceHeader(ByteReader(bytes));
    expect(h.newSize, 1056);
    expect(h.uncompressSize, 0);
    expect(h.extraSafeSize, 40);
    expect(h.compressType, 0);
  });
}
