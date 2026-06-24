import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:meshcore_open/ota/ota_asset_download.dart';

void main() {
  test('returns raw bytes for a .bin url', () async {
    final body = Uint8List.fromList([1, 2, 3, 4]);
    final c = MockClient((_) async => http.Response.bytes(body, 200));
    final got = await downloadFirmwareBin('https://e/fw.bin', client: c);
    expect(got, body);
  });

  test('extracts the inner non-merged .bin from a .zip', () async {
    final fw = Uint8List.fromList(List.generate(50, (i) => i));
    final archive = Archive()
      ..addFile(ArchiveFile('Device_repeater-merged.bin', 3, [9, 9, 9]))
      ..addFile(ArchiveFile('Device_repeater.bin', fw.length, fw))
      ..addFile(ArchiveFile('readme.txt', 2, [65, 66]));
    final zipBytes = ZipEncoder().encode(archive)!;
    final c = MockClient(
        (_) async => http.Response.bytes(Uint8List.fromList(zipBytes), 200));
    final got = await downloadFirmwareBin('https://e/fw.zip', client: c);
    expect(got, fw); // not the -merged.bin, not the txt
  });

  test('throws OtaDownloadException on HTTP error', () async {
    final c = MockClient((_) async => http.Response('nope', 404));
    expect(() => downloadFirmwareBin('https://e/fw.bin', client: c),
        throwsA(isA<OtaDownloadException>()));
  });

  test('throws when a .zip has no usable .bin', () async {
    final archive = Archive()
      ..addFile(ArchiveFile('only.uf2', 2, [1, 2]));
    final zipBytes = ZipEncoder().encode(archive)!;
    final c = MockClient(
        (_) async => http.Response.bytes(Uint8List.fromList(zipBytes), 200));
    expect(() => downloadFirmwareBin('https://e/fw.zip', client: c),
        throwsA(isA<OtaDownloadException>()));
  });
}
