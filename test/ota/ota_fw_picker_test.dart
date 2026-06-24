import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshcore_open/ota/ota_github_source.dart';
import 'package:meshcore_open/ota/ota_fw_source.dart';
import 'package:meshcore_open/screens/ota_fw_picker.dart';

OtaFwSource _source(String repo) {
  final releases = jsonEncode([
    {'tag_name': 'repeater-v1.17.0', 'assets': [
      {'name': 'ProMicro_repeater-v1.17.0-def.zip', 'browser_download_url': 'https://e/p-1.17.zip'}]},
    {'tag_name': 'repeater-v1.16.0', 'assets': [
      {'name': 'ProMicro_repeater-v1.16.0-abc.zip', 'browser_download_url': 'https://e/p-1.16.zip'}]},
  ]);
  final trees = jsonEncode({'tree': [
    {'path': 'variants/promicro/platformio.ini', 'type': 'blob'}]});
  return OtaGithubSource(repo: repo, client: MockClient((req) async {
    final u = req.url.toString();
    if (u.contains('/releases')) return http.Response(releases, 200);
    if (u.contains('/git/trees/')) return http.Response(trees, 200);
    if (u.contains('variants/promicro/platformio.ini')) {
      return http.Response('-D NRF52_PLATFORM', 200);
    }
    return http.Response('nf', 404);
  }));
}

void main() {
  testWidgets('loads via the factory and applies defaults', (tester) async {
    OtaFwSelection? sel;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: OtaFwPicker(sourceFactory: _source, onSelection: (s) => sel = s),
      ),
    ));
    await tester.pumpAndSettle();
    expect(sel, isNotNull);
    expect(sel!.device, 'ProMicro');
    expect(sel!.targetVersion, '1.17.0');
    expect(sel!.currentVersion, '1.16.0');
    expect(sel!.packageFileName,
        'ProMicro_repeater_v1.16.0_to_v1.17.0.otapkg.json');
    // the custom-repo field is present, defaulting to meshcore-dev/MeshCore
    // (widgetWithText finds TextField ancestors of EditableText in Flutter 3.44+)
    expect(find.widgetWithText(TextField, 'meshcore-dev/MeshCore'), findsOneWidget);
    expect(find.text('meshcore-dev/MeshCore'), findsWidgets);
  });
}
