import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/ota/ota_fw_catalog.dart';

void main() {
  group('parseOtaAssetName', () {
    test('parses a repeater zip', () {
      final info = parseOtaAssetName('ProMicro_repeater-v1.16.0-07a3ca9.zip');
      expect(info, isNotNull);
      expect(info!.device, 'ProMicro');
      expect(info.role, OtaFwRole.repeater);
      expect(info.version, '1.16.0');
      expect(info.ext, 'zip');
      expect(info.isMerged, false);
    });

    test('parses a room_server bin with underscored device', () {
      final info = parseOtaAssetName('Heltec_v3_room_server-v1.16.0-07a3ca9.bin');
      expect(info!.device, 'Heltec_v3');
      expect(info.role, OtaFwRole.roomServer);
      expect(info.ext, 'bin');
      expect(info.isMerged, false);
    });

    test('flags merged bins', () {
      final info = parseOtaAssetName('Heltec_v3_room_server-v1.16.0-07a3ca9-merged.bin');
      expect(info!.isMerged, true);
    });

    test('returns null for non-matching names', () {
      expect(parseOtaAssetName('README.txt'), isNull);
    });
  });

  group('selectOtaAsset', () {
    final assets = [
      OtaReleaseAsset(name: 'ProMicro_repeater-v1.16.0-abc.uf2', downloadUrl: 'u'),
      OtaReleaseAsset(name: 'ProMicro_repeater-v1.16.0-abc.zip', downloadUrl: 'z'),
      OtaReleaseAsset(name: 'Heltec_v3_repeater-v1.16.0-abc-merged.bin', downloadUrl: 'm'),
      OtaReleaseAsset(name: 'Heltec_v3_repeater-v1.16.0-abc.bin', downloadUrl: 'b'),
    ];
    test('prefers a non-merged bin over zip/uf2', () {
      final a = selectOtaAsset(assets, 'Heltec_v3', OtaFwRole.repeater);
      expect(a!.downloadUrl, 'b');
    });
    test('falls back to zip when no standalone bin', () {
      final a = selectOtaAsset(assets, 'ProMicro', OtaFwRole.repeater);
      expect(a!.downloadUrl, 'z'); // never the .uf2
    });
    test('never selects a merged bin or a uf2', () {
      final onlyBad = [
        OtaReleaseAsset(name: 'X_repeater-v1.0.0-abc-merged.bin', downloadUrl: 'm'),
        OtaReleaseAsset(name: 'X_repeater-v1.0.0-abc.uf2', downloadUrl: 'u'),
      ];
      expect(selectOtaAsset(onlyBad, 'X', OtaFwRole.repeater), isNull);
    });
  });

  test('otaPackageFileName carries device + both versions', () {
    final n = otaPackageFileName(
      device: 'ProMicro', role: OtaFwRole.repeater,
      currentVersion: '1.16.0', targetVersion: '1.17.0');
    expect(n, 'ProMicro_repeater_v1.16.0_to_v1.17.0.otapkg.json');
  });

  test('compareOtaVersionsDesc orders newest first', () {
    final v = ['1.16.0', '1.17.0', '1.16.2']..sort(compareOtaVersionsDesc);
    expect(v, ['1.17.0', '1.16.2', '1.16.0']);
  });

  group('nRF detection', () {
    test('platformioIsNrf detects nRF variants (extends nrf52_base or literal define)', () {
      // promicro-style: extends the shared nRF base; NRF52_PLATFORM lives in that
      // base in the ROOT platformio.ini, not in the variant file.
      expect(
          platformioIsNrf('[Promicro]\nextends = nrf52_base\n'
              'board = promicro_nrf52840\nbuild_flags = \${nrf52_base.build_flags}'),
          true);
      // a variant that repeats the define directly
      expect(platformioIsNrf('build_flags = -D NRF52_PLATFORM\n  -D X'), true);
      // esp32 variant extends a different base → not nRF
      expect(platformioIsNrf('[X]\nextends = esp32_base\nboard = esp32dev'), false);
    });
    test('deviceIsNrf matches a board-name prefix, separator/case-insensitively', () {
      final nrf = {'promicro', 'ikoka_nano_nrf', 'xiao_nrf52', 't1000-e'};
      expect(deviceIsNrf('ProMicro', nrf), true);
      expect(deviceIsNrf('ikoka_nano_nrf_30dbm', nrf), true); // power-variant suffix
      // asset drops the variant folder's dash: folder `t1000-e` -> asset `t1000e`
      expect(deviceIsNrf('t1000e', nrf), true);
      expect(deviceIsNrf('Heltec_v3', nrf), false);
    });
  });

  group('buildOtaCatalog', () {
    OtaRelease rel(String ver, List<String> assetNames) => OtaRelease(
          role: OtaFwRole.repeater,
          version: ver,
          tag: 'repeater-v$ver',
          assets: [
            for (final n in assetNames) OtaReleaseAsset(name: n, downloadUrl: '$n#u'),
          ],
        );
    final releases = [
      rel('1.16.0', [
        'ProMicro_repeater-v1.16.0-abc.zip',
        'Heltec_v3_repeater-v1.16.0-abc.bin', // not nRF → excluded
        'xiao_c3_repeater-v1.16.0-abc.bin', // not nRF → excluded
      ]),
      rel('1.17.0', ['ProMicro_repeater-v1.17.0-def.zip']),
    ];
    final nrf = {'promicro', 'xiao_nrf52'};

    test('devices are nRF ∩ have-usable-asset, releases newest-first', () {
      final cat = buildOtaCatalog(
          role: OtaFwRole.repeater, releases: releases, nrfBoardNamesLower: nrf);
      expect(cat.devices, ['ProMicro']); // Heltec_v3 + xiao_c3 filtered out
      expect(cat.releases.map((r) => r.version).toList(), ['1.17.0', '1.16.0']);
    });

    test('assetFor resolves the right download url per device+version', () {
      final cat = buildOtaCatalog(
          role: OtaFwRole.repeater, releases: releases, nrfBoardNamesLower: nrf);
      expect(cat.assetFor('ProMicro', '1.17.0')!.downloadUrl,
          'ProMicro_repeater-v1.17.0-def.zip#u');
      expect(cat.assetFor('ProMicro', '9.9.9'), isNull);
    });
  });
}
