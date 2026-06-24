# FOTA Package Generation — Step 2a (Dart delta engine + builder) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A reusable pure-Dart package that creates and applies HPatchLite inplace-lite delta patches, plus an app-side builder that wraps a patch into the MeshCore staged-DEFLATE `.otapkg.json` — so the app can generate firmware packages on any platform with no server and the device side untouched.

**Architecture:** A standalone path package `packages/hpatchlite_dart/` (pure Dart, zero deps) holds the codec: a varint/header reader-writer, an applier (port of the device's `hpatch_lite.c`), and an encoder (rolling-hash matcher emitting pure-copy covers + literal gaps, with a derived `extraSafeSize`). Correctness is proven offline: the applier is checked against a golden patch from the reference `hdiffi.exe`, and the encoder by round-trip (`apply(create(old,new),old) == new`) plus an in-place-safety simulation. The app's `lib/ota/ota_pkg_builder.dart` then DEFLATEs (512-byte window) and wraps the raw diff into the staged `ZLIB` format and assembles the existing `OtaPkg` schema.

**Tech Stack:** Pure Dart (`dart:typed_data` only) for the package; `package:test` for its tests. App side adds `package:archive` (pure-Dart DEFLATE, web-safe) and the path dependency.

## Global Constraints

- **Reusable library is pure Dart, ZERO runtime deps** (only `dart:typed_data`; `package:test` is dev-only). No Flutter, no `dart:io` in `lib/`. It must be usable by any Dart/Flutter/web/server project and publishable to pub.dev unchanged.
- **The device side is the source of truth and is NOT modified.** The format is exactly what `../MeshCore/examples/simple_repeater/nrfota/hpatchlite/hpatch_lite.c` (`hpatchi_inplace_open` + `hpatch_lite_patch`) decodes. Constants from `hpatch_lite_types.h`: `kHeadSize=4`, `kInplaceHeadSize=5`, inplace version code `=2`, `hpi_compressType_no=0`.
- **Format facts (verbatim):** header bytes `[0]='h'(0x68) [1]='I'(0x49) [2]=compressType [3]=packed [4]=extraSafeSizeByteCount`, where `packed = (version<<6) | (uncompressSizeByteCount<<3) | newSizeByteCount`. Then `newSize` (N LE bytes, byte0=LSB), `uncompressSize` (M LE bytes; **0 bytes when compressType==no**), `extraSafeSize` (E LE bytes). Body: varint `coverCount`, then per cover: varint `coverLength`; one `tag` byte; `oldPos` magnitude (`tag&31` as the most-significant 5 bits, continue if `tag&32`, more 7-bit groups follow); sign `tag&64` (set ⇒ `oldPos=oldPosBack-mag`, else `+mag`); `isNotNeedSubDiff=tag&128`; varint `newPosDelta` (`coverNewPos=newPosBack+newPosDelta`); then `coverNewPos-newPosBack` **literal new bytes inline**; then (only if `!isNotNeedSubDiff`) `coverLength` additive sub-diff bytes. `newPosBack` must end exactly at `newSize` (a trailing literal run is a final cover with `coverLength==0`).
- **Varint scheme (matches `_cache_unpackUInt`):** decode `v=initial; while(isNext){b=read; v=(v<<7)|(b&127); isNext=b>>7;}`. Encode: 7-bit groups most-significant first, every byte except the last has bit7 set; value 0 ⇒ a single `0x00` byte.
- **`extraSafeSize` derivation:** `max(0, max over copy covers of (coverNewPos - coverOldPos))`. The encoder accepts a match only if `(newPos - oldPos) <= maxExtraSafeSize` (reads ahead, `oldPos>=newPos`, are always safe and contribute 0). This guarantees the device's delayed-write ring buffer never reads an already-overwritten old byte.
- **Our encoder emits pure-copy covers only** (`isNotNeedSubDiff=1`, no sub-diff). The applier must still *support* sub-diff covers so it can verify reference `hdiffi.exe` golden patches.
- **No byte-identity with `ota_sender.py` is expected for the patch payload** — our simpler matcher yields a different (valid) raw diff. Equivalence is *semantic* (device accepts it; `apply==new`) and *structural* (same `.otapkg.json` schema + same staged `ZLIB` wrapper layout), NOT byte-equal patch bytes.
- **Staged wrapper (app side), byte-layout-compatible with `ota_sender.py::make_patch`:** `['Z','L','I','B'][uncompSize u32le][newFwSize u32le][rawDEFLATE]`; DEFLATE is **raw** (no zlib header) with a **512-byte window** (the device `puff_stream` limit) and the decompressed bytes are the raw inplace diff. `patch_sha256 = sha256(stagedBlob)`.
- **Run package tests with the portable Dart** (flutter's bundled dart): PowerShell `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path`, then `dart pub get` / `dart test` **from the package directory** `packages/hpatchlite_dart`. App tests use `flutter test` from the repo root as before.
- **Commits** autonomous on `feature/nrf-ota-sender`; never `dev`/`main`. Trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01DGscgD7gWZkVT5x8uoW2tV`.

---

### Task 1: Package scaffold + path dependency + golden fixture

**Files:**
- Create: `packages/hpatchlite_dart/pubspec.yaml`
- Create: `packages/hpatchlite_dart/lib/hpatchlite_dart.dart` (export stub)
- Create: `packages/hpatchlite_dart/test/fixtures/README.md` (+ generated fixture files)
- Create: `packages/hpatchlite_dart/test/fixture_test.dart`
- Modify: repo-root `pubspec.yaml` (add the path dependency)

**Interfaces:**
- Produces: a resolvable pure-Dart package `hpatchlite_dart`; fixture files `old.bin`, `new.bin`, `golden.inplace` (raw inplace diff from `hdiffi.exe`) under `test/fixtures/`, and their SHA-256 values in `fixtures/README.md`.

- [ ] **Step 1: Generate the golden fixture with the reference toolchain**

Run (Git Bash). Builds a tiny deterministic old/new pair and the reference raw inplace patch:

```bash
cd "$(git rev-parse --show-toplevel)"
mkdir -p packages/hpatchlite_dart/test/fixtures
cd packages/hpatchlite_dart/test/fixtures
# deterministic 1024-byte "old": bytes 0..255 repeated; "new" = same but a 16-byte block changed + 32 appended
python - <<'PY'
old = bytes([i & 0xFF for i in range(1024)])
new = bytearray(old)
new[200:216] = bytes([0xAA]*16)          # in-place change
new += bytes([0x55]*32)                  # append
open('old.bin','wb').write(old)
open('new.bin','wb').write(bytes(new))
import hashlib
print("old", hashlib.sha256(old).hexdigest())
print("new", hashlib.sha256(bytes(new)).hexdigest())
PY
# locate hdiffi.exe (repo ships it under test_nrf-ota)
HDIFFI=$(ls ../../../../MeshCore/test_nrf-ota/hdiffi.exe ../../../../MeshCore/test_nrf-ota/tools/hdiffi.exe 2>/dev/null | head -1)
echo "hdiffi: $HDIFFI"
"$HDIFFI" -inplaceB old.bin new.bin golden.inplace
ls -l old.bin new.bin golden.inplace
```

Record both SHA-256 lines into `packages/hpatchlite_dart/test/fixtures/README.md` with a one-line note that `golden.inplace` is `hdiffi.exe -inplaceB old.bin new.bin`. (If `python` is missing, use the PlatformIO penv python `D:\FkDev\.platformio\penv\Scripts\python.exe`.)

- [ ] **Step 2: Write the package manifest + export stub + a fixture-presence test**

`packages/hpatchlite_dart/pubspec.yaml`:

```yaml
name: hpatchlite_dart
description: Pure-Dart create/apply for HPatchLite inplace-lite delta patches.
version: 0.1.0
environment:
  sdk: ^3.9.0
dev_dependencies:
  test: ^1.25.0
```

`packages/hpatchlite_dart/lib/hpatchlite_dart.dart`:

```dart
/// Pure-Dart HPatchLite inplace-lite codec: create and apply delta patches
/// byte-compatible with the on-device HPatchLite applier.
library;
// Public API is added by later tasks:
//   export 'src/applier.dart';
//   export 'src/encoder.dart';
```

`packages/hpatchlite_dart/test/fixture_test.dart`:

```dart
import 'dart:io';
import 'package:test/test.dart';

void main() {
  test('golden fixtures exist and are non-empty', () {
    for (final f in ['old.bin', 'new.bin', 'golden.inplace']) {
      final file = File('test/fixtures/$f');
      expect(file.existsSync(), isTrue, reason: '$f missing');
      expect(file.lengthSync(), greaterThan(0));
    }
  });
}
```

- [ ] **Step 3: Wire the path dependency in the app and resolve both**

Add to the repo-root `pubspec.yaml` under `dependencies:` (alongside the others):

```yaml
  hpatchlite_dart:
    path: packages/hpatchlite_dart
```

- [ ] **Step 4: Run the package test and app resolve**

Run:
```
$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path
cd packages/hpatchlite_dart; dart pub get; dart test
```
Expected: 1 test passes.
Then from repo root:
```
$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path
flutter pub get
```
Expected: resolves with `hpatchlite_dart` from path, no errors.

- [ ] **Step 5: Commit**

```bash
git add packages/hpatchlite_dart pubspec.yaml
git commit -m "feat(hpatchlite_dart): package scaffold + path dep + golden fixture"
```

---

### Task 2: Varint + inplace header codec

**Files:**
- Create: `packages/hpatchlite_dart/lib/src/codec.dart`
- Test: `packages/hpatchlite_dart/test/codec_test.dart`

**Interfaces:**
- Produces:
  - `class ByteReader { ByteReader(Uint8List data); int readByte(); }`
  - `int readVarint(ByteReader r, int initial, bool isNext)`
  - `void writeVarint(BytesBuilder b, int v)`
  - `class InplaceHeader { final int newSize, uncompressSize, extraSafeSize, compressType; }`
  - `InplaceHeader readInplaceHeader(ByteReader r)`
  - `Uint8List encodeInplaceHeader({required int newSize, required int extraSafeSize})` (compressType=no, uncompressSize=0)

- [ ] **Step 1: Write the failing test**

`packages/hpatchlite_dart/test/codec_test.dart`:

```dart
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:hpatchlite_dart/src/codec.dart';

void main() {
  test('varint round-trips MSB-first with continuation', () {
    for (final v in [0, 1, 31, 127, 128, 300, 16384, 1 << 20, 0x7FFFFFF]) {
      final b = BytesBuilder();
      writeVarint(b, v);
      final r = ByteReader(b.toBytes());
      expect(readVarint(r, 0, true), v, reason: 'value $v');
    }
  });

  test('value 0 encodes as a single 0x00 byte', () {
    final b = BytesBuilder();
    writeVarint(b, 0);
    expect(b.toBytes(), Uint8List.fromList([0x00]));
  });

  test('inplace header round-trips newSize + extraSafeSize', () {
    final bytes = encodeInplaceHeader(newSize: 1056, extraSafeSize: 40);
    expect(bytes[0], 0x68); // 'h'
    expect(bytes[1], 0x49); // 'I'
    expect(bytes[2], 0); // compressType_no
    expect(bytes[3] >> 6, 2); // inplace version code
    final h = readInplaceHeader(ByteReader(bytes));
    expect(h.newSize, 1056);
    expect(h.uncompressSize, 0);
    expect(h.extraSafeSize, 40);
    expect(h.compressType, 0);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; cd packages/hpatchlite_dart; dart test test/codec_test.dart`
Expected: FAIL — `codec.dart` / symbols not found.

- [ ] **Step 3: Write minimal implementation**

`packages/hpatchlite_dart/lib/src/codec.dart`:

```dart
import 'dart:typed_data';

/// Sequential byte reader over an in-memory buffer.
class ByteReader {
  final Uint8List _d;
  int _p = 0;
  ByteReader(this._d);
  int get pos => _p;
  int readByte() {
    if (_p >= _d.length) {
      throw StateError('ByteReader: read past end ($_p/${_d.length})');
    }
    return _d[_p++];
  }
}

/// Decode a base-128 varint, MSB group first (matches `_cache_unpackUInt`).
/// [initial] seeds the value (e.g. the low bits packed into a tag byte);
/// [isNext] says whether at least one more 7-bit group follows.
int readVarint(ByteReader r, int initial, bool isNext) {
  var v = initial;
  while (isNext) {
    final b = r.readByte();
    v = (v << 7) | (b & 0x7F);
    isNext = (b & 0x80) != 0;
  }
  return v;
}

/// Encode [v] as a base-128 varint, MSB group first; every byte but the last
/// has its high bit set. 0 -> a single 0x00 byte.
void writeVarint(BytesBuilder b, int v) {
  final groups = <int>[];
  do {
    groups.insert(0, v & 0x7F);
    v >>= 7;
  } while (v != 0);
  for (var i = 0; i < groups.length; i++) {
    b.addByte(groups[i] | (i < groups.length - 1 ? 0x80 : 0));
  }
}

class InplaceHeader {
  final int compressType, newSize, uncompressSize, extraSafeSize;
  InplaceHeader(
      this.compressType, this.newSize, this.uncompressSize, this.extraSafeSize);
}

int _readLE(ByteReader r, int n) {
  var v = 0;
  for (var i = 0; i < n; i++) {
    v |= r.readByte() << (8 * i);
  }
  return v;
}

void _writeLE(BytesBuilder b, int v) {
  while (v > 0) {
    b.addByte(v & 0xFF);
    v >>= 8;
  }
}

int _leByteCount(int v) {
  var n = 0;
  while (v > 0) {
    n++;
    v >>= 8;
  }
  return n; // 0 for value 0
}

InplaceHeader readInplaceHeader(ByteReader r) {
  if (r.readByte() != 0x68 || r.readByte() != 0x49) {
    throw const FormatException('not an HPatchLite "hI" stream');
  }
  final compressType = r.readByte();
  final packed = r.readByte();
  final version = packed >> 6;
  final newBytes = packed & 7;
  final uncompBytes = (packed >> 3) & 7;
  final extraBytes = r.readByte();
  if (version != 2) {
    throw FormatException('expected inplace version 2, got $version');
  }
  final newSize = _readLE(r, newBytes);
  final uncompressSize = _readLE(r, uncompBytes);
  final extraSafeSize = _readLE(r, extraBytes);
  return InplaceHeader(compressType, newSize, uncompressSize, extraSafeSize);
}

/// Build the inplace-lite header for an UNCOMPRESSED diff (compressType=no,
/// uncompressSize=0), carrying [newSize] and [extraSafeSize].
Uint8List encodeInplaceHeader(
    {required int newSize, required int extraSafeSize}) {
  final newBytes = _leByteCount(newSize);
  const uncompBytes = 0; // uncompressed
  final extraBytes = _leByteCount(extraSafeSize);
  final b = BytesBuilder();
  b.addByte(0x68); // 'h'
  b.addByte(0x49); // 'I'
  b.addByte(0); // compressType_no
  b.addByte((2 << 6) | (uncompBytes << 3) | newBytes); // version 2
  b.addByte(extraBytes);
  _writeLE(b, newSize);
  // uncompressSize: 0 bytes
  _writeLE(b, extraSafeSize);
  return b.toBytes();
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; cd packages/hpatchlite_dart; dart test test/codec_test.dart`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add packages/hpatchlite_dart/lib/src/codec.dart packages/hpatchlite_dart/test/codec_test.dart
git commit -m "feat(hpatchlite_dart): varint + inplace header codec"
```

---

### Task 3: Applier (port of the device patcher) + golden verification

**Files:**
- Create: `packages/hpatchlite_dart/lib/src/applier.dart`
- Modify: `packages/hpatchlite_dart/lib/hpatchlite_dart.dart` (export applier)
- Test: `packages/hpatchlite_dart/test/applier_test.dart`

**Interfaces:**
- Consumes: `ByteReader`, `readVarint`, `readInplaceHeader` from Task 2.
- Produces: `Uint8List applyInplaceLiteDiff(Uint8List diff, Uint8List oldData)` — reconstructs new from the raw inplace diff and full old buffer; supports both pure-copy and sub-diff covers.

- [ ] **Step 1: Write the failing test**

`packages/hpatchlite_dart/test/applier_test.dart`:

```dart
import 'dart:io';
import 'dart:typed_data';
import 'package:crypto/crypto.dart' as c;
import 'package:test/test.dart';
import 'package:hpatchlite_dart/hpatchlite_dart.dart';

void main() {
  test('applies the reference hdiffi golden patch to reconstruct new.bin', () {
    final old = File('test/fixtures/old.bin').readAsBytesSync();
    final newExpected = File('test/fixtures/new.bin').readAsBytesSync();
    final diff = File('test/fixtures/golden.inplace').readAsBytesSync();
    final got = applyInplaceLiteDiff(
        Uint8List.fromList(diff), Uint8List.fromList(old));
    expect(got.length, newExpected.length);
    expect(c.sha256.convert(got).toString(),
        c.sha256.convert(newExpected).toString());
  });
}
```

Add `crypto` to the package dev_dependencies for tests (it is a transitive dep already in the workspace; declare it so the package test resolves standalone): append to `packages/hpatchlite_dart/pubspec.yaml` `dev_dependencies:`:

```yaml
  crypto: ^3.0.3
```

- [ ] **Step 2: Run test to verify it fails**

Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; cd packages/hpatchlite_dart; dart pub get; dart test test/applier_test.dart`
Expected: FAIL — `applyInplaceLiteDiff` not defined.

- [ ] **Step 3: Write minimal implementation**

`packages/hpatchlite_dart/lib/src/applier.dart`:

```dart
import 'dart:typed_data';
import 'codec.dart';

/// Apply a raw HPatchLite inplace-lite [diff] to [oldData], returning new data.
/// Mirrors `hpatchi_inplace_open` + `hpatch_lite_patch` from the device applier,
/// reading old via random access (so it verifies cover/format correctness; it
/// does NOT model the in-place ring buffer — see the encoder's safety sim).
/// Supports pure-copy covers and additive sub-diff covers.
Uint8List applyInplaceLiteDiff(Uint8List diff, Uint8List oldData) {
  final r = ByteReader(diff);
  final h = readInplaceHeader(r);
  if (h.compressType != 0) {
    throw const FormatException('compressed diff not supported by this applier');
  }
  final out = Uint8List(h.newSize);
  var newPosBack = 0;
  var oldPosBack = 0;
  var coverCount = readVarint(r, 0, true);
  while (coverCount-- > 0) {
    final coverLength = readVarint(r, 0, true);
    final tag = r.readByte();
    final oldMag = readVarint(r, tag & 31, (tag & 32) != 0);
    final isNotNeedSubDiff = (tag & 128) != 0;
    final coverOldPos =
        (tag & 64) != 0 ? oldPosBack - oldMag : oldPosBack + oldMag;
    final coverNewPos = readVarint(r, 0, true) + newPosBack;
    // literal gap: bytes copied straight from the diff stream
    for (var i = newPosBack; i < coverNewPos; i++) {
      out[i] = r.readByte();
    }
    // copy from old (+ additive sub-diff when present)
    for (var k = 0; k < coverLength; k++) {
      var v = oldData[coverOldPos + k];
      if (!isNotNeedSubDiff) v = (v + r.readByte()) & 0xFF;
      out[coverNewPos + k] = v;
    }
    newPosBack = coverNewPos + coverLength;
    oldPosBack = coverOldPos + coverLength;
  }
  if (newPosBack != h.newSize) {
    throw FormatException(
        'patch produced $newPosBack bytes, expected ${h.newSize}');
  }
  return out;
}
```

Update `packages/hpatchlite_dart/lib/hpatchlite_dart.dart`:

```dart
/// Pure-Dart HPatchLite inplace-lite codec: create and apply delta patches
/// byte-compatible with the on-device HPatchLite applier.
library;

export 'src/applier.dart';
// export 'src/encoder.dart'; // added in Task 4
```

- [ ] **Step 4: Run test to verify it passes**

Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; cd packages/hpatchlite_dart; dart test test/applier_test.dart`
Expected: PASS — golden patch reconstructs `new.bin` (sha256 match). This pins the format decode against the real `hdiffi.exe` output.

- [ ] **Step 5: Commit**

```bash
git add packages/hpatchlite_dart/lib/src/applier.dart packages/hpatchlite_dart/lib/hpatchlite_dart.dart packages/hpatchlite_dart/pubspec.yaml packages/hpatchlite_dart/test/applier_test.dart
git commit -m "feat(hpatchlite_dart): inplace-lite applier verified vs hdiffi golden"
```

---

### Task 4: Encoder (matcher + covers + extraSafeSize) + safety sim

**Files:**
- Create: `packages/hpatchlite_dart/lib/src/encoder.dart`
- Modify: `packages/hpatchlite_dart/lib/hpatchlite_dart.dart` (export encoder)
- Test: `packages/hpatchlite_dart/test/encoder_test.dart`

**Interfaces:**
- Consumes: `writeVarint`, `encodeInplaceHeader` from Task 2; `applyInplaceLiteDiff` from Task 3.
- Produces: `Uint8List createInplaceLiteDiff(Uint8List oldData, Uint8List newData, {int maxExtraSafeSize = 0x4000})` — a raw inplace-lite diff (compressType=no) with only pure-copy covers + literal gaps; `extraSafeSize` is the max `newPos-oldPos` over its covers (≤ `maxExtraSafeSize`).

- [ ] **Step 1: Write the failing test**

`packages/hpatchlite_dart/test/encoder_test.dart`:

```dart
import 'dart:math';
import 'dart:typed_data';
import 'package:test/test.dart';
import 'package:hpatchlite_dart/hpatchlite_dart.dart';
import 'package:hpatchlite_dart/src/codec.dart';

// Re-derive extraSafeSize from the diff header and prove in-place safety:
// replay covers while modelling the device's delayed write pointer
// (write lags the new cursor by extraSafeSize); assert no cover ever reads an
// old byte that has already been overwritten.
void _assertInplaceSafe(Uint8List diff, int oldLen) {
  final r = ByteReader(diff);
  final h = readInplaceHeader(r);
  var newPosBack = 0, oldPosBack = 0;
  var coverCount = readVarint(r, 0, true);
  while (coverCount-- > 0) {
    final coverLength = readVarint(r, 0, true);
    final tag = r.readByte();
    final oldMag = readVarint(r, tag & 31, (tag & 32) != 0);
    final coverOldPos =
        (tag & 64) != 0 ? oldPosBack - oldMag : oldPosBack + oldMag;
    final coverNewPos = readVarint(r, 0, true) + newPosBack;
    for (var i = newPosBack; i < coverNewPos; i++) {
      r.readByte(); // literal
    }
    // safety: writePtr at the moment we read oldPos+k is (coverNewPos+k)-extraSafeSize-1
    expect(coverNewPos - coverOldPos <= h.extraSafeSize, isTrue,
        reason: 'cover newPos=$coverNewPos oldPos=$coverOldPos exceeds extraSafeSize=${h.extraSafeSize}');
    newPosBack = coverNewPos + coverLength;
    oldPosBack = coverOldPos + coverLength;
  }
}

void _roundTrip(List<int> oldL, List<int> newL) {
  final old = Uint8List.fromList(oldL);
  final nw = Uint8List.fromList(newL);
  final diff = createInplaceLiteDiff(old, nw);
  expect(applyInplaceLiteDiff(diff, old), nw);
  _assertInplaceSafe(diff, old.length);
}

void main() {
  test('identical', () => _roundTrip(
      List.generate(500, (i) => i & 0xFF), List.generate(500, (i) => i & 0xFF)));
  test('empty new', () => _roundTrip([1, 2, 3], []));
  test('empty old', () => _roundTrip([], [9, 8, 7, 6, 5]));
  test('append', () {
    final base = List.generate(800, (i) => (i * 7) & 0xFF);
    _roundTrip(base, [...base, 1, 2, 3, 4, 5, 6, 7, 8]);
  });
  test('truncate', () {
    final base = List.generate(800, (i) => (i * 7) & 0xFF);
    _roundTrip(base, base.sublist(0, 600));
  });
  test('mid change', () {
    final base = List.generate(1024, (i) => i & 0xFF);
    final nw = [...base];
    for (var i = 400; i < 420; i++) {
      nw[i] = 0xEE;
    }
    _roundTrip(base, nw);
  });
  test('pseudo-random pair stays correct and safe', () {
    final rnd = Random(42);
    final old = List.generate(4000, (_) => rnd.nextInt(256));
    final nw = [...old];
    for (var i = 0; i < 300; i++) {
      nw[rnd.nextInt(nw.length)] = rnd.nextInt(256);
    }
    _roundTrip(old, nw);
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; cd packages/hpatchlite_dart; dart test test/encoder_test.dart`
Expected: FAIL — `createInplaceLiteDiff` not defined.

- [ ] **Step 3: Write minimal implementation**

`packages/hpatchlite_dart/lib/src/encoder.dart`:

```dart
import 'dart:typed_data';
import 'codec.dart';

const int _minMatch = 8; // also the rolling-hash window

class _Cover {
  final int newPos, oldPos, length; // literal gap = newPos - prevNewEnd
  _Cover(this.newPos, this.oldPos, this.length);
}

int _hash8(Uint8List d, int p) {
  // FNV-1a over 8 bytes -> 32-bit
  var h = 0x811c9dc5;
  for (var i = 0; i < _minMatch; i++) {
    h ^= d[p + i];
    h = (h * 0x01000193) & 0xFFFFFFFF;
  }
  return h;
}

/// Create a raw HPatchLite inplace-lite diff (compressType=no) turning
/// [oldData] into [newData], using a rolling-hash greedy matcher that emits
/// pure-copy covers + literal gaps. A match is accepted only when
/// (newPos - oldPos) <= [maxExtraSafeSize], keeping the patch in-place-safe
/// within a bounded device ring buffer.
Uint8List createInplaceLiteDiff(Uint8List oldData, Uint8List newData,
    {int maxExtraSafeSize = 0x4000}) {
  // 1) index old by 8-byte hash -> most recent positions (chain, capped)
  final table = <int, List<int>>{};
  for (var i = 0; i + _minMatch <= oldData.length; i++) {
    (table[_hash8(oldData, i)] ??= <int>[]).add(i);
  }

  // 2) greedy scan of new, building covers
  final covers = <_Cover>[];
  var extraSafeSize = 0;
  var i = 0;
  while (i < newData.length) {
    int bestOld = -1, bestLen = 0;
    if (i + _minMatch <= newData.length) {
      final cands = table[_hash8(newData, i)];
      if (cands != null) {
        // try recent candidates; accept only in-place-safe ones
        for (var ci = cands.length - 1; ci >= 0 && ci >= cands.length - 8; ci--) {
          final oldPos = cands[ci];
          if (i - oldPos > maxExtraSafeSize) continue; // reading too far behind
          var len = 0;
          while (oldPos + len < oldData.length &&
              i + len < newData.length &&
              oldData[oldPos + len] == newData[i + len]) {
            len++;
          }
          if (len > bestLen) {
            bestLen = len;
            bestOld = oldPos;
          }
        }
      }
    }
    if (bestLen >= _minMatch) {
      covers.add(_Cover(i, bestOld, bestLen));
      if (i - bestOld > extraSafeSize) extraSafeSize = i - bestOld;
      i += bestLen;
    } else {
      i++; // literal; absorbed into the next cover's gap (or the trailing cover)
    }
  }

  // 3) ensure newPosBack reaches newSize: append a terminal zero-length cover
  //    carrying any trailing literal gap.
  final lastEnd = covers.isEmpty ? 0 : covers.last.newPos + covers.last.length;
  if (lastEnd < newData.length) {
    covers.add(_Cover(newData.length, 0, 0)); // gap = trailing literals
  }

  // 4) encode
  final body = BytesBuilder();
  writeVarint(body, covers.length);
  var newPosBack = 0, oldPosBack = 0;
  for (final cv in covers) {
    writeVarint(body, cv.length);
    // oldPos delta with sign, packed into a tag byte (isNotNeedSubDiff=1)
    final delta = cv.oldPos - oldPosBack;
    final sign = delta < 0 ? 1 : 0;
    final mag = delta.abs();
    _writeTagAndOldPos(body, mag, sign, isNotNeedSubDiff: true);
    writeVarint(body, cv.newPos - newPosBack);
    // literal gap bytes inline
    for (var p = newPosBack; p < cv.newPos; p++) {
      body.addByte(newData[p]);
    }
    newPosBack = cv.newPos + cv.length;
    oldPosBack = cv.oldPos + cv.length;
  }

  final header =
      encodeInplaceHeader(newSize: newData.length, extraSafeSize: extraSafeSize);
  return (BytesBuilder()
        ..add(header)
        ..add(body.toBytes()))
      .toBytes();
}

/// Emit the tag byte + trailing 7-bit groups for an oldPos magnitude.
/// Decoder: v = tag&31 (top 5 bits), continue if tag&32, then 7-bit groups
/// MSB-first (bit7 = continue). bit6 = sign, bit7 = isNotNeedSubDiff.
void _writeTagAndOldPos(BytesBuilder b, int mag, int sign,
    {required bool isNotNeedSubDiff}) {
  // peel 7-bit groups from the bottom until the remainder fits in 5 bits
  final groups = <int>[];
  var tmp = mag;
  while (tmp > 31) {
    groups.insert(0, tmp & 0x7F);
    tmp >>= 7;
  }
  final top5 = tmp & 31;
  final hasMore = groups.isNotEmpty;
  final tag = (isNotNeedSubDiff ? 0x80 : 0) |
      (sign << 6) |
      (hasMore ? 0x20 : 0) |
      top5;
  b.addByte(tag);
  for (var i = 0; i < groups.length; i++) {
    b.addByte(groups[i] | (i < groups.length - 1 ? 0x80 : 0));
  }
}
```

Update `packages/hpatchlite_dart/lib/hpatchlite_dart.dart` to also `export 'src/encoder.dart';`.

- [ ] **Step 4: Run test to verify it passes**

Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; cd packages/hpatchlite_dart; dart test`
Expected: PASS — all encoder round-trips reconstruct `new` and every diff passes the in-place-safety assertion; plus Task 2/3 tests still green.

- [ ] **Step 5: Commit**

```bash
git add packages/hpatchlite_dart/lib/src/encoder.dart packages/hpatchlite_dart/lib/hpatchlite_dart.dart packages/hpatchlite_dart/test/encoder_test.dart
git commit -m "feat(hpatchlite_dart): inplace-lite encoder (matcher + covers + extraSafeSize) + safety sim"
```

---

### Task 5: App-side package builder (DEFLATE-512 + staged ZLIB + .otapkg.json)

**Files:**
- Create: `lib/ota/ota_pkg_builder.dart`
- Modify: repo-root `pubspec.yaml` (add `archive`)
- Test: `test/ota/ota_pkg_builder_test.dart`

**Interfaces:**
- Consumes: `createInplaceLiteDiff`, `applyInplaceLiteDiff` from `package:hpatchlite_dart`; the existing `OtaPkg` / `mc-fotanrf-otapkg/1` schema (`lib/ota/otapkg.dart`).
- Produces:
  - `class OtaBuildParams { final String channelName; final int channelIdx; final double freqMHz, bwKHz; final int sf, cr; final String scope, path; }`
  - `Uint8List buildStagedPatch(Uint8List oldFw, Uint8List newFw)` — raw diff → raw-DEFLATE(512 window) → staged `['ZLIB'][uncomp u32le][newFwSize u32le][deflate]`.
  - `String buildOtaPkgJson({required Uint8List oldFw, required Uint8List newFw, required OtaBuildParams p})` — assembles the `.otapkg.json` string (raw/unsigned), with a self-check that `applyInplaceLiteDiff(rawDiff, oldFw) == newFw` before emitting (throws `OtaBuildException` otherwise).

- [ ] **Step 1: Write the failing test**

`test/ota/ota_pkg_builder_test.dart`:

```dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as c;
import 'package:meshcore_open/ota/ota_pkg_builder.dart';
import 'package:meshcore_open/ota/otapkg.dart';

void main() {
  final oldFw = Uint8List.fromList(List.generate(2048, (i) => i & 0xFF));
  final newFw = Uint8List.fromList([
    ...List.generate(2048, (i) => i & 0xFF)..setRange(500, 520, List.filled(20, 0xAB)),
    ...List.filled(64, 0x33),
  ]);
  final params = OtaBuildParams(
      channelName: '#fkotanrf', channelIdx: 1,
      freqMHz: 869.618, bwKHz: 62.5, sf: 8, cr: 5, scope: 'zerohop', path: '');

  test('staged patch has the ZLIB header and decompresses to the raw diff', () {
    final staged = buildStagedPatch(oldFw, newFw);
    expect(String.fromCharCodes(staged.sublist(0, 4)), 'ZLIB');
    final uncompSize = staged.buffer.asByteData().getUint32(4, Endian.little);
    final newFwSize = staged.buffer.asByteData().getUint32(8, Endian.little);
    expect(newFwSize, newFw.length);
    final raw = Uint8List.fromList(
        const ZLibDecoder().decodeBytes(staged.sublist(12), raw: true));
    expect(raw.length, uncompSize);
  });

  test('buildOtaPkgJson yields a valid OtaPkg whose patch reconstructs newFw', () {
    final json = buildOtaPkgJson(oldFw: oldFw, newFw: newFw, p: params);
    final pkg = OtaPkg.fromJsonString(json);
    expect(pkg.channelName, '#fkotanrf');
    expect(pkg.freqMHz, 869.618);
    // declared firmware hashes are correct
    expect(pkg.oldSha256, Uint8List.fromList(c.sha256.convert(oldFw).bytes));
    expect(pkg.newSha256, Uint8List.fromList(c.sha256.convert(newFw).bytes));
    expect(pkg.oldFwSize, oldFw.length);
    // OtaPkg.fromJsonString already verifies patch_sha256 == sha256(staged patch)
    // (throws otherwise), so a successful parse proves the staged patch integrity.
    expect((jsonDecode(json) as Map)['format'], 'mc-fotanrf-otapkg/1');
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; flutter test test/ota/ota_pkg_builder_test.dart`
Expected: FAIL — `archive` missing and `ota_pkg_builder.dart` not found.

- [ ] **Step 3: Add `archive` and write the builder**

Add to repo-root `pubspec.yaml` `dependencies:`:

```yaml
  archive: ^4.0.0
```

`lib/ota/ota_pkg_builder.dart`:

```dart
import 'dart:convert';
import 'dart:typed_data';
import 'package:archive/archive.dart';
import 'package:crypto/crypto.dart' as c;
import 'package:hpatchlite_dart/hpatchlite_dart.dart';

class OtaBuildException implements Exception {
  final String message;
  OtaBuildException(this.message);
  @override
  String toString() => 'OtaBuildException: $message';
}

class OtaBuildParams {
  final String channelName;
  final int channelIdx;
  final double freqMHz, bwKHz;
  final int sf, cr;
  final String scope, path;
  OtaBuildParams({
    required this.channelName,
    required this.channelIdx,
    required this.freqMHz,
    required this.bwKHz,
    required this.sf,
    required this.cr,
    this.scope = 'zerohop',
    this.path = '',
  });
}

Uint8List _u32le(int v) =>
    Uint8List(4)..buffer.asByteData().setUint32(0, v, Endian.little);

/// raw inplace diff -> raw DEFLATE (512-byte window) -> staged ZLIB blob,
/// byte-layout-compatible with ota_sender.py::make_patch.
Uint8List buildStagedPatch(Uint8List oldFw, Uint8List newFw) {
  final raw = createInplaceLiteDiff(oldFw, newFw);
  // raw DEFLATE, 512-byte window (windowBits 9) to match the device puff_stream.
  final deflate = const ZLibEncoder().encode(raw, level: 9, raw: true, windowBits: 9);
  final b = BytesBuilder()
    ..add(ascii.encode('ZLIB'))
    ..add(_u32le(raw.length))
    ..add(_u32le(newFw.length))
    ..add(deflate);
  return b.toBytes();
}

String buildOtaPkgJson(
    {required Uint8List oldFw, required Uint8List newFw, required OtaBuildParams p}) {
  // self-check: never emit a silently-wrong package
  final raw = createInplaceLiteDiff(oldFw, newFw);
  final applied = applyInplaceLiteDiff(raw, oldFw);
  if (applied.length != newFw.length) {
    throw OtaBuildException('self-check failed: length ${applied.length} != ${newFw.length}');
  }
  for (var i = 0; i < newFw.length; i++) {
    if (applied[i] != newFw[i]) {
      throw OtaBuildException('self-check failed at byte $i');
    }
  }
  final staged = buildStagedPatch(oldFw, newFw);
  final pkg = {
    'format': 'mc-fotanrf-otapkg/1',
    'created': '1970-01-01T00:00:00Z',
    'channel': {'name': p.channelName, 'idx': p.channelIdx},
    'radio': {'freq': p.freqMHz, 'bw': p.bwKHz, 'sf': p.sf, 'cr': p.cr},
    'scope': p.scope,
    'path': p.path,
    'fw': {
      'old_sha256': _hex(c.sha256.convert(oldFw).bytes),
      'new_sha256': _hex(c.sha256.convert(newFw).bytes),
      'old_fw_size': oldFw.length,
      'patch_sha256': _hex(c.sha256.convert(staged).bytes),
      'patch_len': staged.length,
    },
    'patch_b64': base64.encode(staged),
  };
  return const JsonEncoder.withIndent('  ').convert(pkg);
}

String _hex(List<int> bytes) =>
    bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
```

- [ ] **Step 4: Run the builder test, then the whole OTA suite + analyze**

Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; flutter pub get; flutter test test/ota/ota_pkg_builder_test.dart`
Expected: PASS (2 tests).

Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; flutter test test/ota`
Expected: PASS (all OTA tests).

Run: `$env:Path = "D:\FkDev\Tools\flutter\bin;" + $env:Path; flutter analyze lib`
Expected: `No issues found!`

> If `ZLibEncoder().encode(..., windowBits: 9)` is rejected by the installed `archive` API, fall back to the documented signature for that version (e.g. construct `ZLibEncoder()` and call `encodeBytes`, or use `Deflate(raw, level: 9)` and confirm via the Step-1-style decode test that a 512-window inflater round-trips it). The binding requirement is: raw DEFLATE whose back-references stay within 512 bytes; the round-trip test in Step 1 is the gate.

- [ ] **Step 5: Commit**

```bash
git add lib/ota/ota_pkg_builder.dart pubspec.yaml test/ota/ota_pkg_builder_test.dart
git commit -m "feat(fotanrf): app-side OTA package builder (DEFLATE-512 + staged ZLIB + .otapkg.json)"
```

---

## Self-Review

- **Spec coverage:** §2 pure-Dart rationale → whole plan. §3 format → Tasks 2–4 (constants in Global Constraints, verbatim). §4 reusable library vs app split → package (Tasks 1–4) vs `ota_pkg_builder.dart` (Task 5); zero-dep library honored (crypto/test are dev-only; `archive` lives in the app). §6 verification → Task 3 (applier vs hdiffi golden), Task 4 (encoder round-trip + in-place safety sim), Task 5 (builder self-check + 512-window decode). §7 file table → matches created files. §11 open question on the 512-window DEFLATE API → flagged inline in Task 5 Step 4 with the binding requirement + fallback. On-device verification (§6.5) and the download/wire half are **Plan 2b**, out of this plan.
- **Placeholder scan:** none — every code step is complete and runnable; the Task-5 note is a concrete API-fallback instruction with a named gate, not a TODO.
- **Type consistency:** `ByteReader`, `readVarint`, `writeVarint`, `encodeInplaceHeader`, `readInplaceHeader`, `applyInplaceLiteDiff`, `createInplaceLiteDiff`, `buildStagedPatch`, `buildOtaPkgJson`, `OtaBuildParams` are used with identical signatures across tasks. `extraSafeSize` semantics (max newPos-oldPos) are consistent between encoder (Task 4) and the safety sim (Task 4 test).

## Out of scope (Plan 2b)

Source abstraction (`OtaFwSource` + selectable/custom repo), asset download (`.zip`→bin, CORS fallback), wiring `Create FOTA package` into the screen/slot, and on-device `ota verify`/`ota flash`.
