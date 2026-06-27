import 'dart:typed_data';
import 'package:crypto/crypto.dart' as c;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/fota/models/fota_types.dart';

void main() {
  group('fotaScopePath', () {
    test('zerohop → path_len 0, empty path', () {
      final (len, path) = fotaScopePath(FotaScope.zerohop, '', 1);
      expect(len, 0);
      expect(path, isEmpty);
    });

    test('flood → path_len 0xFF, empty path', () {
      final (len, path) = fotaScopePath(FotaScope.flood, '', 1);
      expect(len, 0xFF);
      expect(path, isEmpty);
    });

    test('region floods like flood (transport code added by companion)', () {
      final (len, path) = fotaScopePath(FotaScope.region, '', 1);
      expect(len, 0xFF);
      expect(path, isEmpty);
    });

    test('direct 1-byte hops: comma-separated, path_len = hop count', () {
      final (len, path) = fotaScopePath(FotaScope.direct, '3f,a1,b2', 1);
      // hash_size=1 → upper bits 0, hop_count=3
      expect(len, 0x03);
      expect(path, [0x3f, 0xa1, 0xb2]);
    });

    test('direct 2-byte hops: path_len encodes hashsize in bits 6-7', () {
      final (len, path) = fotaScopePath(FotaScope.direct, '3fa1,b2c3', 2);
      // ((2-1)<<6)|2 = 0x42
      expect(len, 0x42);
      expect(path, [0x3f, 0xa1, 0xb2, 0xc3]);
    });

    test('direct 3-byte hops', () {
      final (len, path) = fotaScopePath(FotaScope.direct, 'aabbcc,ddeeff', 3);
      // ((3-1)<<6)|2 = 0x82
      expect(len, 0x82);
      expect(path, [0xaa, 0xbb, 0xcc, 0xdd, 0xee, 0xff]);
    });

    test('direct tolerates spaces around commas', () {
      final (len, path) = fotaScopePath(FotaScope.direct, ' 3f , a1 ', 1);
      expect(len, 0x02);
      expect(path, [0x3f, 0xa1]);
    });

    test('direct rejects token whose byte length != hashsize', () {
      expect(() => fotaScopePath(FotaScope.direct, '3f,a1', 2),
          throwsA(isA<FormatException>()));
    });

    test('direct rejects empty path', () {
      expect(() => fotaScopePath(FotaScope.direct, '', 1),
          throwsA(isA<FormatException>()));
    });

    test('direct rejects non-hex', () {
      expect(() => fotaScopePath(FotaScope.direct, 'zz', 1),
          throwsA(isA<FormatException>()));
    });

    test('direct rejects hop_count*hashsize > 64', () {
      // 22 hops * 3 bytes = 66 > 64
      final hops = List.filled(22, 'aabbcc').join(',');
      expect(() => fotaScopePath(FotaScope.direct, hops, 3),
          throwsA(isA<FormatException>()));
    });

    test('direct rejects more than 63 hops', () {
      final hops = List.filled(64, '3f').join(',');
      expect(() => fotaScopePath(FotaScope.direct, hops, 1),
          throwsA(isA<FormatException>()));
    });
  });

  group('fotaRegionKeyFromName', () {
    test('derives SHA256("#"+name)[:16] for a bare name (firmware convention)', () {
      final key = fotaRegionKeyFromName('mesh');
      final expected =
          Uint8List.fromList(c.sha256.convert('#mesh'.codeUnits).bytes.sublist(0, 16));
      expect(key, expected);
      expect(key.length, 16);
    });

    test('does not double-prefix when name already starts with #', () {
      expect(fotaRegionKeyFromName('#mesh'), fotaRegionKeyFromName('mesh'));
    });
  });
}
