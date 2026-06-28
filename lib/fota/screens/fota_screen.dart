import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../../connector/meshcore_connector.dart';
import '../../connector/meshcore_protocol.dart';
import '../helpers/fota_browser_download.dart';
import '../services/fota_asset_download.dart';
import '../services/fota_pkg_builder.dart';
import '../services/fota_sender.dart';
import '../models/fota_types.dart';
import '../services/fota_github_source.dart';
import '../models/fotapkg.dart';
import '../services/fota_key_store.dart';
import 'fota_fw_picker.dart';

class _ConnectorFotaSink implements FotaFrameSink {
  final MeshCoreConnector c;
  _ConnectorFotaSink(this.c);
  // Count only FOTA payload packets (META/SIG/chunk/APPLY go through sendFrame);
  // setChannel/setFloodScope call c.sendFrame directly and are not counted.
  int sent = 0;
  @override
  Future<void> sendFrame(Uint8List frame) {
    sent++;
    return c.sendFrame(frame);
  }
  @override
  Future<void> setRadio(int freqVal, int bwVal, int sf, int cr) =>
      c.sendFrame(buildSetRadioParamsFrame(freqVal, bwVal, sf, cr));
  @override
  Future<void> setChannel(int idx, String name, Uint8List psk) =>
      c.sendFrame(buildSetChannelFrame(idx, name, psk));
  @override
  Future<void> setFloodScope(Uint8List? key16) {
    if (key16 != null) {
      return c.sendFrame(buildSetFloodScopeKeyFrame(key16));
    }
    // Clear: ver 12+ supports an explicit "force unscoped" that ignores the
    // companion's default scope; older firmware only resets the override.
    return c.sendFrame((c.firmwareVerCode ?? 0) >= 12
        ? buildSetFloodScopeUnscopedFrame()
        : buildSetFloodScopeFrame(''));
  }
}

/// Reusable FOTA sender screen. The only difference between launching it from a
/// repeater admin hub and from the global FOTA Broadcast settings entry is the
/// header target ([headerTarget]); the whole send flow below is shared.
///
/// FOTA is a channel GRP_DATA broadcast — it needs no repeater login, so this
/// screen can run without being connected/authenticated to any repeater.
class FotaScreen extends StatefulWidget {
  /// Shown in the app-bar as "FOTA → [headerTarget]" (repeater name or "Broadcast").
  final String headerTarget;
  const FotaScreen({super.key, required this.headerTarget});
  @override
  State<FotaScreen> createState() => _FotaScreenState();
}

class _FotaScreenState extends State<FotaScreen> {
  FotaPkg? _pkg;
  String? _pkgLabel; // názov načítaného balíka (zobrazený na tlačidle výberu)
  FotaFwSelection? _fwSelection;
  String _log = '';
  double _progress = 0;
  bool _busy = false;

  // Send-mode / timing options (mirror fota_sender.py CLI flags).
  FotaScope _scope = FotaScope.zerohop; // --scope (ZeroHop default)
  final _pathController = TextEditingController(); // --path (scope=direct)
  int _pathHashSize = 1; // --path-hashsize (scope=direct: 1/2/3 B per hop)
  final _regionController = TextEditingController(); // --scope-name / --scope-key
  bool _regionAsKey = false; // false = #názov, true = 16B hex kľúč
  final _delayController = TextEditingController(text: '3000'); // --delay [ms]
  final _cyclesController = TextEditingController(text: '1'); // --cycles
  final _headerEveryController = TextEditingController(text: '0'); // --header-every

  // Selection: false = send All (today's behavior), true = only the list below.
  bool _selectionMode = false;
  final _selectionController = TextEditingController();
  FotaSender? _activeSender; // non-null while a send runs (for cancel)

  @override
  void dispose() {
    _pathController.dispose();
    _regionController.dispose();
    _delayController.dispose();
    _cyclesController.dispose();
    _headerEveryController.dispose();
    _selectionController.dispose();
    super.dispose();
  }

  void _append(String s) => setState(() => _log = '$_log$s\n');

  int _intField(TextEditingController c, int fallback, {int min = 0}) {
    final v = int.tryParse(c.text.trim());
    if (v == null || v < min) return fallback;
    return v;
  }

