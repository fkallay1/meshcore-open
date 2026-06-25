import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/fota_fw_catalog.dart';
import '../models/fota_fw_source.dart';

/// Fetches MeshCore firmware releases + nRF variant definitions from GitHub and
/// builds an [FotaFwCatalog]. Pure-IO; all parsing/selection lives in the catalog.
class FotaGithubSource implements FotaFwSource {
  final String repo;
  final String branch;
  final http.Client _client;
  FotaGithubSource({
    this.repo = 'meshcore-dev/MeshCore',
    this.branch = 'main',
    http.Client? client,
  }) : _client = client ?? http.Client();

  List<FotaRelease>? _releases;
  Set<String>? _nrf;

  Future<String> _getApi(String url) async {
    final res = await _client.get(Uri.parse(url),
        headers: {'Accept': 'application/vnd.github+json'});
    if (res.statusCode != 200) {
      throw FotaGithubException('GET $url → HTTP ${res.statusCode}');
    }
    return res.body;
  }

  Future<String> _getRaw(String url) async {
    final res = await _client.get(Uri.parse(url));
    if (res.statusCode != 200) {
      throw FotaGithubException('GET $url → HTTP ${res.statusCode}');
    }
    return res.body;
  }

  static final _tagRe = RegExp(r'^(?:repeater|room-server)-v(.+)$');

  FotaFwRole? _roleForTag(String tag) {
    if (tag.startsWith('repeater-v')) return FotaFwRole.repeater;
    if (tag.startsWith('room-server-v')) return FotaFwRole.roomServer;
    return null;
  }

  Future<List<FotaRelease>> fetchReleases({bool refresh = false}) async {
    if (_releases != null && !refresh) return _releases!;
    final body = await _getApi(
        'https://api.github.com/repos/$repo/releases?per_page=100');
    final list = (jsonDecode(body) as List).cast<Map<String, dynamic>>();
    final out = <FotaRelease>[];
    for (final r in list) {
      final tag = r['tag_name'] as String? ?? '';
      final m = _tagRe.firstMatch(tag);
      if (m == null) continue; // not an FOTA firmware release tag
      final version = m.group(1)!;
      final role = _roleForTag(tag)!;
      final assets = <FotaReleaseAsset>[];
      for (final a in (r['assets'] as List? ?? const [])) {
        final m = a as Map<String, dynamic>;
        assets.add(FotaReleaseAsset(
          name: m['name'] as String,
          downloadUrl: m['browser_download_url'] as String,
        ));
      }
      out.add(FotaRelease(role: role, version: version, tag: tag, assets: assets));
    }
    return _releases = out;
  }

  Future<Set<String>> fetchNrfBoardNamesLower({bool refresh = false}) async {
    if (_nrf != null && !refresh) return _nrf!;
    final treesBody = await _getApi(
        'https://api.github.com/repos/$repo/git/trees/$branch?recursive=1');
    final tree = (jsonDecode(treesBody)['tree'] as List).cast<Map<String, dynamic>>();
    final re = RegExp(r'^variants/([^/]+)/platformio\.ini$');
    final futures = <Future<String?>>[];
    for (final node in tree) {
      final m = re.firstMatch(node['path'] as String? ?? '');
      if (m == null) continue;
      final board = m.group(1)!.toLowerCase();
      futures.add(_getRaw(
              'https://raw.githubusercontent.com/$repo/$branch/${node['path']}')
          .then((ini) => platformioIsNrf(ini) ? board : null));
    }
    final results = await Future.wait(futures);
    final names = results.whereType<String>().toSet();
    return _nrf = names;
  }

  @override
  Future<FotaFwCatalog> loadCatalog(FotaFwRole role, {bool refresh = false}) async {
    final releases = await fetchReleases(refresh: refresh);
    final nrf = await fetchNrfBoardNamesLower(refresh: refresh);
    return buildFotaCatalog(
        role: role, releases: releases, nrfBoardNamesLower: nrf);
  }
}

class FotaGithubException implements Exception {
  final String message;
  FotaGithubException(this.message);
  @override
  String toString() => 'FotaGithubException: $message';
}
