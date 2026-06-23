import 'dart:typed_data';
import 'package:crypto/crypto.dart' as c;
import '../connector/meshcore_protocol.dart';
import 'ota_payload_builder.dart';
import 'ota_types.dart';

abstract class OtaFrameSink {
  Future<void> sendFrame(Uint8List frame);
  Future<void> setRadio(int freqVal, int bwVal, int sf, int cr);
  Future<void> setChannel(int idx, String name, Uint8List psk);
}

class OtaSendConfig {
  final String channelName;
  final int channelIdx;
  final double freqMHz, bwKHz;
  final int sf, cr;
  final OtaScope scope;
  final String pathHex;
  final bool applyAfter, applyRadio;
  final int delayMs, tsBase;
  final Uint8List? seed32; // Ed25519 seed for raw signing; null → zero sig
  OtaSendConfig({
    required this.channelName,
    required this.channelIdx,
    required this.freqMHz,
    required this.bwKHz,
    required this.sf,
    required this.cr,
    required this.scope,
    this.pathHex = '',
    this.applyAfter = false,
    this.applyRadio = false,
    this.delayMs = 300,
    this.tsBase = 0,
    this.seed32,
  });
}

enum OtaPhase { setup, chunks, header, apply, done }

class OtaProgress {
  final OtaPhase phase;
  final int sent, total;
  OtaProgress(this.phase, this.sent, this.total);
}

class OtaSender {
  final OtaFrameSink _sink;
  final OtaPayloadBuilder _b = OtaPayloadBuilder();
  OtaSender(this._sink);

  Future<void> send(OtaJob job, OtaSendConfig cfg,
      {void Function(OtaProgress)? onProgress}) async {
    int ts = cfg.tsBase;

    onProgress?.call(OtaProgress(OtaPhase.setup, 0, 0));
    if (cfg.applyRadio) {
      await _sink.setRadio((cfg.freqMHz * 1000).round(), (cfg.bwKHz * 1000).round(),
          cfg.sf, cfg.cr);
    }
    final psk = Uint8List.fromList(c.sha256
        .convert(Uint8List.fromList(cfg.channelName.codeUnits))
        .bytes
        .sublist(0, 16));
    await _sink.setChannel(cfg.channelIdx, cfg.channelName, psk);

    final (pathLen, path) = _scopePath(cfg.scope, cfg.pathHex);
    Future<void> snd(Uint8List payload) async {
      ts += 1; // increasing ts → unique packet (anti-dedup), matches python
      final data = (BytesBuilder()
            ..add(_u32le(ts))
            ..add(payload))
          .toBytes();
      if (data.length > kGrpDataMaxLen) {
        throw StateError('GRP_DATA data_len ${data.length} > $kGrpDataMaxLen');
      }
      await _sink.sendFrame(
          buildSendChannelDataFrame(cfg.channelIdx, pathLen, path, kOtaMagic, data));
      if (cfg.delayMs > 0) await Future.delayed(Duration(milliseconds: cfg.delayMs));
    }

    final patch = job.patch;
    final total = (patch.length / kOtaChunkData).ceil();
    final oldPrefix = job.oldSha256.sublist(0, 4);

    // chunks (hend order: chunks first)
    for (int i = 0; i < total; i++) {
      final start = i * kOtaChunkData;
      final end = (start + kOtaChunkData).clamp(0, patch.length);
      await snd(_b.buildChunk(
          i, Uint8List.sublistView(patch, start, end), job.oldFwSize, oldPrefix));
      onProgress?.call(OtaProgress(OtaPhase.chunks, i + 1, total));
    }

    // header = META + SIG
    onProgress?.call(OtaProgress(OtaPhase.header, total, total));
    final patchSha = OtaPayloadBuilder.sha256(patch);
    final meta = job.presignedMeta ??
        _b.buildMeta(patch.length, patchSha, job.newSha256, job.oldSha256);
    final sig = job.presignedSig ?? _b.buildSig(meta, cfg.seed32, job.keyId);
    await snd(meta);
    await snd(sig);

    if (cfg.applyAfter) {
      onProgress?.call(OtaProgress(OtaPhase.apply, total, total));
      await snd(_b.buildApply(patchSha));
    }
    onProgress?.call(OtaProgress(OtaPhase.done, total, total));
  }

  (int, Uint8List) _scopePath(OtaScope scope, String pathHex) {
    switch (scope) {
      case OtaScope.zerohop:
        return (0, Uint8List(0));
      case OtaScope.flood:
        return (0xFF, Uint8List(0));
      case OtaScope.direct:
        final p = Uint8List.fromList([
          for (var i = 0; i < pathHex.length; i += 2)
            int.parse(pathHex.substring(i, i + 2), radix: 16)
        ]);
        return (p.length, p);
    }
  }

  static Uint8List _u32le(int v) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);
}
