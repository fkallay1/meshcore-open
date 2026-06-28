# FOTA Selection + APPLY + Cancel Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a per-send selection (specific chunks + H/S), a standalone APPLY button, and a cancel-while-sending control to the FOTA sender screen.

**Architecture:** A pure parser (`parseFotaSelection`) turns a space-separated text list (tolerant of the firmware's `fota miss` CLI output) into a `FotaSelection`. `FotaSender` gains an optional `selection` in its config and a `cancel()` method; when a selection is present it sends only the chosen chunks/META/SIG/APPLY. The screen adds a selection dialog, a third APPLY button (with reboot confirmation), and a cancel button shown while busy.

**Tech Stack:** Dart / Flutter, `flutter_test`, existing `lib/fota/` module (Provider for state, `file_selector`, `crypto`/`pinenacl` already wired).

## Global Constraints

- App identity UNCHANGED: `name: meshcore_open`, title `MeshCore Open`.
- All FOTA logic stays under `lib/fota/{models,services,screens,helpers}`; tests mirror under `test/fota/{models,services,screens}`.
- Every new file is `fota_*`-named.
- Wire protocol is UNCHANGED — only the composition/order of what is sent changes.
- No new dependencies. No ARB/l10n changes (FOTA module uses literal strings).
- Touch upstream files only as already permitted; this plan touches NO upstream file.
- Portable Flutter SDK: run via `D:\FkDev\Tools\flutter\bin` (session activation: `. "$env:DEV_ROOT\Tools\flutter-env.ps1"`). Use `flutter test test/fota` and `flutter analyze lib test/fota`.
- Constant in scope: `kFotaChunkData = 144`; `total = (patchLen / kFotaChunkData).ceil()`.
- Pre-existing acceptable warnings: 2 `unnecessary_non_null_assertion` in `fota_asset_download_test.dart` (not from this work).
- Autonomous commits on `feature/nrf-fota-sender`; Co-Author trailer `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`.

---

### Task 1: `FotaSelection` model + `parseFotaSelection` parser

**Files:**
- Modify: `lib/fota/models/fota_types.dart` (append at end)
- Test: `test/fota/models/fota_selection_test.dart` (create)

**Interfaces:**
- Consumes: nothing (pure Dart).
- Produces:
  - `class FotaSelection { final List<int> chunks; final bool meta; final bool sig; final int? reportedTotal; const FotaSelection(this.chunks, {required this.meta, required this.sig, this.reportedTotal}); }`
  - `FotaSelection parseFotaSelection(String input, {required int totalChunks})` — `chunks` sorted ascending, de-duplicated. Throws `FormatException` on unknown token, malformed range, out-of-range chunk, or empty selection (no chunk and neither H nor S).

- [ ] **Step 1: Write the failing test**

Create `test/fota/models/fota_selection_test.dart`:

```dart
import 'package:flutter_test/flutter_test.dart';
import 'package:meshcore_open/fota/models/fota_types.dart';

void main() {
  group('parseFotaSelection', () {
    test('single numbers and ranges, sorted & deduped', () {
      final s = parseFotaSelection('0 5 7-12 5', totalChunks: 41);
      expect(s.chunks, [0, 5, 7, 8, 9, 10, 11, 12]);
      expect(s.meta, false);
      expect(s.sig, false);
      expect(s.reportedTotal, isNull);
    });

    test('H and S, case-insensitive', () {
      final s = parseFotaSelection('h  S', totalChunks: 41);
      expect(s.chunks, isEmpty);
      expect(s.meta, true);
      expect(s.sig, true);
    });

    test('descending range normalizes', () {
      expect(parseFotaSelection('12-7', totalChunks: 41).chunks,
          [7, 8, 9, 10, 11, 12]);
    });

    test('tolerates full CLI miss line + extracts reportedTotal', () {
      final s = parseFotaSelection('FOTA miss=2/33: 12 29', totalChunks: 33);
      expect(s.chunks, [12, 29]);
      expect(s.meta, false);
      expect(s.sig, false);
      expect(s.reportedTotal, 33);
    });

    test('tolerates missall line with H S and +N overflow', () {
      final s = parseFotaSelection(
          'FOTA missall=14/41: H S 3 7 19-22 +5',
          totalChunks: 41);
      expect(s.chunks, [3, 7, 19, 20, 21, 22]);
      expect(s.meta, true);
      expect(s.sig, true);
      expect(s.reportedTotal, 41);
    });

    test('plain list has null reportedTotal', () {
      expect(parseFotaSelection('12 29', totalChunks: 41).reportedTotal, isNull);
    });

    test('chunk out of range throws', () {
      expect(() => parseFotaSelection('99', totalChunks: 41),
          throwsFormatException);
    });

    test('empty selection throws', () {
      expect(() => parseFotaSelection('   ', totalChunks: 41),
          throwsFormatException);
      expect(() => parseFotaSelection('FOTA miss=0/41:', totalChunks: 41),
          throwsFormatException);
    });

    test('unknown token throws', () {
      expect(() => parseFotaSelection('12 x', totalChunks: 41),
          throwsFormatException);
    });

    test('range endpoint out of range throws', () {
      expect(() => parseFotaSelection('38-45', totalChunks: 41),
          throwsFormatException);
    });
  });
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/fota/models/fota_selection_test.dart`
Expected: FAIL — `parseFotaSelection`/`FotaSelection` not defined (compile error).

- [ ] **Step 3: Write minimal implementation**

Append to `lib/fota/models/fota_types.dart`:

```dart
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

  for (var raw in input.split(RegExp(r'\s+'))) {
    final tok = raw.replaceAll(':', '').trim();
    if (tok.isEmpty) continue;
    final low = tok.toLowerCase();

    if (low == 'h') { meta = true; continue; }
    if (low == 's') { sig = true; continue; }
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
      for (var i = lo; i <= hi; i++) addChunk(i);
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
  return FotaSelection(sorted, meta: meta, sig: sig, reportedTotal: reportedTotal);
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `flutter test test/fota/models/fota_selection_test.dart`
Expected: PASS (all 10 tests).

- [ ] **Step 5: Commit**

```bash
git add lib/fota/models/fota_types.dart test/fota/models/fota_selection_test.dart
git commit -m "feat(fotanrf): FotaSelection + parseFotaSelection (tolerant of fota miss CLI)"
```

---

### Task 2: `FotaSender` — selection-aware send + `cancel()`

**Files:**
- Modify: `lib/fota/services/fota_sender.dart`
- Test: `test/fota/services/fota_sender_test.dart` (extend existing)

**Interfaces:**
- Consumes: `FotaSelection` (Task 1), existing `FotaJob`, `FotaPayloadBuilder`, `FotaFrameSink`.
- Produces:
  - `FotaSendConfig` gains `final FotaSelection? selection;` (default `null`, last named param).
  - `class FotaCancelled implements Exception {}` (exported from `fota_sender.dart`).
  - `FotaSender` gains `void cancel();` — after it is called, the next packet send throws `FotaCancelled` instead of sending.
  - Behavior: `selection == null` → unchanged (all chunks, header, optional APPLY, with `headerEvery`/`cycles`). `selection != null` → per cycle: send only `selection.chunks` (ascending) → if `meta` send META → if `sig` send SIG → if `applyAfter` send APPLY. `headerEvery` ignored in selection mode; `cycles` respected.

- [ ] **Step 1: Read the existing test file to match style**

Run: `flutter test test/fota/services/fota_sender_test.dart` (confirm current state green) and open it to find the existing fake `FotaFrameSink` and how payload types are asserted (first byte: META=0x10, CHUNK=0x11, APPLY=0x12, SIG=0x13; chunk index is bytes 1-2 LE after the 0x11 type, inside the ts-prefixed data payload — i.e. payload starts at data[4]).

- [ ] **Step 2: Write the failing tests**

Append these tests to `test/fota/services/fota_sender_test.dart` (reuse the file's existing fake sink + job/config builders; the snippet below assumes a recording fake `sink.sent` list of `Uint8List` frames and helpers — adapt names to the file). If the file has no reusable helper to read the payload type, add this local helper inside the test file:

```dart
// payload type byte = frame data after [62][chanIdx][pathLen][path][magic 2B][ts 4B]
// For the standard zerohop frame (pathLen=0, no path): header is
// [62][idx][0x00][0xA0 0x07] then data=[ts 4B][payload...]; payload type is the
// byte right after the 4-byte ts. Compute its offset from the frame end-relative
// layout already used by existing tests; if existing tests expose a decoder, use it.
```

Tests to add:

```dart
test('selection: only listed chunks, no header/apply', () async {
  final sink = FakeSink();
  await FotaSender(sink).send(
    job, // existing test job with >=6 chunks
    baseConfig(selection: FotaSelection([0, 2], meta: false, sig: false)),
  );
  final types = sink.payloadTypes(); // helper returning list of payload type bytes
  expect(types, [0x11, 0x11]); // two chunks only
  expect(sink.chunkIndices(), [0, 2]);
});

test('selection: chunks then META then SIG', () async {
  final sink = FakeSink();
  await FotaSender(sink).send(
    job,
    baseConfig(selection: FotaSelection([1], meta: true, sig: true)),
  );
  expect(sink.payloadTypes(), [0x11, 0x10, 0x13]); // chunk, META, SIG
});

test('selection: applyAfter sends APPLY last', () async {
  final sink = FakeSink();
  await FotaSender(sink).send(
    job,
    baseConfig(
        selection: FotaSelection([1], meta: false, sig: false),
        applyAfter: true),
  );
  expect(sink.payloadTypes(), [0x11, 0x12]); // chunk, APPLY
});

test('selection: cycles=2 repeats set, headerEvery ignored', () async {
  final sink = FakeSink();
  await FotaSender(sink).send(
    job,
    baseConfig(
        selection: FotaSelection([0], meta: true, sig: false),
        cycles: 2,
        headerEvery: 1),
  );
  // each cycle: chunk(0x11) + META(0x10); headerEvery adds nothing in selection mode
  expect(sink.payloadTypes(), [0x11, 0x10, 0x11, 0x10]);
});

test('apply-only selection sends exactly one APPLY', () async {
  final sink = FakeSink();
  await FotaSender(sink).send(
    job,
    baseConfig(
        selection: FotaSelection(const [], meta: false, sig: false),
        applyAfter: true),
  );
  expect(sink.payloadTypes(), [0x12]);
});

test('cancel after first packet throws FotaCancelled, stops sending', () async {
  final sink = FakeSink();
  final sender = FotaSender(sink);
  sink.onSent = (count) { if (count == 1) sender.cancel(); };
  await expectLater(
    sender.send(job, baseConfig(selection: FotaSelection([0, 1, 2], meta: false, sig: false))),
    throwsA(isA<FotaCancelled>()),
  );
  expect(sink.sent.length, 1); // only the first packet went out
});
```

If `FakeSink` in the file lacks `onSent`/`payloadTypes`/`chunkIndices`/`sent`, add the minimal versions needed (a `List<Uint8List> sent`, an `onSent` callback fired in `sendFrame`, and decoders that strip the `[62][idx][pathLen]...[magic][ts4]` prefix to read the payload type and chunk index). Keep `null`-selection regression: ensure at least one existing test still asserts full-send behavior.

- [ ] **Step 3: Run tests to verify they fail**

Run: `flutter test test/fota/services/fota_sender_test.dart`
Expected: FAIL — `FotaSendConfig` has no `selection`, `FotaSender` has no `cancel`, `FotaCancelled` undefined.

- [ ] **Step 4: Implement**

In `lib/fota/services/fota_sender.dart`:

1. Add the exception near the top (after imports):

```dart
class FotaCancelled implements Exception {
  @override
  String toString() => 'FotaCancelled';
}
```

2. Add the field to `FotaSendConfig` (new last named param, keep others unchanged):

```dart
  final FotaSelection? selection;
```
and in the constructor parameter list add `this.selection,`.

3. In `FotaSender`, add cancellation state + method:

```dart
  bool _cancelled = false;
  void cancel() => _cancelled = true;
```

4. In `send`, make `snd` cancellation-aware — at the very top of `snd`, before `ts += 1`:

```dart
      if (_cancelled) throw FotaCancelled();
```

5. Replace the chunk/header/apply body inside the `for (cycle)` loop with a branch on `cfg.selection`:

```dart
    for (int cycle = 0; cycle < cycles; cycle++) {
      if (cfg.selection == null) {
        // ── full send (unchanged behavior) ──
        for (int i = 0; i < total; i++) {
          final start = i * kFotaChunkData;
          final end = (start + kFotaChunkData).clamp(0, patch.length);
          await snd(_b.buildChunk(
              i, Uint8List.sublistView(patch, start, end), job.oldFwSize, oldPrefix));
          doneChunks++;
          onProgress?.call(FotaProgress(FotaPhase.chunks, doneChunks, grandTotal));
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
      } else {
        // ── selection send: only chosen chunks, then H, then S, then APPLY ──
        final sel = cfg.selection!;
        for (final i in sel.chunks) {
          final start = i * kFotaChunkData;
          final end = (start + kFotaChunkData).clamp(0, patch.length);
          await snd(_b.buildChunk(
              i, Uint8List.sublistView(patch, start, end), job.oldFwSize, oldPrefix));
          doneChunks++;
          onProgress?.call(FotaProgress(FotaPhase.chunks, doneChunks, grandTotal));
        }
        if (sel.meta) {
          onProgress?.call(FotaProgress(FotaPhase.header, doneChunks, grandTotal));
          await snd(meta);
        }
        if (sel.sig) await snd(sig);
        if (cfg.applyAfter) {
          onProgress?.call(FotaProgress(FotaPhase.apply, doneChunks, grandTotal));
          await snd(_b.buildApply(patchSha));
        }
      }

      if (cycle < cycles - 1 && cfg.cycleDelayMs > 0) {
        await Future.delayed(Duration(milliseconds: cfg.cycleDelayMs));
      }
    }
```

6. Fix `grandTotal` to account for selection (place where `total` and `grandTotal` are computed):

```dart
    final perCycle = cfg.selection == null
        ? total
        : cfg.selection!.chunks.length +
            (cfg.selection!.meta ? 1 : 0) +
            (cfg.selection!.sig ? 1 : 0);
    final grandTotal = perCycle * cycles;
```

(Keep `total` as the full chunk count — still needed by the full-send branch and by `buildChunk` slicing.)

7. Add the import if not present: `import '../models/fota_types.dart';` (already imported — it defines `FotaScope`; `FotaSelection` lives in the same file, so no new import).

- [ ] **Step 5: Run tests to verify they pass**

Run: `flutter test test/fota/services/fota_sender_test.dart`
Expected: PASS (new + all pre-existing tests).

- [ ] **Step 6: Commit**

```bash
git add lib/fota/services/fota_sender.dart test/fota/services/fota_sender_test.dart
git commit -m "feat(fotanrf): selection-aware send + cancel() in FotaSender"
```

---

### Task 3: Screen — selection dialog, APPLY button, cancel UI

**Files:**
- Modify: `lib/fota/screens/fota_screen.dart`
- Test: `test/fota/screens/fota_screen_smoke_test.dart` (extend existing)

**Interfaces:**
- Consumes: `parseFotaSelection`, `FotaSelection`, `FotaCancelled` (Tasks 1-2), existing `FotaSender`, `FotaSendConfig`, `_ConnectorFotaSink`.
- Produces: UI only (no exported API).

- [ ] **Step 1: Write the failing widget test**

Append to `test/fota/screens/fota_screen_smoke_test.dart` (reuse the file's existing pump helper that wraps `FotaScreen` in the required Providers):

```dart
testWidgets('selection button defaults to All and three send buttons exist',
    (tester) async {
  await pumpFotaScreen(tester); // existing helper
  expect(find.text('Výber na odoslanie: All'), findsOneWidget);
  // Send buttons only render once a package is loaded in the real screen;
  // this smoke test asserts the selection toggle button is present in the
  // initial (no-package) state alongside the existing controls.
});
```

If the existing smoke test only renders the no-package state (no `_pkg`), keep this assertion limited to `'Výber na odoslanie: All'`. Do NOT assert send-button text here if the existing test confirms they are gated behind a loaded package — instead leave a comment and rely on Task 2 for send-logic coverage.

- [ ] **Step 2: Run test to verify it fails**

Run: `flutter test test/fota/screens/fota_screen_smoke_test.dart`
Expected: FAIL — `'Výber na odoslanie: All'` not found.

- [ ] **Step 3: Implement screen changes**

In `lib/fota/screens/fota_screen.dart`:

(a) Add state fields to `_FotaScreenState`:

```dart
  bool _selectionMode = false; // false = All, true = Selection
  final _selectionController = TextEditingController();
  FotaSender? _activeSender; // non-null while a send is running (for cancel)
```

(b) Dispose the controller in `dispose()` (add line next to the others):

```dart
    _selectionController.dispose();
```

(c) Add the selection dialog method:

```dart
  Future<void> _openSelectionDialog() async {
    final total = _pkg == null
        ? 0
        : (_pkg!.patchLen / kFotaChunkData).ceil();
    bool mode = _selectionMode;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Výber na odoslanie'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<bool>(
                value: false,
                groupValue: mode,
                onChanged: (v) => setLocal(() => mode = v ?? false),
                title: const Text('Všetko (Select All)'),
                contentPadding: EdgeInsets.zero,
              ),
              RadioListTile<bool>(
                value: true,
                groupValue: mode,
                onChanged: (v) => setLocal(() => mode = v ?? true),
                title: const Text('Len výber nižšie (Only Selection below)'),
                contentPadding: EdgeInsets.zero,
              ),
              TextField(
                controller: _selectionController,
                maxLines: 2,
                decoration: InputDecoration(
                  labelText: 'Zoznam (chunky + H + S)',
                  helperText: total > 0
                      ? 'napr. 0 5 7-12 H S — balík má $total chunkov: 0..${total - 1}'
                      : 'napr. 0 5 7-12 H S',
                  helperMaxLines: 2,
                  border: const OutlineInputBorder(),
                  isDense: true,
                ),
              ),
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Zrušiť')),
            ElevatedButton(
              onPressed: () {
                setState(() => _selectionMode = mode);
                Navigator.pop(ctx);
              },
              child: const Text('Potvrdiť'),
            ),
          ],
        ),
      ),
    );
  }
