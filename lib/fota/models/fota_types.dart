import 'dart:typed_data';
import 'package:crypto/crypto.dart' as c;

const int kFotaMagic = 0x07A0;
const int kFotaProtInfV0 = 0x00;
const int kFotaChunkData = 144;
const int kFotaPktHeader = 0x10;
const int kFotaPktChunk = 0x11;
const int kFotaPktApply = 0x12;
const int kFotaPktHdrSig = 0x13;
const int kFotaPktStatus = 0x20;
const int kFotaPktNack = 0x21;
const int kFotaStVerified = 0x04;
const int kFotaStError = 0x80;
const int kGrpDataMaxLen = 165;

/// CRC16/CCITT-FALSE: init 0xFFFF, poly 0x1021, no reflect, no xorout.
int crc16Ccitt(Uint8List data) {
  int crc = 0xFFFF;
  for (final b in data) {
    crc ^= b << 8;
    for (int i = 0; i < 8; i++) {
      crc = (crc & 0x8000) != 0 ? ((crc << 1) ^ 0x1021) : (crc << 1);
      crc &= 0xFFFF;
    }
  }
  return crc;
}

enum FotaScope { zerohop, flood, region, direct }

/// Auto-region transport key for a hashtag region name, matching the firmware
/// (`TransportKeyStore::getAutoKeyFor`): SHA256 of the '#'-prefixed name, first
/// 16 bytes. A bare name gets the '#' prepended (RegionMap's implicit-hashtag
/// rule), so 'mesh' and '#mesh' derive the same key.
Uint8List fotaRegionKeyFromName(String name) {
  final tag = name.startsWith('#') ? name : '#$name';
  return Uint8List.fromList(c.sha256.convert(tag.codeUnits).bytes.sublist(0, 16));
}

/// Resolve a [FotaScope] (+ direct path) to the GRP_DATA `(path_len, path)` pair
/// used in the CMD-62 frame. Mirrors `fota_sender.py`:
///   zerohop → (0, [])            flood/region → (0xFF, [])
///   direct  → comma-separated hex hops, each [hashSize] bytes; path_len packs
///             hop-count in bits 0-5 and (hashSize-1) in bits 6-7.
/// (For region the transport code is added by the companion, not here.)
/// Throws [FormatException] on malformed direct input.
(int, Uint8List) fotaScopePath(FotaScope scope, String pathStr, int hashSize) {
  switch (scope) {
    case FotaScope.zerohop:
      return (0, Uint8List(0));
    case FotaScope.flood:
    case FotaScope.region:
      return (0xFF, Uint8List(0));
    case FotaScope.direct:
      final toks = pathStr
          .split(',')
          .map((t) => t.trim())
          .where((t) => t.isNotEmpty)
          .toList();
      if (toks.isEmpty) {
        throw const FormatException('path je prázdny (zadaj aspoň 1 hop)');
      }
      final bytes = <int>[];
      for (final t in toks) {
        if (t.length != hashSize * 2) {
          throw FormatException(
              'každý hop musí byť ${hashSize}B (${hashSize * 2} hex znakov): "$t"');
        }
        for (var i = 0; i < t.length; i += 2) {
          final b = int.tryParse(t.substring(i, i + 2), radix: 16);
          if (b == null) throw FormatException('neplatný hex v ceste: "$t"');
          bytes.add(b);
        }
      }
      final hopCount = toks.length;
      if (hopCount > 63 || hopCount * hashSize > 64) {
        throw const FormatException(
            'počet hopov 1..63 a hop_count*hashsize ≤ 64');
      }
      final pathLen = ((hashSize - 1) << 6) | (hopCount & 0x3F);
      return (pathLen, Uint8List.fromList(bytes));
  }
}

