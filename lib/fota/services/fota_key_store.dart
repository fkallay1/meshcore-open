import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'fota_ed25519_expanded.dart';

class FotaKeyStore {
  static const _key = 'fota_ed25519_seed';
  static const _signKey = 'fota_sign_key'; // "seed:<64hex>" | "expanded:<128hex>"
  final FlutterSecureStorage _s;
  FotaKeyStore([FlutterSecureStorage? s]) : _s = s ?? const FlutterSecureStorage();

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

  /// Import from hex: 64 chars = Ed25519 seed (.der), 128 chars = expanded
  /// companion identity key (the "long hex" shown by the companion app).
  Future<void> importHex(String hex) async {
    final h = hex.trim().toLowerCase().replaceAll(RegExp(r'[\s:]'), '');
    if (!RegExp(r'^[0-9a-f]+$').hasMatch(h)) {
      throw ArgumentError('not a hex string');
    }
    if (h.length == 64) {
      await _s.write(key: _signKey, value: 'seed:$h');
    } else if (h.length == 128) {
      await _s.write(key: _signKey, value: 'expanded:$h');
    } else {
      throw ArgumentError(
          'expected 64 (seed) or 128 (expanded) hex chars, got ${h.length}');
    }
  }

  /// Unified signing key: new slot first, fallback to the legacy seed slot.
  Future<FotaSignKey?> loadSignKey() async {
    final v = await _s.read(key: _signKey);
    if (v != null) {
      final i = v.indexOf(':');
      final bytes = _unhex(v.substring(i + 1));
      return v.startsWith('seed:') ? FotaSeedKey(bytes) : FotaExpandedKey(bytes);
    }
    final legacy = await loadSeed(); // old slot fota_ed25519_seed
    return legacy == null ? null : FotaSeedKey(legacy);
  }

  Future<void> clearSignKey() async {
    await _s.delete(key: _signKey);
    await clear();
  }

  static Uint8List _unhex(String v) => Uint8List.fromList(
      [for (var i = 0; i < v.length; i += 2) int.parse(v.substring(i, i + 2), radix: 16)]);

  static String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}
