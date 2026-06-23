import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/screens/ota_screen.dart';

void main() {
  testWidgets('OtaScreen renders the file-picker button and header target',
      (tester) async {
    // No Provider<MeshCoreConnector> needed: it is only read inside _send(),
    // not during the initial build / file pick. Full OTA flow is device-tested
    // (see fkclaude/docs/e2e-checklist.md).
    await tester.pumpWidget(const MaterialApp(
      home: OtaScreen(headerTarget: 'TestRepeater'),
    ));
    expect(find.text('Vyber .otapkg.json'), findsOneWidget);
    expect(find.text('FOTA → TestRepeater'), findsOneWidget);
  });

  testWidgets('OtaScreen works as Broadcast (no repeater)', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: OtaScreen(headerTarget: 'Broadcast'),
    ));
    expect(find.text('FOTA → Broadcast'), findsOneWidget);
  });
}
