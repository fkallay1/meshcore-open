import 'dart:io';
import 'package:test/test.dart';

void main() {
  test('golden fixtures exist and are non-empty', () {
    for (final f in ['old.bin', 'new.bin', 'golden.inplace']) {
      final file = File('test/fixtures/$f');
      expect(file.existsSync(), isTrue, reason: '$f missing');
      expect(file.lengthSync(), greaterThan(0));
    }
  });
}
