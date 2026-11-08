import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/prompt_queue.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/fork/message_actions/message_action_bar.dart';
import 'package:herdr_mobile/fork/message_actions/message_action_sheet.dart';
import 'package:herdr_mobile/fork/message_actions/message_actions_controller.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/render/markdown/markdown.dart';
import 'package:herdr_mobile/ui/features/agent_session/transcript_rows.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../support/fake_agent_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAgentSession session;
  late List<String> clipboardHistory;

  setUp(() {
    clipboardHistory = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        final text = (call.arguments as Map<dynamic, dynamic>?)?['text'] as String?;
        if (text != null) clipboardHistory.add(text);
        return null;
      }
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Widget pumpWithScopes({
    required Widget child,
    FakeAgentSession? activeSession,
    void Function(String)? onSetDraft,
  }) {
    final sess = activeSession ?? session;
    return MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: ComposerDraftScope(
          setDraft: onSetDraft ?? (_) {},
          child: TranscriptSessionScope(
            session: sess,
            child: child,
          ),
        ),
      ),
    );
  }

  group('UserRow Message Actions UI', () {
    testWidgets('renders kebab button and opens action sheet', (tester) async {
      final userMsg = const TranscriptMessage(
        key: 'm1',
        role: MessageRole.user,
        blocks: [TextBlock('Build the login screen')],
      );

      session = FakeAgentSession(
        state: AgentSessionState('s1', items: [userMsg]),
      );

      String? drafted;
      await tester.pumpWidget(
        pumpWithScopes(
          activeSession: session,
          onSetDraft: (t) => drafted = t,
          child: UserRow(
            rowKey: 'm1',
            message: userMsg,
            gap: 0,
            open: true,
            onToggle: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Verify kebab button is rendered
      expect(find.byIcon(LucideIcons.ellipsis), findsOneWidget);

      // Tap kebab button
      await tester.tap(find.byIcon(LucideIcons.ellipsis));
      await tester.pumpAndSettle();

      // Action sheet is shown
      expect(find.text('Your Message'), findsOneWidget);
      expect(find.text('Copy text'), findsOneWidget);
      expect(find.text('Edit in composer'), findsOneWidget);
      expect(find.text('Undo turn & file changes'), findsOneWidget);
      expect(find.text('Retry turn'), findsOneWidget);

      // Tap 'Edit in composer'
      await tester.tap(find.text('Edit in composer'));
      await tester.pumpAndSettle();

      expect(drafted, equals('Build the login screen'));
    });

    testWidgets('Tapping Undo sends /undo to session', (tester) async {
      final userMsg = const TranscriptMessage(
        key: 'm1',
        role: MessageRole.user,
        blocks: [TextBlock('Do something')],
      );
      final agentMsg = const TranscriptMessage(
        key: 'a1',
        role: MessageRole.agent,
        blocks: [TextBlock('Done')],
      );

      session = FakeAgentSession(
        state: AgentSessionState('s1', items: [userMsg, agentMsg]),
      );

      await tester.pumpWidget(
        pumpWithScopes(
          activeSession: session,
          child: UserRow(
            rowKey: 'm1',
            message: userMsg,
            gap: 0,
            open: true,
            onToggle: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(LucideIcons.ellipsis));
      await tester.pumpAndSettle();

      await tester.tap(find.text('Undo turn & file changes'));
      await tester.pumpAndSettle();

      expect(session.sent, contains('/undo'));
    });

    testWidgets('Multi-turn undo shows confirmation dialog', (tester) async {
      final u1 = const TranscriptMessage(key: 'u1', role: MessageRole.user, blocks: [TextBlock('Turn 1')]);
      final a1 = const TranscriptMessage(key: 'a1', role: MessageRole.agent, blocks: [TextBlock('Resp 1')]);
      final u2 = const TranscriptMessage(key: 'u2', role: MessageRole.user, blocks: [TextBlock('Turn 2')]);
      final a2 = const TranscriptMessage(key: 'a2', role: MessageRole.agent, blocks: [TextBlock('Resp 2')]);

      session = FakeAgentSession(
        state: AgentSessionState('s1', items: [u1, a1, u2, a2]),
      )..forcedDelivery = SendDelivery.now;

      // u1 is 2 turns back
      await tester.pumpWidget(
        pumpWithScopes(
          activeSession: session,
          child: UserRow(
            rowKey: 'u1',
            message: u1,
            gap: 0,
            open: true,
            onToggle: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.byIcon(LucideIcons.ellipsis));
      await tester.pumpAndSettle();

      expect(find.text('Undo 2 turns & file changes'), findsOneWidget);
      await tester.tap(find.text('Undo 2 turns & file changes'));
      await tester.pumpAndSettle();

      // Confirmation dialog should appear
      expect(find.text('Undo 2 turns?'), findsOneWidget);
      expect(find.text('Undo turns'), findsOneWidget);

      await tester.tap(find.text('Undo turns'));
      await tester.pumpAndSettle();

      // Both /undo calls were dispatched
      expect(session.sent, equals(['/undo', '/undo']));
    });
  });

  group('AgentTextRow Message Actions UI', () {
    testWidgets('renders inline MessageActionBar below settled answer', (tester) async {
      final userMsg = const TranscriptMessage(
        key: 'u1',
        role: MessageRole.user,
        blocks: [TextBlock('Hello agent')],
      );
      final agentMsg = const TranscriptMessage(
        key: 'a1',
        role: MessageRole.agent,
        blocks: [TextBlock('I am ready to help you.')],
      );

      session = FakeAgentSession(
        state: AgentSessionState('s1', items: [userMsg, agentMsg]),
      );

      await tester.pumpWidget(
        pumpWithScopes(
          activeSession: session,
          child: AgentTextRow(
            rowKey: 'a1#0',
            block: parseMd('I am ready to help you.').blocks.first,
            gap: 0,
            expanded: false,
            message: agentMsg,
            onToggle: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // MessageActionBar is present
      expect(find.byType(MessageActionBar), findsOneWidget);
      expect(find.byIcon(LucideIcons.copy), findsOneWidget);
      expect(find.byIcon(LucideIcons.refreshCw), findsOneWidget);
      expect(find.byIcon(LucideIcons.moreHorizontal), findsOneWidget);

      // Tap copy icon directly on action bar
      await tester.tap(find.byIcon(LucideIcons.copy));
      await tester.pumpAndSettle();

      expect(clipboardHistory, contains('I am ready to help you.'));

      // Tap more actions icon to open sheet
      await tester.tap(find.byIcon(LucideIcons.moreHorizontal));
      await tester.pumpAndSettle();

      expect(find.text('Assistant Response'), findsOneWidget);
      expect(find.text('Copy text'), findsOneWidget);
      expect(find.text('Copy as Markdown'), findsOneWidget);
      expect(find.text('Retry turn'), findsOneWidget);
    });

    testWidgets('older agent message hides retry in inline action bar', (tester) async {
      final user1 = const TranscriptMessage(key: 'u1', role: MessageRole.user, blocks: [TextBlock('1')]);
      final agent1 = const TranscriptMessage(key: 'a1', role: MessageRole.agent, blocks: [TextBlock('resp 1')]);
      final user2 = const TranscriptMessage(key: 'u2', role: MessageRole.user, blocks: [TextBlock('2')]);
      final agent2 = const TranscriptMessage(key: 'a2', role: MessageRole.agent, blocks: [TextBlock('resp 2')]);

      session = FakeAgentSession(
        state: AgentSessionState('s1', items: [user1, agent1, user2, agent2]),
      );

      // Render agent1 (older turn)
      await tester.pumpWidget(
        pumpWithScopes(
          activeSession: session,
          child: AgentTextRow(
            rowKey: 'a1#0',
            block: parseMd('resp 1').blocks.first,
            gap: 0,
            expanded: false,
            message: agent1,
            onToggle: (_) {},
          ),
        ),
      );
      await tester.pumpAndSettle();

      // Older agent response should have copy and more, but NOT retry
      expect(find.byType(MessageActionBar), findsOneWidget);
      expect(find.byIcon(LucideIcons.copy), findsOneWidget);
      expect(find.byIcon(LucideIcons.refreshCw), findsNothing);
      expect(find.byIcon(LucideIcons.moreHorizontal), findsOneWidget);
    });
  });
}