/// A per-send selection: which chunk indices, and whether to (re)send the META
/// (H) and SIG (S) header packets. [reportedTotal] is the total parsed from a
/// pasted `fota miss=N/T` CLI line (null if absent).
class FotaSelection {
  final List<int> chunks; // sorted ascending, de-duplicated
  final bool meta; // H — send META packet
  final bool sig; // S — send SIG packet
  final int? reportedTotal;
  const FotaSelection(this.chunks,
      {required this.meta, required this.sig, this.reportedTotal});
}

/// Parse a space-separated selection list. Tokens (case-insensitive), after
/// stripping ':' from each token and skipping empties:
///   N      → chunk N
///   A-B    → chunks A..B inclusive (descending B-A is normalized)
///   H / S  → META / SIG
/// CLI noise so a whole `fota miss` reply can be pasted, IGNORED:
///   FOTA, miss, missall, miss=N/T (yields reportedTotal=T), +N
/// Throws [FormatException] on an unknown token, malformed range, out-of-range
/// chunk, or an empty selection (no chunk and neither H nor S).
FotaSelection parseFotaSelection(String input, {required int totalChunks}) {
  final chunks = <int>{};
  bool meta = false, sig = false;
  int? reportedTotal;

  void addChunk(int v) {
    if (v < 0 || v >= totalChunks) {
      throw FormatException('chunk $v mimo rozsahu 0..${totalChunks - 1}');
    }
    chunks.add(v);
  }

  for (final raw in input.split(RegExp(r'\s+'))) {
    final tok = raw.replaceAll(':', '').trim();
    if (tok.isEmpty) continue;
    final low = tok.toLowerCase();

    if (low == 'h') {
      meta = true;
      continue;
    }
    if (low == 's') {
      sig = true;
      continue;
    }
    if (low == 'fota') continue;
    if (low.startsWith('+')) continue; // "+N" overflow marker
    if (low.startsWith('miss')) {
      // "miss", "missall", "miss=N/T", "missall=N/T"
      final m = RegExp(r'=(\d+)/(\d+)').firstMatch(low);
      if (m != null) reportedTotal = int.parse(m.group(2)!);
      continue;
    }

    if (tok.contains('-')) {
      final parts = tok.split('-');
      if (parts.length != 2) throw FormatException('neplatný rozsah: "$tok"');
      final a = int.tryParse(parts[0]);
      final b = int.tryParse(parts[1]);
      if (a == null || b == null) {
        throw FormatException('neplatný rozsah: "$tok"');
      }
      final lo = a < b ? a : b;
      final hi = a < b ? b : a;
      for (var i = lo; i <= hi; i++) {
        addChunk(i);
      }
      continue;
    }

    final n = int.tryParse(tok);
    if (n == null) throw FormatException('neznámy token: "$tok"');
    addChunk(n);
  }

  if (chunks.isEmpty && !meta && !sig) {
    throw const FormatException('prázdny výber (zadaj chunky a/alebo H/S)');
  }
  final sorted = chunks.toList()..sort();
  return FotaSelection(sorted,
      meta: meta, sig: sig, reportedTotal: reportedTotal);
}

/// Convert raw contact path bytes (one hop-hash per byte, hashsize 1) to the
/// comma-separated hex form the Direct scope path field expects, e.g.
/// [0x3f, 0xa1] → "3f,a1". Empty input → "" (no known direct path → flood).
String fotaDirectPathFromBytes(Uint8List pathBytes) =>
    pathBytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join(',');

class FotaJob {
  final Uint8List patch;
  final Uint8List oldSha256;
  final Uint8List newSha256;
  final int oldFwSize;
  final int keyId;
  final Uint8List? presignedMeta; // 102B if pre-signed package
  final Uint8List? presignedSig; // 99B if pre-signed package

  FotaJob({
    required this.patch,
    required this.oldSha256,
    required this.newSha256,
    required this.oldFwSize,
    this.keyId = 1,
    this.presignedMeta,
    this.presignedSig,
  });

  bool get isPresigned => presignedMeta != null && presignedSig != null;
}
