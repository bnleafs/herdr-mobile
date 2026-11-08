import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/fork/session_controls/desk_native_config.dart';

class FakeTransport implements HerdrTransport {
  final List<String> sentLines = [];
  final Map<String, dynamic> responses = {};

  @override
  Future<Map<String, dynamic>> request(String method, [Map<String, dynamic> params = const {}]) async {
    if (method == 'pane.send_input') {
      sentLines.add(params['text'] as String? ?? '');
      return {};
    }
    return (responses[method] as Map<String, dynamic>?) ?? {};
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('DeskNativeConfigAdapter', () {
    late FakeTransport transport;
    late MachineConnection machine;
    const paneId = 'pane-1';

    setUp(() {
      transport = FakeTransport();
      final api = HerdrApi(transport);
      machine = MachineConnection(
        profile: const MachineProfile(id: 'm1', label: 'MacBook', host: 'localhost', username: 'test'),
        api: api,
      );
    });

    test('initializes with default model, effort, and effortless options', () {
      final adapter = DeskNativeConfigAdapter(machine: machine, paneId: paneId);

      final options = adapter.options;
      expect(options.length, 3);

      final modelOpt = options.firstWhere((o) => o.id == 'model') as SelectConfigOption;
      expect(modelOpt.category, 'model');
      expect(modelOpt.name, 'Model');
      expect(modelOpt.choices, isNotEmpty);

      final effortOpt = options.firstWhere((o) => o.id == 'thought_level') as SelectConfigOption;
      expect(effortOpt.category, 'thought_level');
      expect(effortOpt.name, 'Effort');
      expect(effortOpt.choices.map((c) => c.value), containsAll(['low', 'medium', 'high', 'max']));

      final effortlessOpt = options.firstWhere((o) => o.id == 'effortless') as SelectConfigOption;
      expect(effortlessOpt.id, 'effortless');
      expect(effortlessOpt.name, 'Effortless');
      expect(effortlessOpt.choices.map((c) => c.value), containsAll(['auto', 'low', 'medium', 'high', 'off']));
    });

    test('updates active model when observed from transcript', () {
      final adapter = DeskNativeConfigAdapter(machine: machine, paneId: paneId);

      adapter.onObservedModel('claude-3-7-sonnet-20250219');

      final modelOpt = adapter.options.firstWhere((o) => o.id == 'model') as SelectConfigOption;
      expect(modelOpt.value, 'claude-3-7-sonnet-20250219');
      expect(modelOpt.currentName, contains('Sonnet 3.7'));
    });

    test('setConfigOption model sends /model command to pane and updates state', () async {
      final adapter = DeskNativeConfigAdapter(machine: machine, paneId: paneId);

      await adapter.setConfigOption('model', 'opus');

      expect(transport.sentLines, contains('/model opus'));
      final modelOpt = adapter.options.firstWhere((o) => o.id == 'model') as SelectConfigOption;
      expect(modelOpt.value, 'opus');
    });

    test('setConfigOption thought_level sends /effort command to pane and updates state', () async {
      final adapter = DeskNativeConfigAdapter(machine: machine, paneId: paneId);

      await adapter.setConfigOption('thought_level', 'high');

      expect(transport.sentLines, contains('/effort high'));
      final effortOpt = adapter.options.firstWhere((o) => o.id == 'thought_level') as SelectConfigOption;
      expect(effortOpt.value, 'high');
    });

    test('setConfigOption effortless sends /effortless command to pane and updates state', () async {
      final adapter = DeskNativeConfigAdapter(machine: machine, paneId: paneId);

      await adapter.setConfigOption('effortless', 'auto');

      expect(transport.sentLines, contains('/effortless auto'));
      final effortlessOpt = adapter.options.firstWhere((o) => o.id == 'effortless') as SelectConfigOption;
      expect(effortlessOpt.value, 'auto');
    });

    test('merges pinned models from model bar into model choices', () {
      final adapter = DeskNativeConfigAdapter(machine: machine, paneId: paneId);
      adapter.setPinnedModels(['minimax-m2.5', 'gpt-6-astra', 'argon']);

      final modelOpt = adapter.options.firstWhere((o) => o.id == 'model') as SelectConfigOption;
      final choiceValues = modelOpt.choices.map((c) => c.value).toList();
      expect(choiceValues, containsAll(['minimax-m2.5', 'gpt-6-astra', 'argon']));
    });
  });
}
