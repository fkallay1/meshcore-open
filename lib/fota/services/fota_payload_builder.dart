import 'dart:typed_data';
import 'package:crypto/crypto.dart' as c;
import '../models/fota_types.dart';
import 'fota_ed25519_expanded.dart';

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

  /// RFC8032 Ed25519 signature of [meta] (64B). Zeros if [key] is null.
  ///
  /// [key] is either FotaSeedKey (pinenacl, matches pycryptodome `eddsa
  /// 'rfc8032'` byte-for-byte) or FotaExpandedKey (companion identity hex) —
  /// both verified by golden-vector tests.
  Uint8List signMeta(Uint8List meta, FotaSignKey? key) =>
      key == null ? Uint8List(64) : key.sign(meta);

  /// SIG payload. keyId==0 (v0-prefix): +4B signer pubkey prefix -> 103 B;
  /// keyId>=1 (legacy, old FW): 99 B, s_authors[keyId-1] on the receiver.
  Uint8List buildSig(Uint8List meta, FotaSignKey? key, int keyId) {
    if (keyId == 0 && key == null) {
      throw ArgumentError('key_id=0 (v0-prefix) requires a signing key');
    }
    final sig = signMeta(meta, key);
    final oldSha256 = meta.sublist(70, 102);
    final b = BytesBuilder();
    b.addByte(kFotaPktHdrSig);
    b.addByte(kFotaProtInfV0);
    b.add(oldSha256);
    b.addByte(keyId & 0xFF);
    b.add(sig);
    if (keyId == 0) b.add(key!.pub.sublist(0, 4));
    final out = b.toBytes();
    assert(out.length == (keyId == 0 ? 103 : 99),
        'SIG must be ${keyId == 0 ? 103 : 99}B, is ${out.length}');
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
