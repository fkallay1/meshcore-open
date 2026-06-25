import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/fota/services/fota_sender.dart';
import 'package:meshcore_open/fota/models/fota_types.dart';
import 'package:meshcore_open/fota/models/fotapkg.dart';

class _FakeSink implements FotaFrameSink {
  final frames = <Uint8List>[];
  int? freqVal, bwVal, sf, cr, chIdx;
  String? chName;
  @override
  Future<void> sendFrame(Uint8List f) async => frames.add(f);
  @override
  Future<void> setRadio(int f, int b, int s, int c) async {
    freqVal = f;
    bwVal = b;
    sf = s;
    cr = c;
  }

  @override
  Future<void> setChannel(int i, String n, Uint8List psk) async {
    chIdx = i;
    chName = n;
  }
}

void main() {
  test('sends chunks then META+SIG (hend), correct count and radio units', () async {
    final pkg = FotaPkg.fromJsonString(File('test/fixtures/sample.fotapkg.json').readAsStringSync());
    final g = jsonDecode(File('test/fixtures/fota_golden.json').readAsStringSync());
    final sink = _FakeSink();
    final sender = FotaSender(sink);
    final total = (pkg.patch.length / kFotaChunkData).ceil();

    await sender.send(
      pkg.toJob(),
      FotaSendConfig(
        channelName: pkg.channelName,
        channelIdx: pkg.channelIdx,
        freqMHz: pkg.freqMHz,
        bwKHz: pkg.bwKHz,
        sf: pkg.sf,
        cr: pkg.cr,
        scope: pkg.scope,
        pathHex: pkg.pathHex,
        applyAfter: false,
        delayMs: 0,
        applyRadio: true,
        tsBase: g['inputs']['ts'],
        seed32: Uint8List.fromList(List<int>.generate(32, (i) => i)),
      ),
    );

    expect(sink.freqVal, 869618); // 869.618 * 1000
    expect(sink.bwVal, 62500); // 62.5 * 1000
    expect(sink.chName, '#fkotanrf');
    // chunks + META + SIG, no APPLY
    expect(sink.frames.length, total + 2);
    // every frame starts with CMD 62
    expect(sink.frames.every((f) => f[0] == 62), true);
    // every data payload ≤ 165 (frame = 3 hdr + 2 dataType + data)
    expect(sink.frames.every((f) => f.length - 5 <= kGrpDataMaxLen), true);
  });

  test('applyAfter adds one APPLY frame', () async {
    final pkg = FotaPkg.fromJsonString(File('test/fixtures/sample.fotapkg.json').readAsStringSync());
    final sink = _FakeSink();
    final total = (pkg.patch.length / kFotaChunkData).ceil();
    await FotaSender(sink).send(
        pkg.toJob(),
        FotaSendConfig(
            channelName: pkg.channelName,
            channelIdx: pkg.channelIdx,
            freqMHz: pkg.freqMHz,
            bwKHz: pkg.bwKHz,
            sf: pkg.sf,
            cr: pkg.cr,
            scope: pkg.scope,
            pathHex: pkg.pathHex,
            applyAfter: true,
            delayMs: 0,
            applyRadio: false,
            tsBase: 1,
            seed32: Uint8List.fromList(List<int>.generate(32, (i) => i))));
    expect(sink.frames.length, total + 3); // + APPLY
    expect(sink.freqVal, null); // applyRadio false → no setRadio
  });

  test('cycles=N repeats the whole broadcast N times', () async {
    final pkg = FotaPkg.fromJsonString(File('test/fixtures/sample.fotapkg.json').readAsStringSync());
    final sink = _FakeSink();
    final total = (pkg.patch.length / kFotaChunkData).ceil();
    await FotaSender(sink).send(
        pkg.toJob(),
        FotaSendConfig(
            channelName: pkg.channelName,
            channelIdx: pkg.channelIdx,
            freqMHz: pkg.freqMHz,
            bwKHz: pkg.bwKHz,
            sf: pkg.sf,
            cr: pkg.cr,
            scope: pkg.scope,
            pathHex: pkg.pathHex,
            delayMs: 0,
            cycleDelayMs: 0,
            cycles: 3,
            applyRadio: false,
            tsBase: 1,
            seed32: Uint8List.fromList(List<int>.generate(32, (i) => i))));
    // 3 cycles, each = chunks + META + SIG (no APPLY)
    expect(sink.frames.length, 3 * (total + 2));
    // setChannel only happens once (setup is outside the cycle loop)
    expect(sink.chName, '#fkotanrf');
  });

  test('headerEvery resends META+SIG every N chunks', () async {
    final pkg = FotaPkg.fromJsonString(File('test/fixtures/sample.fotapkg.json').readAsStringSync());
    final sink = _FakeSink();
    final total = (pkg.patch.length / kFotaChunkData).ceil();
    const every = 2;
    await FotaSender(sink).send(
        pkg.toJob(),
        FotaSendConfig(
            channelName: pkg.channelName,
            channelIdx: pkg.channelIdx,
            freqMHz: pkg.freqMHz,
            bwKHz: pkg.bwKHz,
            sf: pkg.sf,
            cr: pkg.cr,
            scope: pkg.scope,
            pathHex: pkg.pathHex,
            delayMs: 0,
            headerEvery: every,
            applyRadio: false,
            tsBase: 1,
            seed32: Uint8List.fromList(List<int>.generate(32, (i) => i))));
    // chunks + (total ~/ every) redundancy header pairs + final META + SIG
    final redundant = (total ~/ every) * 2;
    expect(sink.frames.length, total + redundant + 2);
  });
}