```

(d) Add APPLY confirmation + apply-only send:

```dart
  Future<bool> _confirmApply() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Poslať APPLY?'),
        content: const Text('Repeater po APPLY nahrá patch a reštartuje sa.'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('Zrušiť')),
          ElevatedButton(
              style: ElevatedButton.styleFrom(backgroundColor: Colors.deepOrange),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('APPLY')),
        ],
      ),
    );
    return ok ?? false;
  }
```

(e) In `_send`, parse selection and wire cancel. Replace the body that builds/sends with selection handling. Near the top of `_send` (after the `_pkg`/connection guards, before building the config):

```dart
    FotaSelection? sel;
    if (_selectionMode) {
      final total = (pkg.patchLen / kFotaChunkData).ceil();
      try {
        sel = parseFotaSelection(_selectionController.text, totalChunks: total);
      } on FormatException catch (e) {
        _append('ERROR: ${e.message}');
        return;
      }
      if (sel.reportedTotal != null && sel.reportedTotal != total) {
        _append('POZOR: repeater hlási total=${sel.reportedTotal}, '
            'balík má $total — iná session?');
      }
    }
```

Then change the sender construction to store the active sender and pass `selection: sel`, and catch `FotaCancelled`:

```dart
      final sender = FotaSender(_ConnectorFotaSink(c));
      _activeSender = sender;
      await sender.send(
        pkg.toJob(),
        FotaSendConfig(
          // ... all existing fields unchanged ...
          selection: sel,
        ),
        onProgress: (p) => setState(() {
          _progress = p.total == 0 ? 0 : (p.sent / p.total).clamp(0.0, 1.0);
        }),
      );
      _append(apply ? 'Done — APPLY sent (repeater will reboot).' : 'Done — all packets sent.');
    } on FotaCancelled {
      _append('Zrušené.');
    } catch (e) {
      _append('ERROR: $e');
    } finally {
      _activeSender = null;
      setState(() => _busy = false);
    }
