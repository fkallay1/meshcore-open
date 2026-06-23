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
}
