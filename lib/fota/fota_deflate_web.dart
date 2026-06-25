// Web path: archive's pure-Dart DEFLATE with windowBits=9.
// Verified: archive Deflate(windowBits: 9) caps LZ77 back-references at 512
// bytes (the device puff_stream window), confirmed by
// test/fota/fota_deflate_web_test.dart round-tripping 4 KB and 3 KB buffers
// through a 512-window decoder (dart:io ZLibCodec raw:true windowBits:9).
// Output is raw DEFLATE (no zlib header).  Native (dart:io) path also uses
// windowBits=9 via ZLibCodec — both paths are exact, not best-effort.
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Web-safe pure-Dart raw DEFLATE (archive 4.x [Deflate] class, windowBits=9).
///
/// Verified to cap LZ77 back-references at ≤512 bytes — decodable by the
/// device puff_stream (512-byte window).  Output is raw DEFLATE, no zlib
/// header.  See test/fota/fota_deflate_web_test.dart for the decisive proof.
Uint8List deflateRaw512(Uint8List data) {
  // windowBits=9 (minimum accepted by Deflate._init) constrains the LZ77
  // sliding window to 512 bytes.  Confirmed by round-trip test through a
  // 512-window decoder — back-references never exceed 512 bytes in output.
  return Deflate(data, level: 9, windowBits: 9).getBytes();
}
