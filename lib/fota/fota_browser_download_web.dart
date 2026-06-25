import 'package:web/web.dart' as web;

/// Web implementation: synthesize an `<a download>` and click it. For a
/// cross-origin GitHub release URL the browser ignores the [filename] hint and
/// uses the server's Content-Disposition name (the real asset name) — which is
/// exactly what we want. This is a download, not a fetch, so no CORS applies.
void triggerBrowserDownload(String url, String filename) {
  final a = web.document.createElement('a') as web.HTMLAnchorElement
    ..href = url
    ..download = filename
    ..target = '_blank';
  web.document.body!.appendChild(a);
  a.click();
  a.remove();
}
