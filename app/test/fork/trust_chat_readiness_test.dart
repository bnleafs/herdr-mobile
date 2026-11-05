import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/observed/claude_kind.dart';
import 'package:herdr_mobile/data/observed/claude_locator.dart';
import 'package:herdr_mobile/data/observed/codex_kind.dart';
import 'package:herdr_mobile/data/observed/omp_kind.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/observed_session.dart';
import 'package:herdr_mobile/data/repositories/observed_sessions.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/fork/telemetry/envelope.dart';
import 'package:herdr_mobile/fork/telemetry/telemetry.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/agent_session/agent_session_screen.dart';
import 'package:herdr_mobile/ui/features/agents/agent_navigation.dart';
import 'package:herdr_mobile/ui/features/pane/pane_screen.dart';
import 'package:provider/provider.dart';

import '../support/create_harness.dart';
import '../support/fake_fs.dart';
import '../support/fake_log_source.dart';
import '../support/fake_transport.dart';
import '../support/memory_terminal_settings_store.dart';

const _sid = '3f1c9a52-7d0e-4b6a-9a11-0c5d2e8b7f41';
const _cwd = '/work/app';
final _logPath = '/home/dev/.claude/projects/-work-app/$_sid.jsonl';
final _pidPath = '/home/dev/.claude/sessions/4242.json';

