import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/acp_models.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/fork/message_actions/message_actions_controller.dart';

class FakeAgentSession implements AgentSessionView {
  FakeAgentSession({
    required this.state,
    this.phase = AgentPhase.idle,
  });

  @override
  AgentSessionState state;

  final AgentPhase phase;
  final List<String> sentMessages = [];

  @override
  Future<bool> send(String text) async {
    sentMessages.add(text);
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('MessageActionsController', () {
    late MessageActionsController controller;

    setUp(() {
      controller = const MessageActionsController();
    });

    TranscriptMessage userMsg(String key, String text) => TranscriptMessage(
      key: key,
      role: MessageRole.user,
      blocks: [TextBlock(text)],
    );

    TranscriptMessage agentMsg(String key, String text) => TranscriptMessage(
      key: key,
      role: MessageRole.agent,
      blocks: [TextBlock(text)],
    );

    test('capabilitiesOf for user message: latest turn allows copy, edit, undo (dist=1), and retry', () {
      final m1 = userMsg('u1', 'First user prompt');
      final a1 = agentMsg('a1', 'Agent reply 1');
      final m2 = userMsg('u2', 'Second user prompt');
      final a2 = agentMsg('a2', 'Agent reply 2');

      final state = AgentSessionState('s1', items: [m1, a1, m2, a2]);
      final session = FakeAgentSession(state: state, phase: AgentPhase.idle);

      final caps = controller.capabilitiesOf(m2, session: session);
      expect(caps.canCopy, isTrue);
      expect(caps.canCopyMarkdown, isFalse);
      expect(caps.canEdit, isTrue);
      expect(caps.canUndo, isTrue);
      expect(caps.turnDistance, 1);
      expect(caps.canRetry, isTrue);
    });

    test('capabilitiesOf for user message: 2 turns back allows undo and retry with dist=2', () {
      final m1 = userMsg('u1', 'First prompt');
      final a1 = agentMsg('a1', 'Reply 1');
      final m2 = userMsg('u2', 'Second prompt');
      final a2 = agentMsg('a2', 'Reply 2');

      final state = AgentSessionState('s1', items: [m1, a1, m2, a2]);
      final session = FakeAgentSession(state: state, phase: AgentPhase.idle);

      final caps = controller.capabilitiesOf(m1, session: session);
      expect(caps.canCopy, isTrue);
      expect(caps.canEdit, isTrue);
      expect(caps.canUndo, isTrue);
      expect(caps.turnDistance, 2);
      expect(caps.canRetry, isTrue);
    });

    test('capabilitiesOf: older than 3 user turns restricts undo and retry, preserves copy and edit', () {
      final m1 = userMsg('u1', 'Prompt 1');
      final a1 = agentMsg('a1', 'Reply 1');
      final m2 = userMsg('u2', 'Prompt 2');
      final a2 = agentMsg('a2', 'Reply 2');
      final m3 = userMsg('u3', 'Prompt 3');
      final a3 = agentMsg('a3', 'Reply 3');
      final m4 = userMsg('u4', 'Prompt 4');
      final a4 = agentMsg('a4', 'Reply 4');

      final state = AgentSessionState('s1', items: [m1, a1, m2, a2, m3, a3, m4, a4]);
      final session = FakeAgentSession(state: state, phase: AgentPhase.idle);

      final caps = controller.capabilitiesOf(m1, session: session);
      expect(caps.canCopy, isTrue);
      expect(caps.canEdit, isTrue);
      expect(caps.canUndo, isFalse);
      expect(caps.canRetry, isFalse);
      expect(caps.turnDistance, 4);
    });

    test('capabilitiesOf: mutation disabled while agent is working', () {
      final m1 = userMsg('u1', 'Active prompt');
      final state = AgentSessionState('s1', items: [m1]);
      final session = FakeAgentSession(state: state, phase: AgentPhase.working);

      final caps = controller.capabilitiesOf(m1, session: session);
      expect(caps.canCopy, isTrue);
      expect(caps.canEdit, isTrue);
      expect(caps.canUndo, isFalse);
      expect(caps.canRetry, isFalse);
    });

    test('capabilitiesOf for agent message: allows copy, markdown, and retry if latest', () {
      final m1 = userMsg('u1', 'Prompt');
      final a1 = agentMsg('a1', '# Markdown Answer\n- Bullet');

      final state = AgentSessionState('s1', items: [m1, a1]);
      final session = FakeAgentSession(state: state, phase: AgentPhase.idle);

      final caps = controller.capabilitiesOf(a1, session: session);
      expect(caps.canCopy, isTrue);
      expect(caps.canCopyMarkdown, isTrue);
      expect(caps.canEdit, isFalse);
      expect(caps.canRetry, isTrue);
    });

    test('undo sends /undo sequentially N times based on turn distance', () async {
      final m1 = userMsg('u1', 'Prompt 1');
      final a1 = agentMsg('a1', 'Reply 1');
      final m2 = userMsg('u2', 'Prompt 2');
      final a2 = agentMsg('a2', 'Reply 2');

      final state = AgentSessionState('s1', items: [m1, a1, m2, a2]);
      final session = FakeAgentSession(state: state, phase: AgentPhase.idle);

      // Undoing m1 means 2 turns back
      await controller.undo(session, m1);

      expect(session.sentMessages, equals(['/undo', '/undo']));
    });

    test('retry executes /undo N times if turn was started, then sends prompt text', () async {
      final m1 = userMsg('u1', 'Prompt 1');
      final a1 = agentMsg('a1', 'Reply 1');

      final state = AgentSessionState('s1', items: [m1, a1]);
      final session = FakeAgentSession(state: state, phase: AgentPhase.idle);

      await controller.retry(session, m1);

      expect(session.sentMessages, equals(['/undo', 'Prompt 1']));
    });

    test('retry on undelivered turn sends prompt directly without /undo', () async {
      final m1 = userMsg('u1', 'Undelivered prompt');
      // No agent response in transcript
      final state = AgentSessionState('s1', items: [m1]);
      final session = FakeAgentSession(state: state, phase: AgentPhase.idle);

      await controller.retry(session, m1);

      expect(session.sentMessages, equals(['Undelivered prompt']));
    });
  });
}
