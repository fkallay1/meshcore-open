import 'dart:typed_data';
import 'codec.dart';

/// Apply a raw HPatchLite inplace-lite [diff] to [oldData], returning new data.
/// Mirrors `hpatchi_inplace_open` + `hpatch_lite_patch` from the device applier,
/// reading old via random access (so it verifies cover/format correctness; it
/// does NOT model the in-place ring buffer — see the encoder's safety sim).
/// Supports pure-copy covers and additive sub-diff covers.
Uint8List applyInplaceLiteDiff(Uint8List diff, Uint8List oldData) {
  final r = ByteReader(diff);
  final h = readInplaceHeader(r);
  if (h.compressType != 0) {
    throw const FormatException('compressed diff not supported by this applier');
  }
  final out = Uint8List(h.newSize);
  var newPosBack = 0;
  var oldPosBack = 0;
  var coverCount = readVarint(r, 0, true);
  while (coverCount-- > 0) {
    final coverLength = readVarint(r, 0, true);
    final tag = r.readByte();
    final oldMag = readVarint(r, tag & 31, (tag & 32) != 0);
    final isNotNeedSubDiff = (tag & 128) != 0;
    final coverOldPos =
        (tag & 64) != 0 ? oldPosBack - oldMag : oldPosBack + oldMag;
    final coverNewPos = readVarint(r, 0, true) + newPosBack;
    // literal gap: bytes copied straight from the diff stream
    for (var i = newPosBack; i < coverNewPos; i++) {
      out[i] = r.readByte();
    }
    // copy from old (+ additive sub-diff when present)
    for (var k = 0; k < coverLength; k++) {
      var v = oldData[coverOldPos + k];
      if (!isNotNeedSubDiff) v = (v + r.readByte()) & 0xFF;
      out[coverNewPos + k] = v;
    }
    newPosBack = coverNewPos + coverLength;
    oldPosBack = coverOldPos + coverLength;
  }
  // trailing literal bytes after last cover
  for (var i = newPosBack; i < h.newSize; i++) {
    out[i] = r.readByte();
  }
  return out;
}
