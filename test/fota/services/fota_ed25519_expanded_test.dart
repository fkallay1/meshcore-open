import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as c;
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/fota/services/fota_ed25519_expanded.dart';

Uint8List _hex(String s) => Uint8List.fromList([
      for (var i = 0; i < s.length; i += 2)
        int.parse(s.substring(i, i + 2), radix: 16)
    ]);

// msg = sha512('fota-msg-<i>') + 38x 'x' — 102 B like META (matches the python
// golden generator in MeshCore test_nrf-fota/test_fota_ed25519_expanded.py).
Uint8List _msg(int i) => Uint8List.fromList(
    c.sha512.convert(utf8.encode('fota-msg-$i')).bytes + List.filled(38, 0x78));

void main() {
  // golden vectors from test_nrf-fota/fota_ed25519_expanded.py (seed = sha256('fota-test-seed-<i>'))
  const expanded0 =
      '707e052131823f4d67165e9a1b4020cb74729c8200b076816fd68af83027267c05da049dd20134fd766fe0ddb3b0d6936e92365274ff672632b8e090213e7b2f';
  const pub0 =
      '866ca5ad06b8eec508668efa124483f1cb07ee9236db0917499201ed1cc024fd';
  const sig0 =
      '2a233a156461ee27e6c023b347c3dd0d7606b643778a36c0fb73705630ed310a2d757462aabaac78f6e82f44d05d8f0757a8ca834219ee90989caa7bdca64505';
  const expanded1 =
      'd87ab3ac996912b3803eb82ce252e61aefec9639072deca644b29023b9ecb279df56fc45e4988cead575cb59fef240056b6e23da887f9cde2c044861b48ac2b5';
  const pub1 =
      '9be5f098708d8c5fbeb7672f151266ca0b3dc48a18e5684a99cb850ffb3f3d9d';
  const sig1 =
      'dc2f416a0e99dbf42b4976a018b7850a9a92332a3f7ceeb7a4c0fa43864fdf7a4ebe2df986fcfce8a17ce8c95e7aac465140796869d0470104b77410193f2c0f';

  test('FotaExpandedKey derive pub + sign == python golden', () {
    final k0 = FotaExpandedKey(_hex(expanded0));
    expect(k0.pub, _hex(pub0));
    expect(k0.sign(_msg(0)), _hex(sig0));
    final k1 = FotaExpandedKey(_hex(expanded1));
    expect(k1.pub, _hex(pub1));
    expect(k1.sign(_msg(1)), _hex(sig1));
  });

  test('FotaSeedKey pub/sign shapes (pinenacl path unchanged)', () {
    final seed = Uint8List.fromList(
        c.sha256.convert(utf8.encode('fota-test-seed-0')).bytes);
    final k = FotaSeedKey(seed);
    expect(k.pub.length, 32);
    expect(k.sign(_msg(0)).length, 64);
  });
}
