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

  // String form for the `fota missall <cesta>` / `fota setpath <cesta>` CLI
  // argument: same reversal, but keeps hops as comma tokens whose width
  // (2/4/6 hex chars) tells the repeater the hash size.
  test('fotaReturnPathArg reverses hop tokens (1B)', () {
    expect(fotaReturnPathArg('3f,a1', 1), 'a1,3f');
    expect(fotaReturnPathArg('11,22,33', 1), '33,22,11');
    expect(fotaReturnPathArg('3f', 1), '3f');
  });

  test('fotaReturnPathArg keeps token width for 2B/3B hashes', () {
    expect(fotaReturnPathArg('11aa,22bb', 2), '22bb,11aa');
    expect(fotaReturnPathArg('112233,445566', 3), '445566,112233');
  });

  test('fotaReturnPathArg normalizes whitespace and rejects invalid input', () {
    expect(fotaReturnPathArg(' 3f , a1 ', 1), 'a1,3f');
    expect(() => fotaReturnPathArg('', 1), throwsFormatException);
    expect(() => fotaReturnPathArg('3f,a1', 2), throwsFormatException);
    expect(() => fotaReturnPathArg('zz', 1), throwsFormatException);
  });
}
