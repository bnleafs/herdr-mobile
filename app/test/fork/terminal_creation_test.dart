import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/app_settings.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/fork/terminal_creation.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:herdr_mobile/ui/features/create/management_sheets.dart';
import 'package:herdr_mobile/ui/features/files/file_browser_screen.dart';
import 'package:herdr_mobile/ui/features/machines/machine_form_view_model.dart' show TransportFactory;
import 'package:herdr_mobile/ui/features/machines/machine_screen.dart';
import 'package:herdr_mobile/ui/features/machines/machines_screen.dart';
import 'package:herdr_mobile/ui/features/pane/pane_screen.dart';
import 'package:provider/provider.dart';

import '../support/create_harness.dart';
import '../support/fake_transport.dart';
import '../support/files_support.dart';
import '../support/herdr_stub.dart';
import '../support/memory_app_settings_store.dart';
import '../support/memory_terminal_settings_store.dart';
import '../support/shot.dart';
import '../ui/ui_harness.dart' show attentionSetProvider;

class _TerminalTestRig {
  _TerminalTestRig({required this.harness, required this.machine, required this.stub});

  final CreateHarness harness;
  final MachineConnection machine;
  final HerdrStub stub;
}

Future<_TerminalTestRig> _buildRig({
  List<Map<String, dynamic>> rawWorkspaces = const [],
  List<Map<String, dynamic>> rawPanes = const [],
  bool enabled = true,
  bool inWidgetTest = false,
}) async {
  final snap = snapshotJson();
  if (rawWorkspaces.isNotEmpty) {
    snap['workspaces'] = [for (final w in rawWorkspaces) Map<String, dynamic>.from(w)];
  }
  if (rawPanes.isNotEmpty) {
    snap['panes'] = [for (final p in rawPanes) Map<String, dynamic>.from(p)];
  }

  final h = await CreateHarness.create([(profile: profileOf('a', 'studio-mac', enabled: enabled), snapshot: snap)]);
  if (!inWidgetTest) {
    addTearDown(h.dispose);
  }
  final machine = h.connection('a');
  if (enabled) {
    await machine.refresh();
  }
  final stub = h.stubs['a']!;
  stub.fs = projectFs();

  var nextPane = 2;
  stub.on['tab.create'] = (params) {
    final wid = params['workspace_id'] as String;
    final pid = '$wid:p${nextPane++}';
    final cwd = params['cwd'] as String?;
    final panes = (stub.snapshot['panes'] as List).cast<Map<String, dynamic>>();
    panes.add({
      'pane_id': pid,
      'workspace_id': wid,
      'tab_id': '$wid:t2',
      'cwd': cwd,
      'agent': null,
      'agent_status': 'idle',
    });
    return {
      'type': 'tab_created',
      'tab': {'tab_id': '$wid:t2'},
      'root_pane': {'pane_id': pid, 'cwd': cwd},
    };
  };

  var nextWs = 1;
  stub.on['workspace.create'] = (params) {
    final label = (params['label'] as String?) ?? '';
    final wid = 'w_created_${nextWs++}';
    final pid = '$wid:p1';
    final cwd = params['cwd'] as String?;
    final panes = (stub.snapshot['panes'] as List).cast<Map<String, dynamic>>();
    panes.add({
      'pane_id': pid,
      'workspace_id': wid,
      'tab_id': '$wid:t1',
      'cwd': cwd,
      'agent': null,
      'agent_status': 'idle',
    });
    return {
      'type': 'workspace_created',
      'workspace': {'workspace_id': wid, 'label': label},
      'tab': {'tab_id': '$wid:t1'},
      'root_pane': {'pane_id': pid, 'cwd': cwd},
    };
  };

  return _TerminalTestRig(harness: h, machine: machine, stub: stub);
}

Future<void> _tearDown(WidgetTester tester, CreateHarness h) async {
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pump();
  h.dispose();
}

