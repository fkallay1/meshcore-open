import 'dart:math';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:hpatchlite_dart/hpatchlite_dart.dart';
import 'package:hpatchlite_dart/src/codec.dart';

// Re-derive extraSafeSize from the diff header and prove in-place safety:
// replay covers while modelling the device's delayed write pointer
// (write lags the new cursor by extraSafeSize); assert no cover ever reads an
// old byte that has already been overwritten.
void _assertInplaceSafe(Uint8List diff, int oldLen) {
  final r = ByteReader(diff);
  final h = readInplaceHeader(r);
  var newPosBack = 0, oldPosBack = 0;
  var coverCount = readVarint(r, 0, true);
  while (coverCount-- > 0) {
    final coverLength = readVarint(r, 0, true);
    final tag = r.readByte();
    final oldMag = readVarint(r, tag & 31, (tag & 32) != 0);
    final coverOldPos =
        (tag & 64) != 0 ? oldPosBack - oldMag : oldPosBack + oldMag;
    final coverNewPos = readVarint(r, 0, true) + newPosBack;
    for (var i = newPosBack; i < coverNewPos; i++) {
      r.readByte(); // literal
    }
    // safety: writePtr at the moment we read oldPos+k is (coverNewPos+k)-extraSafeSize-1
    expect(coverNewPos - coverOldPos <= h.extraSafeSize, isTrue,
        reason: 'cover newPos=$coverNewPos oldPos=$coverOldPos exceeds extraSafeSize=${h.extraSafeSize}');
    newPosBack = coverNewPos + coverLength;
    oldPosBack = coverOldPos + coverLength;
  }
}

void _roundTrip(List<int> oldL, List<int> newL) {
  final old = Uint8List.fromList(oldL);
  final nw = Uint8List.fromList(newL);
  final diff = createInplaceLiteDiff(old, nw);
  expect(applyInplaceLiteDiff(diff, old), nw);
  _assertInplaceSafe(diff, old.length);
}

void main() {
  test('identical', () => _roundTrip(
      List.generate(500, (i) => i & 0xFF), List.generate(500, (i) => i & 0xFF)));
  test('empty new', () => _roundTrip([1, 2, 3], []));
  test('empty old', () => _roundTrip([], [9, 8, 7, 6, 5]));
  test('append', () {
    final base = List.generate(800, (i) => (i * 7) & 0xFF);
    _roundTrip(base, [...base, 1, 2, 3, 4, 5, 6, 7, 8]);
  });
  test('truncate', () {
    final base = List.generate(800, (i) => (i * 7) & 0xFF);
    _roundTrip(base, base.sublist(0, 600));
  });
  test('mid change', () {
    final base = List.generate(1024, (i) => i & 0xFF);
    final nw = [...base];
    for (var i = 400; i < 420; i++) {
      nw[i] = 0xEE;
    }
    _roundTrip(base, nw);
  });
  test('pseudo-random pair stays correct and safe', () {
    final rnd = Random(42);
    final old = List.generate(4000, (_) => rnd.nextInt(256));
    final nw = [...old];
    for (var i = 0; i < 300; i++) {
      nw[rnd.nextInt(nw.length)] = rnd.nextInt(256);
    }
    _roundTrip(old, nw);
  });
}
