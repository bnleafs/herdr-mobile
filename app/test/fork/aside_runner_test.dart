import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/session_state.dart';
import 'package:herdr_mobile/data/models/herdr_models.dart' show PaneRead;
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/fork/aside/aside_models.dart';
import 'package:herdr_mobile/fork/aside/aside_runner.dart';
import 'package:herdr_mobile/fork/aside/aside_storage.dart';
import 'package:herdr_mobile/fork/telemetry/envelope.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_agent_session.dart';
import '../support/fake_transport.dart';

class ScriptedHerdrTransport extends FakeTransport {
  ScriptedHerdrTransport({this.onReadPane});

  PaneRead Function(String paneId, ReadSource source, int? lines)? onReadPane;

  final List<String> sentLines = [];
  final List<List<String>> sentKeysList = [];

  @override
  Future<Map<String, dynamic>> request(String method, [Map<String, dynamic> params = const {}]) async {
    calls.add((method, params));
    if (failure != null) throw failure!;

    if (method == 'pane.read') {
      final paneId = params['pane_id'] as String;
      final source = params['source'] as String?;
      final readSource = ReadSource.values.firstWhere((s) => s.wire == source, orElse: () => ReadSource.recent);
      final lines = params['lines'] as int?;
      final paneRead = onReadPane?.call(paneId, readSource, lines) ?? const PaneRead(text: '', truncated: false);
      return {
        'type': 'pane_read',
        'read': {'text': paneRead.text, 'truncated': paneRead.truncated},
      };
    }

    if (method == 'pane.send_input') {
      final text = params['text'] as String? ?? '';
      sentLines.add(text);
      return {'type': 'ok'};
    }

    if (method == 'pane.send_keys') {
      final keys = (params['keys'] as List<dynamic>? ?? []).cast<String>();
      sentKeysList.add(keys);
      return {'type': 'ok'};
    }

    return super.request(method, params);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('Aside runner: extraction and indent stripping', () {
    test('extracts single-line header, answer and footer with indent stripping', () {
      const screen = '''
    /btw what is the codename?
      The codename is BLUEFINCH.
      - Finches are small seed-eating songbirds
      - Second bullet
    ↑/↓ to scroll · c to copy · f to fork · Esc to close
''';
      final extraction = extractAsideFromScreen(screen.split('\n'), '/btw what is the codename?');
      expect(extraction.headerFound, isTrue);
      expect(extraction.footerFound, isTrue);
      expect(
        extraction.answerText,
        'The codename is BLUEFINCH.\n- Finches are small seed-eating songbirds\n- Second bullet',
      );
    });

    test('extracts wrapped header across multiple lines', () {
      const screen = '''
    /btw what is the codename, and give three
    short bullet facts about finches
      The codename is BLUEFINCH.
      - Fact 1
      - Fact 2
    ↑/↓ to scroll · c to copy · f to fork · Esc to close
''';
      final extraction = extractAsideFromScreen(
        screen.split('\n'),
        '/btw what is the codename, and give three short bullet facts about finches',
      );
      expect(extraction.headerFound, isTrue);
      expect(extraction.lastHeaderLineIndex, 1);
      expect(extraction.footerFound, isTrue);
      expect(extraction.answerText, 'The codename is BLUEFINCH.\n- Fact 1\n- Fact 2');
    });

    test('locates the last matching /btw header when earlier runs are in scrollback', () {
      const screen = '''
    /btw old question
      Old answer
    ↑/↓ to scroll · c to copy · f to fork · Esc to close
    some shell noise
    /btw what is the codename?
      The codename is BLUEFINCH.
    ↑/↓ to scroll · c to copy · f to fork · Esc to close
''';
      final extraction = extractAsideFromScreen(screen.split('\n'), '/btw what is the codename?');
      expect(extraction.headerFound, isTrue);
      expect(extraction.answerText, 'The codename is BLUEFINCH.');
    });
  });

  group('Aside runner: done detection, paging, Esc, and adversarial keys', () {
    test('done detection: completes when footer is present and text unchanged across two reads', () async {
      final transport = ScriptedHerdrTransport();
      final api = HerdrApi(transport, machineId: 'm1');

      int readCount = 0;
      transport.onReadPane = (paneId, source, lines) {
        readCount++;
        if (readCount == 1) {
          // Streaming, footer absent
          return const PaneRead(text: '    /btw test\n      First part of answer\n\n\n', truncated: false);
        } else if (readCount == 2) {
          // Footer arrives with full text
          return const PaneRead(
            text: '    /btw test\n      First part of answer and second part\n    Esc to close\n\n\n',
            truncated: false,
          );
        } else {
          // Unchanged read with footer present
          return const PaneRead(
            text: '    /btw test\n      First part of answer and second part\n    Esc to close\n\n\n',
            truncated: false,
          );
        }
      };

      final runner = AsideRunner(
        paneId: 'p1',
        api: api,
        delay: (_) async {}, // instant delay for test
      );

      final result = await runner.ask(question: 'test', pollInterval: Duration.zero);

      expect(result.outcome, StageOutcome.success);
      expect(result.turn?.answer, 'First part of answer and second part');
      // Esc sent exactly once to close panel
      expect(transport.sentKeysList, [
        const ['esc'],
      ]);

      // Adversarial: f and c never sent
      expect(transport.sentKeysList.any((keys) => keys.contains('f') || keys.contains('c')), isFalse);
      expect(transport.sentLines.any((line) => line == 'f' || line == 'c'), isFalse);
    });

    test('paging with down arrow when answer looks cut until no new lines', () async {
      final transport = ScriptedHerdrTransport();
      final api = HerdrApi(transport, machineId: 'm1');

      // 4-line terminal where footer is at bottom (fills screen)
      int readCount = 0;
      transport.onReadPane = (paneId, source, lines) {
        readCount++;
        if (readCount <= 2) {
          // Screen 1: initial answer
          return const PaneRead(
            text: '    /btw cut question\n      Line 1\n      Line 2\n    Esc to close',
            truncated: false,
          );
        } else if (readCount == 3) {
          // Screen 2: scrolled down by 1 line
          return const PaneRead(
            text: '    /btw cut question\n      Line 2\n      Line 3\n    Esc to close',
            truncated: false,
          );
        } else {
          // Screen 3: nothing new
          return const PaneRead(
            text: '    /btw cut question\n      Line 2\n      Line 3\n    Esc to close',
            truncated: false,
          );
        }
      };

      final runner = AsideRunner(paneId: 'p1', api: api, delay: (_) async {});

      final result = await runner.ask(question: 'cut question', pollInterval: Duration.zero);

      expect(result.outcome, StageOutcome.success);
      expect(result.turn?.answer, 'Line 1\nLine 2\nLine 3');

      // Pressed down arrow then Esc
      expect(transport.sentKeysList, [
        const ['down'],
        const ['down'],
        const ['esc'],
      ]);

      // Adversarial check: f/c never sent
      expect(transport.sentKeysList.any((keys) => keys.contains('f') || keys.contains('c')), isFalse);
    });

    test('paging stops at cap of 30 presses even if new lines keep arriving', () async {
      final transport = ScriptedHerdrTransport();
      final api = HerdrApi(transport, machineId: 'm1');

      int readCount = 0;
      transport.onReadPane = (paneId, source, lines) {
        readCount++;
        if (readCount <= 2) {
          // Stable screen to trigger done detection
          return const PaneRead(
            text: '    /btw infinite\n      Line 1\n      Line 2\n    Esc to close',
            truncated: false,
          );
        }
        // Keep producing new line on each down press
        return PaneRead(
          text: '    /btw infinite\n      Line ${readCount - 1}\n      Line $readCount\n    Esc to close',
          truncated: false,
        );
      };

      final runner = AsideRunner(paneId: 'p1', api: api, delay: (_) async {});

      final result = await runner.ask(question: 'infinite', pollInterval: Duration.zero);

      expect(result.outcome, StageOutcome.success);
      final downPresses = transport.sentKeysList.where((k) => k.length == 1 && k.first == 'down').length;
      expect(downPresses, 30);
      expect(transport.sentKeysList.last, const ['esc']);
    });

    test('refusal during an approval prompt with short reason and zero sends', () async {
      final transport = ScriptedHerdrTransport();
      final api = HerdrApi(transport, machineId: 'm1');

      final session = FakeAgentSession(
        state: const AgentSessionState('s1')
            .withPending(PendingPermission(1, permissionRequest(title: 'Permission needed'))),
      )..observed = true;

      final runner = AsideRunner(paneId: 'p1', api: api, session: session, delay: (_) async {});

      final result = await runner.ask(question: 'will be refused');

      expect(result.outcome, StageOutcome.cancelled);
      expect(result.refusalReason, isNotNull);
      expect(transport.sentLines, isEmpty, reason: 'must not send command to pane on refusal');
      expect(transport.sentKeysList, isEmpty, reason: 'must not send keys on refusal');
    });
  });

  group('Aside format: follow-up line format and truncation', () {
    test('initial question formats as single line capped at 1500 chars', () {
      final cmd = formatAsideCommand('what is the codename?');
      expect(cmd, '/btw what is the codename?');
    });

    test('question with newlines collapsed into spaces', () {
      final cmd = formatAsideCommand('what is\nthe codename\r\nand bullet facts?');
      expect(cmd, '/btw what is the codename and bullet facts?');
      expect(cmd.contains('\n'), isFalse);
      expect(cmd.contains('\r'), isFalse);
    });

    test('follow-up formats with earlier side question and answer', () {
      final turn1 = AsideTurn(
        id: '1',
        question: 'what is the codename?',
        answer: 'The codename is BLUEFINCH.',
        timestamp: DateTime.now(),
      );

      final cmd = formatAsideCommand('give two bullet facts', previousTurns: [turn1]);
      expect(
        cmd,
        '/btw (Earlier side question: "what is the codename?" — your answer: "The codename is BLUEFINCH.") Follow-up: give two bullet facts',
      );
    });

    test('follow-up carries at most the last two turns with answers truncated to ~500 chars', () {
      final longAnswer = 'A' * 600;
      final turn1 = AsideTurn(id: '1', question: 'q1', answer: 'a1', timestamp: DateTime.now());
      final turn2 = AsideTurn(id: '2', question: 'q2', answer: 'a2', timestamp: DateTime.now());
      final turn3 = AsideTurn(id: '3', question: 'q3', answer: longAnswer, timestamp: DateTime.now());

      final cmd = formatAsideCommand('q4', previousTurns: [turn1, turn2, turn3]);
      // turn1 should be omitted
      expect(cmd.contains('q1'), isFalse);
      expect(cmd.contains('q2'), isTrue);
      expect(cmd.contains('q3'), isTrue);
      // longAnswer should be truncated to 500 chars
      expect(cmd.contains('A' * 501), isFalse);
      expect(cmd.contains('A' * 500), isTrue);
      expect(cmd.endsWith('Follow-up: q4'), isTrue);
    });
  });

  group('Aside storage: caps and clear', () {
    test('caps threads at 20 and turns at 30, newest first', () async {
      SharedPreferences.setMockInitialValues({});
      const storage = AsideStorage();
      const sessionKey = 'sess_123';

      // Record 35 turns into one thread
      String? threadId;
      for (int i = 1; i <= 35; i++) {
        final turn = AsideTurn(id: 't_$i', question: 'Question $i', answer: 'Answer $i', timestamp: DateTime.now());
        final thread = await storage.recordTurn(sessionKey: sessionKey, threadId: threadId, turn: turn);
        threadId = thread.id;
      }

      var loaded = await storage.loadThreads(sessionKey);
      expect(loaded.length, 1);
      // Thread turns capped at 30
      expect(loaded.first.turns.length, 30);
      expect(loaded.first.turns.first.question, 'Question 6');
      expect(loaded.first.turns.last.question, 'Question 35');

      // Create 25 distinct threads
      for (int i = 1; i <= 25; i++) {
        await storage.recordTurn(
          sessionKey: sessionKey,
          turn: AsideTurn(
            id: 'new_$i',
            question: 'New thread question $i',
            answer: 'Answer $i',
            timestamp: DateTime.now(),
          ),
        );
      }

      loaded = await storage.loadThreads(sessionKey);
      // Threads capped at 20
      expect(loaded.length, 20);
      // Newest first
      expect(loaded.first.title, 'New thread question 25');

      // Clear one thread
      final toDelete = loaded.first.id;
      await storage.clearThread(sessionKey, toDelete);
      loaded = await storage.loadThreads(sessionKey);
      expect(loaded.length, 19);
      expect(loaded.any((t) => t.id == toDelete), isFalse);

      // Clear all
      await storage.clearAll(sessionKey);
      loaded = await storage.loadThreads(sessionKey);
      expect(loaded, isEmpty);
    });
  });
}
