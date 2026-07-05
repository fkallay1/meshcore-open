import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/fota/models/fota_types.dart';

void main() {
  group('parseFotaSelection', () {
    test('single numbers and ranges, sorted & deduped', () {
      final s = parseFotaSelection('0 5 7-12 5', totalChunks: 41);
      expect(s.chunks, [0, 5, 7, 8, 9, 10, 11, 12]);
      expect(s.meta, false);
      expect(s.sig, false);
      expect(s.reportedTotal, isNull);
    });

    test('H and S, case-insensitive', () {
      final s = parseFotaSelection('h  S', totalChunks: 41);
      expect(s.chunks, isEmpty);
      expect(s.meta, true);
      expect(s.sig, true);
    });

    test('descending range normalizes', () {
      expect(parseFotaSelection('12-7', totalChunks: 41).chunks,
          [7, 8, 9, 10, 11, 12]);
    });

    test('tolerates full CLI miss line + extracts reportedTotal', () {
      final s = parseFotaSelection('FOTA miss=2/33: 12 29', totalChunks: 33);
      expect(s.chunks, [12, 29]);
      expect(s.meta, false);
      expect(s.sig, false);
      expect(s.reportedTotal, 33);
    });

    test('tolerates legacy pre-header reply "(no hdr)"', () {
      final s =
          parseFotaSelection('FOTA miss=3(no hdr): S 0-1', totalChunks: 4);
      expect(s.chunks, [0, 1]);
      expect(s.meta, false);
      expect(s.sig, true);
      expect(s.reportedTotal, isNull);
    });

    test('pre-SIG reply with META estimate "/~T(noS)" extracts the total', () {
      final s =
          parseFotaSelection('FOTA miss=4/~4(noS): S 0-1 3', totalChunks: 4);
      expect(s.chunks, [0, 1, 3]);
      expect(s.sig, true);
      expect(s.meta, false);
      expect(s.reportedTotal, 4);
    });

    test('accepts comma-separated lists (new repeater reply format)', () {
      final s = parseFotaSelection('FOTA miss=11(noHS): H,S,0-4,6-9',
          totalChunks: 12);
      expect(s.chunks, [0, 1, 2, 3, 4, 6, 7, 8, 9]);
      expect(s.meta, true);
      expect(s.sig, true);
      // mixed commas/spaces and a ",+N" overflow token
      expect(parseFotaSelection('1,3 5-6,+2', totalChunks: 10).chunks,
          [1, 3, 5, 6]);
    });

    test('no-META replies "(noH)"/"(noHS)" parse H/S tokens', () {
      final a = parseFotaSelection('FOTA miss=2(noH): H 0', totalChunks: 4);
      expect(a.chunks, [0]);
      expect(a.meta, true);
      final b = parseFotaSelection('FOTA miss=2(noHS): H S', totalChunks: 4);
      expect(b.chunks, isEmpty);
      expect(b.meta, true);
      expect(b.sig, true);
    });

    test('paren stripping keeps H/S from "(no H S)" fragments parseable', () {
      final s = parseFotaSelection('(no H S): 0-4,6-9', totalChunks: 12);
      expect(s.chunks, [0, 1, 2, 3, 4, 6, 7, 8, 9]);
      expect(s.meta, true);
      expect(s.sig, true);
    });
  });

  group('fotaExpandMissTail', () {
    test('replaces "N-??" with the range up to totalChunks-1', () {
      expect(fotaExpandMissTail('FOTA miss=11(no HS): H,S,0-4,6-9,10-??', 15),
          'FOTA miss=11(no HS): H,S,0-4,6-9,10-14');
    });

    test('short tails collapse to single / comma pair', () {
      expect(fotaExpandMissTail('H,S,10-??', 11), 'H,S,10');
      expect(fotaExpandMissTail('H,S,10-??', 12), 'H,S,10,11');
    });

    test('empty tail drops the marker and dangling separator', () {
      expect(fotaExpandMissTail('H,S,10-??', 10), 'H,S');
    });

    test('bare "??" falls back to highest mentioned chunk + 1', () {
      expect(fotaExpandMissTail('FOTA: S,0-1,??', 5), 'FOTA: S,0-1,2-4');
    });

    test('no marker / no total = unchanged', () {
      expect(fotaExpandMissTail('FOTA miss=1/4: 3', 4), 'FOTA miss=1/4: 3');
      expect(fotaExpandMissTail('0-??', 0), '0-??');
    });
  });

  group('parseFotaSelection - errors & CLI noise', () {
    test('tolerates missall line with H S and +N overflow', () {
      final s = parseFotaSelection(
          'FOTA missall=14/41: H S 3 7 19-22 +5',
          totalChunks: 41);
      expect(s.chunks, [3, 7, 19, 20, 21, 22]);
      expect(s.meta, true);
      expect(s.sig, true);
      expect(s.reportedTotal, 41);
    });

    test('plain list has null reportedTotal', () {
      expect(parseFotaSelection('12 29', totalChunks: 41).reportedTotal, isNull);
    });

    test('chunk out of range throws', () {
      expect(() => parseFotaSelection('99', totalChunks: 41),
          throwsFormatException);
    });

    test('empty selection throws', () {
      expect(() => parseFotaSelection('   ', totalChunks: 41),
          throwsFormatException);
      expect(() => parseFotaSelection('FOTA miss=0/41:', totalChunks: 41),
          throwsFormatException);
    });

    test('unknown token throws', () {
      expect(() => parseFotaSelection('12 x', totalChunks: 41),
          throwsFormatException);
    });

    test('range endpoint out of range throws', () {
      expect(() => parseFotaSelection('38-45', totalChunks: 41),
          throwsFormatException);
    });
  });

  group('fotaDirectPathFromBytes', () {
    test('formats one hop-hash per byte as 2-hex, comma-joined', () {
      expect(fotaDirectPathFromBytes(Uint8List.fromList([0x3f, 0xa1])), '3f,a1');
    });

    test('zero-pads single hop', () {
      expect(fotaDirectPathFromBytes(Uint8List.fromList([0x00])), '00');
      expect(fotaDirectPathFromBytes(Uint8List.fromList([0x05])), '05');
    });

    test('empty path → empty string', () {
      expect(fotaDirectPathFromBytes(Uint8List(0)), '');
    });

    test('round-trips through fotaScopePath (direct, hashsize 1)', () {
      final bytes = Uint8List.fromList([0x3f, 0xa1, 0xb2]);
      final str = fotaDirectPathFromBytes(bytes);
      final (pathLen, path) = fotaScopePath(FotaScope.direct, str, 1);
      expect(path, bytes);
      expect(pathLen, 3); // ((1-1)<<6)|3
    });
  });
}
