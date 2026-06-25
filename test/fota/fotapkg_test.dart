import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/fota/fotapkg.dart';
import 'package:meshcore_open/fota/fota_types.dart';

String _x(Uint8List b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();

void main() {
  test('parses raw (unsigned) sample package and builds a job', () {
    final pkg = FotaPkg.fromJsonString(File('test/fixtures/sample.fotapkg.json').readAsStringSync());
    expect(pkg.channelName, '#fkotanrf');
    expect(pkg.channelIdx, 1);
    expect(pkg.scope, FotaScope.zerohop);
    expect(pkg.sf, 8);
    final job = pkg.toJob();
    expect(job.isPresigned, false);
    expect(job.oldFwSize, 442000);
    expect(job.patch.length, pkg.patchLen);
  });

  test('rejects a package with a corrupted patch hash', () {
    // Corrupt the declared patch_sha256 so the sha256-mismatch branch fires
    // with an FotaPkgException (not a raw cast/type error).
    final src = File('test/fixtures/sample.fotapkg.json').readAsStringSync();
    final pkg = FotaPkg.fromJsonString(src);
    final good = _x(pkg.patchSha256);
    final corrupted = (good[0] == '0' ? 'f' : '0') + good.substring(1);
    final bad = src.replaceFirst(good, corrupted);
    expect(bad == src, isFalse, reason: 'fixture must contain the patch_sha256 hex');
    expect(() => FotaPkg.fromJsonString(bad), throwsA(isA<FotaPkgException>()));
  });
}