void main() {
  setUpAll(loadAppFonts);
  setUp(() {
    resetTerminalCreationLocks();
  });
  group('createTerminal unit tests', () {
    test('existing checkout workspace: creates unfocused tab with focus:false, no sendLine', () async {
      final rig = await _buildRig(
        rawWorkspaces: [
          {
            'workspace_id': 'w_repo',
            'label': 'project',
            'worktree': {
              'repo_key': 'rk1',
              'repo_name': 'project',
              'repo_root': '/repos/project',
              'checkout_path': '/repos/project',
              'is_linked_worktree': false,
            },
          },
        ],
        rawPanes: [
          {
            'pane_id': 'w_repo:p1',
            'workspace_id': 'w_repo',
            'tab_id': 'w_repo:t1',
            'cwd': '/repos/project',
            'agent_status': 'idle',
          },
        ],
      );

      final agent = await createTerminal(machine: rig.machine, cwd: '/repos/project/src');

      expect(agent, isA<PaneAgent>());
      expect(agent.machineId, 'a');
      expect(agent.paneId, 'w_repo:p2');

      expect(rig.stub.methods, ['tab.create']);
      final tabParams = rig.stub.paramsOf('tab.create').single;
      expect(tabParams['workspace_id'], 'w_repo');
      expect(tabParams['cwd'], '/repos/project/src');
      expect(tabParams['label'], 'Terminal · src');
      expect(tabParams['focus'], false);

      expect(rig.stub.methods.contains('pane.send_input'), isFalse);
      expect(rig.stub.methods.contains('workspace.create'), isFalse);
    });

    test('existing plain workspace: exact cwd match creates unfocused tab, focus:false', () async {
      final rig = await _buildRig(
        rawWorkspaces: [
          {'workspace_id': 'w_plain', 'label': 'notes'},
        ],
        rawPanes: [
          {
            'pane_id': 'w_plain:p1',
            'workspace_id': 'w_plain',
            'tab_id': 'w_plain:t1',
            'cwd': '/srv/shared-notes',
            'agent_status': 'idle',
          },
        ],
      );

      final agent = await createTerminal(machine: rig.machine, cwd: '/srv/shared-notes');

      expect(agent.paneId, 'w_plain:p2');
      expect(rig.stub.methods, ['tab.create']);
      final tabParams = rig.stub.paramsOf('tab.create').single;
      expect(tabParams['workspace_id'], 'w_plain');
      expect(tabParams['cwd'], '/srv/shared-notes');
      expect(tabParams['focus'], false);
      expect(rig.stub.methods.contains('pane.send_input'), isFalse);
    });

    test('unmatched folder: creates new folder-named workspace and reuses root pane once', () async {
      final rig = await _buildRig();

      final agent = await createTerminal(machine: rig.machine, cwd: '/opt/new-project');

      expect(agent.paneId, 'w_created_1:p1');
      expect(rig.stub.methods, ['workspace.create']);
      final wsParams = rig.stub.paramsOf('workspace.create').single;
      expect(wsParams['label'], 'new-project');
      expect(wsParams['cwd'], '/opt/new-project');
      expect(wsParams['focus'], false);
      expect(rig.stub.methods.contains('tab.create'), isFalse);
      expect(rig.stub.methods.contains('pane.send_input'), isFalse);
    });

    test('root path / creates workspace with label / and cwd /', () async {
      final rig = await _buildRig();

      final agent = await createTerminal(machine: rig.machine, cwd: '/');

      expect(agent.paneId, 'w_created_1:p1');
      expect(rig.stub.methods, ['workspace.create']);
      final wsParams = rig.stub.paramsOf('workspace.create').single;
      expect(wsParams['label'], '/');
      expect(wsParams['cwd'], '/');
      expect(wsParams['focus'], false);
    });

    test('never sends commands or queued keystrokes into plain terminal', () async {
      final rig = await _buildRig();

      await createTerminal(machine: rig.machine, cwd: '/srv/plain');

      expect(rig.stub.methods.contains('pane.send_input'), isFalse);
      expect(rig.stub.methods.contains('pane.send_keys'), isFalse);
    });

    test('missing folder / fallback cwd fails safe without close or typing', () async {
      final rig = await _buildRig();

      rig.stub.on['workspace.create'] = (params) => {
        'type': 'workspace_created',
        'workspace': {'workspace_id': 'w_fallback', 'label': 'missing'},
        'tab': {'tab_id': 'w_fallback:t1'},
        'root_pane': {'pane_id': 'w_fallback:p1', 'cwd': '/home/dev'},
      };

      await expectLater(
        createTerminal(machine: rig.machine, cwd: '/missing/directory'),
        throwsA(
          isA<AgentHostException>()
              .having((e) => e.message, 'message', contains('Directory does not exist on studio-mac'))
              .having((e) => e.message, 'message', contains('host opened /home/dev')),
        ),
      );

      expect(rig.stub.methods.contains('workspace.close'), isFalse);
      expect(rig.stub.methods.contains('pane.send_input'), isFalse);
    });

    test(
      'missing target /private/home/user with host fallback /home/user fails safe without typing or close',
      () async {
        final rig = await _buildRig();

        rig.stub.on['workspace.create'] = (params) => {
          'type': 'workspace_created',
          'workspace': {'workspace_id': 'w_fallback', 'label': 'user'},
          'tab': {'tab_id': 'w_fallback:t1'},
          'root_pane': {'pane_id': 'w_fallback:p1', 'cwd': '/home/user'},
        };

        await expectLater(
          createTerminal(machine: rig.machine, cwd: '/private/home/user'),
          throwsA(
            isA<AgentHostException>()
                .having((e) => e.message, 'message', contains('Directory does not exist on studio-mac'))
                .having((e) => e.message, 'message', contains('host opened /home/user')),
          ),
        );

        expect(rig.stub.methods.contains('workspace.close'), isFalse);
        expect(rig.stub.methods.contains('pane.send_input'), isFalse);
      },
    );

    test('git workspace with pane in unrelated cwd does not capture terminal creation', () async {
      final rig = await _buildRig(
        rawWorkspaces: [
          {
            'workspace_id': 'w_repoA',
            'number': 1,
            'label': 'repoA',
            'focused': false,
            'pane_count': 1,
            'tab_count': 1,
            'agent_status': 'idle',
            'worktree': {
              'repo_key': 'repoA-1',
              'repo_name': 'repoA',
              'repo_root': '/repos/repoA',
              'checkout_path': '/repos/repoA',
              'is_linked_worktree': false,
            },
          },
        ],
        rawPanes: [
          {
            'pane_id': 'w_repoA:p1',
            'workspace_id': 'w_repoA',
            'tab_id': 'w_repoA:t1',
            'cwd': '/notes',
            'agent_status': 'idle',
          },
        ],
      );

      // 1. Terminal for /notes creates separate folder workspace, NEVER tab.create in w_repoA
      final agent = await createTerminal(machine: rig.machine, cwd: '/notes');
      expect(agent.machineId, 'a');
      expect(rig.stub.methods.contains('workspace.create'), isTrue);
      expect(rig.stub.paramsOf('workspace.create').first, {'label': 'notes', 'cwd': '/notes', 'focus': false});
      expect(rig.stub.methods.contains('tab.create'), isFalse);
      expect(rig.stub.methods.contains('pane.send_input'), isFalse);

      rig.stub.calls.clear();

      // 2. Real checkout route still routes to w_repoA via PlaceIndex
      final repoAgent = await createTerminal(machine: rig.machine, cwd: '/repos/repoA/src');
      expect(repoAgent.machineId, 'a');
      expect(rig.stub.methods.contains('tab.create'), isTrue);
      expect(rig.stub.paramsOf('tab.create').first['workspace_id'], 'w_repoA');
      expect(rig.stub.methods.contains('pane.send_input'), isFalse);
    });

    test('unverified / null cwd fails safe without close or typing', () async {
      final rig = await _buildRig();

      rig.stub.on['workspace.create'] = (params) => {
        'type': 'workspace_created',
        'workspace': {'workspace_id': 'w_null', 'label': 'unknown'},
        'tab': {'tab_id': 'w_null:t1'},
        'root_pane': {'pane_id': 'w_null:p1', 'cwd': null},
      };

      await expectLater(
        createTerminal(machine: rig.machine, cwd: '/unverified/dir'),
        throwsA(
          isA<AgentHostException>().having(
            (e) => e.message,
            'message',
            contains('Could not verify working directory on studio-mac'),
          ),
        ),
      );

      expect(rig.stub.methods.contains('workspace.close'), isFalse);
    });

    test('offline machine fails safe immediately without API calls', () async {
      final rig = await _buildRig(enabled: false);

      await expectLater(
        createTerminal(machine: rig.machine, cwd: '/any/folder'),
        throwsA(
          isA<AgentHostException>().having(
            (e) => e.message,
            'message',
            contains('The connection to studio-mac was lost.'),
          ),
        ),
      );

      expect(rig.stub.methods, isEmpty);
    });

    test('timeout during creation reports outcome unknown without blind retry', () async {
      final rig = await _buildRig();

      rig.stub.on['workspace.create'] = (_) => throw TimeoutException('timed out');

      await expectLater(
        createTerminal(machine: rig.machine, cwd: '/opt/timeout'),
        throwsA(
          isA<AgentHostException>()
              .having((e) => e.message, 'message', contains('Creation timed out on studio-mac'))
              .having(
                (e) => e.message,
                'message',
                contains('A tab or workspace may have been created; check the machine before trying again.'),
              ),
        ),
      );

      expect(rig.stub.methods, ['workspace.create']);
      expect(rig.stub.methods.contains('pane.send_input'), isFalse);
    });

    test('transport error during creation reports outcome unknown without blind retry', () async {
      final rig = await _buildRig();

      rig.stub.on['workspace.create'] = (_) => throw const HerdrTransportException('connection reset', fatal: false);

      await expectLater(
        createTerminal(machine: rig.machine, cwd: '/opt/transport'),
        throwsA(
          isA<AgentHostException>()
              .having((e) => e.message, 'message', contains('Connection interrupted during creation on studio-mac'))
              .having(
                (e) => e.message,
                'message',
                contains('A tab or workspace may have been created; check the machine before trying again.'),
              ),
        ),
      );

      expect(rig.stub.methods, ['workspace.create']);
      expect(rig.stub.methods.contains('pane.send_input'), isFalse);
    });
  });

  group('UI widgets and creation flow', () {
    Widget buildTestApp(CreateHarness h, Widget child) {
      return MultiProvider(
        providers: [
          ChangeNotifierProvider.value(value: h.machines),
          ChangeNotifierProvider.value(value: h.fleet),
          ListenableProvider<AgentSessions>.value(value: h.agents),
          ChangeNotifierProvider.value(value: h.agentSettings),
          ChangeNotifierProvider.value(value: TerminalSettings(MemoryTerminalSettingsStore())),
          ChangeNotifierProvider(create: (_) => AppSettings(MemoryAppSettingsStore())),
          ChangeNotifierProvider(create: (_) => AgentScreens()),
          Provider<PanePreviews>(
            create: (_) => PanePreviews(changes: h.fleet, connection: h.fleet.connection),
            dispose: (_, previews) => previews.dispose(),
          ),
          Provider<TransportFactory>.value(value: (p, s, a, b) => throw StateError('unused')),
          attentionSetProvider(),
        ],
        child: MaterialApp(theme: AppTheme.light(), home: child),
      );
    }

    testWidgets('workspace actions sheet offers New terminal here (no duplicate New tab) and navigates to PaneScreen', (
      tester,
    ) async {
      final rig = await _buildRig(
        rawWorkspaces: [
          {'workspace_id': 'w1', 'label': 'main-ws'},
        ],
        rawPanes: [
          {'pane_id': 'w1:p1', 'workspace_id': 'w1', 'tab_id': 'w1:t1', 'cwd': '/work/main', 'agent_status': 'idle'},
        ],
        inWidgetTest: true,
      );

      final ws = rig.machine.snapshot.workspace('w1')!;
      await tester.pumpWidget(
        buildTestApp(
          rig.harness,
          Builder(
            builder: (ctx) => Scaffold(
              body: ElevatedButton(
                onPressed: () => showWorkspaceActions(ctx, rig.machine, ws),
                child: const Text('Open actions'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Open actions'));
      await tester.pumpAndSettle();

      expect(find.text('New terminal here'), findsOneWidget);
      expect(find.text('New tab here'), findsNothing);

      // Tapping New terminal here invokes newTab and creates tab in that workspace
      await tester.tap(find.text('New terminal here'));
      await tester.pumpAndSettle();

      expect(rig.stub.methods, ['tab.create']);
      final params = rig.stub.paramsOf('tab.create').single;
      expect(params['workspace_id'], 'w1');
      expect(params['cwd'], '/work/main');
      expect(params['focus'], false);
      expect(find.byType(PaneScreen), findsOneWidget);
      await _tearDown(tester, rig.harness);
    });

    testWidgets('MachineScreen renders New terminal button, respects offline gating, and tap opens folder picker', (
      tester,
    ) async {
      final liveRig = await _buildRig(
        rawWorkspaces: [
          {'workspace_id': 'w1', 'label': 'main-ws'},
        ],
        inWidgetTest: true,
      );

      liveRig.stub.on['file.read_dir'] = (params) => {
        'type': 'dir_entries',
        'entries': [
          {'path': '/home/dev/repo', 'name': 'repo', 'kind': 'dir'},
        ],
      };

      await tester.pumpWidget(buildTestApp(liveRig.harness, MachineScreen(machine: liveRig.machine)));
      await tester.pumpAndSettle();

      // Terminal button exists
      final terminalBtn = find.byWidgetPredicate((w) => w is CircleButton && w.tooltip == 'New terminal');
      expect(terminalBtn, findsOneWidget);

      // In live state, button is enabled
      final liveBtnWidget = tester.widget<CircleButton>(terminalBtn);
      expect(liveBtnWidget.onPressed, isNotNull);

      // Tapping opens the remote folder picker (FileBrowserScreen)
      await tester.tap(terminalBtn);
      await tester.pumpAndSettle();
      expect(find.byType(FileBrowserScreen), findsOneWidget);

      // Cancel / Back dismisses cleanly with no creation
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();
      expect(find.byType(FileBrowserScreen), findsNothing);
      expect(find.byType(MachineScreen), findsOneWidget);
      expect(liveRig.stub.methods.contains('workspace.create'), isFalse);
      expect(liveRig.stub.methods.contains('tab.create'), isFalse);

      await _tearDown(tester, liveRig.harness);

      // In offline state, button is disabled (onPressed is null)
      final offlineRig = await _buildRig(enabled: false, inWidgetTest: true);
      await tester.pumpWidget(buildTestApp(offlineRig.harness, MachineScreen(machine: offlineRig.machine)));
      await tester.pumpAndSettle();

      final offlineBtn = find.byWidgetPredicate((w) => w is CircleButton && w.tooltip == 'New terminal');
      expect(offlineBtn, findsOneWidget);
      final offlineBtnWidget = tester.widget<CircleButton>(offlineBtn);
      expect(offlineBtnWidget.onPressed, isNull);

      await _tearDown(tester, offlineRig.harness);
    });

    testWidgets(
      'MachinesScreen overflow menu: New terminal opens picker, cancel causes no creation, offline excludes action',
      (tester) async {
        final liveRig = await _buildRig(
          rawWorkspaces: [
            {'workspace_id': 'w1', 'label': 'main-ws'},
          ],
          inWidgetTest: true,
        );

        liveRig.stub.on['file.read_dir'] = (params) => {
          'type': 'dir_entries',
          'entries': [
            {'path': '/home/dev/repo', 'name': 'repo', 'kind': 'dir'},
          ],
        };

        await tester.pumpWidget(buildTestApp(liveRig.harness, const MachinesScreen()));
        await tester.pumpAndSettle();

        // Open row overflow menu
        final moreBtn = find.byTooltip('More options for studio-mac');
        expect(moreBtn, findsOneWidget);
        await tester.tap(moreBtn);
        await tester.pumpAndSettle();

        // "New terminal" action is visible for live machine
        expect(find.text('New terminal'), findsOneWidget);

        // Tapping New terminal opens the folder picker
        await tester.tap(find.text('New terminal'));
        await tester.pumpAndSettle();
        expect(find.byType(FileBrowserScreen), findsOneWidget);

        // Cancelling returns to previous screen with no creation
        await tester.tap(find.byTooltip('Back'));
        await tester.pumpAndSettle();
        expect(find.byType(FileBrowserScreen), findsNothing);
        expect(find.byType(MachinesScreen), findsOneWidget);
        expect(liveRig.stub.methods.contains('workspace.create'), isFalse);
        expect(liveRig.stub.methods.contains('tab.create'), isFalse);

        await _tearDown(tester, liveRig.harness);

        // For offline machine, overflow menu excludes "New terminal"
        final offlineRig = await _buildRig(enabled: false, inWidgetTest: true);
        await tester.pumpWidget(buildTestApp(offlineRig.harness, const MachinesScreen()));
        await tester.pumpAndSettle();

        final offlineMoreBtn = find.byTooltip('More options for studio-mac');
        expect(offlineMoreBtn, findsOneWidget);
        await tester.tap(offlineMoreBtn);
        await tester.pumpAndSettle();

        expect(find.text('New terminal'), findsNothing);
        await _tearDown(tester, offlineRig.harness);
      },
    );

    testWidgets('failed or unknown create: toast appears, original screen remains, and rapid-tap guard resets', (
      tester,
    ) async {
      final rig = await _buildRig(inWidgetTest: true);

      rig.stub.on['file.read_dir'] = (params) => {
        'type': 'dir_entries',
        'entries': [
          {'path': '/home/dev/fail', 'name': 'fail', 'kind': 'dir'},
        ],
      };

      // Script creation failure (TimeoutException -> uncertain outcome)
      rig.stub.on['workspace.create'] = (_) => throw TimeoutException('network timeout');

      await tester.pumpWidget(buildTestApp(rig.harness, MachineScreen(machine: rig.machine)));
      await tester.pumpAndSettle();

      final terminalBtn = find.byWidgetPredicate((w) => w is CircleButton && w.tooltip == 'New terminal');
      await tester.tap(terminalBtn);
      await tester.pumpAndSettle();

      expect(find.byType(FileBrowserScreen), findsOneWidget);
      expect(find.text('Choose this folder'), findsOneWidget);

      await tester.tap(find.text('Choose this folder'));
      await tester.pumpAndSettle();

      // Toast appears with mapped actionable message
      expect(find.byKey(toastKey), findsOneWidget);
      expect(
        find.descendant(of: find.byKey(toastKey), matching: find.textContaining('Creation timed out on studio-mac')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byKey(toastKey),
          matching: find.textContaining(
            'A tab or workspace may have been created; check the machine before trying again.',
          ),
        ),
        findsOneWidget,
      );

      // Navigation did not happen, user remains on screen, not PaneScreen
      expect(find.byType(PaneScreen), findsNothing);

      // Toast dismisses after dwell
      await tester.pump(const Duration(seconds: 6));
      await tester.pumpAndSettle();
      expect(find.byKey(toastKey), findsNothing);

      // Verify rapid-tap guard reset: lock was freed in finally, so subsequent tap works immediately
      // without calling resetTerminalCreationLocks()
      rig.stub.on['workspace.create'] = (params) {
        final wid = 'w_created_retry';
        final pid = '$wid:p1';
        final cwd = params['cwd'] as String?;
        final panes = (rig.stub.snapshot['panes'] as List).cast<Map<String, dynamic>>();
        panes.add({
          'pane_id': pid,
          'workspace_id': wid,
          'tab_id': '$wid:t1',
          'cwd': cwd,
          'agent': null,
          'agent_status': 'idle',
        });
        return {
          'type': 'workspace_created',
          'workspace': {'workspace_id': wid, 'label': 'fail'},
          'tab': {'tab_id': '$wid:t1'},
          'root_pane': {'pane_id': pid, 'cwd': cwd},
        };
      };
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();

      await tester.tap(terminalBtn);
      await tester.pumpAndSettle();
      expect(find.byType(FileBrowserScreen), findsOneWidget);
      await tester.tap(find.text('Choose this folder'));
      await tester.pumpAndSettle();

      // Second attempt succeeded because guard was properly released
      expect(find.byType(PaneScreen), findsOneWidget);
      await _tearDown(tester, rig.harness);
    });

    testWidgets('createTerminalFromChooser: offline machine shows toast and performs no mutation', (tester) async {
      final rig = await _buildRig(enabled: false, inWidgetTest: true);

      await tester.pumpWidget(
        buildTestApp(
          rig.harness,
          Builder(
            builder: (ctx) => Scaffold(
              body: ElevatedButton(
                onPressed: () => createTerminalFromChooser(ctx, rig.machine),
                child: const Text('New Terminal'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('New Terminal'));
      await tester.pumpAndSettle();

      expect(find.byKey(toastKey), findsOneWidget);
      expect(
        find.descendant(
          of: find.byKey(toastKey),
          matching: find.textContaining('The connection to studio-mac was lost.'),
        ),
        findsOneWidget,
      );
      expect(find.byType(FileBrowserScreen), findsNothing);
      expect(find.byType(PaneScreen), findsNothing);
      expect(rig.stub.methods, isEmpty);
      await _tearDown(tester, rig.harness);
    });

    testWidgets('createTerminalFromChooser: cancel folder selection causes no mutation', (tester) async {
      final rig = await _buildRig(inWidgetTest: true);

      // Script file listing so file browser can open
      rig.stub.on['file.read_dir'] = (params) => {
        'type': 'dir_entries',
        'entries': [
          {'path': '/home/dev/repo', 'name': 'repo', 'kind': 'dir'},
        ],
      };

      await tester.pumpWidget(
        buildTestApp(
          rig.harness,
          Builder(
            builder: (ctx) => Scaffold(
              body: ElevatedButton(
                onPressed: () => createTerminalFromChooser(ctx, rig.machine),
                child: const Text('New Terminal'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('New Terminal'));
      await tester.pumpAndSettle();

      // FileBrowserScreen should be open
      expect(find.byType(FileBrowserScreen), findsOneWidget);

      // Dismiss/cancel picker by pressing Back
      await tester.tap(find.byTooltip('Back'));
      await tester.pumpAndSettle();

      // No tab or workspace was created
      expect(rig.stub.methods.contains('workspace.create'), isFalse);
      expect(rig.stub.methods.contains('tab.create'), isFalse);
      await _tearDown(tester, rig.harness);
    });

    testWidgets('createTerminalFromChooser: selecting folder creates terminal and navigates to PaneScreen', (
      tester,
    ) async {
      final rig = await _buildRig(inWidgetTest: true);

      rig.stub.on['file.read_dir'] = (params) => {
        'type': 'dir_entries',
        'entries': [
          {'path': '/home/dev/project', 'name': 'project', 'kind': 'dir'},
        ],
      };

      await tester.pumpWidget(
        buildTestApp(
          rig.harness,
          Builder(
            builder: (ctx) => Scaffold(
              body: ElevatedButton(
                onPressed: () => createTerminalFromChooser(ctx, rig.machine),
                child: const Text('New Terminal'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('New Terminal'));
      await tester.pumpAndSettle();

      expect(find.byType(FileBrowserScreen), findsOneWidget);
      expect(find.text('Choose this folder'), findsOneWidget);

      await tester.tap(find.text('Choose this folder'));
      await tester.pumpAndSettle();

      // Workspace created for chosen folder
      expect(rig.stub.methods.contains('workspace.create'), isTrue);
      expect(find.byType(PaneScreen), findsOneWidget);
      await _tearDown(tester, rig.harness);
    });

    testWidgets('createTerminalFromChooser: rapid taps trigger single creation', (tester) async {
      final rig = await _buildRig(inWidgetTest: true);

      rig.stub.on['file.read_dir'] = (params) => {
        'type': 'dir_entries',
        'entries': [
          {'path': '/home/dev/rapid', 'name': 'rapid', 'kind': 'dir'},
        ],
      };

      await tester.pumpWidget(
        buildTestApp(
          rig.harness,
          Builder(
            builder: (ctx) => Scaffold(
              body: ElevatedButton(
                onPressed: () {
                  createTerminalFromChooser(ctx, rig.machine);
                  createTerminalFromChooser(ctx, rig.machine);
                },
                child: const Text('Double Tap'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('Double Tap'));
      await tester.pumpAndSettle();

      expect(find.byType(FileBrowserScreen), findsOneWidget);
      await tester.tap(find.text('Choose this folder'));
      await tester.pumpAndSettle();

      // Only one workspace created
      final wsCreates = rig.stub.methods.where((m) => m == 'workspace.create').length;
      expect(wsCreates, 1);
      await _tearDown(tester, rig.harness);
    });

    testWidgets('createTerminalFromChooser: unrelated Git cwd does not capture chooser creation', (tester) async {
      final rig = await _buildRig(
        inWidgetTest: true,
        rawWorkspaces: [
          {
            'workspace_id': 'w_repoA',
            'number': 1,
            'label': 'repoA',
            'focused': false,
            'pane_count': 1,
            'tab_count': 1,
            'agent_status': 'idle',
            'worktree': {
              'repo_key': 'repoA-1',
              'repo_name': 'repoA',
              'repo_root': '/repos/repoA',
              'checkout_path': '/repos/repoA',
              'is_linked_worktree': false,
            },
          },
        ],
        rawPanes: [
          {
            'pane_id': 'w_repoA:p1',
            'workspace_id': 'w_repoA',
            'tab_id': 'w_repoA:t1',
            'cwd': '/home/dev',
            'agent_status': 'idle',
          },
        ],
      );

      rig.stub.on['file.read_dir'] = (params) => {
        'type': 'dir_entries',
        'entries': [
          {'path': '/home/dev/project', 'name': 'project', 'kind': 'dir'},
        ],
      };

      await tester.pumpWidget(
        buildTestApp(
          rig.harness,
          Builder(
            builder: (ctx) => Scaffold(
              body: ElevatedButton(
                onPressed: () => createTerminalFromChooser(ctx, rig.machine),
                child: const Text('New Terminal'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('New Terminal'));
      await tester.pumpAndSettle();

      expect(find.byType(FileBrowserScreen), findsOneWidget);
      await tester.tap(find.text('Choose this folder'));
      await tester.pumpAndSettle();

      // Creates a separate folder workspace, NEVER tab.create in w_repoA
      expect(rig.stub.methods.contains('workspace.create'), isTrue);
      expect(rig.stub.paramsOf('workspace.create').first['cwd'], '/home/dev');
      expect(rig.stub.methods.contains('tab.create'), isFalse);
      expect(find.byType(PaneScreen), findsOneWidget);
      await _tearDown(tester, rig.harness);
    });
  });
}
