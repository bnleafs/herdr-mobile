import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/fork/model_bar/model_bar_client.dart';
import 'package:herdr_mobile/fork/model_bar/model_bar_models.dart';

import '../support/fake_exec.dart';
import '../support/fake_fs.dart';
import '../support/fake_transport.dart';

void main() {
  group('ReadyModel', () {
    test('parses from valid JSON from /v1/models/ready', () {
      final json = {
        'id': 'argon',
        'alias': 'gemini-4-argon',
        'provider': 'google',
        'upstream': 'cliproxy',
        'tier': 'high',
        'configuredInUpstream': true,
        'inCooldown': false,
        'ready': true,
      };

      final model = ReadyModel.fromJson(json);
      expect(model.id, 'argon');
      expect(model.alias, 'gemini-4-argon');
      expect(model.provider, 'google');
      expect(model.tier, 'high');
      expect(model.configuredInUpstream, isTrue);
      expect(model.ready, isTrue);
      expect(model.hasDistinctAlias, isTrue);
    });

    test('handles missing optional fields and identical alias', () {
      final json = {'id': 'haiku', 'alias': 'haiku', 'ready': false};

      final model = ReadyModel.fromJson(json);
      expect(model.id, 'haiku');
      expect(model.alias, 'haiku');
      expect(model.ready, isFalse);
      expect(model.configuredInUpstream, isFalse);
      expect(model.tier, isNull);
      expect(model.hasDistinctAlias, isFalse);
    });
  });

  group('ModelBarConfig', () {
    test('parses valid config JSON', () {
      final json = {
        'pinned': ['argon', 'flash'],
        'more': ['codex'],
      };

      final config = ModelBarConfig.fromJson(json);
      expect(config.pinned, ['argon', 'flash']);
      expect(config.more, ['codex']);
      expect(config.isPinned('argon'), isTrue);
      expect(config.isPinned('codex'), isFalse);
      expect(config.isPinned('unknown'), isFalse);
    });

    test('serializes to exact JSON structure', () {
      const config = ModelBarConfig(pinned: ['argon'], more: ['flash', 'codex']);

      expect(config.toJson(), {
        'pinned': ['argon'],
        'more': ['flash', 'codex'],
      });
    });

    test('withToggled flips pinned state deterministically', () {
      const initial = ModelBarConfig(pinned: ['argon'], more: ['flash']);

      // Star 'flash' -> becomes pinned, removed from more
      final starred = initial.withToggled('flash');
      expect(starred.pinned, ['argon', 'flash']);
      expect(starred.more, isEmpty);
      expect(starred.isPinned('flash'), isTrue);

      // Unstar 'argon' -> removed from pinned, added to more
      final unstarred = starred.withToggled('argon');
      expect(unstarred.pinned, ['flash']);
      expect(unstarred.more, ['argon']);
      expect(unstarred.isPinned('argon'), isFalse);
    });

    test('validates valid JSON without error', () {
      final valid = {
        'pinned': ['opus', 'sonnet'],
        'more': ['haiku'],
      };

      expect(() => validateModelBarJson(valid), returnsNormally);
      final config = parseAndValidateModelBarJson(valid);
      expect(config.pinned, ['opus', 'sonnet']);
    });

    test('rejects unknown fields (server parity)', () {
      final invalid = {
        'pinned': ['argon'],
        'more': [],
        'unexpected': true,
      };

      expect(
        () => validateModelBarJson(invalid),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            contains("unknown field 'unexpected' is not permitted"),
          ),
        ),
      );
    });

    test('rejects missing or non-string array fields', () {
      expect(() => validateModelBarJson({'pinned': 'not an array', 'more': []}), throwsA(isA<FormatException>()));
      expect(
        () => validateModelBarJson({
          'pinned': [],
          'more': [123],
        }),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => validateModelBarJson({
          'pinned': ['  '],
          'more': [],
        }),
        throwsA(isA<FormatException>()),
      );
    });
  });

  group('ModelBarClient', () {
    late FakeTransport transport;
    late MachineConnection machine;
    late ModelBarClient client;

    setUp(() {
      transport = FakeTransport();
      machine = MachineConnection(
        profile: const MachineProfile(id: 'm1', label: 'box1', host: 'h1', username: 'u1'),
        api: HerdrApi(transport, machineId: 'm1'),
        backoff: (_) => const Duration(hours: 1),
      );
      client = const ModelBarClient();
    });

    test('fetchReadyModels executes curl and parses models list', () async {
      transport.onExec = (cmd) async {
        expect(cmd, contains('/v1/models/ready'));
        return FakeExecChannel.run(
          stdout: [
            jsonEncode({
              'object': 'readiness_list',
              'models': [
                {'id': 'argon', 'alias': 'gemini-4-argon', 'ready': true},
                {'id': 'flash', 'alias': 'gemini-flash', 'ready': true},
              ],
            }),
          ],
          code: 0,
        );
      };

      final models = await client.fetchReadyModels(machine);
      expect(models.length, 2);
      expect(models[0].id, 'argon');
      expect(models[1].id, 'flash');
    });

    test('fetchConfig executes curl and parses ModelBarConfig', () async {
      transport.onExec = (cmd) async {
        expect(cmd, contains('/v1/model-bar'));
        return FakeExecChannel.run(
          stdout: [
            jsonEncode({
              'pinned': ['argon'],
              'more': ['flash'],
            }),
          ],
          code: 0,
        );
      };

      final config = await client.fetchConfig(machine);
      expect(config.pinned, ['argon']);
      expect(config.more, ['flash']);
    });

    test('saveConfig executes PUT curl and validates server return', () async {
      transport.onExec = (cmd) async {
        expect(cmd, contains('PUT'));
        expect(cmd, contains('/v1/model-bar'));
        return FakeExecChannel.run(
          stdout: [
            jsonEncode({
              'ok': true,
              'pinned': ['argon', 'codex'],
              'more': [],
            }),
          ],
          code: 0,
        );
      };

      final saved = await client.saveConfig(machine, const ModelBarConfig(pinned: ['argon', 'codex'], more: []));
      expect(saved.pinned, ['argon', 'codex']);
    });

    test('saveConfig throws ModelBarException when server rejects or curl fails', () async {
      transport.onExec = (cmd) async {
        return FakeExecChannel.run(
          stdout: [
            jsonEncode({'error': 'validation_error', 'reason': 'unknown field'}),
          ],
          code: 1,
        );
      };

      expect(
        () => client.saveConfig(machine, const ModelBarConfig(pinned: ['invalid'], more: [])),
        throwsA(isA<ModelBarException>()),
      );
    });

    test('fetchConfig falls back to reading ~/.config/effortless/model-bar.json when exec fails', () async {
      // openExec fails
      transport.onExec = (cmd) => Future.error(const HerdrTransportException('exec failed'));
      // FS provides file
      final fs = FakeFs(home: '/home/u1');
      transport.fs = fs;
      fs.nodes['/home/u1/.config/effortless/model-bar.json'] = FakeNode.file(
        Uint8List.fromList(
          utf8.encode(
            jsonEncode({
              'pinned': ['fallback-model'],
              'more': <String>[],
            }),
          ),
        ),
      );

      final config = await client.fetchConfig(machine);
      expect(config.pinned, ['fallback-model']);
    });

    test('fetchConfig fallback returns empty config when file does not exist', () async {
      transport.onExec = (cmd) => Future.error(const HerdrTransportException('exec failed'));
      final fs = FakeFs(home: '/home/u1');
      transport.fs = fs;

      final config = await client.fetchConfig(machine);
      expect(config.pinned, isEmpty);
      expect(config.more, isEmpty);
    });
  });
}
