import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as c;
import 'package:test/test.dart';
import 'package:hpatchlite_dart/hpatchlite_dart.dart';

void main() {
  test('applies the reference hdiffi golden patch to reconstruct new.bin', () {
    final old = File('test/fixtures/old.bin').readAsBytesSync();
    final newExpected = File('test/fixtures/new.bin').readAsBytesSync();
    final diff = File('test/fixtures/golden.inplace').readAsBytesSync();
    final got = applyInplaceLiteDiff(
        Uint8List.fromList(diff), Uint8List.fromList(old));
    expect(got.length, newExpected.length);
    expect(c.sha256.convert(got).toString(),
        c.sha256.convert(newExpected).toString());
  });
}
