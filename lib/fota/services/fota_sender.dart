import 'dart:typed_data';
import 'package:crypto/crypto.dart' as c;
import '../../connector/meshcore_protocol.dart';
import 'fota_payload_builder.dart';
import '../models/fota_types.dart';

abstract class FotaFrameSink {
  Future<void> sendFrame(Uint8List frame);
  Future<void> setRadio(int freqVal, int bwVal, int sf, int cr);
  Future<void> setChannel(int idx, String name, Uint8List psk);

  /// Set the companion's outgoing flood scope before sending. [key16] non-null →
  /// region scope (companion computes the transport code); null → clear/unscoped
  /// (pure flood). Has no effect on zero-hop/direct routes (they don't flood).
  Future<void> setFloodScope(Uint8List? key16);
}

class FotaSendConfig {
  final String channelName;
  final int channelIdx;
  final double freqMHz, bwKHz;
  final int sf, cr;
  final FotaScope scope;
  final String pathHex;
  // scope=direct: bytes per path hop (1/2/3), mirrors --path-hashsize.
  final int pathHashSize;
  // scope=region: 16-byte transport key (companion derives the transport code).
  final Uint8List? scopeKey;
  final bool applyAfter, applyRadio;
  final int delayMs, tsBase;
  // Timing / redundancy knobs mirroring fota_sender.py:
  //   headerEvery  → --header-every : resend META+SIG every N chunks (0 = off)
  //   cycles       → --cycles       : repeat the whole broadcast N times (fire-and-forget)
  //   cycleDelayMs → --cycle-delay  : pause between cycles
  final int headerEvery, cycles, cycleDelayMs;
  final Uint8List? seed32; // Ed25519 seed for raw signing; null → zero sig
  FotaSendConfig({
    required this.channelName,
    required this.channelIdx,
    required this.freqMHz,
    required this.bwKHz,
    required this.sf,
    required this.cr,
    required this.scope,
    this.pathHex = '',
    this.pathHashSize = 1,
    this.scopeKey,
    this.applyAfter = false,
    this.applyRadio = false,
    this.delayMs = 300,
    this.headerEvery = 0,
    this.cycles = 1,
    this.cycleDelayMs = 2000,
    this.tsBase = 0,
    this.seed32,
  });
}

enum FotaPhase { setup, chunks, header, apply, done }

class FotaProgress {
  final FotaPhase phase;
  final int sent, total;
  FotaProgress(this.phase, this.sent, this.total);
}

class FotaSender {
  final FotaFrameSink _sink;
  final FotaPayloadBuilder _b = FotaPayloadBuilder();
  FotaSender(this._sink);

  Future<void> send(FotaJob job, FotaSendConfig cfg,
      {void Function(FotaProgress)? onProgress}) async {
    int ts = cfg.tsBase;

    onProgress?.call(FotaProgress(FotaPhase.setup, 0, 0));
    if (cfg.applyRadio) {
      await _sink.setRadio((cfg.freqMHz * 1000).round(), (cfg.bwKHz * 1000).round(),
          cfg.sf, cfg.cr);
    }
    final psk = Uint8List.fromList(c.sha256
        .convert(Uint8List.fromList(cfg.channelName.codeUnits))
        .bytes
        .sublist(0, 16));
    await _sink.setChannel(cfg.channelIdx, cfg.channelName, psk);

    // Flood scope is companion state, not a per-packet field: set the region key
    // for region scope, otherwise clear it so flood is a true unscoped flood and
    // no stale region leaks into this broadcast (zero-hop/direct don't flood, but
    // clearing keeps companion state predictable).
    await _sink.setFloodScope(cfg.scope == FotaScope.region ? cfg.scopeKey : null);

    final (pathLen, path) =
        fotaScopePath(cfg.scope, cfg.pathHex, cfg.pathHashSize);
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
          buildSendChannelDataFrame(cfg.channelIdx, pathLen, path, kFotaMagic, data));
      if (cfg.delayMs > 0) await Future.delayed(Duration(milliseconds: cfg.delayMs));
    }

    final patch = job.patch;
    final total = (patch.length / kFotaChunkData).ceil();
    final oldPrefix = job.oldSha256.sublist(0, 4);

    // header = META + SIG (built once, reused across cycles / redundancy resends)
    final patchSha = FotaPayloadBuilder.sha256(patch);
    final meta = job.presignedMeta ??
        _b.buildMeta(patch.length, patchSha, job.newSha256, job.oldSha256);
    final sig = job.presignedSig ?? _b.buildSig(meta, cfg.seed32, job.keyId);
    Future<void> sendHeader() async {
      await snd(meta);
      await snd(sig);
    }

    final cycles = cfg.cycles < 1 ? 1 : cfg.cycles;
    final grandTotal = total * cycles;
    int doneChunks = 0;

    for (int cycle = 0; cycle < cycles; cycle++) {
      // chunks (hend order: chunks first)
      for (int i = 0; i < total; i++) {
        final start = i * kFotaChunkData;
        final end = (start + kFotaChunkData).clamp(0, patch.length);
        await snd(_b.buildChunk(
            i, Uint8List.sublistView(patch, start, end), job.oldFwSize, oldPrefix));
        doneChunks++;
        onProgress?.call(FotaProgress(FotaPhase.chunks, doneChunks, grandTotal));
        // HEADER redundancy: META+SIG is the single critical packet (total=0
        // blocks everything) and has no accumulation advantage like chunks.
        if (cfg.headerEvery > 0 && (i + 1) % cfg.headerEvery == 0) {
          await sendHeader();
        }
      }

      onProgress?.call(FotaProgress(FotaPhase.header, doneChunks, grandTotal));
      await sendHeader();

      if (cfg.applyAfter) {
        onProgress?.call(FotaProgress(FotaPhase.apply, doneChunks, grandTotal));
        await snd(_b.buildApply(patchSha));
      }

      if (cycle < cycles - 1 && cfg.cycleDelayMs > 0) {
        await Future.delayed(Duration(milliseconds: cfg.cycleDelayMs));
      }
    }
    onProgress?.call(FotaProgress(FotaPhase.done, grandTotal, grandTotal));
  }

  static Uint8List _u32le(int v) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);
}
