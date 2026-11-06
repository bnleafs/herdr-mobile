import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/slash_command.dart';
import 'package:herdr_mobile/data/repositories/command_source.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/composer/command_model.dart';
import 'package:herdr_mobile/ui/features/composer/command_palette.dart';
import 'package:herdr_mobile/ui/features/composer/unknown_command.dart';

class _FakeSource extends ChangeNotifier implements CommandSource {
  _FakeSource()
    : commands = const [
        SlashCommand('pony', 'Lazy senior dev mode', SlashSource.project),
        SlashCommand('review', 'Review pull request', SlashSource.project),
        SlashCommand('compact', 'Compact context', SlashSource.builtIn),
        SlashCommand('skill', 'Codex skill', SlashSource.project, trigger: r'$'),
      ];

  @override
  final String? agent = 'claude';

  @override
  final List<SlashCommand> commands;

  int loadedCount = 0;

  @override
  void ensureLoaded() {
    loadedCount++;
  }
}

void main() {
  group('commandAt', () {
    test('returns null for non-collapsed selection', () {
      const v1 = TextEditingValue(text: '/pony', selection: TextSelection(baseOffset: 0, extentOffset: 3));
      expect(commandAt(v1), isNull);
    });

    test('returns null for words not starting with slash or dollar', () {
      const v1 = TextEditingValue(text: 'a/b', selection: TextSelection.collapsed(offset: 3));
      expect(commandAt(v1), isNull);

      const v2 = TextEditingValue(text: 'https://example.com/foo', selection: TextSelection.collapsed(offset: 23));
      expect(commandAt(v2), isNull);

      const v3 = TextEditingValue(text: '~/dir', selection: TextSelection.collapsed(offset: 5));
      expect(commandAt(v3), isNull);

      const v4 = TextEditingValue(text: './x', selection: TextSelection.collapsed(offset: 3));
      expect(commandAt(v4), isNull);
    });

    test('returns null when caret is not touching slash word', () {
      const v = TextEditingValue(text: 'check /pony now', selection: TextSelection.collapsed(offset: 2));
      expect(commandAt(v), isNull);
    });

    test('returns null when caret is after trailing space', () {
      const v = TextEditingValue(text: 'hello / ', selection: TextSelection.collapsed(offset: 8));
      expect(commandAt(v), isNull);
    });

    test('returns CommandToken for slash at draft start', () {
      const v0 = TextEditingValue(text: '/pony', selection: TextSelection.collapsed(offset: 0));
      expect(commandAt(v0), const CommandToken(start: 0, end: 5, text: '/pony'));

      const v5 = TextEditingValue(text: '/pony', selection: TextSelection.collapsed(offset: 5));
      expect(commandAt(v5), const CommandToken(start: 0, end: 5, text: '/pony'));
    });

    test('returns CommandToken for slash or dollar mid-draft', () {
      const vSlash = TextEditingValue(text: 'hello /po world', selection: TextSelection.collapsed(offset: 9));
      expect(commandAt(vSlash), const CommandToken(start: 6, end: 9, text: '/po'));

      const vDollar = TextEditingValue(text: r'run $sk now', selection: TextSelection.collapsed(offset: 7));
      expect(commandAt(vDollar), const CommandToken(start: 4, end: 7, text: r'$sk'));
    });
  });

  group('CommandPalette anywhere in draft', () {
    late _FakeSource source;
    late CommandPaletteModel model;
    late TextEditingController input;
    late FocusNode focus;
    final picked = <SlashCommand>[];

    setUp(() {
      source = _FakeSource();
      model = CommandPaletteModel(source: source);
      input = TextEditingController();
      focus = FocusNode();
      picked.clear();
    });

    tearDown(() {
      input.dispose();
      model.dispose();
      source.dispose();
      focus.dispose();
    });

    Future<void> pumpTestWidget(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.dark(),
          home: Scaffold(
            body: Column(
              children: [
                CommandPalette(
                  input: input,
                  model: model,
                  onPick: (c) {
                    picked.add(c);
                    fillCommand(input, focus, c);
                  },
                ),
                TextField(controller: input, focusNode: focus),
              ],
            ),
          ),
        ),
      );
    }

    testWidgets('mid-draft / after text opens the palette and lists commands', (tester) async {
      await pumpTestWidget(tester);

      input.value = const TextEditingValue(text: 'hello /', selection: TextSelection.collapsed(offset: 7));
      await tester.pump();

      expect(find.text('/pony', findRichText: true), findsOneWidget);
      expect(find.text('/review', findRichText: true), findsOneWidget);
      expect(find.text('/compact', findRichText: true), findsOneWidget);
    });

    testWidgets('typing /po mid-draft filters the list', (tester) async {
      await pumpTestWidget(tester);

      input.value = const TextEditingValue(text: 'hello /po', selection: TextSelection.collapsed(offset: 9));
      await tester.pump();

      expect(find.text('/pony', findRichText: true), findsOneWidget);
      expect(find.text('/review', findRichText: true), findsNothing);
      expect(find.text('/compact', findRichText: true), findsNothing);
    });

    testWidgets('picking replaces only the token and keeps text before and after', (tester) async {
      await pumpTestWidget(tester);

      input.value = const TextEditingValue(text: 'hello /po world', selection: TextSelection.collapsed(offset: 9));
      await tester.pump();

      await tester.tap(find.text('/pony', findRichText: true));
      await tester.pump();

      expect(input.text, 'hello /pony  world');
      expect(input.selection.baseOffset, 12);
      expect(picked.single.name, 'pony');
    });

    testWidgets('works in landscape orientation', (tester) async {
      tester.view.physicalSize = const Size(800, 400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
      });

      await pumpTestWidget(tester);

      input.value = const TextEditingValue(
        text: 'sentence with /po mid-line',
        selection: TextSelection.collapsed(offset: 17),
      );
      await tester.pump();

      expect(find.text('/pony', findRichText: true), findsOneWidget);
    });

    testWidgets('leading command behaviour is unchanged', (tester) async {
      await pumpTestWidget(tester);

      input.value = const TextEditingValue(text: '/po', selection: TextSelection.collapsed(offset: 3));
      await tester.pump();

      expect(find.text('/pony', findRichText: true), findsOneWidget);

      await tester.tap(find.text('/pony', findRichText: true));
      await tester.pump();

      expect(input.text, '/pony ');
      expect(input.selection.baseOffset, 6);
    });

    testWidgets('a/b and a URL do not open palette', (tester) async {
      await pumpTestWidget(tester);

      input.value = const TextEditingValue(text: 'a/b', selection: TextSelection.collapsed(offset: 3));
      await tester.pump();
      expect(find.byType(ListView), findsNothing);

      input.value = const TextEditingValue(
        text: 'https://example.com/foo',
        selection: TextSelection.collapsed(offset: 23),
      );
      await tester.pump();
      expect(find.byType(ListView), findsNothing);

      input.value = const TextEditingValue(text: 'see /etc/hosts', selection: TextSelection.collapsed(offset: 14));
      await tester.pump();
      expect(find.byType(ListView), findsNothing);
    });
  });

  group('UnknownCommandGuard with mid-sentence slashes', () {
    test('ensureLoaded triggers when commandAt matches mid-draft or leading', () {
      final source = _FakeSource();
      final model = CommandPaletteModel(source: source);

      void checkInput(TextEditingValue v) {
        if (commandAt(v) != null) model.ensureLoaded();
      }

      checkInput(const TextEditingValue(text: 'just words', selection: TextSelection.collapsed(offset: 10)));
      expect(source.loadedCount, 0);

      checkInput(const TextEditingValue(text: 'hello /po', selection: TextSelection.collapsed(offset: 9)));
      expect(source.loadedCount, 1);

      checkInput(const TextEditingValue(text: '/po', selection: TextSelection.collapsed(offset: 3)));
      expect(source.loadedCount, 2);

      model.dispose();
      source.dispose();
    });

    test('ignores mid-sentence slashes and paths', () {
      final source = _FakeSource();
      final model = CommandPaletteModel(source: source);
      final input = TextEditingController();
      final guard = UnknownCommandGuard(input: input, model: model);

      expect(guard.holds('see /etc/hosts'), isFalse);
      expect(guard.word, isNull);

      expect(guard.holds('run /unknown mid-sentence'), isFalse);
      expect(guard.word, isNull);

      expect(guard.holds('/unknown'), isTrue);
      expect(guard.word, 'unknown');

      guard.dispose();
      input.dispose();
      model.dispose();
      source.dispose();
    });
  });
}
