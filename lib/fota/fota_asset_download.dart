import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:http/http.dart' as http;

class FotaDownloadException implements Exception {
  final String message;
  FotaDownloadException(this.message);
  @override
  String toString() => 'FotaDownloadException: $message';
}

/// Download a firmware binary from [url]. If [url] is a `.zip`, return the inner
/// non-merged `.bin`; otherwise return the response bytes. On web, GitHub
/// release-asset downloads are CORS-blocked and surface here as an exception —
/// callers should fall back to local-file selection.
Future<Uint8List> downloadFirmwareBin(String url, {http.Client? client}) async {
  final c = client ?? http.Client();
  try {
    http.Response res;
    try {
      res = await c.get(Uri.parse(url));
    } catch (e) {
      throw FotaDownloadException('download failed (CORS on web?): $e');
    }
    if (res.statusCode != 200) {
      throw FotaDownloadException('GET $url → HTTP ${res.statusCode}');
    }
    final bytes = res.bodyBytes;
    if (!url.toLowerCase().endsWith('.zip')) return bytes;
    return extractFirmwareBinFromZip(bytes);
  } finally {
    if (client == null) c.close();
  }
}

/// Extract the inner non-merged `.bin` from a firmware release `.zip`.
/// Throws [FotaDownloadException] if the zip is invalid or has no usable `.bin`.
/// Reused for both GitHub downloads and locally-picked `.zip` files (the web
/// CORS-free path: download the release zip in the browser, then pick it here).
Uint8List extractFirmwareBinFromZip(Uint8List zipBytes) {
  final Archive archive;
  try {
    archive = ZipDecoder().decodeBytes(zipBytes);
  } catch (e) {
    throw FotaDownloadException('not a valid .zip: $e');
  }
  for (final f in archive.files) {
    if (!f.isFile) continue;
    final name = f.name.toLowerCase();
    if (name.endsWith('.bin') && !name.contains('merged')) {
      return Uint8List.fromList(f.content as List<int>);
    }
  }
  throw FotaDownloadException('zip has no usable (non-merged) .bin');
}
