import 'dart:convert';
import 'package:http/http.dart' as http;
import 'ota_fw_catalog.dart';

/// Fetches MeshCore firmware releases + nRF variant definitions from GitHub and
/// builds an [OtaFwCatalog]. Pure-IO; all parsing/selection lives in the catalog.
class OtaGithubSource {
  static const _repo = 'meshcore-dev/MeshCore';
  static const _branch = 'main';

  final http.Client _client;
  OtaGithubSource({http.Client? client}) : _client = client ?? http.Client();

  List<OtaRelease>? _releases;
  Set<String>? _nrf;

  Future<String> _get(String url) async {
    final res = await _client.get(Uri.parse(url),
        headers: {'Accept': 'application/vnd.github+json'});
    if (res.statusCode != 200) {
      throw OtaGithubException('GET $url → HTTP ${res.statusCode}');
    }
    return res.body;
  }

  OtaFwRole? _roleForTag(String tag) {
    if (tag.startsWith('repeater-v')) return OtaFwRole.repeater;
    if (tag.startsWith('room-server-v')) return OtaFwRole.roomServer;
    return null;
  }

  Future<List<OtaRelease>> fetchReleases({bool refresh = false}) async {
    if (_releases != null && !refresh) return _releases!;
    final body =
        await _get('https://api.github.com/repos/$_repo/releases?per_page=100');
    final list = (jsonDecode(body) as List).cast<Map<String, dynamic>>();
    final out = <OtaRelease>[];
    for (final r in list) {
      final tag = r['tag_name'] as String? ?? '';
      final role = _roleForTag(tag);
      if (role == null) continue;
      final version = tag.substring(tag.indexOf('-v') + 2);
      final assets = <OtaReleaseAsset>[];
      for (final a in (r['assets'] as List? ?? const [])) {
        final m = a as Map<String, dynamic>;
        assets.add(OtaReleaseAsset(
          name: m['name'] as String,
          downloadUrl: m['browser_download_url'] as String,
        ));
      }
      out.add(OtaRelease(role: role, version: version, tag: tag, assets: assets));
    }
    return _releases = out;
  }

  Future<Set<String>> fetchNrfBoardNamesLower({bool refresh = false}) async {
    if (_nrf != null && !refresh) return _nrf!;
    final treesBody = await _get(
        'https://api.github.com/repos/$_repo/git/trees/$_branch?recursive=1');
    final tree = (jsonDecode(treesBody)['tree'] as List).cast<Map<String, dynamic>>();
    final re = RegExp(r'^variants/([^/]+)/platformio\.ini$');
    final names = <String>{};
    for (final node in tree) {
      final path = node['path'] as String? ?? '';
      final m = re.firstMatch(path);
      if (m == null) continue;
      final ini = await _get(
          'https://raw.githubusercontent.com/$_repo/$_branch/$path');
      if (platformioIsNrf(ini)) names.add(m.group(1)!.toLowerCase());
    }
    return _nrf = names;
  }

  Future<OtaFwCatalog> loadCatalog(OtaFwRole role, {bool refresh = false}) async {
    final releases = await fetchReleases(refresh: refresh);
    final nrf = await fetchNrfBoardNamesLower(refresh: refresh);
    return buildOtaCatalog(
        role: role, releases: releases, nrfBoardNamesLower: nrf);
  }
}

class OtaGithubException implements Exception {
  final String message;
  OtaGithubException(this.message);
  @override
  String toString() => 'OtaGithubException: $message';
}