  FotaBuildParams _buildParams() => FotaBuildParams(
        channelName: '#fkotanrf',
        channelIdx: 1,
        freqMHz: 869.618,
        bwKHz: 62.5,
        sf: 8,
        cr: 5,
        scope: _scope.name,
        path: _pathController.text.trim(),
        pathHashSize: _pathHashSize,
        scopeName: _regionAsKey ? '' : _regionController.text.trim(),
        scopeKey: _regionAsKey ? _regionController.text.trim() : '',
      );

  Future<void> _loadGeneratedPkg(Uint8List oldFw, Uint8List newFw, String label) async {
    _append('Generujem patch ($label)…');
    final json = buildFotaPkgJson(oldFw: oldFw, newFw: newFw, p: _buildParams());
    final pkg = FotaPkg.fromJsonString(json);
    setState(() {
      _pkg = pkg;
      _pkgLabel = label;
      _resetSelection();
      _adoptPkgScope(pkg);
    });
    _append('Hotovo: patch=${pkg.patchLen}B '
        'chunkov=${(pkg.patchLen / kFotaChunkData).ceil()}');
  }

  Future<void> _createFromGithub() async {
    final sel = _fwSelection;
    if (sel == null) return;
    final cur = sel.currentAsset, tgt = sel.targetAsset;
    if (cur == null || tgt == null) {
      _append('ERROR: chýba asset pre current alebo target.');
      return;
    }
    setState(() => _busy = true);
    try {
      _append('Sťahujem current: ${cur.name}…');
      final oldFw = await downloadFirmwareBin(cur.downloadUrl);
      _append('Sťahujem target: ${tgt.name}…');
      final newFw = await downloadFirmwareBin(tgt.downloadUrl);
      await _loadGeneratedPkg(oldFw, newFw, sel.packageFileName);
    } catch (e) {
      _append('ERROR: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  // WEB: trigger the browser to download the exact current+target assets (a
  // navigation/download, not a fetch, so no CORS). The user then picks the two
  // downloaded files with "Create FOTA package".
  void _downloadFwViaBrowser() {
    final sel = _fwSelection;
    final cur = sel?.currentAsset, tgt = sel?.targetAsset;
    if (cur == null || tgt == null) {
      _append('ERROR: chýba asset pre current alebo target.');
      return;
    }
    triggerBrowserDownload(cur.downloadUrl, cur.name);
    triggerBrowserDownload(tgt.downloadUrl, tgt.name);
    _append('Sťahujem v prehliadači: ${cur.name} + ${tgt.name}.\n'
        'Potom daj „Create FOTA package" a vyber tie dva stiahnuté súbory.');
  }

  // WEB create: the GitHub binary host has no CORS, so instead of fetching we
  // pick the two browser-downloaded files and match them to current/target by
  // their (real) asset names.
  Future<void> _createFromPickedFiles() async {
    final sel = _fwSelection;
    if (sel == null) return;
    final cur = sel.currentAsset, tgt = sel.targetAsset;
    if (cur == null || tgt == null) {
      _append('ERROR: chýba asset pre current alebo target.');
      return;
    }
    const group = XTypeGroup(label: 'firmware', extensions: ['bin', 'zip']);
    _append('Vyber 2 stiahnuté súbory: ${cur.name} + ${tgt.name}');
    final files = await openFiles(acceptedTypeGroups: [group]);
    if (files.isEmpty) return;
    XFile? pick(String assetName, String version) {
      for (final f in files) {
        if (f.name == assetName) return f;
      }
      for (final f in files) {
        if (f.name.contains(version)) return f;
      }
      return null;
    }

    final oldF = pick(cur.name, sel.currentVersion);
    final newF = pick(tgt.name, sel.targetVersion);
    if (oldF == null || newF == null) {
      _append('ERROR: nenašiel som oba súbory '
          '(current=${cur.name}, target=${tgt.name}).');
      return;
    }
    setState(() => _busy = true);
    try {
      final oldFw = _binFromPicked(oldF.name, await oldF.readAsBytes());
      final newFw = _binFromPicked(newF.name, await newF.readAsBytes());
      await _loadGeneratedPkg(oldFw, newFw, sel.packageFileName);
    } catch (e) {
      _append('ERROR: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  // A picked firmware file may be a raw .bin or a release .zip (browser-download
  // path on web, which sidesteps the GitHub binary-host CORS block).
  Uint8List _binFromPicked(String name, Uint8List bytes) =>
      name.toLowerCase().endsWith('.zip') ? extractFirmwareBinFromZip(bytes) : bytes;

  Future<void> _createFromLocalBins() async {
    const group = XTypeGroup(label: 'firmware', extensions: ['bin', 'zip']);
    _append('Vyber STARÝ (current) .bin/.zip…');
    final oldFile = await openFile(acceptedTypeGroups: [group]);
    if (oldFile == null) return;
    _append('Vyber NOVÝ (target) .bin/.zip…');
    final newFile = await openFile(acceptedTypeGroups: [group]);
    if (newFile == null) return;
    // _busy gates only the compute (read + patch gen), not the file dialogs.
    setState(() => _busy = true);
    try {
      final oldFw = _binFromPicked(oldFile.name, await oldFile.readAsBytes());
      final newFw = _binFromPicked(newFile.name, await newFile.readAsBytes());
      await _loadGeneratedPkg(oldFw, newFw, '${oldFile.name} → ${newFile.name}');
    } catch (e) {
      _append('ERROR: $e');
    } finally {
      setState(() => _busy = false);
    }
  }

  Future<void> _pickPkg() async {
    const group =
        XTypeGroup(label: 'fotapkg', extensions: ['json', 'fotapkg', 'otapkg']);
    final file = await openFile(acceptedTypeGroups: [group]);
    if (file == null) return;
    try {
      final bytes = await file.readAsBytes();
      final pkg = FotaPkg.fromJsonString(String.fromCharCodes(bytes));
      setState(() {
        _pkg = pkg;
        _pkgLabel = file.name;
        _resetSelection();
        // Adopt the package's recommended scope (defaults to zerohop) and path,
        // but the controls below let the user override them per send.
        _adoptPkgScope(pkg);
      });
      _append('Loaded ${file.name}: '
          'patch=${pkg.patchLen}B chunks=${(pkg.patchLen / kFotaChunkData).ceil()} '
          'signed=${pkg.meta != null}');
    } catch (e) {
      _append('ERROR: $e');
    }
  }

  // A newly loaded package resets the send selection back to All (its chunk
  // count differs, so a stale list would be meaningless). Caller wraps in setState.
  void _resetSelection() {
    _selectionMode = false;
    _selectionController.clear();
  }

  // Adopt a loaded package's recommended scope/path/region into the editable
  // controls (the user can still override before sending). Caller wraps in setState.
  void _adoptPkgScope(FotaPkg pkg) {
    _scope = pkg.scope;
    _pathController.text = pkg.pathHex;
    _pathHashSize = (pkg.pathHashSize >= 1 && pkg.pathHashSize <= 3) ? pkg.pathHashSize : 1;
    _regionAsKey = pkg.scopeKeyHex.isNotEmpty;
    _regionController.text = _regionAsKey ? pkg.scopeKeyHex : pkg.scopeName;
  }

  // Resolve the 16-byte region transport key from the UI (name → SHA256("#"+name)
  // like the firmware; or a raw 32-hex-char key). Returns null + logs on error.
  Uint8List? _resolveRegionKey() {
    final raw = _regionController.text.trim();
    if (raw.isEmpty) {
      _append('ERROR: scope=region vyžaduje názov regiónu alebo 16B hex kľúč.');
      return null;
    }
    if (!_regionAsKey) return fotaRegionKeyFromName(raw);
    final hex = raw.startsWith('0x') ? raw.substring(2) : raw;
    if (hex.length != 32) {
      _append('ERROR: 16B kľúč musí mať 32 hex znakov (má ${hex.length}).');
      return null;
    }
    final bytes = <int>[];
    for (var i = 0; i < 32; i += 2) {
      final b = int.tryParse(hex.substring(i, i + 2), radix: 16);
      if (b == null) {
        _append('ERROR: neplatný hex v 16B kľúči.');
        return null;
      }
      bytes.add(b);
    }
    return Uint8List.fromList(bytes);
  }

  Future<void> _send({required bool apply, FotaSelection? selectionOverride}) async {
    final pkg = _pkg;
    if (pkg == null) return;
    final c = Provider.of<MeshCoreConnector>(context, listen: false);
    if (!c.isConnected) {
      _append('Not connected.');
      return;
    }
    if (_scope == FotaScope.direct && _pathController.text.trim().isEmpty) {
      _append('ERROR: scope=direct vyžaduje path (hex hopy oddelené čiarkou).');
      return;
    }
    Uint8List? regionKey;
    if (_scope == FotaScope.region) {
      regionKey = _resolveRegionKey();
      if (regionKey == null) return;
    }
    final total = (pkg.patchLen / kFotaChunkData).ceil();
    // Resolve the selection: an explicit override (APPLY-only button) wins;
    // otherwise parse the text field when in Selection mode; else null = All.
    FotaSelection? sel = selectionOverride;
    if (sel == null && _selectionMode) {
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
    // Packet accounting for the result line: Req = how many FOTA packets this
    // send should emit; Sent = how many actually went out (sink counter);
    // All = packets in a complete package (all chunks + META + SIG).
    final cyclesN = _intField(_cyclesController, 1, min: 1);
    final headerEveryN = _intField(_headerEveryController, 0);
    final int req;
    if (sel != null) {
      req = (sel.chunks.length +
              (sel.meta ? 1 : 0) +
              (sel.sig ? 1 : 0) +
              (apply ? 1 : 0)) *
          cyclesN;
    } else {
      final redundancy = headerEveryN > 0 ? (total ~/ headerEveryN) * 2 : 0;
      req = (total + 2 + redundancy + (apply ? 1 : 0)) * cyclesN;
    }
    final allPackets = total + 2;
    final sink = _ConnectorFotaSink(c);
    setState(() {
      _busy = true;
      _progress = 0;
    });
    try {
      Uint8List? seed;
      if (pkg.meta == null) seed = await FotaKeyStore().loadSeed(); // raw → need key
      final sender = FotaSender(sink);
      _activeSender = sender;
      await sender.send(
        pkg.toJob(),
        FotaSendConfig(
          channelName: pkg.channelName,
          channelIdx: pkg.channelIdx,
          freqMHz: pkg.freqMHz,
          bwKHz: pkg.bwKHz,
          sf: pkg.sf,
          cr: pkg.cr,
          scope: _scope,
          pathHex: _pathController.text.trim(),
          pathHashSize: _pathHashSize,
          scopeKey: regionKey,
          applyAfter: apply,
          // FOTA obrazovka nemení rádio companiona — predpoklad: companion je už
          // naladený na rovnakú sieť (freq/bw/sf/cr) ako repeater. Mení sa len kanál.
          applyRadio: false,
          delayMs: _intField(_delayController, 3000),
          cycles: cyclesN,
          headerEvery: headerEveryN,
          // ts base = wall-clock epoch seconds (like python senders' int(time.time())).
          // Without this it defaulted to 0, so every send replayed the SAME ts
          // sequence (1,2,3,...). For an unchanged patch the packets were then
          // byte-identical → same packet_hash → MeshCore's seen-table dedup dropped
          // the re-send as duplicates (repeater showed only RAW). Re-sends are >=1s
          // apart so a fresh epoch base keeps every session's packets unique.
          tsBase: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          seed32: seed,
          selection: sel,
        ),
        onProgress: (p) => setState(() {
          _progress = p.total == 0 ? 0 : (p.sent / p.total).clamp(0.0, 1.0);
        }),
      );
      _append('Done - all packets sent. Req: $req  Sent: ${sink.sent}  '
          'All: $allPackets');
    } on FotaCancelled {
      _append('Done - problem - packets send. Req: $req  Sent: ${sink.sent}  '
          'All: $allPackets  Canceled');
    } catch (e) {
      _append('Done - problem - packets send. Req: $req  Sent: ${sink.sent}  '
          'All: $allPackets  Error: $e');
    } finally {
      _activeSender = null;
      setState(() => _busy = false);
    }
  }

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
              style:
                  ElevatedButton.styleFrom(backgroundColor: Colors.deepOrange),
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('APPLY')),
        ],
      ),
    );
    return ok ?? false;
  }

  // APPLY-only: send just the APPLY packet (empty selection, applyAfter=true)
  // so it routes through the same sender path (channel/ts/cancel handling).
  Future<void> _sendApplyOnly() async {
    if (_pkg == null) return;
    if (!await _confirmApply()) return;
    await _send(
        apply: true,
        selectionOverride:
            const FotaSelection([], meta: false, sig: false));
  }

  Future<void> _openSelectionDialog() async {
    final total = _pkg == null ? 0 : (_pkg!.patchLen / kFotaChunkData).ceil();
    bool mode = _selectionMode;
    String? error;
    await showDialog<void>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setLocal) => AlertDialog(
          title: const Text('Výber na odoslanie'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioGroup<bool>(
                groupValue: mode,
                onChanged: (v) => setLocal(() => mode = v ?? false),
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RadioListTile<bool>(
                      value: false,
                      title: Text('Všetko (Select All)'),
                      contentPadding: EdgeInsets.zero,
                    ),
                    RadioListTile<bool>(
                      value: true,
                      title: Text('Len výber nižšie (Only Selection below)'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ],
                ),
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
              if (error != null) ...[
                const SizedBox(height: 8),
                Text(error!,
                    style: const TextStyle(color: Colors.red, fontSize: 12)),
              ],
            ],
          ),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('Zrušiť')),
            ElevatedButton(
              onPressed: () {
                // Validate the list now (on confirm) when in Selection mode, so
                // typos are caught here rather than silently at send time.
                if (mode) {
                  try {
                    parseFotaSelection(_selectionController.text,
                        totalChunks: total);
                  } on FormatException catch (e) {
                    setLocal(() => error = e.message);
                    return;
                  }
                }
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

  @override
  Widget build(BuildContext context) {
    final pkg = _pkg;
    return Scaffold(
      appBar: AppBar(title: Text('FOTA → ${widget.headerTarget}'), centerTitle: true),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 8),
            title: const Text('Priprav z GitHubu'),
            children: [
              FotaFwPicker(
                sourceFactory: (repo) => FotaGithubSource(repo: repo),
                onSelection: (s) => setState(() => _fwSelection = s),
              ),
              const SizedBox(height: 8),
              // Web: GitHub binary downloads are CORS-blocked for in-app fetch,
              // so first let the browser download the exact files, then pick them.
              if (kIsWeb && _fwSelection != null) ...[
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _busy ? null : _downloadFwViaBrowser,
                    icon: const Icon(Icons.download),
                    label: const Text('⬇ Stiahni FW (current + target)'),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: (_busy || _fwSelection == null)
                      ? null
                      : (kIsWeb ? _createFromPickedFiles : _createFromGithub),
                  icon: const Icon(Icons.build),
                  label: Text(_fwSelection == null
                      ? 'Create FOTA package'
                      : (kIsWeb
                          ? 'Create FOTA package (vyber stiahnuté súbory)'
                          : 'Create FOTA package: ${_fwSelection!.packageFileName}')),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _createFromLocalBins,
              icon: const Icon(Icons.folder_zip),
              label: const Text('Vyrob z lokálnych .bin/.zip'),
            ),
          ),
          const SizedBox(height: 8),
          ElevatedButton.icon(
            onPressed: _busy ? null : _pickPkg,
            icon: const Icon(Icons.folder_open),
            label: Text(_pkgLabel ?? 'Vyber .fotapkg.json'),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: (_busy || pkg == null) ? null : _openSelectionDialog,
              icon: const Icon(Icons.checklist),
              label: Text(_selectionMode
                  ? 'Výber na odoslanie: Selection'
                  : 'Výber na odoslanie: All'),
            ),
          ),
          if (pkg != null) ...[
            const SizedBox(height: 8),
            Expanded(
              child: ListView(children: [
                Text('Kanál: ${pkg.channelName} [${pkg.channelIdx}]   '
                    'Rádio: ${pkg.freqMHz}/${pkg.bwKHz}/SF${pkg.sf}/CR${pkg.cr}'),
                Text('Patch: ${pkg.patchLen} B   '
                    'chunkov: ${(pkg.patchLen / kFotaChunkData).ceil()}   '
                    'signed: ${pkg.meta != null}'),
                const SizedBox(height: 8),
                DropdownButtonFormField<FotaScope>(
                  initialValue: _scope,
                  decoration: const InputDecoration(
                    labelText: 'Scope (LoRa šírenie)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(
                        value: FotaScope.zerohop,
                        child: Text('ZeroHop — len priami susedia (default)')),
                    DropdownMenuItem(
                        value: FotaScope.flood,
                        child: Text('Flood — každý repeater re-flooduje')),
                    DropdownMenuItem(
                        value: FotaScope.region,
                        child: Text('Region — flood len v zhodnom regióne')),
                    DropdownMenuItem(
                        value: FotaScope.direct,
                        child: Text('Direct — cez menované hopy (path)')),
                  ],
                  onChanged:
                      _busy ? null : (v) => setState(() => _scope = v ?? FotaScope.zerohop),
                ),
                if (_scope == FotaScope.region) ...[
                  const SizedBox(height: 8),
                  DropdownButtonFormField<bool>(
                    initialValue: _regionAsKey,
                    decoration: const InputDecoration(
                      labelText: 'Región zadaný ako',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(
                          value: false, child: Text('Názov (#hashtag)')),
                      DropdownMenuItem(
                          value: true, child: Text('16-bajtový hex kľúč')),
                    ],
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _regionAsKey = v ?? false),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _regionController,
                    enabled: !_busy,
                    decoration: InputDecoration(
                      labelText: _regionAsKey
                          ? '16B kľúč (32 hex znakov)'
                          : 'Názov regiónu (napr. mesh → #mesh)',
                      helperText: _regionAsKey
                          ? 'Surový transport kľúč.'
                          : 'Kľúč = SHA256("#"+názov)[:16]; companion dopočíta transport code.',
                      helperMaxLines: 2,
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ],
                if (_scope == FotaScope.direct) ...[
                  const SizedBox(height: 8),
                  DropdownButtonFormField<int>(
                    initialValue: _pathHashSize,
                    decoration: const InputDecoration(
                      labelText: 'Path hashsize (bajtov/hop)',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                    items: const [
                      DropdownMenuItem(value: 1, child: Text('1 bajt/hop')),
                      DropdownMenuItem(value: 2, child: Text('2 bajty/hop')),
                      DropdownMenuItem(value: 3, child: Text('3 bajty/hop')),
                    ],
                    onChanged: _busy
                        ? null
                        : (v) => setState(() => _pathHashSize = v ?? 1),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: _pathController,
                    enabled: !_busy,
                    decoration: InputDecoration(
                      labelText: _pathHashSize == 1
                          ? 'Path (hopy oddelené čiarkou, napr. 3f,a1,b2)'
                          : 'Path (hopy po ${_pathHashSize}B, napr. ${_pathHashSize == 2 ? "3fa1,b2c3" : "aabbcc,ddeeff"})',
                      border: const OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ],
                const SizedBox(height: 12),
                const Text('Časovanie paketov',
                    style: TextStyle(fontWeight: FontWeight.w600)),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                    child: _numField(
                      _delayController,
                      'Pauza/paket [ms]',
                      'Pauza medzi paketmi (--delay).',
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _numField(
                      _cyclesController,
                      'Cykly',
                      'Koľkokrát zopakovať celý broadcast (--cycles). '
                          'Prijímač kumuluje chunky naprieč cyklami.',
                    ),
                  ),
                ]),
                const SizedBox(height: 8),
                _numField(
                  _headerEveryController,
                  'Header každých N chunkov',
                  'Redundancia HEADER-a (META+SIG) po každých N chunkoch '
                      '(--header-every; 0 = vyp).',
                ),
                const SizedBox(height: 8),
                Row(children: [
                  Expanded(
                      child: ElevatedButton(
                          onPressed: _busy ? null : () => _send(apply: false),
                          child: const Text('Odoslať patch'))),
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
                  const SizedBox(width: 8),
                  Expanded(
                      child: ElevatedButton(
                          onPressed: _busy ? null : _sendApplyOnly,
                          style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.orange),
                          child: const Text('APPLY'))),
                ]),
              ]),
            ),
          ],
          const SizedBox(height: 8),
          if (_busy)
            Row(children: [
              Expanded(child: LinearProgressIndicator(value: _progress)),
              const SizedBox(width: 8),
              TextButton(
                onPressed: () => _activeSender?.cancel(),
                child: const Text('Zrušiť odosielanie'),
              ),
            ]),
          const SizedBox(height: 8),
          SizedBox(
            height: 140,
            child: Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              color: Colors.black12,
              child: SingleChildScrollView(
                  child: Text(_log,
                      style:
                          const TextStyle(fontFamily: 'monospace', fontSize: 12))),
            ),
          ),
        ]),
      ),
    );
  }

  Widget _numField(TextEditingController c, String label, String helper) {
    return TextField(
      controller: c,
      enabled: !_busy,
      keyboardType: TextInputType.number,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 3,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }
}
