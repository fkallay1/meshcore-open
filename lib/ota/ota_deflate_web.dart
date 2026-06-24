// Web fallback: archive's pure-Dart DEFLATE does not expose a configurable
// LZ77 window, so the 512-byte back-reference bound the device puff_stream
// requires is BEST-EFFORT on web.  For small patches back-references stay
// within 512; large patches generated on web may exceed it.  Native (dart:io)
// is exact.  TODO(step2b/follow-up): true 512-window pure-Dart deflate if web
// large-patch generation is needed.
import 'dart:typed_data';

import 'package:archive/archive.dart';

/// Web-safe pure-Dart raw DEFLATE (archive 4.x [Deflate] class, windowBits=9
/// best-effort — see file-level comment).
Uint8List deflateRaw512(Uint8List data) {
  // Deflate(data, level: 9, windowBits: 9) uses the pure-Dart DEFLATE engine.
  // windowBits=9 is the minimum accepted (≥9 per the archive Deflate._init
  // check), so back-references are constrained to ≤512 bytes on a best-effort
  // basis.  The output is raw DEFLATE (no zlib header) because Deflate emits
  // raw bitstream directly — there is no adler32/zlib wrapper added.
  return Deflate(data, level: 9, windowBits: 9).getBytes();
}
