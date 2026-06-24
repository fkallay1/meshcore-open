import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;

class OtaDownloadException implements Exception {
  final String message;
  OtaDownloadException(this.message);
  @override
  String toString() => 'OtaDownloadException: $message';
}

/// Download a firmware binary from [url]. If [url] is a `.zip`, return the inner
/// non-merged `.bin`; otherwise return the response bytes. On web, GitHub
/// release-asset downloads are CORS-blocked and surface here as an exception —
/// callers should fall back to local-file selection.
Future<Uint8List> downloadFirmwareBin(String url, {http.Client? client}) async {
  final c = client ?? http.Client();
  http.Response res;
  try {
    res = await c.get(Uri.parse(url));
  } catch (e) {
    throw OtaDownloadException('download failed (CORS on web?): $e');
  }
  if (res.statusCode != 200) {
    throw OtaDownloadException('GET $url → HTTP ${res.statusCode}');
  }
  final bytes = res.bodyBytes;
  if (!url.toLowerCase().endsWith('.zip')) return bytes;

  final archive = ZipDecoder().decodeBytes(bytes);
  for (final f in archive.files) {
    if (!f.isFile) continue;
    final name = f.name.toLowerCase();
    if (name.endsWith('.bin') && !name.contains('merged')) {
      return Uint8List.fromList(f.content as List<int>);
    }
  }
  throw OtaDownloadException('zip has no usable (non-merged) .bin');
}
