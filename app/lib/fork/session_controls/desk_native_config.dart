import 'dart:async';

import '../../data/acp/acp_models.dart';
import '../../data/repositories/machine_connection.dart';
import '../model_bar/model_bar_client.dart';

/// Adapts desk-native terminal panes (where Claude runs in a raw shell) to
/// provide dynamic Model, Effort, and Effortless config options compatible with
/// Herdr's [SessionChipsRow] and [showSessionOptions].
class DeskNativeConfigAdapter {
  DeskNativeConfigAdapter({required this.machine, required this.paneId, this.modelBarClient = const ModelBarClient()}) {
    _initDefaults();
  }

  final MachineConnection machine;
  final String paneId;
  final ModelBarClient modelBarClient;

  String _activeModel = 'claude-3-7-sonnet';
  String _activeEffort = 'high';
  String _activeEffortless = 'auto';

  final List<String> _pinnedModels = [];
  bool _loaded = false;

  void _initDefaults() {
    _pinnedModels.addAll([
      'claude-3-7-sonnet',
      'claude-3-5-sonnet',
      'claude-3-opus',
      'claude-3-5-haiku',
      'argon',
      'flash',
      'codex',
      'muse',
    ]);
  }

  /// Asynchronously loads pinned models from the Mac's model bar store.
  Future<void> load() async {
    if (_loaded) return;
    _loaded = true;
    try {
      final config = await modelBarClient.fetchConfig(machine);
      if (config.pinned.isNotEmpty) {
        setPinnedModels(config.pinned);
      }
    } catch (_) {
      // Retain fallback defaults if unreachable
    }
  }

  void setPinnedModels(List<String> models) {
    _pinnedModels.clear();
    for (final m in models) {
      if (m.trim().isNotEmpty && !_pinnedModels.contains(m.trim())) {
        _pinnedModels.add(m.trim());
      }
    }
    // Ensure active model is present in choices
    if (!_pinnedModels.contains(_activeModel)) {
      _pinnedModels.insert(0, _activeModel);
    }
  }

  /// Called when an assistant turn in Claude's JSONL transcript specifies a model.
  void onObservedModel(String model) {
    final clean = model.trim();
    if (clean.isEmpty || clean == '<synthetic>') return;
    _activeModel = clean;
    if (!_pinnedModels.contains(clean)) {
      _pinnedModels.insert(0, clean);
    }
  }

  /// Synthesizes ACP [ConfigOption]s so upstream [SessionChipsRow] and
  /// [showSessionOptions] render native Model, Effort, and Effortless chips.
  List<ConfigOption> get options {
    final modelChoices = <ConfigChoice>[];
    final seen = <String>{};

    void addChoice(String id) {
      if (seen.add(id)) {
        modelChoices.add(ConfigChoice(value: id, name: friendlyModelName(id)));
      }
    }

    if (_activeModel.isNotEmpty) addChoice(_activeModel);
    for (final id in _pinnedModels) {
      addChoice(id);
    }

    return [
      SelectConfigOption(id: 'model', name: 'Model', category: 'model', value: _activeModel, choices: modelChoices),
      SelectConfigOption(
        id: 'thought_level',
        name: 'Effort',
        category: 'thought_level',
        value: _activeEffort,
        choices: const [
          ConfigChoice(value: 'low', name: 'Low'),
          ConfigChoice(value: 'medium', name: 'Medium'),
          ConfigChoice(value: 'high', name: 'High'),
          ConfigChoice(value: 'max', name: 'Max'),
        ],
      ),
      SelectConfigOption(
        id: 'effortless',
        name: 'Effortless',
        category: 'other',
        value: _activeEffortless,
        choices: const [
          ConfigChoice(value: 'auto', name: 'Auto'),
          ConfigChoice(value: 'low', name: 'Low'),
          ConfigChoice(value: 'medium', name: 'Medium'),
          ConfigChoice(value: 'high', name: 'High'),
          ConfigChoice(value: 'off', name: 'Off'),
        ],
      ),
    ];
  }

  /// Dispatches the appropriate steering command into the Claude terminal pane.
  Future<void> setConfigOption(String configId, Object value) async {
    final valStr = value.toString().trim();
    if (valStr.isEmpty) return;

    switch (configId) {
      case 'model':
        _activeModel = valStr;
        if (!_pinnedModels.contains(valStr)) {
          _pinnedModels.insert(0, valStr);
        }
        await machine.api.sendLine(paneId, '/model $valStr');
      case 'thought_level':
        _activeEffort = valStr;
        await machine.api.sendLine(paneId, '/effort $valStr');
      case 'effortless':
        _activeEffortless = valStr;
        await machine.api.sendLine(paneId, '/effortless $valStr');
    }
  }

  /// Formats raw model IDs into human-readable labels matching desktop parity.
  static String friendlyModelName(String id) {
    final lower = id.toLowerCase();
    if (lower.contains('3-7-sonnet') || lower.contains('3.7-sonnet')) return 'Sonnet 3.7';
    if (lower.contains('3-5-sonnet') || lower.contains('3.5-sonnet')) return 'Sonnet 3.5';
    if (lower.contains('opus')) return 'Opus';
    if (lower.contains('haiku')) return 'Haiku 3.5';
    if (lower.contains('argon')) return 'Argon';
    if (lower.contains('flash')) return 'Flash';
    if (lower.contains('codex')) return 'Codex';
    if (lower.contains('muse')) return 'Muse';
    if (lower.contains('gpt-6')) return 'GPT-6 Astra';
    if (lower.contains('minimax')) return 'MiniMax M2.5';
    if (id.length > 20) {
      final slash = id.lastIndexOf('/');
      if (slash >= 0) return id.substring(slash + 1);
    }
    return id.substring(0, 1).toUpperCase() + id.substring(1);
  }
}
