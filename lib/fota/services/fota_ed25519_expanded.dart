import 'dart:typed_data';
import 'package:crypto/crypto.dart' as c;
import 'package:pinenacl/ed25519.dart' as nacl;

/// Jednotný podpisový kľúč pre FOTA SIG (seed .der aj companion expanded hex).
abstract class FotaSignKey {
  Uint8List get pub;
  Uint8List sign(Uint8List msg);
}

/// 32 B seed (z PKCS#8 .der / 64-znakový hex) — podpis cez pinenacl ako doteraz.
class FotaSeedKey implements FotaSignKey {
  final Uint8List seed;
  final nacl.SigningKey _sk;
  FotaSeedKey(this.seed) : _sk = nacl.SigningKey(seed: seed);
  @override
  Uint8List get pub => Uint8List.fromList(_sk.publicKey.toUint8List());
  @override
  Uint8List sign(Uint8List msg) => Uint8List.fromList(_sk.sign(msg).signature);
}

/// 64 B expandovaný kľúč (companion identity, 128-znakový hex).
///
/// Port MeshCore lib/ed25519 (orlp): companion privkey = SHA512(seed) s
/// clampingom, takže podpis expanziu preskočí a počíta priamo s [expanded].
/// Výsledok je štandardný RFC8032 podpis (na repeateri ho overí existujúci
/// fota_ed25519_verify). BigInt aritmetika stačí — podpisuje sa jedna 102 B
/// META, výkon je irelevantný. Korektnosť: golden vektory z Pythonu
/// (fota_ed25519_expanded_test.dart).
class FotaExpandedKey implements FotaSignKey {
  final Uint8List expanded;
  late final Uint8List _pub = _derivePub(expanded);
  FotaExpandedKey(this.expanded) {
    if (expanded.length != 64) {
      throw ArgumentError('expanded key must be 64 bytes');
    }
  }
  @override
  Uint8List get pub => _pub;

  @override
  Uint8List sign(Uint8List msg) {
    final a = _leToBig(expanded.sublist(0, 32));
    final prefix = expanded.sublist(32);
    final r = _leToBig(_sha512(Uint8List.fromList(prefix + msg))) % _L;
    final R = _encodePoint(_scalarMultBase(r));
    final k = _leToBig(_sha512(Uint8List.fromList(R + _pub + msg))) % _L;
    final S = (r + k * a) % _L;
    return Uint8List.fromList(R + _bigToLe(S, 32));
  }

  // ── ed25519 field/point math (ref10 ekvivalent, BigInt) ──
  static final BigInt _p = (BigInt.one << 255) - BigInt.from(19);
  static final BigInt _L = (BigInt.one << 252) +
      BigInt.parse('27742317777372353535851937790883648493');
  // Dart BigInt.% vracia nezáporný zvyšok pri kladnom module — -121665 % p je OK.
  static final BigInt _d =
      (BigInt.from(-121665) * _inv(BigInt.from(121666))) % _p;
  static final BigInt _I = BigInt.two.modPow((_p - BigInt.one) >> 2, _p);

  static BigInt _inv(BigInt x) => x.modPow(_p - BigInt.two, _p);

  static final List<BigInt> _B = _makeB();
  static List<BigInt> _makeB() {
    final by = (BigInt.from(4) * _inv(BigInt.from(5))) % _p;
    final bx = _xRecover(by);
    return [bx, by, BigInt.one, (bx * by) % _p];
  }

  static BigInt _xRecover(BigInt y) {
    final xx = ((y * y - BigInt.one) % _p) *
        _inv((_d * y * y + BigInt.one) % _p) %
        _p;
    var x = xx.modPow((_p + BigInt.from(3)) >> 3, _p);
    if ((x * x - xx) % _p != BigInt.zero) x = (x * _I) % _p;
    if (x.isOdd) x = _p - x;
    return x;
  }

  static List<BigInt> _edAdd(List<BigInt> P, List<BigInt> Q) {
    final a = ((P[1] - P[0]) * (Q[1] - Q[0])) % _p;
    final b = ((P[1] + P[0]) * (Q[1] + Q[0])) % _p;
    final cc = (P[3] * BigInt.two * _d * Q[3]) % _p;
    final dd = (P[2] * BigInt.two * Q[2]) % _p;
    final e = b - a, f = dd - cc, g = dd + cc, h = b + a;
    return [(e * f) % _p, (g * h) % _p, (f * g) % _p, (e * h) % _p];
  }

  static List<BigInt> _scalarMultBase(BigInt e) {
    var P = _B;
    var Q = [BigInt.zero, BigInt.one, BigInt.one, BigInt.zero];
    while (e > BigInt.zero) {
      if (e.isOdd) Q = _edAdd(Q, P);
      P = _edAdd(P, P);
      e >>= 1;
    }
    return Q;
  }

  static Uint8List _encodePoint(List<BigInt> P) {
    final zi = _inv(P[2]);
    final x = (P[0] * zi) % _p;
    final y = (P[1] * zi) % _p;
    final v = y | ((x & BigInt.one) << 255);
    return _bigToLe(v, 32);
  }

  static Uint8List _derivePub(Uint8List expanded64) =>
      _encodePoint(_scalarMultBase(_leToBig(expanded64.sublist(0, 32))));

  static Uint8List _sha512(Uint8List d) =>
      Uint8List.fromList(c.sha512.convert(d).bytes);

  static BigInt _leToBig(List<int> b) {
    var v = BigInt.zero;
    for (var i = b.length - 1; i >= 0; i--) {
      v = (v << 8) | BigInt.from(b[i]);
    }
    return v;
  }

  static Uint8List _bigToLe(BigInt v, int len) {
    final out = Uint8List(len);
    var x = v;
    for (var i = 0; i < len; i++) {
      out[i] = (x & BigInt.from(0xff)).toInt();
      x >>= 8;
    }
    return out;
  }
}
