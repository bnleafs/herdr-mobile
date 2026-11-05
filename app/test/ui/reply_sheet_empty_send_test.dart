// The reply sheet's text composer uses bounded multiline newline editing:
// Enter/Shift+Enter/Ctrl/Cmd+Enter and IME actions (send, done, newline) do not
// dispatch and keep the draft. Only the explicit app Send button dispatches.
// Bare Enter on an empty field via keyboard is never sent; explicit raw Enter
// key button sends guarded bare Enter.
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/pane_preview.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/agents/reply_sheet.dart';
import 'package:herdr_mobile/ui/features/composer/composer_frame.dart';

import '../support/shot.dart' show loadAppFonts;
import 'board_support.dart';
import 'ui_harness.dart';

({MachineProfile profile, Map<String, dynamic> snapshot}) _machine() => (
  profile: const MachineProfile(id: 'a', label: 'box-a', host: 'a.example', username: 'dev'),
  snapshot: snapshotWith([(id: 'w1:p1', ws: 'w1', agent: 'claude', status: 'blocked')], title: (_) => 'task 1'),
);

const _prompt = PromptInfo(
  question: 'Do you want to proceed?',
  replies: [
    QuickReply(label: '1. Yes', keys: ['1', 'enter']),
    QuickReply(label: '2. No', keys: ['2', 'enter']),
  ],
);

Future<BoardHarness> _sheet(WidgetTester tester, {PromptInfo? prompt}) async {
  final h = await BoardHarness.create([_machine()]);
  h.previews.set('a/w1:p1', const ['…context…'], prompt: prompt);
  await pumpBoard(tester, h, width: 360, height: 2400);
  await tester.tap(replyTo('task 1'), warnIfMissed: false);
  await tester.pump();
  return h;
}

List<Object?> _sentKeys(BoardHarness h) => [
  for (final (m, p) in h.transports['a']!.calls)
    if (m == 'pane.send_keys') p['keys'],
];

List<Map<String, dynamic>> _sentInputs(BoardHarness h) => [
  for (final (m, p) in h.transports['a']!.calls)
    if (m == 'pane.send_input') p,
];

Future<void> _focusComposer(WidgetTester tester) async {
  await tester.tap(find.descendant(of: find.byType(ReplySheet), matching: find.byType(TextField)), warnIfMissed: false);
  await tester.pump();
}

Future<void> _imeActions(WidgetTester tester) async {
  await _focusComposer(tester);
  await tester.testTextInput.receiveAction(TextInputAction.send);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.testTextInput.receiveAction(TextInputAction.newline);
  await tester.pump();
}

Future<void> _hardwareKeys(WidgetTester tester) async {
  await _focusComposer(tester);
  // Enter
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pump();
  // Shift + Enter
  await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
  await tester.pump();
  // Ctrl + Enter
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pump();
  // Cmd/Meta + Enter
  await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
  await tester.pump();
}

