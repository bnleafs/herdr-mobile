import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/fork/model_bar/model_bar_models.dart';

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
      final json = {
        'id': 'haiku',
        'alias': 'haiku',
        'ready': false,
      };

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
      const config = ModelBarConfig(
        pinned: ['argon'],
        more: ['flash', 'codex'],
      );

      expect(config.toJson(), {
        'pinned': ['argon'],
        'more': ['flash', 'codex'],
      });
    });

    test('withToggled flips pinned state deterministically', () {
      const initial = ModelBarConfig(
        pinned: ['argon'],
        more: ['flash'],
      );

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
        throwsA(isA<FormatException>().having(
          (e) => e.message,
          'message',
          contains("unknown field 'unexpected' is not permitted"),
        )),
      );
    });

    test('rejects missing or non-string array fields', () {
      expect(
        () => validateModelBarJson({'pinned': 'not an array', 'more': []}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => validateModelBarJson({'pinned': [], 'more': [123]}),
        throwsA(isA<FormatException>()),
      );
      expect(
        () => validateModelBarJson({'pinned': ['  '], 'more': []}),
        throwsA(isA<FormatException>()),
      );
    });
  });
}