```

(Keep the existing `setState({_busy=true; _progress=0;})` at the start of the try.)

(f) Add the apply-only handler (uses an empty selection so it routes through the sender):

```dart
  Future<void> _sendApplyOnly() async {
    if (_pkg == null) return;
    if (!await _confirmApply()) return;
    _selectionApplyOnly = true;
    await _send(apply: true, applyOnlyOverride: true);
    _selectionApplyOnly = false;
  }
```

Simpler: instead of extra flags, give `_send` an optional override. Change `_send` signature to:

```dart
  Future<void> _send({required bool apply, FotaSelection? selectionOverride}) async {
```

and where `sel` is computed, prefer the override:

```dart
    FotaSelection? sel = selectionOverride;
    if (sel == null && _selectionMode) {
      // ... existing parse block ...
    }
```

Then `_sendApplyOnly` becomes:

```dart
  Future<void> _sendApplyOnly() async {
    if (_pkg == null) return;
    if (!await _confirmApply()) return;
    await _send(
        apply: true,
        selectionOverride:
            const FotaSelection([], meta: false, sig: false));
  }
```

And make the existing "Odoslať + APPLY" button call `_confirmApply` first:

```dart
                  onPressed: _busy
                      ? null
                      : () async {
                          if (await _confirmApply()) _send(apply: true);
                        },
```

(g) Add the selection toggle button above the send-button row (inside the `if (pkg != null)` ListView, just before the `Row` with the send buttons):

```dart
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _openSelectionDialog,
                    icon: const Icon(Icons.checklist),
                    label: Text(_selectionMode
                        ? 'Výber na odoslanie: Selection'
                        : 'Výber na odoslanie: All'),
                  ),
                ),
                const SizedBox(height: 8),
