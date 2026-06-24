import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../connector/meshcore_connector.dart';
import '../connector/meshcore_protocol.dart';
import '../ota/browser_download.dart';
import '../ota/ota_asset_download.dart';
import '../ota/ota_pkg_builder.dart';
import '../ota/ota_sender.dart';
import '../ota/ota_types.dart';
import '../ota/ota_github_source.dart';
import '../ota/otapkg.dart';
import '../services/ota_key_store.dart';
import 'ota_fw_picker.dart';

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
      c.sendFrame(buildSetChannelFrame(idx, name, psk));
}

/// Reusable OTA sender screen. The only difference between launching it from a
/// repeater admin hub and from the global FOTA Broadcast settings entry is the
/// header target ([headerTarget]); the whole send flow below is shared.
///
/// OTA is a channel GRP_DATA broadcast — it needs no repeater login, so this
/// screen can run without being connected/authenticated to any repeater.
class OtaScreen extends StatefulWidget {
  /// Shown in the app-bar as "FOTA → [headerTarget]" (repeater name or "Broadcast").
  final String headerTarget;
  const OtaScreen({super.key, required this.headerTarget});
  @override
  State<OtaScreen> createState() => _OtaScreenState();
}

class _OtaScreenState extends State<OtaScreen> {
  OtaPkg? _pkg;
  OtaFwSelection? _fwSelection;
  String _log = '';
  double _progress = 0;
  bool _busy = false;
  bool _applyRadio = true;

  // Send-mode / timing options (mirror ota_sender.py CLI flags).
  OtaScope _scope = OtaScope.zerohop; // --scope (ZeroHop default)
  final _pathController = TextEditingController(); // --path (scope=direct)
  final _delayController = TextEditingController(text: '300'); // --delay [ms]
  final _cyclesController = TextEditingController(text: '1'); // --cycles
  final _headerEveryController = TextEditingController(text: '0'); // --header-every

  @override
  void dispose() {
    _pathController.dispose();
    _delayController.dispose();
    _cyclesController.dispose();
    _headerEveryController.dispose();
    super.dispose();
  }

  void _append(String s) => setState(() => _log = '$_log$s\n');

  int _intField(TextEditingController c, int fallback, {int min = 0}) {
    final v = int.tryParse(c.text.trim());
    if (v == null || v < min) return fallback;
    return v;
  }

  OtaBuildParams _buildParams() => OtaBuildParams(
        channelName: '#fkotanrf',
        channelIdx: 1,
        freqMHz: 869.618,
        bwKHz: 62.5,
        sf: 8,
        cr: 5,
        scope: _scope.name,
        path: _pathController.text.trim(),
      );

