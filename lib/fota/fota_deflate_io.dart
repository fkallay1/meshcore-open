import 'dart:io';
import 'dart:typed_data';

/// Native (dart:io) raw DEFLATE with a 512-byte LZ77 window.
///
/// windowBits=9 → 2^9 = 512-byte back-reference window, which matches the
/// device puff_stream inflate window.  raw=true → no zlib header/trailer.
Uint8List deflateRaw512(Uint8List data) {
  final codec = ZLibCodec(level: 9, windowBits: 9, raw: true);
  return Uint8List.fromList(codec.encode(data));
}
