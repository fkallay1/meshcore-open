import 'dart:typed_data';

/// Sequential byte reader over an in-memory buffer.
class ByteReader {
  final Uint8List _d;
  int _p = 0;
  ByteReader(this._d);
  int get pos => _p;
  int readByte() {
    if (_p >= _d.length) {
      throw StateError('ByteReader: read past end ($_p/${_d.length})');
    }
    return _d[_p++];
  }
}

/// Decode a base-128 varint, MSB group first (matches `_cache_unpackUInt`).
/// [initial] seeds the value (e.g. the low bits packed into a tag byte);
/// [isNext] says whether at least one more 7-bit group follows.
int readVarint(ByteReader r, int initial, bool isNext) {
  var v = initial;
  while (isNext) {
    final b = r.readByte();
    v = (v << 7) | (b & 0x7F);
    isNext = (b & 0x80) != 0;
  }
  return v;
}

/// Encode [v] as a base-128 varint, MSB group first; every byte but the last
/// has its high bit set. 0 -> a single 0x00 byte.
void writeVarint(BytesBuilder b, int v) {
  final groups = <int>[];
  do {
    groups.insert(0, v & 0x7F);
    v >>= 7;
  } while (v != 0);
  for (var i = 0; i < groups.length; i++) {
    b.addByte(groups[i] | (i < groups.length - 1 ? 0x80 : 0));
  }
}

class InplaceHeader {
  final int compressType, newSize, uncompressSize, extraSafeSize;
  InplaceHeader(
      this.compressType, this.newSize, this.uncompressSize, this.extraSafeSize);
}

int _readLE(ByteReader r, int n) {
  var v = 0;
  for (var i = 0; i < n; i++) {
    v |= r.readByte() << (8 * i);
  }
  return v;
}

void _writeLE(BytesBuilder b, int v) {
  while (v > 0) {
    b.addByte(v & 0xFF);
    v >>= 8;
  }
}

int _leByteCount(int v) {
  var n = 0;
  while (v > 0) {
    n++;
    v >>= 8;
  }
  return n; // 0 for value 0
}

InplaceHeader readInplaceHeader(ByteReader r) {
  if (r.readByte() != 0x68 || r.readByte() != 0x49) {
    throw const FormatException('not an HPatchLite "hI" stream');
  }
  final compressType = r.readByte();
  final packed = r.readByte();
  final version = packed >> 6;
  final newBytes = packed & 7;
  final uncompBytes = (packed >> 3) & 7;
  final extraBytes = r.readByte();
  if (version != 2) {
    throw FormatException('expected inplace version 2, got $version');
  }
  final newSize = _readLE(r, newBytes);
  final uncompressSize = _readLE(r, uncompBytes);
  final extraSafeSize = _readLE(r, extraBytes);
  return InplaceHeader(compressType, newSize, uncompressSize, extraSafeSize);
}

/// Build the inplace-lite header for an UNCOMPRESSED diff (compressType=no,
/// uncompressSize=0), carrying [newSize] and [extraSafeSize].
Uint8List encodeInplaceHeader(
    {required int newSize, required int extraSafeSize}) {
  final newBytes = _leByteCount(newSize);
  const uncompBytes = 0; // uncompressed
  final extraBytes = _leByteCount(extraSafeSize);
  final b = BytesBuilder();
  b.addByte(0x68); // 'h'
  b.addByte(0x49); // 'I'
  b.addByte(0); // compressType_no
  b.addByte((2 << 6) | (uncompBytes << 3) | newBytes); // version 2
  b.addByte(extraBytes);
  _writeLE(b, newSize);
  // uncompressSize: 0 bytes
  _writeLE(b, extraSafeSize);
  return b.toBytes();
}
