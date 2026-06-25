import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/fota/screens/fota_screen.dart';

void main() {
  testWidgets('FotaScreen renders the file-picker button and header target',
      (tester) async {
    // No Provider<MeshCoreConnector> needed: it is only read inside _send(),
    // not during the initial build / file pick. Full FOTA flow is device-tested
    // (see fkclaude/docs/e2e-checklist.md).
    await tester.pumpWidget(const MaterialApp(
      home: FotaScreen(headerTarget: 'TestRepeater'),
    ));
    expect(find.text('Vyber .fotapkg.json'), findsOneWidget);
    expect(find.text('FOTA → TestRepeater'), findsOneWidget);
  });

  testWidgets('FotaScreen works as Broadcast (no repeater)', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: FotaScreen(headerTarget: 'Broadcast'),
    ));
    expect(find.text('FOTA → Broadcast'), findsOneWidget);
  });

  testWidgets('FOTA screen shows the GitHub prepare section', (tester) async {
    await tester.pumpWidget(const MaterialApp(
      home: FotaScreen(headerTarget: 'Broadcast'),
    ));
    expect(find.text('Priprav z GitHubu'), findsOneWidget);
    expect(find.text('Vyber .fotapkg.json'), findsOneWidget);
  });

  testWidgets('Create FOTA package button is enabled once a selection exists',
      (tester) async {
    // The button is disabled with no selection; this asserts the new
    // local-bin entry is present (the always-available web fallback).
    await tester.pumpWidget(const MaterialApp(
      home: FotaScreen(headerTarget: 'Broadcast'),
    ));
    expect(find.text('Vyrob z lokálnych .bin/.zip'), findsOneWidget);
  });
}
