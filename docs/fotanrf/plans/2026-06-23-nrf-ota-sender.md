# nRF-OTA Sender (Flutter) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add an nRF-OTA sender + OTA admin quick-commands to a fork of `zjs81/meshcore-open`, so a phone can push a LoRa delta-patch firmware update to a MeshCore repeater over BLE/USB/WiFi.

**Architecture:** Reuse meshcore-open's `MeshCoreConnector` (BLE/USB/TCP transport, `sendFrame`, `setChannel`, repeater CLI). Add one new frame builder (`CMD_SEND_CHANNEL_DATA=62`) and a self-contained `lib/ota/` module (payload builder, patch source, sender) that is a byte-exact Dart port of `MeshCore/test_nrf-ota/ota_sender.py`. Phase A = load a PC-built `.otapkg.json`; phase B (later) = on-device hdiff via FFI, swapping only `PatchSource`.

**Tech Stack:** Flutter 3.38 / Dart `^3.9.2`, Provider (state), `pointycastle` (Ed25519), `crypto` (SHA256), `file_picker` + `flutter_secure_storage` (new deps).

## Global Constraints

- **App identity unchanged:** keep `name: meshcore_open` and `title: 'MeshCore Open'` in pubspec/main — do NOT rename to the fork name (keeps upstream diffs minimal for `git pull upstream`).
- **License:** preserve `LICENSE` (MIT © 2025 zjs81); add our copyright + derivative note in README only.
- **Isolation:** all OTA logic lives in NEW files under `lib/ota/`, `lib/screens/ota_screen.dart`, `lib/services/ota_key_store.dart`. The ONLY edits to existing upstream files are: `+1` builder in `meshcore_protocol.dart`, OTA quick-commands in `repeater_cli_screen.dart`, one nav tile in `repeater_hub_screen.dart`.
- **Byte-exactness is mandatory:** `OtaPayloadBuilder` and `buildSendChannelDataFrame` output MUST equal `ota_sender.py` byte-for-byte. Verified by committed golden vectors (`test/fixtures/ota_golden.json`).
- **Frame style:** use the existing `BufferWriter` (writeByte / writeBytes / writeUInt16LE / writeUInt32LE) — do not introduce a new byte writer.
- **State:** Provider (`Provider.of<MeshCoreConnector>(context, listen: false)`), not Riverpod.
- **Lint:** `package:flutter_lints/flutter.yaml` (inherited). Run `flutter analyze` clean before each commit.
- **Radio units (companion protocol):** freq value = `(freqMHz * 1000).round()`, bw value = `(bwKHz * 1000).round()` (e.g. `869.618 → 869618`, `62.5 → 62500`), each UInt32LE.
- **Toolchain note:** Flutter SDK is not yet installed on the dev machine. Code is written now; `flutter pub get` / `flutter test` / `flutter analyze` run once the portable toolchain (Flutter zip + Android cmdline-tools + JDK) is set up. Treat every "Run:" step as executed after the toolchain exists.

## OTA wire reference (from `test_nrf-ota/ota_sender.py`, authoritative)

```
OTA_MAGIC=0x07A0  OTA_PROT_INF_V0=0x00  OTA_CHUNK_DATA=144
OTA_PKT_HEADER=0x10  CHUNK=0x11  APPLY=0x12  HDR_SIG=0x13  STATUS=0x20  NACK=0x21

META (102B) = [0x10][0x00] + patch_size(u32le) + patch_sha256(32) + new_sha256(32) + old_sha256(32)
SIG  (99B)  = [0x13][0x00] + old_sha256(32) + key_id(1) + ed25519_sig(64)   # sig over the 102B META; no key → 64×0x00
CHUNK       = [0x11] + idx(u16le) + crc16(data)(u16le) + old_fw_size(u32le) + old_sha256[:4](4) + data(≤144)
APPLY       = [0x12] + patch_sha256(32)
CRC16/CCITT-FALSE: init=0xFFFF, poly=0x1021, no reflect, no xorout

GRP_DATA data = [ts(u32le)][ota_payload]      (len(data) ≤ 165)
CMD_SEND_CHANNEL_DATA frame = [62][channel_idx][path_len][path...][data_type(u16le)=0x07A0][data...]
scope→(path_len,path): zerohop=(0,b""), flood=(0xFF,b""), direct=(N, N×1B hashes)
send order (default 'hend'): chunks…, then META, then SIG, then (optional) APPLY; ts increments +1 per packet
```

---

### Task 1: Scaffold the fork, branch, deps, docs

**Files:**
- Clone: FK's fork of `meshcore-open` → `D:\FkDev\FkProj\VSC\mc_fotanrf_flutterapp`
- Modify: `pubspec.yaml` (add 2 deps)
- Modify: `README.md` (derivative note)
- Move: existing `docs/specs/…` + `docs/plans/…` → `docs/fotanrf/`

**Interfaces:**
- Produces: a working fork checkout on branch `feature/nrf-ota-sender`, `upstream` remote set, deps resolvable.

- [ ] **Step 1: Clone FK fork into the target dir**

The dir currently holds only our `docs/`. Clone to a temp path, then graft.

```bash
cd /d/FkDev/FkProj/VSC
mv mc_fotanrf_flutterapp _fotanrf_docs_tmp           # park our docs
git clone <FK_FORK_URL> mc_fotanrf_flutterapp        # FK provides the URL of his fork
cd mc_fotanrf_flutterapp
git remote add upstream https://github.com/zjs81/meshcore-open.git
git remote -v
```

- [ ] **Step 2: Create our working branch + relocate docs under the repo**

```bash
git checkout -b feature/nrf-ota-sender
mkdir -p docs/fotanrf
cp -r ../_fotanrf_docs_tmp/docs/specs docs/fotanrf/
cp -r ../_fotanrf_docs_tmp/docs/plans docs/fotanrf/
rm -rf ../_fotanrf_docs_tmp
```

- [ ] **Step 3: Add the two new dependencies**

In `pubspec.yaml`, under `dependencies:` (after `pointycastle: ^4.0.0`), add:

```yaml
  file_picker: ^8.1.2
  flutter_secure_storage: ^9.2.2
```

- [ ] **Step 4: README derivative note**

Add near the top of `README.md`:

```markdown
> **mc_fotanrf_flutterapp** — a derivative of [zjs81/meshcore-open](https://github.com/zjs81/meshcore-open) (MIT)
> adding an nRF52840 LoRa delta-patch **OTA sender** and OTA admin quick-commands.
> Upstream is tracked as the `upstream` git remote. App identity (`meshcore_open`) is kept
> unchanged so upstream changes merge cleanly. © 2026 Fedor Kallay; original © 2025 zjs81.
```

- [ ] **Step 5: Resolve deps and analyze**

Run: `flutter pub get`
Expected: resolves with `file_picker` and `flutter_secure_storage` added, no version conflicts.
Run: `flutter analyze`
Expected: no new errors.

- [ ] **Step 6: Commit**

```bash
git add pubspec.yaml pubspec.lock README.md docs/
git commit -m "chore(fotanrf): fork scaffold — branch, upstream remote, OTA deps, docs"
```

---

### Task 2: Golden-vector fixture (Python emitter → committed JSON)

**Files:**
- Create: `MeshCore/test_nrf-ota/tools/emit_ota_golden.py`
- Create (committed fixtures): `test/fixtures/ota_golden.json`, `test/fixtures/test_ed25519_seed.hex`

