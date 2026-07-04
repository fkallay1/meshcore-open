import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

void main() {
  final pubKey = Uint8List.fromList(List.generate(32, (i) => i));

  test('buildSendReturnPathFrame = [0x70][pub_key 32B][path_len][path]', () {
    final frame =
        buildSendReturnPathFrame(pubKey, Uint8List.fromList([0xa1, 0x3f]));
    expect(frame.length, 1 + 32 + 1 + 2);
    expect(frame[0], 0x70);
    expect(frame.sublist(1, 33), pubKey);
    expect(frame[33], 2);
    expect(frame.sublist(34), [0xa1, 0x3f]);
  });

  test('buildSendReturnPathFrame accepts empty path (zero-hop direct)', () {
    final frame = buildSendReturnPathFrame(pubKey, Uint8List(0));
    expect(frame.length, 1 + 32 + 1);
    expect(frame[33], 0);
  });

  test('buildSendReturnPathFrame rejects bad pub key / too long path', () {
    expect(() => buildSendReturnPathFrame(Uint8List(31), Uint8List(0)),
        throwsArgumentError);
    expect(() => buildSendReturnPathFrame(pubKey, Uint8List(65)),
        throwsArgumentError);
  });
}
