import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshcore_open/fota/services/fota_github_source.dart';
import 'package:meshcore_open/fota/models/fota_fw_source.dart';
import 'package:meshcore_open/fota/screens/fota_fw_picker.dart';

FotaFwSource _source(String repo) {
  final releases = jsonEncode([
    {'tag_name': 'repeater-v1.17.0', 'assets': [
      {'name': 'ProMicro_repeater-v1.17.0-def.zip', 'browser_download_url': 'https://e/p-1.17.zip'}]},
    {'tag_name': 'repeater-v1.16.0', 'assets': [
      {'name': 'ProMicro_repeater-v1.16.0-abc.zip', 'browser_download_url': 'https://e/p-1.16.zip'}]},
  ]);
  final trees = jsonEncode({'tree': [
    {'path': 'variants/promicro/platformio.ini', 'type': 'blob'}]});
  return FotaGithubSource(repo: repo, client: MockClient((req) async {
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
    FotaFwSelection? sel;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: FotaFwPicker(sourceFactory: _source, onSelection: (s) => sel = s),
      ),
    ));
    await tester.pumpAndSettle();
    expect(sel, isNotNull);
    expect(sel!.device, 'ProMicro');
    expect(sel!.targetVersion, '1.17.0');
    expect(sel!.currentVersion, '1.16.0');
    expect(sel!.packageFileName,
        'ProMicro_repeater_v1.16.0_to_v1.17.0.fotapkg.json');
    expect(find.text('ProMicro'), findsWidgets);            // device dropdown rendered
    // repo-source dropdown defaults to the meshcore-dev/MeshCore preset
    expect(find.text('meshcore-dev/MeshCore'), findsWidgets);
  });

  testWidgets('selecting Custom reveals a free-text repo field', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: FotaFwPicker(sourceFactory: _source)),
    ));
    await tester.pumpAndSettle();
    // no custom TextField until "Custom…" is chosen
    expect(find.widgetWithText(TextField, 'meshcore-dev/MeshCore'), findsNothing);
    await tester.tap(find.text('meshcore-dev/MeshCore').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Custom…').last);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, 'meshcore-dev/MeshCore'), findsOneWidget);
  });
}
