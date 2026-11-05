import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart' show AgentLink;
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/fork/continuity_presentation.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/agents/agents_grouping.dart';
import 'package:herdr_mobile/ui/features/composer/composer_frame.dart';
import 'package:herdr_mobile/ui/features/machines/machines_screen.dart';
import 'package:herdr_mobile/ui/features/pane/pane_screen.dart';
import 'package:herdr_mobile/ui/features/pane/quick_keys.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../support/fake_agent_session.dart';
import '../support/shot.dart' show loadAppFonts;
import '../ui/ui_harness.dart';

MachineProfile _m(String id, String label, {bool enabled = true, String host = '10.0.0.1'}) =>
    MachineProfile(id: id, label: label, host: host, username: 'dev', enabled: enabled);

List<Pane> _agents(int count, {int blocked = 0}) => [
  for (var i = 1; i <= count; i++)
    (id: 'w1:p$i', ws: 'w1', agent: 'claude', status: i <= blocked ? 'blocked' : 'working'),
];

Future<void> _pump(WidgetTester tester, Widget home, {required UiHarness harness}) async {
  tester.view
    ..physicalSize = const Size(360, 740) * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: harness.terminalSettings),
        ChangeNotifierProvider.value(value: harness.appSettings),
        ChangeNotifierProvider.value(value: harness.machines),
        ChangeNotifierProvider.value(value: harness.fleet),
        ChangeNotifierProvider.value(value: harness.agentScreens),
        Provider<PanePreviews>.value(value: harness.previews),
        attentionSetProvider(),
      ],
      child: MaterialApp(theme: AppTheme.dark(), home: home),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

/// Lets async connection work and animations finish.
Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    for (var j = 0; j < 30; j++) {
      await Future<void>.value();
    }
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Future<void> _tearDown(WidgetTester tester, [UiHarness? h]) async {
  await tester.pumpWidget(const SizedBox());
  h?.dispose();
}

