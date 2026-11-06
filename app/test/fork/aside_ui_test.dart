import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/fork/aside/aside_models.dart';
import 'package:herdr_mobile/fork/aside/aside_sheet.dart';
import 'package:herdr_mobile/fork/aside/aside_storage.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/render/markdown/markdown.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_agent_session.dart';
import '../support/fake_transport.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeTransport transport;
  late MachineConnection machine;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    transport = FakeTransport();
    machine = MachineConnection(
      profile: const MachineProfile(id: 'm1', label: 'box1', host: 'h1', username: 'u1'),
      api: HerdrApi(transport, machineId: 'm1'),
      backoff: (_) => const Duration(hours: 1),
    );
  });

  Widget pumpSheet({AsideStorage storage = const AsideStorage(), String? initialQuestion}) => MaterialApp(
    theme: AppTheme.light(),
    home: Scaffold(
      body: AsideSheet(
        sessionKey: 's_test',
        paneId: 'p_1',
        machine: machine,
        initialQuestion: initialQuestion,
        storage: storage,
      ),
    ),
  );

  group('Aside sheet UI', () {
    testWidgets('renders existing thread answers using chat markdown renderer', (tester) async {
      final storage = const AsideStorage();
      await storage.recordTurn(
        sessionKey: 's_test',
        turn: AsideTurn(
          id: 't1',
          question: 'what is the codename?',
          answer: 'The codename is **BLUEFINCH**.\n- Fact 1\n- Fact 2',
          timestamp: DateTime.now(),
        ),
      );

      await tester.pumpWidget(pumpSheet(storage: storage));
      await tester.pumpAndSettle();

      // Question rendered
      expect(find.text('what is the codename?'), findsOneWidget);
      // Answer rendered with MdDocumentView
      expect(find.byType(MdDocumentView), findsOneWidget);
      expect(find.textContaining('BLUEFINCH'), findsOneWidget);
      expect(find.textContaining('Fact 1'), findsOneWidget);
    });

    testWidgets('history list shows relative time, turn count, and allows switching threads', (tester) async {
      final storage = const AsideStorage();
      await storage.recordTurn(
        sessionKey: 's_test',
        turn: AsideTurn(
          id: 't1',
          question: 'First thread question',
          answer: 'First answer',
          timestamp: DateTime.now().subtract(const Duration(minutes: 5)),
        ),
      );

      await storage.recordTurn(
        sessionKey: 's_test',
        turn: AsideTurn(
          id: 't2',
          question: 'Second thread question',
          answer: 'Second answer',
          timestamp: DateTime.now(),
        ),
      );

      await tester.pumpWidget(pumpSheet(storage: storage));
      await tester.pumpAndSettle();

      // Active thread is newest (Second thread)
      expect(find.text('Second thread question'), findsOneWidget);

      // Tap history button
      await tester.tap(find.byTooltip('History'));
      await tester.pumpAndSettle();

      // History list header
      expect(find.text('Aside history'), findsOneWidget);
      // Both thread titles visible
      expect(find.text('Second thread question'), findsOneWidget);
      expect(find.text('First thread question'), findsOneWidget);
      expect(find.textContaining('1 turn'), findsNWidgets(2));

      // Tap first thread to reopen and switch
      await tester.tap(find.text('First thread question'));
      await tester.pumpAndSettle();

      // Back on thread view showing first thread
      expect(find.text('First thread question'), findsOneWidget);
      expect(find.textContaining('First answer'), findsOneWidget);
    });

    testWidgets('New aside button clears active thread to start fresh', (tester) async {
      final storage = const AsideStorage();
      await storage.recordTurn(
        sessionKey: 's_test',
        turn: AsideTurn(id: 't1', question: 'Previous question', answer: 'Previous answer', timestamp: DateTime.now()),
      );

      await tester.pumpWidget(pumpSheet(storage: storage));
      await tester.pumpAndSettle();

      expect(find.text('Previous question'), findsOneWidget);

      // Tap New aside button
      await tester.tap(find.byTooltip('New aside'));
      await tester.pumpAndSettle();

      // Empty thread state with friendly prompt
      expect(find.text('Ask a side question without interrupting Claude Code'), findsOneWidget);
    });

    testWidgets('Clear button deletes the current thread', (tester) async {
      final storage = const AsideStorage();
      await storage.recordTurn(
        sessionKey: 's_test',
        turn: AsideTurn(id: 't1', question: 'Question to clear', answer: 'Answer to clear', timestamp: DateTime.now()),
      );

      await tester.pumpWidget(pumpSheet(storage: storage));
      await tester.pumpAndSettle();

      expect(find.text('Question to clear'), findsOneWidget);

      // Tap clear
      await tester.tap(find.byTooltip('Clear'));
      await tester.pumpAndSettle();

      // Thread cleared
      expect(find.text('Question to clear'), findsNothing);
      expect(find.text('Ask a side question without interrupting Claude Code'), findsOneWidget);
    });

    testWidgets('Clear all in history removes all asides for the session', (tester) async {
      final storage = const AsideStorage();
      await storage.recordTurn(
        sessionKey: 's_test',
        turn: AsideTurn(id: 't1', question: 'Thread 1', answer: 'Answer 1', timestamp: DateTime.now()),
      );
      await storage.recordTurn(
        sessionKey: 's_test',
        turn: AsideTurn(id: 't2', question: 'Thread 2', answer: 'Answer 2', timestamp: DateTime.now()),
      );

      await tester.pumpWidget(pumpSheet(storage: storage));
      await tester.pumpAndSettle();

      // Go to history
      await tester.tap(find.byTooltip('History'));
      await tester.pumpAndSettle();

      expect(find.text('Thread 1'), findsOneWidget);
      expect(find.text('Thread 2'), findsOneWidget);

      // Tap Clear all
      await tester.tap(find.text('Clear all'));
      await tester.pumpAndSettle();

      expect(find.text('No asides yet'), findsOneWidget);
    });

    testWidgets('terminal composer Aside button is shown for Claude pane and hidden for shell', (tester) async {
      final claudeTransport = FakeTransport(
        snapshotJson(panes: [(id: 'p_1', ws: 'w1', agent: 'claude', status: 'idle')]),
      );
      final claudeMachine = MachineConnection(
        profile: const MachineProfile(id: 'm1', label: 'box1', host: 'h1', username: 'u1'),
        api: HerdrApi(claudeTransport, machineId: 'm1'),
        backoff: (_) => const Duration(hours: 1),
      );

      final shellTransport = FakeTransport(snapshotJson(panes: [(id: 'p_1', ws: 'w1', agent: null, status: 'idle')]));
      final shellMachine = MachineConnection(
        profile: const MachineProfile(id: 'm1', label: 'box1', host: 'h1', username: 'u1'),
        api: HerdrApi(shellTransport, machineId: 'm1'),
        backoff: (_) => const Duration(hours: 1),
      );

      // Test Claude pane in chat composer
      final claudeSession = FakeAgentSession(machine: claudeMachine, state: stateWith())
        ..observed = true
        ..paneId = 'p_1';

      // Test Shell session
      final shellSession = FakeAgentSession(machine: shellMachine, state: stateWith(), agent: 'shell')
        ..observed = false
        ..paneId = 'p_1';

      // Claude has Aside button
      expect(claudeSession.isObserved && claudeSession.agent == 'claude', isTrue);
      // Shell does not
      expect(shellSession.isObserved && shellSession.agent == 'claude', isFalse);
    });
  });
}