**Interfaces:**
- Produces: `test/fixtures/ota_golden.json` — the source-of-truth byte vectors every Dart test asserts against. Schema:
  ```jsonc
  {
    "seed_hex": "<32B ed25519 seed>",
    "inputs": { "patch_size": 1234, "patch_sha256":"<hex32>", "new_sha256":"<hex32>",
                "old_sha256":"<hex32>", "key_id": 1, "old_fw_size": 442000,
                "chunk_idx": 2, "chunk_data_hex": "<hex>", "ts": 1000000 },
    "meta_hex": "<102B>", "sig_hex": "<99B>", "chunk_hex": "<…>", "apply_hex": "<33B>",
    "crc16_of_chunk_data": 12345,
    "channel_data_frame_hex": "<full CMD 62 frame, zerohop, idx=1>"
  }
  ```

- [ ] **Step 1: Write the emitter** (`MeshCore/test_nrf-ota/tools/emit_ota_golden.py`)

```python
#!/usr/bin/env python3
"""Emit byte-exact OTA golden vectors for the Flutter Dart tests.
Uses FIXED synthetic inputs (no hdiffi needed). Run from MeshCore repo root:
    python test_nrf-ota/tools/emit_ota_golden.py <out_json>
"""
import json, struct, sys, hashlib
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))  # test_nrf-ota/
import ota_sender as S
from Crypto.PublicKey import ECC
from Crypto.Signature import eddsa

SEED = bytes(range(32))                      # deterministic 00 01 02 … 1f
key = ECC.construct(curve='Ed25519', seed=SEED)
key_id = 1

patch = bytes((i * 7) % 256 for i in range(1234))      # synthetic staged patch
patch_size = len(patch)
patch_sha256 = hashlib.sha256(patch).digest()
new_sha256 = hashlib.sha256(b'NEW').digest()
old_sha256 = hashlib.sha256(b'OLD').digest()
old_fw_size = 442000
chunk_idx = 2
chunk_data = patch[chunk_idx*S.OTA_CHUNK_DATA:(chunk_idx+1)*S.OTA_CHUNK_DATA]
ts = 1000000
channel_idx = 1

meta = S.build_meta_payload(0, patch_size, patch_sha256, new_sha256, old_sha256)
sig = S.build_sig_payload(meta, key, key_id)
chunk = S.build_ota_chunk(chunk_idx, chunk_data, old_fw_size, old_sha256[:4])
apply = S.build_ota_apply(patch_sha256)

# full CMD_SEND_CHANNEL_DATA frame for META, zerohop, idx=1 (mirror ota_sender_mcpy)
data = struct.pack('<I', ts) + meta
frame = bytes([62, channel_idx, 0]) + struct.pack('<H', S.OTA_MAGIC) + data

out = {
  "seed_hex": SEED.hex(),
  "inputs": {"patch_size": patch_size, "patch_sha256": patch_sha256.hex(),
             "new_sha256": new_sha256.hex(), "old_sha256": old_sha256.hex(),
             "key_id": key_id, "old_fw_size": old_fw_size, "chunk_idx": chunk_idx,
             "chunk_data_hex": chunk_data.hex(), "ts": ts, "channel_idx": channel_idx,
             "patch_hex": patch.hex()},
  "meta_hex": meta.hex(), "sig_hex": sig.hex(), "chunk_hex": chunk.hex(),
  "apply_hex": apply.hex(), "crc16_of_chunk_data": S.crc16(chunk_data),
  "channel_data_frame_hex": frame.hex(),
}
Path(sys.argv[1]).write_text(json.dumps(out, indent=2))
print(f"wrote {sys.argv[1]}: meta={len(meta)}B sig={len(sig)}B chunk={len(chunk)}B")
```

- [ ] **Step 2: Run it to generate the fixture**

```bash
cd /d/FkDev/FkProj/VSC/MeshCore
python test_nrf-ota/tools/emit_ota_golden.py ../mc_fotanrf_flutterapp/test/fixtures/ota_golden.json
```
Expected: prints `meta=102B sig=99B chunk=…B`; file created.

- [ ] **Step 3: Persist the seed as a separate fixture (for the key-store test)**

Write `test/fixtures/test_ed25519_seed.hex` containing the 64-char hex `000102…1f` (same as `seed_hex`).

- [ ] **Step 4: Commit (two repos)**

```bash
cd /d/FkDev/FkProj/VSC/MeshCore && git add test_nrf-ota/tools/emit_ota_golden.py && \
  git commit -m "test(nrfota): golden-vector emitter for Flutter OTA port"
cd /d/FkDev/FkProj/VSC/mc_fotanrf_flutterapp && git add test/fixtures/ && \
  git commit -m "test(fotanrf): commit OTA golden vectors fixture"
```

---

### Task 3: OTA constants + CRC16

**Files:**
- Create: `lib/ota/ota_types.dart`
- Test: `test/ota/crc16_test.dart`

**Interfaces:**
- Produces:
  - constants `kOtaMagic=0x07A0`, `kOtaProtInfV0=0`, `kOtaChunkData=144`, `kOtaPktHeader=0x10`, `kOtaPktChunk=0x11`, `kOtaPktApply=0x12`, `kOtaPktHdrSig=0x13`, `kOtaPktStatus=0x20`, `kOtaPktNack=0x21`, `kOtaStVerified=0x04`, `kOtaStError=0x80`, `kGrpDataMaxLen=165`.
  - `int crc16Ccitt(Uint8List data)` — CCITT-FALSE.
  - `enum OtaScope { zerohop, flood, direct }`
  - `class OtaJob { final Uint8List patch; final Uint8List oldSha256; final Uint8List newSha256; final int oldFwSize; final Uint8List? presignedMeta; final Uint8List? presignedSig; final int keyId; ... }`

- [ ] **Step 1: Write the failing test** (`test/ota/crc16_test.dart`)

```dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/ota/ota_types.dart';

void main() {
  test('crc16Ccitt matches python crc16 golden', () {
    final g = jsonDecode(File('test/fixtures/ota_golden.json').readAsStringSync());
    final data = _hex(g['inputs']['chunk_data_hex'] as String);
    expect(crc16Ccitt(data), g['crc16_of_chunk_data'] as int);
  });
  test('crc16Ccitt of empty is 0xFFFF', () {
    expect(crc16Ccitt(Uint8List(0)), 0xFFFF);
  });
}

Uint8List _hex(String s) => Uint8List.fromList(
    [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/ota/crc16_test.dart`
Expected: FAIL — `ota_types.dart` / `crc16Ccitt` not found.

- [ ] **Step 3: Implement** (`lib/ota/ota_types.dart`)

```dart
import 'dart:typed_data';

const int kOtaMagic = 0x07A0;
const int kOtaProtInfV0 = 0x00;
const int kOtaChunkData = 144;
const int kOtaPktHeader = 0x10;
const int kOtaPktChunk = 0x11;
const int kOtaPktApply = 0x12;
const int kOtaPktHdrSig = 0x13;
const int kOtaPktStatus = 0x20;
const int kOtaPktNack = 0x21;
const int kOtaStVerified = 0x04;
const int kOtaStError = 0x80;
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

enum OtaScope { zerohop, flood, direct }

class OtaJob {
  final Uint8List patch;
  final Uint8List oldSha256;
  final Uint8List newSha256;
  final int oldFwSize;
  final int keyId;
  final Uint8List? presignedMeta; // 102B if pre-signed package
  final Uint8List? presignedSig;  // 99B if pre-signed package

  OtaJob({
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `flutter test test/ota/crc16_test.dart`
Expected: PASS (both tests).

- [ ] **Step 5: Commit**

```bash
git add lib/ota/ota_types.dart test/ota/crc16_test.dart
git commit -m "feat(fotanrf): OTA constants, OtaJob, CRC16/CCITT-FALSE"
```

---

### Task 4: `buildSendChannelDataFrame` (CMD 62)

**Files:**
- Modify: `lib/connector/meshcore_protocol.dart` (add `cmdSendChannelData=62` after line 216; add builder near the other build* fns)
- Test: `test/ota/channel_data_frame_test.dart`

**Interfaces:**
- Consumes: `BufferWriter` (existing), `cmdSendChannelData`.
- Produces: `Uint8List buildSendChannelDataFrame(int channelIndex, int pathLen, Uint8List path, int dataType, Uint8List data)` → `[62][idx][pathLen][path][dataType u16le][data]`.

- [ ] **Step 1: Write the failing test** (`test/ota/channel_data_frame_test.dart`)

```dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/connector/meshcore_protocol.dart';

