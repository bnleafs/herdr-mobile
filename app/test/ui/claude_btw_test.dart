import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/models/slash_command.dart';
import 'package:herdr_mobile/data/repositories/slash_catalog.dart';
import 'package:herdr_mobile/fork/aside/aside_sheet.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';

import '../support/fake_agent_session.dart';
import '../support/fake_fs.dart';
import '../support/files_support.dart';

TextField _composerField(WidgetTester tester) => tester.widget<TextField>(find.byType(TextField).last);

Future<void> _pumpScreen(WidgetTester tester, FakeAgentSession session, {Size size = const Size(412, 892)}) async {
  tester.view.physicalSize = size * 2;
  tester.view.devicePixelRatio = 2;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: AppTheme.light(),
      home: AgentSessionScreen(key: ObjectKey(session), session: session),
    ),
  );
  await tester.pump(const Duration(milliseconds: 100));
}

void main() {
  group('Claude /btw command palette catalog', () {
    test('builtInSlashCommands lists btw for Claude with question hint and not for other agents', () {
      final claudeCommands = builtInSlashCommands['claude']!;
      final btw = claudeCommands.where((c) => c.name == 'btw').firstOrNull;
      expect(btw, isNotNull);
      expect(btw!.hint, 'question');
      expect(btw.description, 'Ask a quick side question without interrupting current work');
      expect(btw.source, SlashSource.builtIn);

      final codexCommands = builtInSlashCommands['codex']!;
      expect(codexCommands.any((c) => c.name == 'btw'), isFalse);

      final opencodeCommands = builtInSlashCommands['opencode']!;
      expect(opencodeCommands.any((c) => c.name == 'btw'), isFalse);
    });

    test('SlashCatalog.load includes btw for Claude and omits for other agents', () async {
      final catalog = SlashCatalog(machineWithFiles(FakeFs()).files);
      const cwd = '/home/dev/app';

      final claudeLoaded = await catalog.load(agent: 'claude', cwd: cwd);
      final claudeBtw = claudeLoaded.where((c) => c.name == 'btw').firstOrNull;
      expect(claudeBtw, isNotNull);
      expect(claudeBtw!.hint, 'question');

      final codexLoaded = await catalog.load(agent: 'codex', cwd: cwd);
      expect(codexLoaded.any((c) => c.name == 'btw'), isFalse);
    });
  });

  group('Claude /btw chat view behavior while agent is working', () {
    testWidgets('/btw q bypasses busy gate, clears draft and opens Aside sheet', (tester) async {
      final session = FakeAgentSession(state: stateWith(turnActive: true))
        ..observed = true
        ..paneId = 'p_1';

      await _pumpScreen(tester, session);

      // Aside button exists for Claude observed session
      expect(find.byTooltip('Aside'), findsOneWidget);

      // Typing /btw question while turn is active (working)
      await tester.enterText(find.byType(TextField), '/btw what does flag -c do?');
      await tester.pump();

      // Tap send button
      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.pumpAndSettle();

      // Opens Aside sheet
      expect(find.byType(AsideSheet), findsOneWidget);

      // Not added as a message to the transcript
      final userMessages = session.state.items.where((i) => i is TranscriptMessage && i.role == MessageRole.user);
      expect(userMessages, isEmpty, reason: 'must not add fake user message to chat transcript');
    });

    testWidgets('normal prompt while working is refused by busy gate with toast', (tester) async {
      final session = FakeAgentSession(state: stateWith(turnActive: true))..observed = true;

      await _pumpScreen(tester, session);

      // Normal prompt while working
      await tester.enterText(find.byType(TextField), 'fix the database pool');
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.pump();

      // Nothing sent
      expect(session.sent, isEmpty);
      // Draft preserved
      expect(_composerField(tester).controller!.text, 'fix the database pool');
      // Toast displayed
      expect(find.text('The agent is working. Send it once it is idle'), findsOneWidget);
    });

    testWidgets('bare /btw without question text is refused while working and not sent to pane', (tester) async {
      final session = FakeAgentSession(state: stateWith(turnActive: true))..observed = true;

      await _pumpScreen(tester, session);

      await tester.enterText(find.byType(TextField), '/btw   ');
      await tester.pump();

      await tester.tap(find.byKey(const ValueKey('send')));
      await tester.pump();

      expect(session.sent, isEmpty, reason: 'empty /btw must not dispatch to pane');
      expect(_composerField(tester).controller!.text, '/btw   ');
      expect(find.text('The agent is working. Send it once it is idle'), findsOneWidget);
    });

    testWidgets('Aside button shows only for Claude panes', (tester) async {
      final claudeSession = FakeAgentSession(state: stateWith(turnActive: true))
        ..observed = true
        ..paneId = 'p_1';

      await _pumpScreen(tester, claudeSession);
      expect(find.byTooltip('Aside'), findsOneWidget);

      // Tapping Aside button opens AsideSheet
      await tester.tap(find.byTooltip('Aside'));
      await tester.pumpAndSettle();
      expect(find.byType(AsideSheet), findsOneWidget);
    });

    testWidgets('ACP session behavior is unchanged (no side-question bypass, Stop button displayed, no Aside button)', (
      tester,
    ) async {
      final session = FakeAgentSession(state: stateWith(turnActive: true)); // observed == false

      await _pumpScreen(tester, session);

      // Stop button shown while working in ACP
      expect(find.byIcon(HerdrIcons.stopMark), findsOneWidget);
      // Aside button absent for non-observed ACP
      expect(find.byTooltip('Aside'), findsNothing);

      await tester.enterText(find.byType(TextField), '/btw ACP question');
      await tester.pump();

      // Keyboard send does not dispatch
      await tester.testTextInput.receiveAction(TextInputAction.send);
      await tester.pump();
      expect(session.sent, isEmpty);

      // Tap stop mark triggers cancel
      await tester.pump(Dwell.tapGuard);
      await tester.tap(find.byIcon(HerdrIcons.stopMark));
      await tester.pump(const Duration(milliseconds: 50));
      expect(session.cancelCount, 1);
    });
  });
}
