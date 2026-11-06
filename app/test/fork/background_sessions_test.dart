import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/fork/background_sessions.dart';

import '../support/create_harness.dart';
import '../support/fake_fs.dart';
import '../support/fake_transport.dart';
import '../support/herdr_stub.dart';

void main() {
  group('BackgroundSession model', () {
    test('parses valid bg session', () {
      final json = {
        'kind': 'bg',
        'sessionId': 'e62b0838-5182-4467-bc13-8ea98a96e8e1',
        'cwd': '/Users/dev/project',
        'name': 'refactor-task',
        'status': 'busy',
        'updatedAt': 1762400000000,
        'pid': 12345,
        'jobId': 'job-99',
      };
      final session = BackgroundSession.fromJson(json);
      expect(session, isNotNull);
      expect(session!.sessionId, 'e62b0838-5182-4467-bc13-8ea98a96e8e1');
      expect(session.cwd, '/Users/dev/project');
      expect(session.name, 'refactor-task');
      expect(session.status, 'busy');
      expect(session.isBusy, isTrue);
      expect(session.updatedAt, DateTime.fromMillisecondsSinceEpoch(1762400000000));
      expect(session.pid, 12345);
      expect(session.jobId, 'job-99');
    });

    test('drops interactive sessions', () {
      final json = {
        'kind': 'interactive',
        'sessionId': 'e62b0838-5182-4467-bc13-8ea98a96e8e1',
        'cwd': '/Users/dev/project',
      };
      expect(BackgroundSession.fromJson(json), isNull);
    });

    test('drops sessions with invalid or missing sessionIds', () {
      final invalidIds = [
        '',
        'not-a-uuid',
        'e62b0838-5182-4467-bc13',
        'e62b0838-5182-4467-bc13-8ea98a96e8e1-extra',
        12345,
        null,
      ];
      for (final id in invalidIds) {
        final json = {'kind': 'bg', 'sessionId': id, 'cwd': '/Users/dev/project'};
        expect(BackgroundSession.fromJson(json), isNull, reason: 'id: $id');
      }
    });

    test('drops sessions with empty or non-string cwd', () {
      expect(
        BackgroundSession.fromJson({'kind': 'bg', 'sessionId': 'e62b0838-5182-4467-bc13-8ea98a96e8e1', 'cwd': ''}),
        isNull,
      );
      expect(BackgroundSession.fromJson({'kind': 'bg', 'sessionId': 'e62b0838-5182-4467-bc13-8ea98a96e8e1'}), isNull);
    });
  });

  group('compareBackgroundSessions', () {
    test('sorts busy first, then newest updatedAt', () {
      final busyOld = BackgroundSession(
        sessionId: '11111111-1111-1111-1111-111111111111',
        cwd: '/a',
        status: 'busy',
        updatedAt: DateTime.fromMillisecondsSinceEpoch(1000),
      );
      final busyNew = BackgroundSession(
        sessionId: '22222222-2222-2222-2222-222222222222',
        cwd: '/b',
        status: 'busy',
        updatedAt: DateTime.fromMillisecondsSinceEpoch(2000),
      );
      final idleNew = BackgroundSession(
        sessionId: '33333333-3333-3333-3333-333333333333',
        cwd: '/c',
        status: 'idle',
        updatedAt: DateTime.fromMillisecondsSinceEpoch(3000),
      );
      final idleOld = BackgroundSession(
        sessionId: '44444444-4444-4444-4444-444444444444',
        cwd: '/d',
        status: 'idle',
        updatedAt: DateTime.fromMillisecondsSinceEpoch(500),
      );

      final list = [idleOld, idleNew, busyOld, busyNew]..sort(compareBackgroundSessions);
      expect(list.map((s) => s.sessionId).toList(), [
        busyNew.sessionId,
        busyOld.sessionId,
        idleNew.sessionId,
        idleOld.sessionId,
      ]);
    });
  });

  group('listBackgroundSessions with FakeFs', () {
    late CreateHarness harness;
    late MachineConnection machine;
    late FakeFs fs;

    setUp(() async {
      fs = FakeFs();
      harness = await CreateHarness.create([
        (profile: profileOf('m1', 'mac-pro', enabled: true), snapshot: snapshotJson()),
      ]);
      harness.stubs['m1']!.fs = fs;
      machine = harness.connection('m1');
      await machine.refresh();
    });

    tearDown(() => harness.dispose());

    test('reads valid bg sessions, skips interactive and invalid json', () async {
      final sessDir = '/home/dev/.claude/sessions';
      fs.addDir(sessDir);

      // Valid busy session
      fs.addFile(
        '$sessDir/101.json',
        jsonEncode({
          'kind': 'bg',
          'sessionId': 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',
          'cwd': '/work/one',
          'name': 'task-a',
          'status': 'busy',
          'updatedAt': 10000,
        }),
      );

      // Valid idle session (newer)
      fs.addFile(
        '$sessDir/102.json',
        jsonEncode({
          'kind': 'bg',
          'sessionId': 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',
          'cwd': '/work/two',
          'name': 'task-b',
          'status': 'idle',
          'updatedAt': 20000,
        }),
      );

      // Interactive session (must be skipped)
      fs.addFile(
        '$sessDir/103.json',
        jsonEncode({'kind': 'interactive', 'sessionId': 'cccccccc-cccc-cccc-cccc-cccccccccccc', 'cwd': '/work/three'}),
      );

      // Invalid json with stray trailing } (must be skipped silently)
      fs.addFile('$sessDir/104.json', '{"kind":"bg","sessionId":"dddddddd-dddd-dddd-dddd-dddddddddddd"}}');

      // Oversized file > 64KB (must be skipped)
      final huge = utf8.encode(
        jsonEncode({
          'kind': 'bg',
          'sessionId': 'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee',
          'cwd': '/work/five',
          'padding': 'x' * (65 * 1024),
        }),
      );
      fs.addFile('$sessDir/105.json', Uint8List.fromList(huge));

      final sessions = await listBackgroundSessions(machine);
      expect(sessions.length, 2);
      expect(sessions[0].sessionId, 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'); // busy first
      expect(sessions[0].isBusy, isTrue);
      expect(sessions[1].sessionId, 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb');
      expect(sessions[1].isBusy, isFalse);
    });

    test('caps scan count at 64 files', () async {
      final sessDir = '/home/dev/.claude/sessions';
      fs.addDir(sessDir);

      for (var i = 0; i < 70; i++) {
        final padded = i.toString().padLeft(2, '0');
        fs.addFile(
          '$sessDir/$padded.json',
          jsonEncode({
            'kind': 'bg',
            'sessionId': '00000000-0000-0000-0000-0000000000$padded',
            'cwd': '/work/$padded',
            'status': 'idle',
            'updatedAt': i * 100,
          }),
        );
      }

      final sessions = await listBackgroundSessions(machine);
      expect(sessions.length, maxBackgroundSessionFiles);
      expect(sessions.length, 64);
    });

    test('missing folder returns empty list and calls onReason quietly', () async {
      String? reason;
      final sessions = await listBackgroundSessions(machine, onReason: (r) => reason = r);
      expect(sessions, isEmpty);
      expect(reason, isNotNull);
    });
  });

  group('attachBackgroundSession', () {
    late CreateHarness harness;
    late MachineConnection machine;
    late HerdrStub stub;

    setUp(() async {
      harness = await CreateHarness.create([
        (profile: profileOf('m1', 'mac-pro', enabled: true), snapshot: snapshotJson()),
      ]);
      stub = harness.stubs['m1']!;
      stub.on['workspace.create'] = (params) {
        final wid = 'w_created';
        final pid = '$wid:p1';
        final cwd = params['cwd'] as String?;
        return {
          'type': 'workspace_created',
          'workspace': {'workspace_id': wid, 'label': params['label']},
          'tab': {'tab_id': '$wid:t1'},
          'root_pane': {'pane_id': pid, 'cwd': cwd},
        };
      };
      machine = harness.connection('m1');
      await machine.refresh();
    });

    tearDown(() => harness.dispose());

    test('types exactly one line claude attach with quotes, no extra commands', () async {
      const sessionId = '12345678-1234-1234-1234-123456789abc';
      const session = BackgroundSession(sessionId: sessionId, cwd: '/work/project');

      final paneAgent = await attachBackgroundSession(machine: machine, session: session);

      expect(paneAgent.machineId, 'm1');
      expect(paneAgent.paneId, isNotEmpty);

      // Verify what was sent to herdr API
      final sentInputs = stub.paramsOf('pane.send_input');
      expect(sentInputs, hasLength(1), reason: 'must send exactly one input line');
      final inputCall = sentInputs.first;
      expect(inputCall['text'], "claude attach '$sessionId'");
      expect(inputCall['keys'], ['enter']);

      // Ensure no pane.send_text or pane.send_keys were invoked
      expect(stub.paramsOf('pane.send_text'), isEmpty);
      expect(stub.paramsOf('pane.send_keys'), isEmpty);
    });

    test('adversarial sessionId with quotes is safely shell-quoted and cannot inject', () async {
      const evilId = "test'; rm -rf /; echo 'pwned";
      const session = BackgroundSession(sessionId: evilId, cwd: '/work/project');

      await attachBackgroundSession(machine: machine, session: session);

      final sentInputs = stub.paramsOf('pane.send_input');
      expect(sentInputs, hasLength(1));
      final text = sentInputs.first['text'] as String;
      // Single quotes in string must be escaped with '\''
      expect(text, r"claude attach 'test'\''; rm -rf /; echo '\''pwned'");
    });
  });
}
