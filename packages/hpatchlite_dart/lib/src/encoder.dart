import 'dart:typed_data';
import 'codec.dart';

const int _minMatch = 8; // also the rolling-hash window

class _Cover {
  final int newPos, oldPos, length; // literal gap = newPos - prevNewEnd
  _Cover(this.newPos, this.oldPos, this.length);
}

int _hash8(Uint8List d, int p) {
  // FNV-1a over 8 bytes -> 32-bit
  var h = 0x811c9dc5;
  for (var i = 0; i < _minMatch; i++) {
    h ^= d[p + i];
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

/// Create a raw HPatchLite inplace-lite diff (compressType=no) turning
/// [oldData] into [newData], using a rolling-hash greedy matcher that emits
/// pure-copy covers + literal gaps. A match is accepted only when
/// (newPos - oldPos) <= [maxExtraSafeSize], keeping the patch in-place-safe
/// within a bounded device ring buffer.
Uint8List createInplaceLiteDiff(Uint8List oldData, Uint8List newData,
    {int maxExtraSafeSize = 0x4000}) {
  // 1) index old by 8-byte hash -> most recent positions (chain, capped)
  final table = <int, List<int>>{};
  for (var i = 0; i + _minMatch <= oldData.length; i++) {
    (table[_hash8(oldData, i)] ??= <int>[]).add(i);
  }

  // 2) greedy scan of new, building covers
  final covers = <_Cover>[];
  var extraSafeSize = 0;
  var i = 0;
  while (i < newData.length) {
    int bestOld = -1, bestLen = 0;
    if (i + _minMatch <= newData.length) {
      final cands = table[_hash8(newData, i)];
      if (cands != null) {
        // try recent candidates; accept only in-place-safe ones
        for (var ci = cands.length - 1; ci >= 0 && ci >= cands.length - 8; ci--) {
          final oldPos = cands[ci];
          if (i - oldPos > maxExtraSafeSize) continue; // reading too far behind
          var len = 0;
          while (oldPos + len < oldData.length &&
              i + len < newData.length &&
              oldData[oldPos + len] == newData[i + len]) {
            len++;
          }
          if (len > bestLen) {
            bestLen = len;
            bestOld = oldPos;
          }
        }
      }
    }
    if (bestLen >= _minMatch) {
      covers.add(_Cover(i, bestOld, bestLen));
      if (i - bestOld > extraSafeSize) extraSafeSize = i - bestOld;
      i += bestLen;
    } else {
      i++; // literal; absorbed into the next cover's gap (or the trailing cover)
    }
  }

  // 3) ensure newPosBack reaches newSize: append a terminal zero-length cover
  //    carrying any trailing literal gap.
  //    Use oldPos = newData.length so (newPos - oldPos) = 0, keeping the
  //    terminal cover in-place-safe regardless of extraSafeSize.
  final lastEnd = covers.isEmpty ? 0 : covers.last.newPos + covers.last.length;
  if (lastEnd < newData.length) {
    covers.add(_Cover(newData.length, newData.length, 0)); // gap = trailing literals
  }

  // 4) encode
  final body = BytesBuilder();
  writeVarint(body, covers.length);
  var newPosBack = 0, oldPosBack = 0;
  for (final cv in covers) {
    writeVarint(body, cv.length);
    // oldPos delta with sign, packed into a tag byte (isNotNeedSubDiff=1)
    final delta = cv.oldPos - oldPosBack;
    final sign = delta < 0 ? 1 : 0;
    final mag = delta.abs();
    _writeTagAndOldPos(body, mag, sign, isNotNeedSubDiff: true);
    writeVarint(body, cv.newPos - newPosBack);
    // literal gap bytes inline
    for (var p = newPosBack; p < cv.newPos; p++) {
      body.addByte(newData[p]);
    }
    newPosBack = cv.newPos + cv.length;
    oldPosBack = cv.oldPos + cv.length;
  }

  final header =
      encodeInplaceHeader(newSize: newData.length, extraSafeSize: extraSafeSize);
  return (BytesBuilder()
        ..add(header)
        ..add(body.toBytes()))
      .toBytes();
}

/// Emit the tag byte + trailing 7-bit groups for an oldPos magnitude.
/// Decoder: v = tag&31 (top 5 bits), continue if tag&32, then 7-bit groups
/// MSB-first (bit7 = continue). bit6 = sign, bit7 = isNotNeedSubDiff.
void _writeTagAndOldPos(BytesBuilder b, int mag, int sign,
    {required bool isNotNeedSubDiff}) {
  // peel 7-bit groups from the bottom until the remainder fits in 5 bits
  final groups = <int>[];
  var tmp = mag;
  while (tmp > 31) {
    groups.insert(0, tmp & 0x7F);
    tmp >>= 7;
  }
  final top5 = tmp & 31;
  final hasMore = groups.isNotEmpty;
  final tag = (isNotNeedSubDiff ? 0x80 : 0) |
      (sign << 6) |
      (hasMore ? 0x20 : 0) |
      top5;
  b.addByte(tag);
  for (var i = 0; i < groups.length; i++) {
    b.addByte(groups[i] | (i < groups.length - 1 ? 0x80 : 0));
  }
}
