import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/fota/models/fota_types.dart';

void main() {
  // The app's Direct path field holds the forward route client -> repeater
  // (hop order as the client transmits). The PATH packet payload must carry
  // the route the REPEATER uses to reach the client, i.e. the same hops in
  // reverse order (see MeshCore handleReturnPathRetry: an incoming flood
  // packet's accumulated path is already in sender->me order, which is what
  // the sender needs; our forward path is the opposite, so reverse it).
  test('fotaReturnPathBytes reverses the forward comma path', () {
    expect(fotaReturnPathBytes('3f,a1'), [0xa1, 0x3f]);
    expect(fotaReturnPathBytes('11,22,33'), [0x33, 0x22, 0x11]);
  });

  test('fotaReturnPathBytes single hop stays as-is', () {
    expect(fotaReturnPathBytes('3f'), [0x3f]);
  });

  test('fotaReturnPathBytes rejects empty / invalid path', () {
    expect(() => fotaReturnPathBytes(''), throwsFormatException);
    expect(() => fotaReturnPathBytes('zz'), throwsFormatException);
    expect(() => fotaReturnPathBytes('3f,a1b2'), throwsFormatException);
  });
}
