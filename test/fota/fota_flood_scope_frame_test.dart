import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

void main() {
  test('buildSetFloodScopeKeyFrame = [54][0][16-byte key]', () {
    final key = Uint8List.fromList(List<int>.generate(16, (i) => i + 1));
    final frame = buildSetFloodScopeKeyFrame(key);
    expect(frame.length, 18);
    expect(frame[0], cmdSetFloodScope); // 54
    expect(frame[1], 0);
    expect(frame.sublist(2), key);
  });

  test('buildSetFloodScopeKeyFrame rejects non-16-byte key', () {
    expect(() => buildSetFloodScopeKeyFrame(Uint8List(8)),
        throwsA(isA<ArgumentError>()));
  });

  test('buildSetFloodScopeUnscopedFrame = [54][1] (force unscoped flood)', () {
    final frame = buildSetFloodScopeUnscopedFrame();
    expect(frame, [cmdSetFloodScope, 1]);
  });
}
