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
}