  Future<void> _loadGeneratedPkg(Uint8List oldFw, Uint8List newFw, String label) async {
    _append('Generujem patch ($label)…');
    final json = buildOtaPkgJson(oldFw: oldFw, newFw: newFw, p: _buildParams());
    final pkg = OtaPkg.fromJsonString(json);
    setState(() {
      _pkg = pkg;
      _scope = pkg.scope;
      _pathController.text = pkg.pathHex;
    });
    _append('Hotovo: patch=${pkg.patchLen}B '
        'chunkov=${(pkg.patchLen / kOtaChunkData).ceil()}');
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
    const group = XTypeGroup(label: 'otapkg', extensions: ['json', 'otapkg']);
    final file = await openFile(acceptedTypeGroups: [group]);
    if (file == null) return;
    try {
      final bytes = await file.readAsBytes();
      final pkg = OtaPkg.fromJsonString(String.fromCharCodes(bytes));
      setState(() {
        _pkg = pkg;
        // Adopt the package's recommended scope (defaults to zerohop) and path,
        // but the controls below let the user override them per send.
        _scope = pkg.scope;
        _pathController.text = pkg.pathHex;
      });
      _append('Loaded ${file.name}: '
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
    if (!c.isConnected) {
      _append('Not connected.');
      return;
    }
    if (_scope == OtaScope.direct && _pathController.text.trim().isEmpty) {
      _append('ERROR: scope=direct vyžaduje path (hex hopy).');
      return;
    }
    setState(() {
      _busy = true;
      _progress = 0;
    });
    try {
      Uint8List? seed;
      if (pkg.meta == null) seed = await OtaKeyStore().loadSeed(); // raw → need key
      await OtaSender(_ConnectorOtaSink(c)).send(
        pkg.toJob(),
        OtaSendConfig(
          channelName: pkg.channelName,
          channelIdx: pkg.channelIdx,
          freqMHz: pkg.freqMHz,
          bwKHz: pkg.bwKHz,
          sf: pkg.sf,
          cr: pkg.cr,
          scope: _scope,
          pathHex: _pathController.text.trim(),
          applyAfter: apply,
          applyRadio: _applyRadio,
          delayMs: _intField(_delayController, 300),
          cycles: _intField(_cyclesController, 1, min: 1),
          headerEvery: _intField(_headerEveryController, 0),
          // ts base = wall-clock epoch seconds (like python senders' int(time.time())).
          // Without this it defaulted to 0, so every send replayed the SAME ts
          // sequence (1,2,3,...). For an unchanged patch the packets were then
          // byte-identical → same packet_hash → MeshCore's seen-table dedup dropped
          // the re-send as duplicates (repeater showed only RAW). Re-sends are >=1s
          // apart so a fresh epoch base keeps every session's packets unique.
          tsBase: DateTime.now().millisecondsSinceEpoch ~/ 1000,
          seed32: seed,
        ),
        onProgress: (p) => setState(() {
          _progress = p.total == 0 ? 0 : (p.sent / p.total).clamp(0.0, 1.0);
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
      appBar: AppBar(title: Text('FOTA → ${widget.headerTarget}'), centerTitle: true),
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            childrenPadding: const EdgeInsets.only(bottom: 8),
            title: const Text('Priprav z GitHubu'),
            children: [
              OtaFwPicker(
                sourceFactory: (repo) => OtaGithubSource(repo: repo),
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
            label: const Text('Vyber .otapkg.json'),
          ),
          if (pkg != null) ...[
            const SizedBox(height: 8),
            Expanded(
              child: ListView(children: [
                Text('Kanál: ${pkg.channelName} [${pkg.channelIdx}]   '
                    'Rádio: ${pkg.freqMHz}/${pkg.bwKHz}/SF${pkg.sf}/CR${pkg.cr}'),
                Text('Patch: ${pkg.patchLen} B   '
                    'chunkov: ${(pkg.patchLen / kOtaChunkData).ceil()}   '
                    'signed: ${pkg.meta != null}'),
                const SizedBox(height: 8),
                DropdownButtonFormField<OtaScope>(
                  initialValue: _scope,
                  decoration: const InputDecoration(
                    labelText: 'Scope (LoRa šírenie)',
                    border: OutlineInputBorder(),
                    isDense: true,
                  ),
                  items: const [
                    DropdownMenuItem(
                        value: OtaScope.zerohop,
                        child: Text('ZeroHop — len priami susedia (default)')),
                    DropdownMenuItem(
                        value: OtaScope.flood,
                        child: Text('Flood — každý repeater re-flooduje')),
                    DropdownMenuItem(
                        value: OtaScope.direct,
                        child: Text('Direct — cez menované hopy (path)')),
                  ],
                  onChanged:
                      _busy ? null : (v) => setState(() => _scope = v ?? OtaScope.zerohop),
                ),
                if (_scope == OtaScope.direct) ...[
                  const SizedBox(height: 8),
                  TextField(
                    controller: _pathController,
                    enabled: !_busy,
                    decoration: const InputDecoration(
                      labelText: 'Path (hex hopy, napr. 3fa1b2)',
                      border: OutlineInputBorder(),
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
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: _applyRadio,
                  onChanged: _busy ? null : (v) => setState(() => _applyRadio = v),
                  title: const Text('Nastaviť rádio companionu podľa balíka'),
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
                          onPressed: _busy ? null : () => _send(apply: true),
                          style: ElevatedButton.styleFrom(
                              backgroundColor: Colors.deepOrange),
                          child: const Text('Odoslať + APPLY'))),
                ]),
              ]),
            ),
          ],
          const SizedBox(height: 8),
          if (_busy) LinearProgressIndicator(value: _progress),
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