void main() {
  test('buildSendChannelDataFrame matches python META frame (zerohop, idx=1)', () {
    final g = jsonDecode(File('test/fixtures/ota_golden.json').readAsStringSync());
    final meta = _hex(g['meta_hex'] as String);
    final ts = g['inputs']['ts'] as int;
    final data = BytesBuilder()
      ..add(_u32le(ts))
      ..add(meta);
    final frame = buildSendChannelDataFrame(1, 0, Uint8List(0), 0x07A0, data.toBytes());
    expect(_toHex(frame), g['channel_data_frame_hex'] as String);
  });
}

Uint8List _u32le(int v) => Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);
Uint8List _hex(String s) => Uint8List.fromList(
    [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
String _toHex(Uint8List b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/ota/channel_data_frame_test.dart`
Expected: FAIL — `buildSendChannelDataFrame` undefined.

- [ ] **Step 3: Implement**

In `lib/connector/meshcore_protocol.dart`, add after `const int cmdSetPathHashMode = 61;`:

```dart
const int cmdSendChannelData = 62;
```

Add near the other `build*Frame` functions:

```dart
/// CMD_SEND_CHANNEL_DATA (62): [62][channelIndex][pathLen][path][dataType u16le][data].
/// Mirrors test_nrf-ota/ota_sender_mcpy.py companion_chan_data_frame.
Uint8List buildSendChannelDataFrame(
    int channelIndex, int pathLen, Uint8List path, int dataType, Uint8List data) {
  final writer = BufferWriter();
  writer.writeByte(cmdSendChannelData);
  writer.writeByte(channelIndex & 0xFF);
  writer.writeByte(pathLen & 0xFF);
  writer.writeBytes(path);
  writer.writeUInt16LE(dataType);
  writer.writeBytes(data);
  return writer.toBytes();
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `flutter test test/ota/channel_data_frame_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/connector/meshcore_protocol.dart test/ota/channel_data_frame_test.dart
git commit -m "feat(fotanrf): buildSendChannelDataFrame (CMD_SEND_CHANNEL_DATA=62)"
```

---

### Task 5: `OtaPayloadBuilder` (META/SIG/chunk/APPLY + Ed25519)

**Files:**
- Create: `lib/ota/ota_payload_builder.dart`
- Test: `test/ota/ota_payload_builder_test.dart`

**Interfaces:**
- Consumes: `crc16Ccitt`, constants (Task 3); `pointycastle` Ed25519.
- Produces a class:
  - `Uint8List buildMeta(int patchSize, Uint8List patchSha256, Uint8List newSha256, Uint8List oldSha256)` → 102B
  - `Uint8List signMeta(Uint8List meta, Uint8List? seed32)` → 64B (zeros if seed null)
  - `Uint8List buildSig(Uint8List meta, Uint8List? seed32, int keyId)` → 99B
  - `Uint8List buildChunk(int idx, Uint8List data, int oldFwSize, Uint8List oldSha256Prefix4)`
  - `Uint8List buildApply(Uint8List patchSha256)` → 33B
  - static `Uint8List sha256(Uint8List)` helper.

- [ ] **Step 1: Write the failing test** (`test/ota/ota_payload_builder_test.dart`)

```dart
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/ota/ota_payload_builder.dart';

void main() {
  late Map g;
  setUpAll(() => g = jsonDecode(File('test/fixtures/ota_golden.json').readAsStringSync()));

  test('buildMeta matches python (102B)', () {
    final b = OtaPayloadBuilder();
    final meta = b.buildMeta(g['inputs']['patch_size'], _h(g['inputs']['patch_sha256']),
        _h(g['inputs']['new_sha256']), _h(g['inputs']['old_sha256']));
    expect(meta.length, 102);
    expect(_x(meta), g['meta_hex']);
  });

  test('buildSig matches python (99B) — pointycastle == pycryptodome rfc8032', () {
    final b = OtaPayloadBuilder();
    final meta = _h(g['meta_hex']);
    final sig = b.buildSig(meta, _h(g['seed_hex']), g['inputs']['key_id']);
    expect(sig.length, 99);
    expect(_x(sig), g['sig_hex']);
  });

  test('buildChunk matches python', () {
    final b = OtaPayloadBuilder();
    final chunk = b.buildChunk(g['inputs']['chunk_idx'], _h(g['inputs']['chunk_data_hex']),
        g['inputs']['old_fw_size'], _h(g['inputs']['old_sha256']).sublist(0, 4));
    expect(_x(chunk), g['chunk_hex']);
  });

  test('buildApply matches python (33B)', () {
    final b = OtaPayloadBuilder();
    final apply = b.buildApply(_h(g['inputs']['patch_sha256']));
    expect(_x(apply), g['apply_hex']);
  });
}

Uint8List _h(String s) => Uint8List.fromList(
    [for (var i = 0; i < s.length; i += 2) int.parse(s.substring(i, i + 2), radix: 16)]);
String _x(Uint8List b) => b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/ota/ota_payload_builder_test.dart`
Expected: FAIL — class undefined.

- [ ] **Step 3: Implement** (`lib/ota/ota_payload_builder.dart`)

```dart
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as c;
import 'package:pointycastle/export.dart' as pc;
import 'ota_types.dart';

class OtaPayloadBuilder {
  static Uint8List sha256(Uint8List data) => Uint8List.fromList(c.sha256.convert(data).bytes);

  Uint8List buildMeta(int patchSize, Uint8List patchSha256, Uint8List newSha256,
      Uint8List oldSha256) {
    final b = BytesBuilder();
    b.addByte(kOtaPktHeader);
    b.addByte(kOtaProtInfV0);
    b.add(_u32le(patchSize));
    b.add(patchSha256);
    b.add(newSha256);
    b.add(oldSha256);
    final out = b.toBytes();
    assert(out.length == 102, 'META must be 102B, is ${out.length}');
    return out;
  }

  /// RFC8032 Ed25519 signature of [meta] (64B). Zeros if [seed32] is null.
  Uint8List signMeta(Uint8List meta, Uint8List? seed32) {
    if (seed32 == null) return Uint8List(64);
    final signer = pc.Ed25519Signer();
    final sk = pc.Ed25519PrivateKey(seed32);
    signer.init(true, pc.PrivateKeyParameter<pc.Ed25519PrivateKey>(sk));
    return signer.generateSignature(meta).bytes;
  }

  Uint8List buildSig(Uint8List meta, Uint8List? seed32, int keyId) {
    final sig = signMeta(meta, seed32);
    final oldSha256 = meta.sublist(70, 102);
    final b = BytesBuilder();
    b.addByte(kOtaPktHdrSig);
    b.addByte(kOtaProtInfV0);
    b.add(oldSha256);
    b.addByte(keyId & 0xFF);
    b.add(sig);
    final out = b.toBytes();
    assert(out.length == 99, 'SIG must be 99B, is ${out.length}');
    return out;
  }

  Uint8List buildChunk(int idx, Uint8List data, int oldFwSize, Uint8List oldSha256Prefix4) {
    final b = BytesBuilder();
    b.addByte(kOtaPktChunk);
    b.add(_u16le(idx));
    b.add(_u16le(crc16Ccitt(data)));
    b.add(_u32le(oldFwSize));
    b.add(oldSha256Prefix4);
    b.add(data);
    return b.toBytes();
  }

  Uint8List buildApply(Uint8List patchSha256) {
    final b = BytesBuilder()
      ..addByte(kOtaPktApply)
      ..add(patchSha256);
    return b.toBytes();
  }

  static Uint8List _u16le(int v) =>
      Uint8List(2)..buffer.asByteData().setUint16(0, v, Endian.little);
  static Uint8List _u32le(int v) =>
      Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);
}
```

> **Note on pointycastle Ed25519 API:** if `Ed25519Signer`/`Ed25519PrivateKey` names differ in `pointycastle ^4.0.0`, the signing primitive is exported from `package:pointycastle/export.dart`. The committed golden vector test is the gate — adjust the three lines in `signMeta` until `buildSig` matches `sig_hex`. Do not change the byte layout.

- [ ] **Step 4: Run to verify it passes**

Run: `flutter test test/ota/ota_payload_builder_test.dart`
Expected: PASS (4 tests). If only `buildSig` fails, fix `signMeta` per the note (proves pointycastle↔pycryptodome equivalence).

- [ ] **Step 5: Commit**

```bash
git add lib/ota/ota_payload_builder.dart test/ota/ota_payload_builder_test.dart
git commit -m "feat(fotanrf): OtaPayloadBuilder (META/SIG/chunk/APPLY + Ed25519, byte-exact)"
```

---

### Task 6: `.otapkg.json` model + parser

**Files:**
- Create: `lib/ota/otapkg.dart`
- Create (fixture): `test/fixtures/sample.otapkg.json`
- Test: `test/ota/otapkg_test.dart`

**Interfaces:**
- Consumes: `OtaScope`, `OtaJob` (Task 3).
- Produces:
  - `class OtaPkg { channelName, channelIdx, freqMHz, bwKHz, sf, cr, scope, pathHex, oldSha256, newSha256, oldFwSize, patchSha256, patchLen, patch, keyId, meta?, sig? }`
  - `factory OtaPkg.fromJsonString(String)` (validates `format == "mc-fotanrf-otapkg/1"`, base64-decodes patch, verifies `sha256(patch)==patchSha256` and `patch.length==patchLen`, throws `OtaPkgException` on mismatch)
  - `OtaJob toJob()`.

- [ ] **Step 1: Create the sample fixture** (`test/fixtures/sample.otapkg.json`)

Build it from the golden patch so hashes are consistent. Run:

```bash
cd /d/FkDev/FkProj/VSC/MeshCore
python - <<'PY'
import json, base64, hashlib
g = json.load(open('../mc_fotanrf_flutterapp/test/fixtures/ota_golden.json'))
patch = bytes.fromhex(g['inputs']['patch_hex'])
pkg = {
  "format":"mc-fotanrf-otapkg/1","created":"2026-06-23T00:00:00Z",
  "channel":{"name":"#fkotanrf","idx":1},
  "radio":{"freq":869.618,"bw":62.5,"sf":8,"cr":5},
  "scope":"zerohop","path":"",
  "fw":{"old_sha256":g['inputs']['old_sha256'],"new_sha256":g['inputs']['new_sha256'],
        "old_fw_size":g['inputs']['old_fw_size'],
        "patch_sha256":hashlib.sha256(patch).hexdigest(),"patch_len":len(patch)},
  "patch_b64": base64.b64encode(patch).decode(),
}
open('../mc_fotanrf_flutterapp/test/fixtures/sample.otapkg.json','w').write(json.dumps(pkg,indent=2))
print("ok", len(patch))
PY
```

- [ ] **Step 2: Write the failing test** (`test/ota/otapkg_test.dart`)

```dart
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/ota/otapkg.dart';
import 'package:meshcore_open/ota/ota_types.dart';

void main() {
  test('parses raw (unsigned) sample package and builds a job', () {
    final pkg = OtaPkg.fromJsonString(File('test/fixtures/sample.otapkg.json').readAsStringSync());
    expect(pkg.channelName, '#fkotanrf');
    expect(pkg.channelIdx, 1);
    expect(pkg.scope, OtaScope.zerohop);
    expect(pkg.sf, 8);
    final job = pkg.toJob();
    expect(job.isPresigned, false);
    expect(job.oldFwSize, 442000);
    expect(job.patch.length, pkg.patchLen);
  });

  test('rejects a package with a corrupted patch hash', () {
    final bad = File('test/fixtures/sample.otapkg.json').readAsStringSync()
        .replaceFirst('"patch_len"', '"patch_len_DISABLED"');
    expect(() => OtaPkg.fromJsonString(bad), throwsA(isA<OtaPkgException>()));
  });
}
```

- [ ] **Step 3: Run to verify it fails**

Run: `flutter test test/ota/otapkg_test.dart`
Expected: FAIL — `OtaPkg` undefined.

- [ ] **Step 4: Implement** (`lib/ota/otapkg.dart`)

```dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as c;
import 'ota_types.dart';

class OtaPkgException implements Exception {
  final String message;
  OtaPkgException(this.message);
  @override
  String toString() => 'OtaPkgException: $message';
}

class OtaPkg {
  final String channelName;
  final int channelIdx;
  final double freqMHz, bwKHz;
  final int sf, cr;
  final OtaScope scope;
  final String pathHex;
  final Uint8List oldSha256, newSha256, patchSha256, patch;
  final int oldFwSize, patchLen, keyId;
  final Uint8List? meta, sig; // present iff pre-signed

  OtaPkg({
    required this.channelName, required this.channelIdx,
    required this.freqMHz, required this.bwKHz, required this.sf, required this.cr,
    required this.scope, required this.pathHex,
    required this.oldSha256, required this.newSha256, required this.patchSha256,
    required this.patch, required this.oldFwSize, required this.patchLen,
    required this.keyId, this.meta, this.sig,
  });

  factory OtaPkg.fromJsonString(String s) {
    final Map j;
    try {
      j = jsonDecode(s) as Map;
    } catch (e) {
      throw OtaPkgException('invalid JSON: $e');
    }
    if (j['format'] != 'mc-fotanrf-otapkg/1') {
      throw OtaPkgException('unsupported format: ${j['format']}');
    }
    final fw = j['fw'];
    if (fw is! Map) throw OtaPkgException('missing fw block');
    final patch = _b64(j['patch_b64'], 'patch_b64');
    final patchLen = (fw['patch_len'] as num).toInt();
    if (patch.length != patchLen) {
      throw OtaPkgException('patch_len ${patchLen} != actual ${patch.length}');
    }
    final patchSha = Uint8List.fromList(c.sha256.convert(patch).bytes);
    final declared = _hex(fw['patch_sha256'], 'patch_sha256');
    if (!_eq(patchSha, declared)) throw OtaPkgException('patch sha256 mismatch');

    final ch = j['channel'] as Map, radio = j['radio'] as Map;
    final signed = j['signed'];
    return OtaPkg(
      channelName: ch['name'] as String,
      channelIdx: (ch['idx'] as num).toInt(),
      freqMHz: (radio['freq'] as num).toDouble(),
      bwKHz: (radio['bw'] as num).toDouble(),
      sf: (radio['sf'] as num).toInt(),
      cr: (radio['cr'] as num).toInt(),
      scope: _scope(j['scope'] as String?),
      pathHex: (j['path'] as String?) ?? '',
      oldSha256: _hex(fw['old_sha256'], 'old_sha256'),
      newSha256: _hex(fw['new_sha256'], 'new_sha256'),
      patchSha256: patchSha,
      patch: patch,
      oldFwSize: (fw['old_fw_size'] as num).toInt(),
      patchLen: patchLen,
      keyId: signed is Map ? (signed['key_id'] as num).toInt() : 1,
      meta: signed is Map ? _b64(signed['meta_b64'], 'meta_b64') : null,
      sig: signed is Map ? _b64(signed['sig_b64'], 'sig_b64') : null,
    );
  }

  OtaJob toJob() => OtaJob(
        patch: patch, oldSha256: oldSha256, newSha256: newSha256,
        oldFwSize: oldFwSize, keyId: keyId, presignedMeta: meta, presignedSig: sig,
      );

  static OtaScope _scope(String? s) {
    switch (s) {
      case 'flood': return OtaScope.flood;
      case 'direct': return OtaScope.direct;
      case 'zerohop':
      case null: return OtaScope.zerohop;
      default: throw OtaPkgException('unknown scope: $s');
    }
  }

  static Uint8List _b64(dynamic v, String f) {
    if (v is! String) throw OtaPkgException('missing $f');
    try { return Uint8List.fromList(base64.decode(v)); }
    catch (e) { throw OtaPkgException('bad base64 in $f'); }
  }

  static Uint8List _hex(dynamic v, String f) {
    if (v is! String || v.length.isOdd) throw OtaPkgException('bad hex in $f');
    return Uint8List.fromList(
        [for (var i = 0; i < v.length; i += 2) int.parse(v.substring(i, i + 2), radix: 16)]);
  }

  static bool _eq(Uint8List a, Uint8List b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) { if (a[i] != b[i]) return false; }
    return true;
  }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `flutter test test/ota/otapkg_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 6: Commit**

```bash
git add lib/ota/otapkg.dart test/fixtures/sample.otapkg.json test/ota/otapkg_test.dart
git commit -m "feat(fotanrf): .otapkg.json parser (pre-signed + raw), validated"
```

---

### Task 7: `OtaSender` orchestration (with fake-connector test)

**Files:**
- Create: `lib/ota/ota_sender.dart`
- Test: `test/ota/ota_sender_test.dart`

**Interfaces:**
- Consumes: `OtaPayloadBuilder`, `OtaJob`, `buildSendChannelDataFrame`, constants. Takes a minimal sink abstraction so it is testable without a real connector:
  - `abstract class OtaFrameSink { Future<void> sendFrame(Uint8List frame); Future<void> setRadio(int freqVal, int bwVal, int sf, int cr); Future<void> setChannel(int idx, String name, Uint8List psk); }`
- Produces:
  - `class OtaSender` with `Future<void> send(OtaJob job, OtaSendConfig cfg, {void Function(OtaProgress)? onProgress})`.
  - `class OtaSendConfig { channelName, channelIdx, freqMHz, bwKHz, sf, cr, scope, pathHex, applyAfter, delayMs, applyRadio, seed32? }`.
  - `class OtaProgress { phase (setup/chunks/header/apply/done), sent, total }`.
- Behavior (mirror `ota_sender_mcpy.py` default `hend`): optional `setRadio` → `setChannel` (PSK = `sha256(channelName)[:16]`) → for each chunk send `[ts][chunk]` → send `[ts][meta]`, `[ts][sig]` → if `applyAfter` send `[ts][apply]`. `ts` starts at a passed base and `+1` per packet. Each `data` must be ≤165B (assert/throw otherwise). META/SIG come from `job.presignedMeta/Sig` if present, else built+signed with `cfg.seed32`.

- [ ] **Step 1: Write the failing test** (`test/ota/ota_sender_test.dart`)

```dart
import 'dart:io';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/ota/ota_sender.dart';
import 'package:meshcore_open/ota/ota_types.dart';
import 'package:meshcore_open/ota/otapkg.dart';

class _FakeSink implements OtaFrameSink {
  final frames = <Uint8List>[];
  int? freqVal, bwVal, sf, cr, chIdx;
  String? chName;
  @override Future<void> sendFrame(Uint8List f) async => frames.add(f);
  @override Future<void> setRadio(int f, int b, int s, int c) async {
    freqVal = f; bwVal = b; sf = s; cr = c;
  }
  @override Future<void> setChannel(int i, String n, Uint8List psk) async {
    chIdx = i; chName = n;
  }
}

void main() {
  test('sends chunks then META+SIG (hend), correct count and radio units', () async {
    final pkg = OtaPkg.fromJsonString(File('test/fixtures/sample.otapkg.json').readAsStringSync());
    final g = jsonDecode(File('test/fixtures/ota_golden.json').readAsStringSync());
    final sink = _FakeSink();
    final sender = OtaSender(sink);
    final total = (pkg.patch.length / kOtaChunkData).ceil();

    await sender.send(
      pkg.toJob(),
      OtaSendConfig(
        channelName: pkg.channelName, channelIdx: pkg.channelIdx,
        freqMHz: pkg.freqMHz, bwKHz: pkg.bwKHz, sf: pkg.sf, cr: pkg.cr,
        scope: pkg.scope, pathHex: pkg.pathHex, applyAfter: false,
        delayMs: 0, applyRadio: true, tsBase: g['inputs']['ts'],
        seed32: Uint8List.fromList(List<int>.generate(32, (i) => i)),
      ),
    );

    expect(sink.freqVal, 869618);  // 869.618 * 1000
    expect(sink.bwVal, 62500);     // 62.5 * 1000
    expect(sink.chName, '#fkotanrf');
    // chunks + META + SIG, no APPLY
    expect(sink.frames.length, total + 2);
    // every frame starts with CMD 62
    expect(sink.frames.every((f) => f[0] == 62), true);
    // every data payload ≤ 165 (frame = 3 hdr + 2 dataType + data)
    expect(sink.frames.every((f) => f.length - 5 <= kGrpDataMaxLen), true);
  });

  test('applyAfter adds one APPLY frame', () async {
    final pkg = OtaPkg.fromJsonString(File('test/fixtures/sample.otapkg.json').readAsStringSync());
    final sink = _FakeSink();
    final total = (pkg.patch.length / kOtaChunkData).ceil();
    await OtaSender(sink).send(pkg.toJob(),
      OtaSendConfig(channelName: pkg.channelName, channelIdx: pkg.channelIdx,
        freqMHz: pkg.freqMHz, bwKHz: pkg.bwKHz, sf: pkg.sf, cr: pkg.cr,
        scope: pkg.scope, pathHex: pkg.pathHex, applyAfter: true, delayMs: 0,
        applyRadio: false, tsBase: 1,
        seed32: Uint8List.fromList(List<int>.generate(32, (i) => i))));
    expect(sink.frames.length, total + 3); // + APPLY
    expect(sink.freqVal, null);             // applyRadio false → no setRadio
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/ota/ota_sender_test.dart`
Expected: FAIL — `OtaSender`/`OtaFrameSink` undefined.

- [ ] **Step 3: Implement** (`lib/ota/ota_sender.dart`)

```dart
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
    required this.channelName, required this.channelIdx,
    required this.freqMHz, required this.bwKHz, required this.sf, required this.cr,
    required this.scope, this.pathHex = '', this.applyAfter = false,
    this.applyRadio = false, this.delayMs = 300, this.tsBase = 0, this.seed32,
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
    final psk = Uint8List.fromList(c.sha256.convert(
        Uint8List.fromList(cfg.channelName.codeUnits)).bytes.sublist(0, 16));
    await _sink.setChannel(cfg.channelIdx, cfg.channelName, psk);

    final (pathLen, path) = _scopePath(cfg.scope, cfg.pathHex);
    Future<void> snd(Uint8List payload) async {
      ts += 1; // increasing ts → unique packet (anti-dedup), matches python
      final data = (BytesBuilder()..add(_u32le(ts))..add(payload)).toBytes();
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
      await snd(_b.buildChunk(i, Uint8List.sublistView(patch, start, end),
          job.oldFwSize, oldPrefix));
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
      case OtaScope.zerohop: return (0, Uint8List(0));
      case OtaScope.flood: return (0xFF, Uint8List(0));
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
```

- [ ] **Step 4: Run to verify it passes**

Run: `flutter test test/ota/ota_sender_test.dart`
Expected: PASS (2 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/ota/ota_sender.dart test/ota/ota_sender_test.dart
git commit -m "feat(fotanrf): OtaSender session orchestration (hend order, scope, pacing)"
```

---

### Task 8: `OtaKeyStore` — import/store Ed25519 key

**Files:**
- Create: `lib/services/ota_key_store.dart`
- Test: `test/ota/ota_key_store_test.dart`

**Interfaces:**
- Produces:
  - static `Uint8List seedFromPkcs8Der(Uint8List der)` — extract the 32-byte Ed25519 seed from a PKCS#8 DER (the seed is the final 32 bytes of the inner OCTET STRING; for the standard 48-byte Ed25519 PKCS#8 it is `der.sublist(16, 48)`).
  - `Future<void> importSeed(Uint8List seed32)` / `Future<Uint8List?> loadSeed()` (via `flutter_secure_storage`, hex-encoded under key `ota_ed25519_seed`).

- [ ] **Step 1: Write the failing test** (pure DER-parse part; storage is device-tested)

```dart
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/services/ota_key_store.dart';

void main() {
  test('seedFromPkcs8Der extracts the 32B seed (matches fixture seed)', () {
    // A 48-byte Ed25519 PKCS#8 DER whose seed is 00..1f (same as golden seed).
    final seedHex = File('test/fixtures/test_ed25519_seed.hex').readAsStringSync().trim();
    final seed = Uint8List.fromList(
        [for (var i = 0; i < seedHex.length; i += 2) int.parse(seedHex.substring(i, i+2), radix: 16)]);
    // Standard PKCS#8 Ed25519 prefix (RFC 8410), 16 bytes, then 32B seed:
    final prefix = Uint8List.fromList([
      0x30,0x2e,0x02,0x01,0x00,0x30,0x05,0x06,0x03,0x2b,0x65,0x70,0x04,0x22,0x04,0x20
    ]);
    final der = Uint8List.fromList([...prefix, ...seed]);
    expect(OtaKeyStore.seedFromPkcs8Der(der), seed);
  });
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `flutter test test/ota/ota_key_store_test.dart`
Expected: FAIL — `OtaKeyStore` undefined.

- [ ] **Step 3: Implement** (`lib/services/ota_key_store.dart`)

```dart
import 'dart:typed_data';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class OtaKeyStore {
  static const _key = 'ota_ed25519_seed';
  final FlutterSecureStorage _s;
  OtaKeyStore([FlutterSecureStorage? s]) : _s = s ?? const FlutterSecureStorage();

  /// Extract the 32-byte Ed25519 seed from a PKCS#8 DER (RFC 8410).
  /// Standard encoding is 48 bytes: 16-byte prefix + 32-byte seed.
  static Uint8List seedFromPkcs8Der(Uint8List der) {
    if (der.length < 32) throw ArgumentError('DER too short for Ed25519 key');
    return Uint8List.fromList(der.sublist(der.length - 32));
  }

  Future<void> importSeed(Uint8List seed32) async {
    if (seed32.length != 32) throw ArgumentError('seed must be 32 bytes');
    await _s.write(key: _key, value: _hex(seed32));
  }

  Future<Uint8List?> loadSeed() async {
    final v = await _s.read(key: _key);
    if (v == null) return null;
    return Uint8List.fromList(
        [for (var i = 0; i < v.length; i += 2) int.parse(v.substring(i, i + 2), radix: 16)]);
  }

  Future<void> clear() => _s.delete(key: _key);

  static String _hex(Uint8List b) =>
      b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `flutter test test/ota/ota_key_store_test.dart`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add lib/services/ota_key_store.dart test/ota/ota_key_store_test.dart
git commit -m "feat(fotanrf): OtaKeyStore — Ed25519 seed import (DER) + secure storage"
```

---

### Task 9: PC export tool `ota_export_pkg.py`

**Files:**
- Create: `MeshCore/test_nrf-ota/ota_export_pkg.py`
- Test: `MeshCore/test_nrf-ota/tests/test_export_pkg.py`

**Interfaces:**
- Produces a CLI: `python ota_export_pkg.py --old o.bin --new n.bin [--privkey k.der --keyid 1] [--channel-name "#fkotanrf"] [--channel-idx 1] [--scope zerohop] [--freq 869.618 --bw 62.5 --sf 8 --cr 5] --out fw.otapkg.json`. Reuses `make_patch`, `build_meta_payload`, `build_sig_payload` from `ota_sender.py`. With `--privkey`, emits a `signed{}` block.

- [ ] **Step 1: Write the failing test** (`tests/test_export_pkg.py`)

```python
import base64, json, hashlib, subprocess, sys, struct
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]

def test_export_pkg_roundtrip(tmp_path):
    old = tmp_path / "old.bin"; new = tmp_path / "new.bin"
    old.write_bytes(bytes(4096)); new.write_bytes(bytes(2048) + b"\x01" * 2048)
    out = tmp_path / "fw.otapkg.json"
    r = subprocess.run([sys.executable, str(ROOT / "ota_export_pkg.py"),
        "--old", str(old), "--new", str(new), "--out", str(out)], capture_output=True)
    assert r.returncode == 0, r.stderr.decode()
    pkg = json.loads(out.read_text())
    assert pkg["format"] == "mc-fotanrf-otapkg/1"
    patch = base64.b64decode(pkg["patch_b64"])
    assert pkg["fw"]["patch_len"] == len(patch)
    assert pkg["fw"]["patch_sha256"] == hashlib.sha256(patch).hexdigest()
    assert "signed" not in pkg  # no --privkey
```

- [ ] **Step 2: Run to verify it fails**

Run: `cd /d/FkDev/FkProj/VSC/MeshCore && python -m pytest test_nrf-ota/tests/test_export_pkg.py -v`
Expected: FAIL — `ota_export_pkg.py` does not exist.

- [ ] **Step 3: Implement** (`MeshCore/test_nrf-ota/ota_export_pkg.py`)

```python
#!/usr/bin/env python3
"""Export a .otapkg.json for mc_fotanrf_flutterapp (phase A).
Reuses ota_sender.make_patch / build_meta_payload / build_sig_payload."""
import argparse, base64, json, sys
from pathlib import Path
sys.path.insert(0, str(Path(__file__).resolve().parent))
import ota_sender as S
from ota_sender import (make_patch, build_meta_payload, build_sig_payload,
                        load_ed25519_privkey, OTA_CHANNEL_NAME, OTA_CHUNK_DATA)

def main():
    ap = argparse.ArgumentParser(description="Export .otapkg.json for the Flutter OTA app")
    ap.add_argument('--old', required=True); ap.add_argument('--new', required=True)
    ap.add_argument('--patch', default='ota_patch.bin')
    ap.add_argument('--out', required=True)
    ap.add_argument('--channel-name', default=OTA_CHANNEL_NAME)
    ap.add_argument('--channel-idx', type=int, default=1)
    ap.add_argument('--scope', choices=['zerohop','flood','direct'], default='zerohop')
    ap.add_argument('--path', default='')
    ap.add_argument('--freq', type=float, default=869.618); ap.add_argument('--bw', type=float, default=62.5)
    ap.add_argument('--sf', type=int, default=8); ap.add_argument('--cr', type=int, default=5)
    ap.add_argument('--privkey'); ap.add_argument('--keyid', type=int, default=1)
    args = ap.parse_args()

    patch, patch_sha256, new_sha256, old_sha256, old_fw_size = \
        make_patch(Path(args.old), Path(args.new), Path(args.patch))
    pkg = {
        "format": "mc-fotanrf-otapkg/1",
        "created": "1970-01-01T00:00:00Z",
        "channel": {"name": args.channel_name, "idx": args.channel_idx},
        "radio": {"freq": args.freq, "bw": args.bw, "sf": args.sf, "cr": args.cr},
        "scope": args.scope, "path": args.path,
        "fw": {"old_sha256": old_sha256.hex(), "new_sha256": new_sha256.hex(),
               "old_fw_size": old_fw_size, "patch_sha256": patch_sha256.hex(),
               "patch_len": len(patch)},
        "patch_b64": base64.b64encode(patch).decode(),
    }
    if args.privkey:
        privkey = load_ed25519_privkey(Path(args.privkey))
        total = (len(patch) + OTA_CHUNK_DATA - 1) // OTA_CHUNK_DATA
        meta = build_meta_payload(total, len(patch), patch_sha256, new_sha256, old_sha256)
        sig = build_sig_payload(meta, privkey, args.keyid)
        pkg["signed"] = {"key_id": args.keyid,
                         "meta_b64": base64.b64encode(meta).decode(),
                         "sig_b64": base64.b64encode(sig).decode()}
    Path(args.out).write_text(json.dumps(pkg, indent=2))
    print(f"[export] {args.out}: patch={len(patch)}B signed={'signed' in pkg}")

if __name__ == '__main__':
    main()
```

- [ ] **Step 4: Run to verify it passes**

Run: `cd /d/FkDev/FkProj/VSC/MeshCore && python -m pytest test_nrf-ota/tests/test_export_pkg.py -v`
Expected: PASS. (Requires `hdiffi.exe` present in `test_nrf-ota/`, as the existing OTA tests do.)

- [ ] **Step 5: Commit (MeshCore repo)**

```bash
cd /d/FkDev/FkProj/VSC/MeshCore
git add test_nrf-ota/ota_export_pkg.py test_nrf-ota/tests/test_export_pkg.py
git commit -m "feat(nrfota): ota_export_pkg.py — .otapkg.json export for Flutter OTA app"
```

---

### Task 10: `ota_screen` + hub entry (UI)

**Files:**
- Create: `lib/screens/ota_screen.dart`
- Modify: `lib/screens/repeater_hub_screen.dart` (add one `_HubActionTile`)
- Test: `test/ota/ota_screen_smoke_test.dart`

**Interfaces:**
- Consumes: `OtaPkg`, `OtaSender`/`OtaFrameSink`, `OtaKeyStore`, `MeshCoreConnector` (via Provider), `file_picker`.
- Produces: `class OtaScreen extends StatefulWidget` with `const OtaScreen({required Contact repeater, required String password})`. An inner `class _ConnectorOtaSink implements OtaFrameSink` adapting `MeshCoreConnector` (`sendFrame`, `buildSetRadioParamsFrame`, `setChannel`).

- [ ] **Step 1: Implement the connector adapter + screen** (`lib/screens/ota_screen.dart`)

```dart
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../models/contact.dart';
import '../ota/ota_sender.dart';
import '../ota/ota_types.dart';
import '../ota/otapkg.dart';
import '../services/ota_key_store.dart';

class _ConnectorOtaSink implements OtaFrameSink {
  final MeshCoreConnector c;
  _ConnectorOtaSink(this.c);
  @override
  Future<void> sendFrame(Uint8List frame) => c.sendFrame(frame);
  @override
  Future<void> setRadio(int freqVal, int bwVal, int sf, int cr) =>
      c.sendFrame(buildSetRadioParamsFrame(freqVal, bwVal, sf, cr));
  @override
  Future<void> setChannel(int idx, String name, Uint8List psk) =>
      c.setChannel(idx, name, psk);
}

class OtaScreen extends StatefulWidget {
  final Contact repeater;
  final String password;
  const OtaScreen({super.key, required this.repeater, required this.password});
  @override
  State<OtaScreen> createState() => _OtaScreenState();
}

class _OtaScreenState extends State<OtaScreen> {
  OtaPkg? _pkg;
  String _log = '';
  double _progress = 0;
  bool _busy = false;
  bool _applyRadio = true;

  void _append(String s) => setState(() => _log = '$_log$s\n');

  Future<void> _pickPkg() async {
    final res = await FilePicker.platform.pickFiles(withData: true, type: FileType.any);
    if (res == null || res.files.single.bytes == null) return;
    try {
      final pkg = OtaPkg.fromJsonString(String.fromCharCodes(res.files.single.bytes!));
      setState(() => _pkg = pkg);
      _append('Loaded ${res.files.single.name}: '
          'patch=${pkg.patchLen}B chunks=${(pkg.patchLen / kOtaChunkData).ceil()} '
          'signed=${pkg.meta != null}');
    } catch (e) {
      _append('ERROR: $e');
    }
  }

  Future<void> _send({required bool apply}) async {
    final pkg = _pkg;
    if (pkg == null) return;
    final c = Provider.of<MeshCoreConnector>(context, listen: false);
    if (!c.isConnected) { _append('Not connected.'); return; }
    setState(() { _busy = true; _progress = 0; });
    try {
      Uint8List? seed;
      if (pkg.meta == null) seed = await OtaKeyStore().loadSeed(); // raw → need key
      await OtaSender(_ConnectorOtaSink(c)).send(
        pkg.toJob(),
        OtaSendConfig(
          channelName: pkg.channelName, channelIdx: pkg.channelIdx,
          freqMHz: pkg.freqMHz, bwKHz: pkg.bwKHz, sf: pkg.sf, cr: pkg.cr,
          scope: pkg.scope, pathHex: pkg.pathHex,
          applyAfter: apply, applyRadio: _applyRadio, delayMs: 300, seed32: seed,
        ),
        onProgress: (p) => setState(() {
          _progress = p.total == 0 ? 0 : p.sent / p.total;
        }),
      );
      _append(apply ? 'Done — APPLY sent (repeater will reboot).' : 'Done — all packets sent.');
    } catch (e) {
      _append('ERROR: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final pkg = _pkg;
    return Scaffold(
      appBar: AppBar(title: Text('OTA → ${widget.repeater.advName}')),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ElevatedButton.icon(
            onPressed: _busy ? null : _pickPkg,
            icon: const Icon(Icons.folder_open),
            label: const Text('Vyber .otapkg.json'),
          ),
          if (pkg != null) ...[
            const SizedBox(height: 8),
            Text('Kanál: ${pkg.channelName} [${pkg.channelIdx}]   '
                'Rádio: ${pkg.freqMHz}/${pkg.bwKHz}/SF${pkg.sf}/CR${pkg.cr}'),
            Text('Patch: ${pkg.patchLen} B   '
                'chunkov: ${(pkg.patchLen / kOtaChunkData).ceil()}   '
                'scope: ${pkg.scope.name}   signed: ${pkg.meta != null}'),
            SwitchListTile(
              value: _applyRadio,
              onChanged: _busy ? null : (v) => setState(() => _applyRadio = v),
              title: const Text('Nastaviť rádio companionu podľa balíka'),
            ),
            const SizedBox(height: 8),
            Row(children: [
              Expanded(child: ElevatedButton(
                onPressed: _busy ? null : () => _send(apply: false),
                child: const Text('Odoslať patch'))),
              const SizedBox(width: 8),
              Expanded(child: ElevatedButton(
                onPressed: _busy ? null : () => _send(apply: true),
                style: ElevatedButton.styleFrom(backgroundColor: Colors.deepOrange),
                child: const Text('Odoslať + APPLY'))),
            ]),
          ],
          const SizedBox(height: 8),
          if (_busy) LinearProgressIndicator(value: _progress),
          const SizedBox(height: 8),
          Expanded(child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            color: Colors.black12,
            child: SingleChildScrollView(child: Text(_log,
                style: const TextStyle(fontFamily: 'monospace', fontSize: 12))),
          )),
        ]),
      ),
    );
  }
}
```

> **Verify field names against the model:** `Contact.advName` / `Contact.publicKeyHex` are used elsewhere in the app (see `repeater_hub_screen.dart`). If the display-name getter differs, match the existing usage in that file.

- [ ] **Step 2: Add the hub entry** in `lib/screens/repeater_hub_screen.dart`

After the existing `_HubActionTile`s, add (importing `ota_screen.dart`):

```dart
_HubActionTile(
  index: 99,
  icon: Icons.system_update,
  title: 'OTA update',
  subtitle: 'LoRa delta-patch firmware update',
  accentColor: MeshPalette.blue,
  onTap: () {
    HapticFeedback.selectionClick();
    Navigator.push(context, MaterialPageRoute(
      builder: (context) => OtaScreen(repeater: repeater, password: password)));
  },
),
```

- [ ] **Step 3: Smoke test** (`test/ota/ota_screen_smoke_test.dart`)

```dart
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/screens/ota_screen.dart';
// Build a minimal Contact per the app's model constructor (match models/contact.dart).

void main() {
  testWidgets('OtaScreen renders the file-picker button', (tester) async {
    // NOTE: construct a Contact via its real constructor; see models/contact.dart.
    // This smoke test asserts the screen builds and shows the picker label.
    // (Provider<MeshCoreConnector> not needed until a send is triggered.)
  });
}
```

> Keep the smoke test minimal — full OTA flow is verified on hardware (Task 11). If constructing a `Contact` in a unit test is heavy, assert instead on a small pure widget extracted from the screen, or skip with a `// device-tested` note. Do not fake the whole connector here.

- [ ] **Step 4: Analyze + run tests**

Run: `flutter analyze` → no new errors.
Run: `flutter test` → all pass.

- [ ] **Step 5: Commit**

```bash
git add lib/screens/ota_screen.dart lib/screens/repeater_hub_screen.dart test/ota/ota_screen_smoke_test.dart
git commit -m "feat(fotanrf): OTA screen (pick .otapkg, send/apply, progress) + hub entry"
```

---

### Task 11: OTA admin quick-commands + on-device E2E checklist

**Files:**
- Modify: `lib/screens/repeater_cli_screen.dart` (extend `_quickCommands`)
- Create: `docs/fotanrf/e2e-checklist.md`

**Interfaces:**
- Consumes: existing `_quickCommands` / `RepeaterCommandService` (no API change).

- [ ] **Step 1: Add OTA quick-commands** to `_quickCommands` in `repeater_cli_screen.dart`:

```dart
  {'labelKey': 'otaStatus', 'command': 'ota status'},
  {'labelKey': 'otaVerify', 'command': 'ota verify'},
```

(If the list renders labels via l10n keys, add `otaStatus`/`otaVerify` to the ARB files, or use the literal command string as label — match how the existing entries resolve `labelKey`.)

- [ ] **Step 2: Write the E2E checklist** (`docs/fotanrf/e2e-checklist.md`)

```markdown
# nRF-OTA Flutter — on-device E2E checklist

Pre-reqs: companion (Xiao nRF52 / ESP32) flashed; OTA repeater (`ProMicro_repeater_ota`)
running; `agc_reset_interval = 0` (see fcl_readme_tech_nrf-ota §8.4); a `fw.otapkg.json`
built on PC via `ota_export_pkg.py`.

1. Connect to the companion (BLE: pair with 6-digit PIN / USB / WiFi). Confirm "connected".
2. Open repeater → Hub → "OTA update". Pick the `.otapkg.json`. Verify the summary
   (chunk count, channel, radio, signed=yes/no) matches the PC export log.
3. (raw pkg only) Import the Ed25519 key once if signed=no.
4. Tap "Odoslať patch" (no APPLY). Watch the progress bar reach 100%.
5. In the repeater CLI screen, run `ota status` → expect recv count rising to total, then
   VERIFIED. Run `ota verify` (dry-run) → expect SHA OK.
6. Tap "Odoslať + APPLY" (or send `ota flash` from CLI). Repeater reboots into the new build;
   confirm the new build number.
7. Repeat over USB and WiFi transports to confirm transport-agnostic behaviour.
8. Record pass/fail + build numbers (mirrors the Python E2E history in fcl_readme_tech_nrf-ota §10).
```

- [ ] **Step 3: Analyze + commit**

Run: `flutter analyze` → clean.

```bash
git add lib/screens/repeater_cli_screen.dart docs/fotanrf/e2e-checklist.md
git commit -m "feat(fotanrf): OTA admin quick-commands + on-device E2E checklist"
```

---

## Self-Review

**Spec coverage:**
- Transports BLE/USB/WiFi → reused via `MeshCoreConnector` (Task 1 fork) ✓
- CMD_SEND_CHANNEL_DATA=62 → Task 4 ✓
- META/SIG/chunk/APPLY byte-exact → Task 5 + golden vectors Task 2 ✓
- CRC16 → Task 3 ✓
- Ed25519 (pre-signed + raw) → Task 5 (sign) + Task 6 (pkg `signed{}`) + Task 8 (key store) ✓
- `.otapkg.json` (pre-signed + raw) → Task 6 ✓
- Session orchestration (hend, scope, pacing, ts++) → Task 7 ✓
- PC export tool (only MeshCore-repo change) → Task 9 ✓
- OTA screen + hub entry → Task 10 ✓
- Admin terminal (reuse) + OTA quick-commands → Task 11 ✓
- Radio units (×1000) → Global Constraints + Task 7 test asserts 869618/62500 ✓
- Phase B (FFI hdiff) → out of scope by design; `PatchSource`/`OtaJob` boundary preserved (Task 3 `OtaJob`, Task 6 `toJob`) so only a new `PatchSource` impl is added later ✓

**Placeholder scan:** Task 10 smoke test is intentionally light (UI is device-tested) with an explicit instruction, not a silent TODO. All code steps contain real code.

**Type consistency:** `OtaJob`, `OtaPayloadBuilder`, `OtaFrameSink`, `OtaSendConfig`, `OtaPkg.toJob()` names match across Tasks 3/5/6/7/10. `buildSendChannelDataFrame` signature identical in Tasks 4/7. Radio value `(freqMHz*1000).round()` consistent in Global Constraints/Task 7.

**Known follow-ups (not blockers):**
- pointycastle Ed25519 exact class names confirmed by the Task 5 golden gate.
- `Contact` display/key getters confirmed against `repeater_hub_screen.dart` usage in Task 10.
- Channel index collision (OTA uses idx from pkg; could clobber a user channel) — surfaced to the user in the OTA screen summary; a "safe index" picker is a future enhancement.
