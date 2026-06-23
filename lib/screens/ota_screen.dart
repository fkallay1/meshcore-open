import 'dart:typed_data';
import 'package:file_selector/file_selector.dart';
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
      c.sendFrame(buildSetChannelFrame(idx, name, psk));
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
    const group = XTypeGroup(label: 'otapkg', extensions: ['json', 'otapkg']);
    final file = await openFile(acceptedTypeGroups: [group]);
    if (file == null) return;
    try {
      final bytes = await file.readAsBytes();
      final pkg = OtaPkg.fromJsonString(String.fromCharCodes(bytes));
      setState(() => _pkg = pkg);
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
          scope: pkg.scope,
          pathHex: pkg.pathHex,
          applyAfter: apply,
          applyRadio: _applyRadio,
          delayMs: 300,
          seed32: seed,
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
      appBar: AppBar(title: Text('OTA → ${widget.repeater.name}'), centerTitle: true),
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
              Expanded(
                  child: ElevatedButton(
                      onPressed: _busy ? null : () => _send(apply: false),
                      child: const Text('Odoslať patch'))),
              const SizedBox(width: 8),
              Expanded(
                  child: ElevatedButton(
                      onPressed: _busy ? null : () => _send(apply: true),
                      style: ElevatedButton.styleFrom(backgroundColor: Colors.deepOrange),
                      child: const Text('Odoslať + APPLY'))),
            ]),
          ],
          const SizedBox(height: 8),
          if (_busy) LinearProgressIndicator(value: _progress),
          const SizedBox(height: 8),
          Expanded(
              child: Container(
            width: double.infinity,
            padding: const EdgeInsets.all(8),
            color: Colors.black12,
            child: SingleChildScrollView(
                child: Text(_log,
                    style: const TextStyle(fontFamily: 'monospace', fontSize: 12))),
          )),
        ]),
      ),
    );
  }
}
