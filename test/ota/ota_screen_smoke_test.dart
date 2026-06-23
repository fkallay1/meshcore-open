import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/models/contact.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart' show advTypeRepeater;
import 'package:meshcore_open/screens/ota_screen.dart';

void main() {
  testWidgets('OtaScreen renders the file-picker button and title', (tester) async {
    final repeater = Contact(
      publicKey: Uint8List.fromList(List<int>.generate(32, (i) => i)),
      name: 'TestRepeater',
      type: advTypeRepeater,
      pathLength: 0,
      path: Uint8List(0),
      lastSeen: DateTime(2026, 1, 1),
    );
    // No Provider<MeshCoreConnector> needed: it is only read inside _send(),
    // not during the initial build / file pick. Full OTA flow is device-tested
    // (see fkclaude/docs/e2e-checklist.md).
    await tester.pumpWidget(MaterialApp(
      home: OtaScreen(repeater: repeater, password: ''),
    ));
    expect(find.text('Vyber .otapkg.json'), findsOneWidget);
    expect(find.text('OTA → TestRepeater'), findsOneWidget);
  });
}