```

(h) Replace the two-button send `Row` with three buttons:

```dart
                Row(children: [
                  Expanded(
                      child: ElevatedButton(
                          onPressed: _busy ? null : () => _send(apply: false),
                          child: const Text('Odoslať patch'))),
                  const SizedBox(width: 8),
                  Expanded(
                      child: ElevatedButton(
                          onPressed: _busy ? null : _sendApplyOnly,
                          style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.orange),
                          child: const Text('APPLY'))),
                  const SizedBox(width: 8),
                  Expanded(
                      child: ElevatedButton(
                          onPressed: _busy
                              ? null
                              : () async {
                                  if (await _confirmApply()) _send(apply: true);
                                },
                          style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.deepOrange),
                          child: const Text('Odoslať + APPLY'))),
                ]),
```

(i) Add the cancel button next to the progress indicator (replace the `if (_busy) LinearProgressIndicator(...)` block):

```dart
          if (_busy) ...[
            Row(children: [
              Expanded(child: LinearProgressIndicator(value: _progress)),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => _activeSender?.cancel(),
                child: const Text('Zrušiť odosielanie'),
              ),
            ]),
          ],
```

Note: the selection toggle button shows `Výper...` only when a package is loaded; if the smoke test renders the no-package state, also add the toggle button OUTSIDE the `if (pkg != null)` block — but per spec it belongs with the send controls. To satisfy the smoke test in the no-package state, instead place the selection toggle button just above the package `if` so it is always visible once the screen builds. Final decision: place the selection toggle button right after the "Vyber .fotapkg.json" button (always visible), so the smoke test finds it without a loaded package. Disable it (`onPressed: null`) when `_pkg == null` is acceptable, but keep the label visible.

- [ ] **Step 4: Run tests to verify they pass**

Run: `flutter test test/fota/screens/fota_screen_smoke_test.dart`
Expected: PASS.

- [ ] **Step 5: Full module test + analyze**

Run: `flutter test test/fota`
Expected: PASS (all FOTA tests).
Run: `flutter analyze lib test/fota`
Expected: No new issues (only the 2 known `unnecessary_non_null_assertion` warnings in `fota_asset_download_test.dart`).

- [ ] **Step 6: Commit**

```bash
git add lib/fota/screens/fota_screen.dart test/fota/screens/fota_screen_smoke_test.dart
git commit -m "feat(fotanrf): selection dialog + APPLY button + cancel UI on FOTA screen"
```

---

### Task 4: Work-log + spec status update

**Files:**
- Modify: `fkclaude/fcl_readme_nrf-fota-flutterapp.md` (prepend a dated entry under the work-log section)

**Interfaces:** none (docs).

- [ ] **Step 1: Append work-log entry**

Add a `2026-06-28` entry to the work-log in `fkclaude/fcl_readme_nrf-fota-flutterapp.md` summarizing: Selection (chunks+H/S, tolerant of `fota miss` CLI), APPLY-only button (with reboot confirmation), cancel-while-sending; note Úloha B (repeater-aware: auto Direct path + Get missing Chunks) is deferred to its own spec/plan; record verification (`flutter test test/fota`, `flutter analyze lib test/fota`).

- [ ] **Step 2: Commit**

```bash
git add fkclaude/fcl_readme_nrf-fota-flutterapp.md
git commit -m "docs(fotanrf): work-log — selection + APPLY + cancel done"
```

---

## Self-Review

**Spec coverage:**
- §2 parser → Task 1 (incl. CLI-noise tolerance + reportedTotal). ✓
- §3.1 selection send → Task 2 steps 4.5-4.6. ✓
- §3.2 cancel → Task 2 (FotaCancelled + cancel()). ✓
- §3.3 / §4.3 APPLY-only via empty selection → Task 3 (f). ✓
- §4.1 state fields → Task 3 (a). ✓
- §4.2 selection dialog → Task 3 (c). ✓
- §4.3 three buttons + reboot confirm → Task 3 (d,h). ✓
- §4.4 parse on send + reportedTotal warning → Task 3 (e). ✓
- §4.5 cancel UI → Task 3 (i). ✓
- §5 tests → Tasks 1-3 test steps. ✓
- §6 touched files → Tasks 1-3 + work-log Task 4. ✓

**Placeholder scan:** Task 3 step 1/3 deliberately defers exact send-button assertions to the existing smoke helper's capabilities (the screen gates send buttons behind a loaded `_pkg`); the toggle-button placement is resolved explicitly in step 3 note (place after "Vyber .fotapkg.json", always visible). No `TODO`/`TBD` left.

**Type consistency:** `FotaSelection(this.chunks, {required this.meta, required this.sig, this.reportedTotal})` used identically in Tasks 1-3. `parseFotaSelection(String, {required int totalChunks})`, `FotaCancelled`, `FotaSender.cancel()`, `FotaSendConfig.selection` consistent across tasks. `kFotaChunkData` used for `total`. Payload type bytes (0x10/0x11/0x12/0x13) match `fota_types.dart` constants.

**Open implementation note for executor:** the exact `FakeSink` helper names in Task 2 (`payloadTypes`, `chunkIndices`, `onSent`, `sent`) must be reconciled with the existing `fota_sender_test.dart` fake; adapt to whatever the file already defines rather than forcing these names.
