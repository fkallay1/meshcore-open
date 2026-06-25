import 'dart:typed_data';
import 'package:crypto/crypto.dart' as c;
import 'package:pinenacl/ed25519.dart' as nacl;
import '../models/fota_types.dart';

class FotaPayloadBuilder {
  static Uint8List sha256(Uint8List data) => Uint8List.fromList(c.sha256.convert(data).bytes);

  Uint8List buildMeta(int patchSize, Uint8List patchSha256, Uint8List newSha256,
      Uint8List oldSha256) {
    final b = BytesBuilder();
    b.addByte(kFotaPktHeader);
    b.addByte(kFotaProtInfV0);
    b.add(_u32le(patchSize));
    b.add(patchSha256);
    b.add(newSha256);
    b.add(oldSha256);
    final out = b.toBytes();
    assert(out.length == 102, 'META must be 102B, is ${out.length}');
    return out;
  }

  /// RFC8032 Ed25519 signature of [meta] (64B). Zeros if [seed32] is null.
  ///
  /// Uses pinenacl (TweetNaCl) — pointycastle 4.0.0 has no Ed25519. Ed25519 is
  /// deterministic, so this matches pycryptodome `eddsa 'rfc8032'` byte-for-byte
  /// (verified by the golden-vector test `buildSig`).
  Uint8List signMeta(Uint8List meta, Uint8List? seed32) {
    if (seed32 == null) return Uint8List(64);
    final sk = nacl.SigningKey(seed: seed32);
    return Uint8List.fromList(sk.sign(meta).signature);
  }

  Uint8List buildSig(Uint8List meta, Uint8List? seed32, int keyId) {
    final sig = signMeta(meta, seed32);
    final oldSha256 = meta.sublist(70, 102);
    final b = BytesBuilder();
    b.addByte(kFotaPktHdrSig);
    b.addByte(kFotaProtInfV0);
    b.add(oldSha256);
    b.addByte(keyId & 0xFF);
    b.add(sig);
    final out = b.toBytes();
    assert(out.length == 99, 'SIG must be 99B, is ${out.length}');
    return out;
  }

  Uint8List buildChunk(int idx, Uint8List data, int oldFwSize, Uint8List oldSha256Prefix4) {
    final b = BytesBuilder();
    b.addByte(kFotaPktChunk);
    b.add(_u16le(idx));
    b.add(_u16le(crc16Ccitt(data)));
    b.add(_u32le(oldFwSize));
    b.add(oldSha256Prefix4);
    b.add(data);
    return b.toBytes();
  }

  Uint8List buildApply(Uint8List patchSha256) {
    final b = BytesBuilder()
      ..addByte(kFotaPktApply)
      ..add(patchSha256);
    return b.toBytes();
  }

  static Uint8List _u16le(int v) =>
      Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little);
  static Uint8List _u32le(int v) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);
}
