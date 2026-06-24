import 'package:flutter/material.dart';
import '../ota/ota_fw_catalog.dart';
import '../ota/ota_github_source.dart';

class OtaFwSelection {
  final String device;
  final OtaFwRole role;
  final String currentVersion;
  final String targetVersion;
  final OtaReleaseAsset? currentAsset;
  final OtaReleaseAsset? targetAsset;
  const OtaFwSelection({
    required this.device,
    required this.role,
    required this.currentVersion,
    required this.targetVersion,
    required this.currentAsset,
    required this.targetAsset,
  });

  String get packageFileName => otaPackageFileName(
        device: device,
        role: role,
        currentVersion: currentVersion,
        targetVersion: targetVersion,
      );
}

class OtaFwPicker extends StatefulWidget {
  final OtaGithubSource source;
  final void Function(OtaFwSelection)? onSelection;
  const OtaFwPicker({super.key, required this.source, this.onSelection});
  @override
  State<OtaFwPicker> createState() => _OtaFwPickerState();
}

class _OtaFwPickerState extends State<OtaFwPicker> {
  OtaFwRole _role = OtaFwRole.repeater;
  OtaFwCatalog? _cat;
  String? _error;
  bool _loading = true;

  String? _device;
  String? _current;
  String? _target;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cat = await widget.source.loadCatalog(_role);
      if (!mounted) return;
      setState(() {
        _cat = cat;
        _applyDefaults(cat);
        _loading = false;
      });
      _emit();
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _error = '$e';
        _loading = false;
      });
    }
  }

  void _applyDefaults(OtaFwCatalog cat) {
    _device = cat.devices.firstWhere(
      (d) => d.toLowerCase() == 'promicro',
      orElse: () => cat.devices.isNotEmpty ? cat.devices.first : '',
    );
    final versions = cat.releases.map((r) => r.version).toList();
    _target = versions.isNotEmpty ? versions.first : null;
    _current = versions.length > 1 ? versions[1] : _target;
  }

  void _emit() {
    final cat = _cat;
    if (cat == null || _device == null || _current == null || _target == null) {
      return;
    }
    widget.onSelection?.call(OtaFwSelection(
      device: _device!,
      role: _role,
      currentVersion: _current!,
      targetVersion: _target!,
      currentAsset: cat.assetFor(_device!, _current!),
      targetAsset: cat.assetFor(_device!, _target!),
    ));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Padding(
        padding: EdgeInsets.all(8),
        child: Row(children: [
          SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(strokeWidth: 2)),
          SizedBox(width: 8),
          Text('Načítavam firmware z GitHubu…'),
        ]),
      );
    }
    if (_error != null) {
      return Padding(
        padding: const EdgeInsets.all(8),
        child: Row(children: [
          Expanded(child: Text('GitHub chyba: $_error')),
          TextButton(onPressed: _load, child: const Text('Skúsiť znova')),
        ]),
      );
    }
    final cat = _cat;
    if (cat == null) return const SizedBox.shrink();
    final versions = cat.releases.map((r) => r.version).toList();
    final targetAsset =
        (_device != null && _target != null) ? cat.assetFor(_device!, _target!) : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      DropdownButtonFormField<OtaFwRole>(
        value: _role,
        decoration: const InputDecoration(
            labelText: 'Rola firmvéru', border: OutlineInputBorder(), isDense: true),
        items: const [
          DropdownMenuItem(value: OtaFwRole.repeater, child: Text('Repeater')),
          DropdownMenuItem(value: OtaFwRole.roomServer, child: Text('Room Server')),
        ],
        onChanged: (v) {
          if (v == null) return;
          setState(() => _role = v);
          _load();
        },
      ),
      const SizedBox(height: 8),
      DropdownButtonFormField<String>(
        value: _device,
        isExpanded: true,
        decoration: const InputDecoration(
            labelText: 'Zariadenie', border: OutlineInputBorder(), isDense: true),
        items: [
          for (final d in cat.devices) DropdownMenuItem(value: d, child: Text(d)),
        ],
        onChanged: (v) {
          setState(() => _device = v);
          _emit();
        },
      ),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            value: _current,
            isExpanded: true,
            decoration: const InputDecoration(
                labelText: 'Current FW',
                border: OutlineInputBorder(),
                isDense: true),
            items: [
              for (final v in versions)
                DropdownMenuItem(value: v, child: Text('v$v')),
            ],
            onChanged: (v) {
              setState(() => _current = v);
              _emit();
            },
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: DropdownButtonFormField<String>(
            value: _target,
            isExpanded: true,
            decoration: const InputDecoration(
                labelText: 'Target FW',
                border: OutlineInputBorder(),
                isDense: true),
            items: [
              for (final v in versions)
                DropdownMenuItem(value: v, child: Text('v$v')),
            ],
            onChanged: (v) {
              setState(() => _target = v);
              _emit();
            },
          ),
        ),
      ]),
      const SizedBox(height: 6),
      Text(
        targetAsset == null
            ? 'Pre toto zariadenie/verziu nie je vhodný asset (bin/zip).'
            : 'Asset: ${targetAsset.name}',
        style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
      ),
    ]);
  }
}
