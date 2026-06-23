import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/ota_key_store.dart';

void main() {
  test('seedFromPkcs8Der extracts the 32B seed (matches fixture seed)', () {
    // A 48-byte Ed25519 PKCS#8 DER whose seed is 00..1f (same as golden seed).
    final seedHex = File('test/fixtures/test_ed25519_seed.hex').readAsStringSync().trim();
    final seed = Uint8List.fromList(
        [for (var i = 0; i < seedHex.length; i += 2) int.parse(seedHex.substring(i, i + 2), radix: 16)]);
    // Standard PKCS#8 Ed25519 prefix (RFC 8410), 16 bytes, then 32B seed:
    final prefix = Uint8List.fromList([
      0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20
    ]);
    final der = Uint8List.fromList([...prefix, ...seed]);
    expect(OtaKeyStore.seedFromPkcs8Der(der), seed);
  });
}
