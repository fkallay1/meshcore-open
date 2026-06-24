import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshcore_open/ota/ota_github_source.dart';
import 'package:meshcore_open/screens/ota_fw_picker.dart';

OtaGithubSource _source() {
  final releases = jsonEncode([
    {'tag_name': 'repeater-v1.17.0', 'assets': [
      {'name': 'ProMicro_repeater-v1.17.0-def.zip', 'browser_download_url': 'https://e/p-1.17.zip'}]},
    {'tag_name': 'repeater-v1.16.0', 'assets': [
      {'name': 'ProMicro_repeater-v1.16.0-abc.zip', 'browser_download_url': 'https://e/p-1.16.zip'}]},
  ]);
  final trees = jsonEncode({'tree': [
    {'path': 'variants/promicro/platformio.ini', 'type': 'blob'}]});
  return OtaGithubSource(client: MockClient((req) async {
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
  testWidgets('loads catalog and applies defaults (device/current/target)',
      (tester) async {
    OtaFwSelection? sel;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: OtaFwPicker(source: _source(), onSelection: (s) => sel = s),
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('ProMicro'), findsWidgets); // device dropdown value
    expect(sel, isNotNull);
    expect(sel!.device, 'ProMicro');
    expect(sel!.targetVersion, '1.17.0'); // newest
    expect(sel!.currentVersion, '1.16.0'); // second-newest
    expect(sel!.packageFileName,
        'ProMicro_repeater_v1.16.0_to_v1.17.0.otapkg.json');
  });
}
