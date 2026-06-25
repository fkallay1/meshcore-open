import 'package:flutter/material.dart';
import 'fota_fw_catalog.dart';
import 'fota_fw_source.dart';

class FotaFwSelection {
  final String device;
  final FotaFwRole role;
  final String currentVersion;
  final String targetVersion;
  final FotaReleaseAsset? currentAsset;
  final FotaReleaseAsset? targetAsset;
  const FotaFwSelection({
    required this.device,
    required this.role,
    required this.currentVersion,
    required this.targetVersion,
    required this.currentAsset,
    required this.targetAsset,
  });

  String get packageFileName => fotaPackageFileName(
        device: device,
        role: role,
        currentVersion: currentVersion,
        targetVersion: targetVersion,
      );
}

class FotaFwPicker extends StatefulWidget {
  final FotaFwSource Function(String repo) sourceFactory;
  final String initialRepo;
  final void Function(FotaFwSelection)? onSelection;
  const FotaFwPicker({
    super.key,
    required this.sourceFactory,
    this.initialRepo = 'meshcore-dev/MeshCore',
    this.onSelection,
  });
  @override
  State<FotaFwPicker> createState() => _FotaFwPickerState();
}

class _FotaFwPickerState extends State<FotaFwPicker> {
  FotaFwRole _role = FotaFwRole.repeater;
  FotaFwCatalog? _cat;
  String? _error;
  bool _loading = true;

  String? _device;
  String? _current;
  String? _target;

  static const _customRepo = '__custom__';
  static const _repoPresets = <String, String>{
    'meshcore-dev/MeshCore': 'meshcore-dev/MeshCore',
    'fkallay1/MeshCore': 'fkallay1/MeshCore',
    _customRepo: 'Custom…',
  };
  late String _repoPreset = _repoPresets.containsKey(widget.initialRepo)
      ? widget.initialRepo
      : _customRepo;
  late final TextEditingController _repoController =
      TextEditingController(text: widget.initialRepo);

  String _effectiveRepo() {
    if (_repoPreset == _customRepo) {
      final r = _repoController.text.trim();
      return r.isEmpty ? widget.initialRepo : r;
    }
    return _repoPreset;
  }

  FotaFwSource _buildSource() => widget.sourceFactory(_effectiveRepo());

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _repoController.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final cat = await _buildSource().loadCatalog(_role);
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

  void _applyDefaults(FotaFwCatalog cat) {
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
    widget.onSelection?.call(FotaFwSelection(
      device: _device!,
      role: _role,
      currentVersion: _current!,
      targetVersion: _target!,
      currentAsset: cat.assetFor(_device!, _current!),
      targetAsset: cat.assetFor(_device!, _target!),
    ));
  }

  Widget _buildStateWidget(BuildContext context) {
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
    final currentAsset =
        (_device != null && _current != null) ? cat.assetFor(_device!, _current!) : null;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      DropdownButtonFormField<FotaFwRole>(
        initialValue: _role,
        decoration: const InputDecoration(
            labelText: 'Rola firmvéru', border: OutlineInputBorder(), isDense: true),
        items: const [
          DropdownMenuItem(value: FotaFwRole.repeater, child: Text('Repeater')),
          DropdownMenuItem(value: FotaFwRole.roomServer, child: Text('Room Server')),
        ],
        onChanged: (v) {
          if (v == null) return;
          setState(() => _role = v);
          _load();
        },
      ),
      const SizedBox(height: 8),
      // Searchable device picker: type to filter (34+ nRF boards). Keyed on the
      // device list so it resets its shown selection when the catalog reloads
      // (role/repo change) and re-applies the promicro default.
      DropdownMenu<String>(
        key: ValueKey('dev-$_role-${cat.devices.join('|').hashCode}'),
        initialSelection: _device,
        enableFilter: true,
        requestFocusOnTap: true,
        expandedInsets: EdgeInsets.zero,
        menuHeight: 360,
        label: const Text('Zariadenie (píš pre vyhľadanie)'),
        inputDecorationTheme: const InputDecorationTheme(
            border: OutlineInputBorder(), isDense: true),
        dropdownMenuEntries: [
          for (final d in cat.devices) DropdownMenuEntry(value: d, label: d),
        ],
        onSelected: (v) {
          if (v == null) return;
          setState(() => _device = v);
          _emit();
        },
      ),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: DropdownButtonFormField<String>(
            initialValue: _current,
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
            initialValue: _target,
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
        'Current: ${currentAsset?.name ?? '— (žiadny vhodný asset)'}\n'
        'Target:  ${targetAsset?.name ?? '— (žiadny vhodný asset)'}',
        style: const TextStyle(fontSize: 11, fontFamily: 'monospace'),
      ),
    ]);
  }

  @override
  Widget build(BuildContext context) {
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      DropdownButtonFormField<String>(
        initialValue: _repoPreset,
        isExpanded: true,
        decoration: const InputDecoration(
          labelText: 'Zdroj firmvéru (GitHub repo)',
          border: OutlineInputBorder(),
          isDense: true,
        ),
        items: [
          for (final e in _repoPresets.entries)
            DropdownMenuItem(value: e.key, child: Text(e.value)),
        ],
        onChanged: (v) {
          if (v == null) return;
          setState(() => _repoPreset = v);
          if (v != _customRepo) _load(); // Custom: reload on field submit
        },
      ),
      if (_repoPreset == _customRepo) ...[
        const SizedBox(height: 8),
        TextField(
          controller: _repoController,
          decoration: const InputDecoration(
            labelText: 'Custom repo (owner/repo)',
            border: OutlineInputBorder(),
            isDense: true,
          ),
          onSubmitted: (_) => _load(),
        ),
      ],
      const SizedBox(height: 8),
      _buildStateWidget(context),
    ]);
  }
}
