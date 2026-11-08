import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/prompt_queue.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/fork/message_actions/message_action_sheet.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/agent_session/content_copy.dart';
import 'package:herdr_mobile/ui/features/agent_session/transcript_rows.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../support/fake_agent_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late FakeAgentSession session;
  late List<String> clipboardHistory;

  setUp(() {
    clipboardHistory = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      (call) async {
        if (call.method == 'Clipboard.setData') {
          final text = (call.arguments as Map<dynamic, dynamic>?)?['text'] as String?;
          if (text != null) clipboardHistory.add(text);
          return null;
        }
        return null;
      },
    );
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    );
  });

  Widget pumpWithScopes({required Widget child, FakeAgentSession? activeSession, void Function(String)? onSetDraft}) {
    final sess = activeSession ?? session;
    return MaterialApp(
      theme: AppTheme.light(),
      home: Scaffold(
        body: ComposerDraftScope(
          setDraft: onSetDraft ?? (_) {},
          child: TranscriptSessionScope(session: sess, child: child),
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

      session = FakeAgentSession(state: AgentSessionState('s1', items: [userMsg]));

      String? drafted;
      await tester.pumpWidget(
        pumpWithScopes(
          activeSession: session,
          onSetDraft: (t) => drafted = t,
          child: UserRow(rowKey: 'm1', message: userMsg, gap: 0, open: true, onToggle: (_) {}),
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
      final userMsg = const TranscriptMessage(key: 'm1', role: MessageRole.user, blocks: [TextBlock('Do something')]);
      final agentMsg = const TranscriptMessage(key: 'a1', role: MessageRole.agent, blocks: [TextBlock('Done')]);

      session = FakeAgentSession(state: AgentSessionState('s1', items: [userMsg, agentMsg]));

      await tester.pumpWidget(
        pumpWithScopes(
          activeSession: session,
          child: UserRow(rowKey: 'm1', message: userMsg, gap: 0, open: true, onToggle: (_) {}),
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

      session = FakeAgentSession(state: AgentSessionState('s1', items: [u1, a1, u2, a2]))
        ..forcedDelivery = SendDelivery.now;

      // u1 is 2 turns back
      await tester.pumpWidget(
        pumpWithScopes(
          activeSession: session,
          child: UserRow(rowKey: 'u1', message: u1, gap: 0, open: true, onToggle: (_) {}),
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

  group('Agent Message Actions UI', () {
    testWidgets('showMessageCopySheet includes Retry response when latest', (tester) async {
      final userMsg = const TranscriptMessage(key: 'u1', role: MessageRole.user, blocks: [TextBlock('Hello agent')]);
      final agentMsg = const TranscriptMessage(
        key: 'a1',
        role: MessageRole.agent,
        blocks: [TextBlock('I am ready to help you.')],
      );

      session = FakeAgentSession(state: AgentSessionState('s1', items: [userMsg, agentMsg]));

      await tester.pumpWidget(
        pumpWithScopes(
          activeSession: session,
          child: Builder(
            builder: (ctx) =>
                TextButton(onPressed: () => showMessageCopySheet(ctx, agentMsg), child: const Text('Open Sheet')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Open Sheet'));
      await tester.pumpAndSettle();

      expect(find.text('Copy text'), findsOneWidget);
      expect(find.text('Copy as Markdown'), findsOneWidget);
      expect(find.text('Retry response'), findsOneWidget);

      await tester.tap(find.text('Retry response'));
      await tester.pumpAndSettle();

      expect(session.sent, contains('Hello agent'));
    });

    testWidgets('showMessageCopySheet omits Retry response for older agent responses', (tester) async {
      final u1 = const TranscriptMessage(key: 'u1', role: MessageRole.user, blocks: [TextBlock('Turn 1')]);
      final a1 = const TranscriptMessage(key: 'a1', role: MessageRole.agent, blocks: [TextBlock('Resp 1')]);
      final u2 = const TranscriptMessage(key: 'u2', role: MessageRole.user, blocks: [TextBlock('Turn 2')]);
      final a2 = const TranscriptMessage(key: 'a2', role: MessageRole.agent, blocks: [TextBlock('Resp 2')]);

      session = FakeAgentSession(state: AgentSessionState('s1', items: [u1, a1, u2, a2]));

      await tester.pumpWidget(
        pumpWithScopes(
          activeSession: session,
          child: Builder(
            builder: (ctx) =>
                TextButton(onPressed: () => showMessageCopySheet(ctx, a1), child: const Text('Open Sheet')),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.text('Open Sheet'));
      await tester.pumpAndSettle();

      expect(find.text('Copy text'), findsOneWidget);
      expect(find.text('Copy as Markdown'), findsOneWidget);
      expect(find.text('Retry response'), findsNothing);
    });
  });
}