void main() {
  group('Trust-to-Chat Synthetic Readiness Lifecycle & Latch Reproduction', () {
    test(
      'transient missing metadata latches 60s blacklist and drops session instead of recovering SAME identity',
      () async {
        final h = await CreateHarness.create([
          (
            profile: profileOf('m1', 'workstation'),
            snapshot: snapshotJson(
              workspaces: const [(id: 'w1', label: 'api')],
              panes: const [(id: 'w1:p1', ws: 'w1', agent: 'claude', status: 'idle')],
            ),
          ),
        ]);
        addTearDown(h.dispose);

        final stub = h.stubs['m1']!;
        final fs = FakeFs();
        stub.fs = fs;
        stub.on['pane.process_info'] = (_) => {
          'type': 'pane_process_info',
          'process_info': {
            'foreground_processes': [
              {'pid': 4242, 'name': '2.1.293', 'argv0': 'claude', 'cmdline': 'claude'},
            ],
          },
        };

        final machine = h.connection('m1');
        final previews = PanePreviews(changes: machine, connection: (_) => machine, startGap: Duration.zero);
        addTearDown(previews.dispose);
        final logSource = FakeLogSource();
        final sessions = ObservedSessions(
          fleet: h.fleet,
          previews: previews,
          sourceFor: (_) => logSource,
          kinds: {'omp': ompKind, 'claude': claudeKind, 'codex': codexKind},
        );
        addTearDown(sessions.dispose);

        // Phase 1: Pre-trust prompt state. Process is running, but ~/.claude/sessions/4242.json does not exist.
        final session = sessions.forPane(machine, 'w1:p1');
        expect(session, isNotNull);
        session!.acquire();

        // Locator runs: Claude is starting this session -> NotYet readiness.
        // ObservedAgentSession enters readiness without failing or latching unlinked.
        await eventually(() => session.link == AgentLink.live, reason: 'enters live readiness');
        expect(session.waiting, ClaudeLocator.readinessWhy);
        expect(session.link, AgentLink.live);
        expect(sessions.supports(machine, 'w1:p1'), isTrue, reason: 'readiness does not latch unlinked');

        // User steps away (e.g. navigates to terminal to accept folder trust prompt):
        session.release();

        // Phase 2: Metadata becomes valid after user accepts folder trust in terminal.
        fs.addFile(_pidPath, jsonEncode({'pid': 4242, 'sessionId': _sid, 'cwd': _cwd, 'kind': 'interactive'}));
        fs.addFile(_logPath, '{"type":"user","message":"hello"}\n');
        logSource.write(['{"type":"user","message":"hello"}\n']);

        // Phase 3: User explicitly returns to chat view.
        // Expectation for a resilient system: recovers session without duplicate process or replayed input.
        final recovered = sessions.forPane(machine, 'w1:p1');
        expect(recovered, isNotNull, reason: 'chat should be available once metadata is valid');
        expect(
          recovered,
          same(session),
          reason: 'should recover SAME session identity without duplicate process/replayed input',
        );
      },
    );

    test(
      'held session follow loop terminates permanently on Unlinked and does not resume after metadata appears',
      () async {
        final h = await CreateHarness.create([
          (
            profile: profileOf('m1', 'workstation'),
            snapshot: snapshotJson(
              workspaces: const [(id: 'w1', label: 'api')],
              panes: const [(id: 'w1:p1', ws: 'w1', agent: 'claude', status: 'idle')],
            ),
          ),
        ]);
        addTearDown(h.dispose);

        final stub = h.stubs['m1']!;
        final fs = FakeFs();
        stub.fs = fs;
        stub.on['pane.process_info'] = (_) => {
          'type': 'pane_process_info',
          'process_info': {
            'foreground_processes': [
              {'pid': 4242, 'name': '2.1.293', 'argv0': 'claude', 'cmdline': 'claude'},
            ],
          },
        };

        final machine = h.connection('m1');
        final previews = PanePreviews(changes: machine, connection: (_) => machine, startGap: Duration.zero);
        addTearDown(previews.dispose);
        final logSource = FakeLogSource();
        final sessions = ObservedSessions(
          fleet: h.fleet,
          previews: previews,
          sourceFor: (_) => logSource,
          kinds: {'omp': ompKind, 'claude': claudeKind, 'codex': codexKind},
        );
        addTearDown(sessions.dispose);

        final session = sessions.forPane(machine, 'w1:p1')!;
        session.acquire();

        await eventually(() => session.link == AgentLink.live, reason: 'enters live readiness');
        expect(session.following, isTrue, reason: 'follow loop stays alive in readiness state');
        expect(session.waiting, ClaudeLocator.readinessWhy);

        // Metadata becomes valid while user remains on screen:
        fs.addFile(_pidPath, jsonEncode({'pid': 4242, 'sessionId': _sid, 'cwd': _cwd, 'kind': 'interactive'}));
        fs.addFile(_logPath, '{"type":"user","message":"hello"}\n');

        session.nudgeLocate();
        await eventually(() => session.logPath == _logPath, reason: 'held session follows log once metadata is valid');
        expect(session.link, isNot(AgentLink.failed), reason: 'held session recovers without failing');
      },
    );
  });

  group('Negative Controls: Genuine Failures vs Transient Readiness', () {
    test('unsupported API (pane.process_info) remains unlinked and does not recover', () async {
      final h = await CreateHarness.create([
        (
          profile: profileOf('m1', 'workstation'),
          snapshot: snapshotJson(
            workspaces: const [(id: 'w1', label: 'api')],
            panes: const [(id: 'w1:p1', ws: 'w1', agent: 'claude', status: 'idle')],
          ),
        ),
      ]);
      addTearDown(h.dispose);

      final stub = h.stubs['m1']!;
      stub.on['pane.process_info'] = (_) => throw const HerdrUnsupportedException('pane.process_info');

      final machine = h.connection('m1');
      final previews = PanePreviews(changes: machine, connection: (_) => machine, startGap: Duration.zero);
      addTearDown(previews.dispose);
      final sessions = ObservedSessions(
        fleet: h.fleet,
        previews: previews,
        sourceFor: (_) => FakeLogSource(),
        kinds: {'omp': ompKind, 'claude': claudeKind, 'codex': codexKind},
      );
      addTearDown(sessions.dispose);

      final session = sessions.forPane(machine, 'w1:p1')!;
      session.acquire();
      await eventually(() => session.link == AgentLink.failed, reason: 'unsupported api fails');

      // Genuinely unsupported should remain unlinked; supports() is false.
      expect(sessions.supports(machine, 'w1:p1'), isFalse);
    });

    test('closed pane is not recoverable', () async {
      final h = await CreateHarness.create([
        (
          profile: profileOf('m1', 'workstation'),
          snapshot: snapshotJson(
            workspaces: const [(id: 'w1', label: 'api')],
            panes: const [(id: 'w1:p1', ws: 'w1', agent: 'claude', status: 'idle')],
          ),
        ),
      ]);
      addTearDown(h.dispose);

      final machine = h.connection('m1');
      final previews = PanePreviews(changes: machine, connection: (_) => machine, startGap: Duration.zero);
      addTearDown(previews.dispose);
      final sessions = ObservedSessions(
        fleet: h.fleet,
        previews: previews,
        sourceFor: (_) => FakeLogSource(),
        kinds: {'omp': ompKind, 'claude': claudeKind, 'codex': codexKind},
      );
      addTearDown(sessions.dispose);

      // Mutate snapshot to close pane:
      final snap = h.stubs['m1']!.snapshot;
      (snap['panes'] as List).clear();
      await machine.refresh();

      expect(machine.paneById('w1:p1'), isNull);
      expect(sessions.forPane(machine, 'w1:p1'), isNull);
    });

    test('changed process generation does not resurrect old session for different pid', () async {
      final h = await CreateHarness.create([
        (
          profile: profileOf('m1', 'workstation'),
          snapshot: snapshotJson(
            workspaces: const [(id: 'w1', label: 'api')],
            panes: const [(id: 'w1:p1', ws: 'w1', agent: 'claude', status: 'idle')],
          ),
        ),
      ]);
      addTearDown(h.dispose);

      var currentPid = 4242;
      final stub = h.stubs['m1']!;
      stub.on['pane.process_info'] = (_) => {
        'type': 'pane_process_info',
        'process_info': {
          'foreground_processes': [
            {'pid': currentPid, 'name': '2.1.293', 'argv0': 'claude', 'cmdline': 'claude'},
          ],
        },
      };

      final machine = h.connection('m1');
      final previews = PanePreviews(changes: machine, connection: (_) => machine, startGap: Duration.zero);
      addTearDown(previews.dispose);
      final sessions = ObservedSessions(
        fleet: h.fleet,
        previews: previews,
        sourceFor: (_) => FakeLogSource(),
        kinds: {'omp': ompKind, 'claude': claudeKind, 'codex': codexKind},
      );
      addTearDown(sessions.dispose);

      final session1 = sessions.forPane(machine, 'w1:p1')!;
      session1.acquire();
      await eventually(() => session1.link == AgentLink.failed);
      session1.release();

      // Process changes to a different pid (new generation):
      currentPid = 9999;
      // When generation changes, the old session state should not be reused blindly.
      expect(session1.link, AgentLink.failed);
    });
  });

  group('UI & Navigation Red Reproduction', () {
    testWidgets('AgentSessionScreen suppresses Retry button when observed session fails', (tester) async {
      late CreateHarness h;
      late ObservedSessions sessions;
      late ObservedAgentSession session;

      await tester.runAsync(() async {
        h = await CreateHarness.create([
          (
            profile: profileOf('m1', 'workstation'),
            snapshot: snapshotJson(
              workspaces: const [(id: 'w1', label: 'api')],
              panes: const [(id: 'w1:p1', ws: 'w1', agent: 'claude', status: 'idle')],
            ),
          ),
        ]);

        final machine = h.connection('m1');
        final previews = PanePreviews(changes: machine, connection: (_) => machine, startGap: Duration.zero);
        sessions = ObservedSessions(
          fleet: h.fleet,
          previews: previews,
          sourceFor: (_) => FakeLogSource(),
          kinds: {'omp': ompKind, 'claude': claudeKind, 'codex': codexKind},
        );

        session = sessions.forPane(machine, 'w1:p1')!;
        session.acquire();
        await eventually(() => session.link == AgentLink.failed);
      });
      addTearDown(h.dispose);
      addTearDown(sessions.dispose);
      addTearDown(session.release);

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<FleetRepository>.value(value: h.fleet),
            ChangeNotifierProvider<ObservedSessions>.value(value: sessions),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: AgentSessionScreen(session: session, agent: const PaneAgent('m1', 'w1:p1')),
            ),
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 300));

      // Expected recovery affordance: Retry button must be present for user to retry once ready.
      expect(find.text('Retry'), findsOneWidget, reason: 'failed observed session must offer Retry button');
      expect(find.text('Open terminal'), findsOneWidget, reason: 'terminal action remains reachable');
      await tester.tap(find.text('Retry'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    });

    testWidgets('navigating to chat bounces to terminal when metadata was missing and remains latched', (tester) async {
      late CreateHarness h;
      late ObservedSessions sessions;
      late AgentScreens screens;
      late TerminalSettings terminalSettings;

      await tester.runAsync(() async {
        h = await CreateHarness.create([
          (
            profile: profileOf('m1', 'workstation'),
            snapshot: snapshotJson(
              workspaces: const [(id: 'w1', label: 'api')],
              panes: const [(id: 'w1:p1', ws: 'w1', agent: 'claude', status: 'idle')],
            ),
          ),
        ]);

        final stub = h.stubs['m1']!;
        final fs = FakeFs();
        stub.fs = fs;
        stub.on['pane.process_info'] = (_) => {
          'type': 'pane_process_info',
          'process_info': {
            'foreground_processes': [
              {'pid': 4242, 'name': '2.1.293', 'argv0': 'claude', 'cmdline': 'claude'},
            ],
          },
        };

        final machine = h.connection('m1');
        final previews = PanePreviews(changes: machine, connection: (_) => machine, startGap: Duration.zero);
        final logSource = FakeLogSource();
        sessions = ObservedSessions(
          fleet: h.fleet,
          previews: previews,
          sourceFor: (_) => logSource,
          kinds: {'omp': ompKind, 'claude': claudeKind, 'codex': codexKind},
        );
        screens = AgentScreens();
        terminalSettings = TerminalSettings(MemoryTerminalSettingsStore());

        // Initial pre-trust prompt state:
        final session = sessions.forPane(machine, 'w1:p1')!;
        session.acquire();
        await eventually(() => session.link == AgentLink.live);
        session.release();

        // Metadata becomes valid:
        fs.addFile(_pidPath, jsonEncode({'pid': 4242, 'sessionId': _sid, 'cwd': _cwd, 'kind': 'interactive'}));
        fs.addFile(_logPath, '{"type":"user","message":"hello"}\n');
      });
      addTearDown(h.dispose);
      addTearDown(sessions.dispose);
      addTearDown(screens.dispose);

      late BuildContext navContext;
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<FleetRepository>.value(value: h.fleet),
            ChangeNotifierProvider<ObservedSessions>.value(value: sessions),
            ChangeNotifierProvider<AgentScreens>.value(value: screens),
            ChangeNotifierProvider<TerminalSettings>.value(value: terminalSettings),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: Scaffold(
              body: Builder(
                builder: (context) {
                  navContext = context;
                  return const Text('home');
                },
              ),
            ),
          ),
        ),
      );

      // User explicitly requests chat view for the pane:
      unawaited(openAgent(navContext, const PaneAgent('m1', 'w1:p1'), view: AgentView.chat));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));

      // Expected: openAgent in chat view should open AgentSessionScreen when metadata is valid.
      // Actual bug: forPane returns null due to _unlinked latch, so _screenFor falls back to PaneScreen!
      expect(
        find.byType(AgentSessionScreen),
        findsOneWidget,
        reason: 'should open AgentSessionScreen, not fallback to PaneScreen',
      );
      expect(find.byType(PaneScreen), findsNothing, reason: 'should not bounce to PaneScreen terminal');

      await tester.pumpWidget(const SizedBox());
      sessions.dispose();
    });
  });

  group('Telemetry On Readiness & Recovery Journey', () {
    test('records waitingAgent, transcriptLocate, fallback and userRetry without PII leaks', () async {
      final milestones = <TelemetryEnvelope>[];
      final sink = _TestSink(milestones);
      final telemetry = ForkTelemetry.withSinks(sinks: [sink]);
      ForkTelemetry.setTestInstance(telemetry);
      addTearDown(ForkTelemetry.resetInstance);

      final h = await CreateHarness.create([
        (
          profile: profileOf('m1', 'workstation'),
          snapshot: snapshotJson(
            workspaces: const [(id: 'w1', label: 'api')],
            panes: const [(id: 'w1:p1', ws: 'w1', agent: 'claude', status: 'idle')],
          ),
        ),
      ]);
      addTearDown(h.dispose);

      final stub = h.stubs['m1']!;
      final fs = FakeFs();
      stub.fs = fs;
      stub.on['pane.process_info'] = (_) => {
        'type': 'pane_process_info',
        'process_info': {
          'foreground_processes': [
            {'pid': 4242, 'name': '2.1.293', 'argv0': 'claude', 'cmdline': 'claude'},
          ],
        },
      };

      final machine = h.connection('m1');
      final previews = PanePreviews(changes: machine, connection: (_) => machine, startGap: Duration.zero);
      addTearDown(previews.dispose);
      final sessions = ObservedSessions(
        fleet: h.fleet,
        previews: previews,
        sourceFor: (_) => FakeLogSource(),
        kinds: {'claude': claudeKind},
      );
      addTearDown(sessions.dispose);

      final session = sessions.forPane(machine, 'w1:p1')!;
      session.acquire();
      addTearDown(session.release);

      // 1. Initial readiness state records waitingAgent:
      await eventually(() => milestones.any((m) => m.stage == TelemetryStage.waitingAgent));
      final waitingEv = milestones.firstWhere((m) => m.stage == TelemetryStage.waitingAgent);
      expect(waitingEv.opId, isNotEmpty);
      expect(waitingEv.category, TelemetryCategory.none);

      // 2. Metadata appears -> transcriptLocate:
      fs.addFile(_pidPath, jsonEncode({'pid': 4242, 'sessionId': _sid, 'cwd': _cwd, 'kind': 'interactive'}));
      fs.addFile(_logPath, '{"type":"user","message":"hello"}\n');
      session.nudgeLocate();

      await eventually(() => milestones.any((m) => m.stage == TelemetryStage.transcriptLocate));
      final locateEv = milestones.firstWhere((m) => m.stage == TelemetryStage.transcriptLocate);
      expect(locateEv.opId, waitingEv.opId, reason: 'same opId across attach journey');

      // 3. Fallback stage on markUnlinked:
      sessions.markUnlinked(machine, 'w1:p1');
      expect(milestones.any((m) => m.stage == TelemetryStage.fallback), isTrue);

      // 4. Verify no PII in JSON envelopes:
      for (final m in milestones) {
        final json = jsonEncode(m.toJson());
        expect(json.contains(_sid), isFalse);
        expect(json.contains(_cwd), isFalse);
        expect(json.contains(_logPath), isFalse);
        expect(json.contains('w1:p1'), isFalse);
        expect(json.contains('workstation'), isFalse);
      }
    });
  });
}

class _TestSink implements TelemetrySink {
  _TestSink(this.milestones);
  final List<TelemetryEnvelope> milestones;

  @override
  Future<void> init() async {}

  @override
  Future<void> sendMilestone(TelemetryEnvelope envelope) async {
    milestones.add(envelope);
  }

  @override
  Future<void> sendError(TelemetryEnvelope envelope) async {}

  @override
  Future<void> reset() async {}

  @override
  Future<void> close() async {}
}