void main() {
  setUpAll(loadAppFonts);

  testWidgets('Send on an empty or whitespace field dispatches nothing via keyboard or hardware keys', (tester) async {
    final h = await _sheet(tester, prompt: _prompt);
    await tester.pump(Dwell.tapGuard * 2);

    // 1. Empty field: keyboard actions and hardware keys do not dispatch
    await _imeActions(tester);
    await _hardwareKeys(tester);
    expect(_sentKeys(h), isEmpty, reason: 'empty keyboard actions must never dispatch bare Enter');
    expect(_sentInputs(h), isEmpty);

    // App Send button is disabled (ready == false)
    final sendBtn = find.descendant(of: find.byType(ReplySheet), matching: find.byType(ComposerRoundButton));
    expect(sendBtn, findsOneWidget);
    expect(tester.widget<ComposerRoundButton>(sendBtn).ready, isFalse);

    // Tapping disabled Send button does nothing
    await tester.tap(sendBtn, warnIfMissed: false);
    await tester.pump();
    expect(_sentKeys(h), isEmpty);
    expect(_sentInputs(h), isEmpty);

    // 2. Whitespace-only field: same zero dispatch
    final field = find.descendant(of: find.byType(ReplySheet), matching: find.byType(TextField));
    await tester.enterText(field, '   \n  ');
    await tester.pump();
    expect(tester.widget<ComposerRoundButton>(sendBtn).ready, isFalse);

    await _imeActions(tester);
    await _hardwareKeys(tester);
    expect(_sentKeys(h), isEmpty);
    expect(_sentInputs(h), isEmpty);

    await tester.pump(const Duration(seconds: 5));
    await teardownBoard(tester, h);
  });

  testWidgets(
    'with nothing asked, keyboard actions on empty field send nothing; explicit raw Enter key sends bare Enter once settled',
    (tester) async {
      final h = await _sheet(tester);

      // Keyboard actions on empty field send NOTHING (intentional behavior update: bare Enter is never sent via keyboard)
      await _imeActions(tester);
      await _hardwareKeys(tester);
      expect(_sentKeys(h), isEmpty, reason: 'keyboard enter on empty field must not send bare Enter');

      // Just opened: explicit raw Enter button is guarded by tapGuard
      final rawEnter = find.descendant(of: find.byType(ReplySheet), matching: find.bySemanticsLabel('Enter'));
      expect(rawEnter, findsOneWidget);
      await tester.tap(rawEnter, warnIfMissed: false);
      await tester.pump();
      expect(_sentKeys(h), isEmpty, reason: 'guard holds raw Enter until settled');

      // Settled: explicit raw Enter button sends ['enter']
      await tester.pump(Dwell.tapGuard * 2);
      await tester.tap(rawEnter, warnIfMissed: false);
      await tester.pump();
      expect(_sentKeys(h), [
        ['enter'],
      ]);
      await tester.pump(const Duration(seconds: 5));
      await teardownBoard(tester, h);
    },
  );

  testWidgets('multiline typed text dispatches exclusively via app Send button, preserving line breaks', (
    tester,
  ) async {
    final h = await _sheet(tester, prompt: _prompt);
    await tester.pump(Dwell.tapGuard * 2);

    final field = find.descendant(of: find.byType(ReplySheet), matching: find.byType(TextField));
    await tester.enterText(field, 'first line\nsecond line');
    await tester.pump();

    // Keyboard actions and hardware keys do NOT send
    await _imeActions(tester);
    await _hardwareKeys(tester);
    expect(_sentInputs(h), isEmpty, reason: 'keyboard actions must not dispatch typed line');
    expect(tester.widget<TextField>(field).controller!.text, 'first line\nsecond line', reason: 'draft preserved');

    // Focus blur does not dispatch
    tester.widget<TextField>(field).focusNode?.unfocus();
    await tester.pump();
    expect(_sentInputs(h), isEmpty);

    // App Send button is ready and dispatches multiline payload
    final sendBtn = find.descendant(of: find.byType(ReplySheet), matching: find.byType(ComposerRoundButton));
    expect(tester.widget<ComposerRoundButton>(sendBtn).ready, isTrue);

    await tester.tap(sendBtn, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 50));

    expect(_sentInputs(h), [
      {
        'pane_id': 'w1:p1',
        'text': 'first line\nsecond line',
        'keys': ['enter'],
      },
    ]);
    expect(tester.widget<TextField>(field).controller!.text, isEmpty, reason: 'field cleared on send');
    await tester.pump(const Duration(seconds: 5));
    await teardownBoard(tester, h);
  });

  testWidgets('active composing text is included when user taps Send and double-tap deduplicates', (tester) async {
    final h = await _sheet(tester, prompt: _prompt);
    await tester.pump(Dwell.tapGuard * 2);

    await _focusComposer(tester);

    // Active composing region included
    tester.testTextInput.updateEditingValue(
      const TextEditingValue(text: 'step 1\nstep 2 composing', composing: TextRange(start: 14, end: 23)),
    );
    await tester.pump();

    final sendBtn = find.descendant(of: find.byType(ReplySheet), matching: find.byType(ComposerRoundButton));
    expect(tester.widget<ComposerRoundButton>(sendBtn).ready, isTrue);

    // Double-tap Send
    await tester.tap(sendBtn, warnIfMissed: false);
    await tester.pump();
    await tester.tap(sendBtn, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 50));

    expect(_sentInputs(h), hasLength(1));
    expect(_sentInputs(h).single['text'], 'step 1\nstep 2 composing');
    await tester.pump(const Duration(seconds: 5));
    await teardownBoard(tester, h);
  });

  testWidgets('offline agent allows drafting in memory, gates Send, and reconnect dispatches on explicit Send once', (
    tester,
  ) async {
    final h = await _sheet(tester);
    await tester.pump(Dwell.tapGuard * 2);

    final field = find.descendant(of: find.byType(ReplySheet), matching: find.byType(TextField));
    final sendBtn = find.descendant(of: find.byType(ReplySheet), matching: find.byType(ComposerRoundButton));

    // Suspend connection -> machine is offline / reconnecting
    h.fleet.connection('a')!.suspend();
    await tester.pump();

    // Draft typing in memory is preserved
    await tester.enterText(field, 'draft command\nsecond line');
    await tester.pump();
    expect(find.text('draft command\nsecond line'), findsOneWidget);

    // Send button is not ready while offline
    expect(tester.widget<ComposerRoundButton>(sendBtn).ready, isFalse);

    // Tapping Send or keyboard actions dispatches nothing
    await tester.tap(sendBtn, warnIfMissed: false);
    await _imeActions(tester);
    await _hardwareKeys(tester);
    expect(_sentInputs(h), isEmpty);
    expect(find.text('draft command\nsecond line'), findsOneWidget);

    // Reconnecting does NOT auto-replay
    h.fleet.connection('a')!.reconnect();
    await tester.pump();
    expect(_sentInputs(h), isEmpty);
    expect(find.text('draft command\nsecond line'), findsOneWidget);

    // Explicit manual Send dispatches exactly once
    expect(tester.widget<ComposerRoundButton>(sendBtn).ready, isTrue);
    await tester.tap(sendBtn, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 50));

    expect(_sentInputs(h), hasLength(1));
    expect(_sentInputs(h).single['text'], 'draft command\nsecond line');
    await tester.pump(const Duration(seconds: 5));
    await teardownBoard(tester, h);
  });

  testWidgets('blocked question prompt choices cannot be bypassed by composer keyboard events', (tester) async {
    final h = await _sheet(tester, prompt: _prompt);
    await tester.pump(Dwell.tapGuard * 2);

    // Prompt question is displayed with chips in the reply sheet
    expect(
      find.descendant(of: find.byType(ReplySheet), matching: find.text('Do you want to proceed?')),
      findsOneWidget,
    );
    expect(find.descendant(of: find.byType(ReplySheet), matching: find.text('1. Yes')), findsOneWidget);

    // Keyboard events on empty composer cannot bypass or trigger bare Enter
    await _imeActions(tester);
    await _hardwareKeys(tester);
    expect(_sentKeys(h), isEmpty);

    // Explicitly choosing a question chip dispatches the chosen reply
    final chip = find.descendant(of: find.byType(ReplySheet), matching: find.text('1. Yes'));
    await tester.tap(chip, warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 50));

    expect(_sentKeys(h), [
      ['1', 'enter'],
    ]);
    await tester.pump(const Duration(seconds: 5));
    await teardownBoard(tester, h);
  });
}
