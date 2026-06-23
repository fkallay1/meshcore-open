import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class OtaKeyStore {
  static const _key = 'ota_ed25519_seed';
  final FlutterSecureStorage _s;
  OtaKeyStore([FlutterSecureStorage? s]) : _s = s ?? const FlutterSecureStorage();

  /// Extract the 32-byte Ed25519 seed from a PKCS#8 DER (RFC 8410).
  /// Standard encoding is 48 bytes: 16-byte prefix + 32-byte seed.
  static Uint8List seedFromPkcs8Der(Uint8List der) {
    if (der.length < 32) throw ArgumentError('DER too short for Ed25519 key');
    return Uint8List.fromList(der.sublist(der.length - 32));
  }

  Future<void> importSeed(Uint8List seed32) async {
    if (seed32.length != 32) throw ArgumentError('seed must be 32 bytes');
    await _s.write(key: _key, value: _hex(seed32));
  }

  Future<Uint8List?> loadSeed() async {
    final v = await _s.read(key: _key);
    if (v == null) return null;
    return Uint8List.fromList(
        [for (var i = 0; i < v.length; i += 2) int.parse(v.substring(i, i + 2), radix: 16)]);
  }

  Future<void> clear() => _s.delete(key: _key);

  static String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}
