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

    test('initializes model, effort, and effortless options without guessed values', () {
      final adapter = DeskNativeConfigAdapter(machine: machine, paneId: paneId);

      final options = adapter.options;
      expect(options.length, 3);

      // Nothing observed or chosen yet: no built-in model list and no guessed model.
      final modelOpt = options.firstWhere((o) => o.id == 'model') as SelectConfigOption;
      expect(modelOpt.category, 'model');
      expect(modelOpt.name, 'Model');
      expect(modelOpt.value, isEmpty);
      expect(modelOpt.choices, isEmpty);

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

    test('E04_onObservedEffort shows the observed effort', () {
      final adapter = DeskNativeConfigAdapter(machine: machine, paneId: paneId);

      (adapter as dynamic).onObservedEffort('xhigh');

      final effortOpt = adapter.options.firstWhere((o) => o.id == 'thought_level') as SelectConfigOption;
      expect(effortOpt.value, 'xhigh');
    });

    test('E05_new adapter Model and Effort carry an empty value', () {
      final adapter = DeskNativeConfigAdapter(machine: machine, paneId: paneId);

      final modelOpt = adapter.options.firstWhere((o) => o.id == 'model') as SelectConfigOption;
      final effortOpt = adapter.options.firstWhere((o) => o.id == 'thought_level') as SelectConfigOption;
      expect(modelOpt.value, isEmpty);
      expect(effortOpt.value, isEmpty);
    });

    test('E06_effort choices are low medium high xhigh max in order', () {
      final adapter = DeskNativeConfigAdapter(machine: machine, paneId: paneId);

      final effortOpt = adapter.options.firstWhere((o) => o.id == 'thought_level') as SelectConfigOption;
      expect([for (final c in effortOpt.choices) c.value], ['low', 'medium', 'high', 'xhigh', 'max']);
    });

    test('E07_no builtin fallback models before the model bar loads', () {
      final adapter = DeskNativeConfigAdapter(machine: machine, paneId: paneId);

      final before = adapter.options.firstWhere((o) => o.id == 'model') as SelectConfigOption;
      expect([for (final c in before.choices) c.value], isEmpty);

      adapter.onObservedModel('claude-opus-5-5');
      final after = adapter.options.firstWhere((o) => o.id == 'model') as SelectConfigOption;
      expect([for (final c in after.choices) c.value], ['claude-opus-5-5']);
    });

    test('E08_choosing a model sends slash-model and shows that id only', () async {
      final adapter = DeskNativeConfigAdapter(machine: machine, paneId: paneId);

      await adapter.setConfigOption('model', 'claude-opus-5-5');

      expect(transport.sentLines, contains('/model claude-opus-5-5'));
      final modelOpt = adapter.options.firstWhere((o) => o.id == 'model') as SelectConfigOption;
      expect(modelOpt.value, 'claude-opus-5-5');
      expect([for (final c in modelOpt.choices) c.value], ['claude-opus-5-5']);
    });

    test('E09_choosing an effort sends slash-effort and shows that level', () async {
      final adapter = DeskNativeConfigAdapter(machine: machine, paneId: paneId);

      await adapter.setConfigOption('thought_level', 'xhigh');

      expect(transport.sentLines, contains('/effort xhigh'));
      final effortOpt = adapter.options.firstWhere((o) => o.id == 'thought_level') as SelectConfigOption;
      expect(effortOpt.value, 'xhigh');
      expect([for (final c in effortOpt.choices) c.value], ['low', 'medium', 'high', 'xhigh', 'max']);
    });
  });
}
