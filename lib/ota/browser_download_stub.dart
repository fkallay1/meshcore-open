/// Non-web stub. Native platforms download firmware directly via http, so they
/// never trigger a browser download; calling this off-web is a programming error.
void triggerBrowserDownload(String url, String filename) {
  throw UnsupportedError('triggerBrowserDownload is web-only');
}