Future<void> _pumpSessionScreen(WidgetTester tester, FakeAgentSession session) async {
  tester.view
    ..physicalSize = const Size(412, 892) * 2
    ..devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.dark(),
      home: AgentSessionScreen(key: ObjectKey(session), session: session),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  setUpAll(loadAppFonts);

  group('continuity helper unit behavior', () {
    test('isTransientReconnect returns true only when reconnecting, no error, and retained data present', () async {
      final h = await UiHarness.create([
        (profile: _m('m1', 'box1'), snapshot: snapshotWith(_agents(2))),
        (profile: _m('m2', 'box2'), snapshot: snapshotWith(const [], workspaces: const [])),
      ]);
      addTearDown(h.dispose);

      final c1 = h.fleet.connection('m1')!;
      final c2 = h.fleet.connection('m2')!;

      // Online: false
      expect(c1.state, LinkState.online);
      expect(isTransientReconnect(c1), isFalse);

      // Transient reconnect with retained data: true
      c1.suspend();
      expect(c1.state, LinkState.reconnecting);
      expect(c1.error, isNull);
      expect(isTransientReconnect(c1), isTrue);

      // Reconnect with recorded error: false
      h.transports['m1']!.failure = const HerdrTransportException('dropped');
      c1.reconnect();
      await pumpEventQueue(times: 50);
      expect(c1.error, isNotNull);
      expect(isTransientReconnect(c1), isFalse);

      // Machine with no data reconnecting: false
      c2.suspend();
      expect(c2.state, LinkState.reconnecting);
      expect(isTransientReconnect(c2), isFalse);
    });

    test('machineSubtitleLead formats honest states and avoids false live appearance', () async {
      final h = await UiHarness.create([(profile: _m('m1', 'box1'), snapshot: snapshotWith(_agents(3)))]);
      addTearDown(h.dispose);
      final c = h.fleet.connection('m1')!;

      // Online
      expect(machineSubtitleLead(machine: c, profile: c.profile, agents: 3), '3 agents');
      expect(machineSubtitleLead(machine: c, profile: c.profile, agents: 0), 'No agents');

      // Transient reconnect with retained data
      c.suspend();
      expect(machineSubtitleLead(machine: c, profile: c.profile, agents: 3), '3 agents · Updating');
      expect(machineSubtitleLead(machine: c, profile: c.profile, agents: 0), 'No agents · Updating');

      // Offline
      c.goOffline();
      expect(machineSubtitleLead(machine: c, profile: c.profile, agents: 3), 'Offline');

      // Disabled
      final disabledProfile = c.profile.copyWith(enabled: false);
      expect(machineSubtitleLead(machine: c, profile: disabledProfile, agents: 3), 'Offline · not connecting');
    });
  });

  group('machines list honest retained presentation', () {
    testWidgets('retains known count with honest Updating indicator during transient reconnect', (tester) async {
      final h = await UiHarness.create([(profile: _m('warm', 'box-warm'), snapshot: snapshotWith(_agents(3)))]);

      final c = h.fleet.connection('warm')!;
      c.suspend(); // transient reconnect: state=reconnecting, error=null, snapshot retained
      expect(c.state, LinkState.reconnecting);
      expect(c.error, isNull);

      await _pump(tester, const MachinesScreen(), harness: h);

      expect(find.text('box-warm'), findsOneWidget);
      expect(find.textContaining('3 agents · Updating', findRichText: true), findsOneWidget);
      expect(find.text('Reconnecting…', findRichText: true), findsNothing);
      expect(find.text('3 agents', findRichText: true), findsNothing); // Never looks bare live!
      await _tearDown(tester, h);
    });

    testWidgets('machine with no data shows standard Reconnecting without faked counts', (tester) async {
      final h = await UiHarness.create([
        (profile: _m('empty', 'box-empty'), snapshot: snapshotWith(const [], workspaces: const [])),
      ]);

      final c = h.fleet.connection('empty')!;
      c.suspend();
      expect(c.state, LinkState.reconnecting);

      await _pump(tester, const MachinesScreen(), harness: h);

      expect(find.text('box-empty'), findsOneWidget);
      expect(find.textContaining('Updating', findRichText: true), findsNothing);
      expect(find.textContaining('Reconnecting', findRichText: true), findsOneWidget);
      await _tearDown(tester, h);
    });

    testWidgets('failing machine or auth challenge preserves error panels and stays troubled', (tester) async {
      final h = await UiHarness.create([
        (profile: _m('failing', 'box-failing'), snapshot: snapshotWith(_agents(1))),
        (profile: _m('auth', 'box-auth'), snapshot: snapshotWith(_agents(1))),
      ]);

      h.transports['failing']!.failure = const HerdrTransportException('Connection refused');
      h.fleet.connection('failing')!.reconnect();
      h.transports['auth']!.failure = const HerdrTransportException('Permission denied (publickey).', fatal: true);
      h.fleet.connection('auth')!.reconnect();

      await _pump(tester, const MachinesScreen(), harness: h);
      await _flush(tester);

      expect(find.text('box-failing'), findsOneWidget);
      expect(find.text('box-auth'), findsOneWidget);
      expect(find.textContaining('Needs attention'), findsOneWidget);
      expect(find.text('Permission denied (publickey).'), findsOneWidget);
      expect(find.text('Retry'), findsWidgets);
      await _tearDown(tester, h);
    });
  });

  group('agents grouping troubled classification', () {
    test('transient reconnect machine is excluded from troubled while failing/auth machines stay troubled', () async {
      final h = await UiHarness.create([
        (profile: _m('warm', 'box-warm'), snapshot: snapshotWith(_agents(2))),
        (profile: _m('failing', 'box-failing'), snapshot: snapshotWith(_agents(1))),
        (profile: _m('auth', 'box-auth'), snapshot: snapshotWith(_agents(1))),
      ]);
      addTearDown(h.dispose);

      // warm is suspended transiently with no error
      h.fleet.connection('warm')!.suspend();

      // failing encounters an error
      h.transports['failing']!.failure = const HerdrTransportException('Socket timeout');
      h.fleet.connection('failing')!.reconnect();

      // auth encounters fatal auth exception
      h.transports['auth']!.failure = const HerdrTransportException('SSH key invalid', fatal: true);
      h.fleet.connection('auth')!.reconnect();

      await pumpEventQueue(times: 50);

      final overview = AgentsOverview.of(h.fleet);

      // Warm is NOT in troubled!
      expect(overview.troubled.any((t) => t.machine.profile.id == 'warm'), isFalse);

      // Failing and Auth ARE in troubled with their reasons
      expect(overview.troubled.any((t) => t.machine.profile.id == 'failing'), isTrue);
      expect(overview.troubled.any((t) => t.machine.profile.id == 'auth'), isTrue);

      // Agents from warm machine are still listed in overview.agents
      expect(overview.agents.where((a) => a.machine.profile.id == 'warm'), hasLength(2));
    });
  });

  group('terminal composer offline drafting and send protection', () {
    testWidgets('allows editing draft while disconnected, gates send button, and prevents leakage on enter', (
      tester,
    ) async {
      final h = await UiHarness.create([(profile: _m('box', 'devbox'), snapshot: snapshotWith(_agents(1)))]);

      final c = h.fleet.connection('box')!;
      final transport = h.transports['box']!;
      final paneRef = PaneAgent('box', 'w1:p1');

      // Put machine into suspended/reconnecting state
      c.suspend();
      expect(c.acceptsInput('w1:p1'), isFalse);

      await _pump(tester, PaneScreen(agent: paneRef), harness: h);

      final fieldFinder = find.byType(TextField);
      expect(fieldFinder, findsOneWidget);

      // 1. Text field remains enabled for local drafting in memory!
      expect(tester.widget<TextField>(fieldFinder).enabled, isTrue);

      // 2. Multiline typing with newlines into field works
      await tester.enterText(fieldFinder, 'git status\ngit diff');
      await tester.pump();
      expect(find.text('git status\ngit diff'), findsOneWidget);

      // 3. Send button is disabled (ready == false)
      final sendFinder = find.byWidgetPredicate((w) => w is ComposerRoundButton && w.label == 'Send');
      expect(sendFinder, findsOneWidget);
      expect(tester.widget<ComposerRoundButton>(sendFinder).ready, isFalse);

      // 4. Tapping disabled Send button does nothing, does not clear draft, makes no call
      await tester.tap(sendFinder);
      await tester.pump();
      expect(find.text('git status\ngit diff'), findsOneWidget);
      expect(transport.calls.where((call) => call.$1.startsWith('pane.send')), isEmpty);

      // 5. Keyboard actions (send, done, newline) and hardware key events (Enter, Shift+Enter, Ctrl/Cmd+Enter) do NOT send and do NOT clear draft
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.testTextInput.receiveAction(TextInputAction.newline);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(find.text('git status\ngit diff'), findsOneWidget);
      expect(transport.calls.where((call) => call.$1.startsWith('pane.send')), isEmpty);

      // 6. Focus loss (blur) does not send
      tester.widget<TextField>(fieldFinder).focusNode?.unfocus();
      await tester.pump();
      expect(transport.calls.where((call) => call.$1.startsWith('pane.send')), isEmpty);

      // 7. Restoring live connection does NOT auto-replay pending input
      c.reconnect();
      await _flush(tester);
      expect(c.isLive, isTrue);
      expect(c.acceptsInput('w1:p1'), isTrue);
      await tester.pump();

      // Still no auto-send occurred, multiline draft preserved
      expect(transport.calls.where((call) => call.$1.startsWith('pane.send')), isEmpty);
      expect(find.text('git status\ngit diff'), findsOneWidget);

      // Send button is now ready!
      expect(tester.widget<ComposerRoundButton>(sendFinder).ready, isTrue);

      // 8. Active non-empty composing text is included when user taps Send
      await tester.showKeyboard(fieldFinder);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(text: 'git status\ngit diff\nfinal', composing: TextRange(start: 20, end: 25)),
      );
      await tester.pump();

      // 9. Double tap does not duplicate dispatch
      await tester.tap(sendFinder);
      await tester.pump();
      await tester.tap(sendFinder);
      await _flush(tester);

      // Sent to transport exactly once with exact multiline payload
      final sends = transport.calls.where((call) => call.$1 == 'pane.send_input').toList();
      expect(sends, hasLength(1));
      expect(sends.first.$2['text'], 'git status\ngit diff\nfinal');
      expect(sends.first.$2['pane_id'], 'w1:p1');

      // Field cleared after send
      expect(find.text('git status\ngit diff\nfinal'), findsNothing);
      await _tearDown(tester, h);
    });

    testWidgets('missing or closed pane gates editor', (tester) async {
      final h = await UiHarness.create([(profile: _m('box', 'devbox'), snapshot: snapshotWith(const []))]);

      final paneRef = PaneAgent('box', 'nonexistent:p99');
      await _pump(tester, PaneScreen(agent: paneRef), harness: h);

      final fieldFinder = find.byType(TextField);
      expect(fieldFinder, findsOneWidget);
      expect(tester.widget<TextField>(fieldFinder).enabled, isFalse);
      expect(find.text('Pane closed'), findsOneWidget);
      await _tearDown(tester, h);
    });

    testWidgets('raw terminal QuickKeys Enter retains explicit PTY key semantics without text composition', (
      tester,
    ) async {
      final h = await UiHarness.create([(profile: _m('box', 'devbox'), snapshot: snapshotWith(_agents(1)))]);
      final transport = h.transports['box']!;
      final paneRef = PaneAgent('box', 'w1:p1');

      await _pump(tester, PaneScreen(agent: paneRef), harness: h);

      final field = find.byType(TextField);
      await tester.enterText(field, 'unsent text');
      await tester.pump();

      // Tap raw QuickKeys Enter
      final enterKey = find.descendant(of: find.byType(QuickKeys), matching: find.byIcon(LucideIcons.cornerDownLeft));
      expect(enterKey, findsOneWidget);
      await tester.tap(enterKey);
      await _flush(tester);

      // Raw enter sends pane.send_keys ['enter'], does NOT send the composer text
      expect(transport.calls.any((c) => c.$1 == 'pane.send_keys' && (c.$2['keys'] as List).contains('enter')), isTrue);
      expect(transport.calls.where((c) => c.$1 == 'pane.send_input'), isEmpty);
      // Composer text remains untouched in field
      expect(find.text('unsent text'), findsOneWidget);
      await _tearDown(tester, h);
    });
  });

  group('structured chat composer edit gating', () {
    testWidgets('allows draft typing while reconnecting and disables send until live', (tester) async {
      final session = FakeAgentSession(link: AgentLink.reconnecting);
      await _pumpSessionScreen(tester, session);

      // Reconnecting allows draft composition
      final field = find.byType(TextField);
      expect(tester.widget<TextField>(field).enabled, isTrue);
      expect(find.text('Offline · reconnecting'), findsOneWidget);

      // Send button is not ready
      final send = find.byKey(const ValueKey('send'));
      expect(tester.widget<ComposerRoundButton>(send).ready, isFalse);

      // Type local multiline draft
      await tester.enterText(field, 'Draft instruction for agent\nSecond line');
      await tester.pump();
      expect(find.text('Draft instruction for agent\nSecond line'), findsOneWidget);

      // Keyboard actions (send, done, newline) and hardware key events (Enter, Shift+Enter, Ctrl/Cmd+Enter) do not dispatch
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.testTextInput.receiveAction(TextInputAction.newline);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(session.sent, isEmpty);
      expect(session.sentBlocks, isEmpty);

      // Tapping send does not clear and does not send
      await tester.tap(send);
      await tester.pump();
      expect(find.text('Draft instruction for agent\nSecond line'), findsOneWidget);
      expect(session.sentBlocks, isEmpty);

      // Focus blur does not dispatch
      tester.widget<TextField>(field).focusNode?.unfocus();
      await tester.pump();
      expect(session.sent, isEmpty);

      // Live restores send capability
      session.setLink(AgentLink.live);
      await tester.pump();
      expect(tester.widget<ComposerRoundButton>(send).ready, isTrue);

      // Active composing region included on Send
      await tester.showKeyboard(field);
      tester.testTextInput.updateEditingValue(
        const TextEditingValue(
          text: 'Draft instruction for agent\nSecond line composing',
          composing: TextRange(start: 40, end: 49),
        ),
      );
      await tester.pump();

      // Tap Send once
      await tester.tap(send);
      await tester.pump();
      expect(session.sent, ['Draft instruction for agent\nSecond line composing']);
      expect(tester.widget<TextField>(field).controller!.text, isEmpty);

      // Ended session disables editor as read only
      session.setLink(AgentLink.ended);
      await tester.pump();
      expect(tester.widget<TextField>(field).enabled, isFalse);
      expect(find.text('Session ended · read only'), findsOneWidget);
    });
  });
}
