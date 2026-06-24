import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshcore_open/ota/ota_fw_catalog.dart';
import 'package:meshcore_open/ota/ota_github_source.dart';

http.Client _fake(Map<String, String> routes) {
  return MockClient((req) async {
    final url = req.url.toString();
    for (final entry in routes.entries) {
      if (url.contains(entry.key)) {
        return http.Response(entry.value, 200,
            headers: {'content-type': 'application/json'});
      }
    }
    return http.Response('not found: $url', 404);
  });
}

void main() {
  final releasesJson = jsonEncode([
    {
      'tag_name': 'repeater-v1.17.0',
      'assets': [
        {
          'name': 'ProMicro_repeater-v1.17.0-def.zip',
          'browser_download_url': 'https://example/ProMicro-1.17.0.zip'
        }
      ]
    },
    {
      'tag_name': 'repeater-v1.16.0',
      'assets': [
        {
          'name': 'ProMicro_repeater-v1.16.0-abc.zip',
          'browser_download_url': 'https://example/ProMicro-1.16.0.zip'
        },
        {
          'name': 'xiao_c3_repeater-v1.16.0-abc.bin',
          'browser_download_url': 'https://example/xiao_c3-1.16.0.bin'
        }
      ]
    },
    {
      'tag_name': 'room-server-v1.16.0',
      'assets': [
        {
          'name': 'ProMicro_room_server-v1.16.0-abc.zip',
          'browser_download_url': 'https://example/ProMicro-room.zip'
        }
      ]
    }
  ]);

  final treesJson = jsonEncode({
    'tree': [
      {'path': 'variants/promicro/platformio.ini', 'type': 'blob'},
      {'path': 'variants/xiao_c3/platformio.ini', 'type': 'blob'},
      {'path': 'README.md', 'type': 'blob'},
    ]
  });

  test('fetchReleases parses tags into role+version+assets', () async {
    final src = OtaGithubSource(client: _fake({'/releases': releasesJson}));
    final rels = await src.fetchReleases();
    expect(rels.where((r) => r.role == OtaFwRole.repeater).length, 2);
    expect(rels.where((r) => r.role == OtaFwRole.roomServer).length, 1);
    final r = rels.firstWhere((r) => r.version == '1.17.0');
    expect(r.assets.single.downloadUrl, 'https://example/ProMicro-1.17.0.zip');
  });

  test('fetchNrfBoardNamesLower keeps only NRF52_PLATFORM variants', () async {
    final src = OtaGithubSource(
        client: _fake({
      '/git/trees/': treesJson,
      'variants/promicro/platformio.ini': '-D NRF52_PLATFORM',
      'variants/xiao_c3/platformio.ini': '-D ESP32 stuff',
    }));
    final nrf = await src.fetchNrfBoardNamesLower();
    expect(nrf.contains('promicro'), true);
    expect(nrf.contains('xiao_c3'), false);
  });

  test('loadCatalog yields nRF-only devices for the chosen role', () async {
    final src = OtaGithubSource(
        client: _fake({
      '/releases': releasesJson,
      '/git/trees/': treesJson,
      'variants/promicro/platformio.ini': '-D NRF52_PLATFORM',
      'variants/xiao_c3/platformio.ini': '-D ESP32',
    }));
    final cat = await src.loadCatalog(OtaFwRole.repeater);
    expect(cat.devices, ['ProMicro']); // xiao_c3 is esp32 → excluded
    expect(cat.releases.map((r) => r.version).toList(), ['1.17.0', '1.16.0']);
  });

  test('fetchReleases cache is bypassed on refresh: true', () async {
    int hits = 0;
    final c = MockClient((_) async {
      hits++;
      return http.Response(releasesJson, 200);
    });
    final src = OtaGithubSource(client: c);
    await src.fetchReleases();              // populates cache (hit 1)
    await src.fetchReleases();              // served from cache (no hit)
    await src.fetchReleases(refresh: true); // bypasses cache (hit 2)
    expect(hits, 2);
  });

  test('throws OtaGithubException on non-200', () async {
    final src = OtaGithubSource(
        client: MockClient((_) async => http.Response('nope', 404)));
    expect(() => src.fetchReleases(), throwsA(isA<OtaGithubException>()));
  });
}
