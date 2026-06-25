/// Trigger a browser file download for [url] (web only). On web this is a
/// normal navigation/download — NOT subject to CORS, unlike a programmatic
/// fetch — so it works for GitHub release assets the app cannot fetch+read.
/// Native platforms never call this (they download directly via http).
library;

export 'fota_browser_download_stub.dart'
    if (dart.library.js_interop) 'fota_browser_download_web.dart';
