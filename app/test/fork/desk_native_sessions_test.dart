import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart';
import 'package:herdr_mobile/data/observed/claude_kind.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:herdr_mobile/data/repositories/agent_session.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/pane_previews.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/fork/desk_native_sessions.dart';
import 'package:herdr_mobile/ui/features/create/new_agent_session_view_model.dart';

import '../support/create_harness.dart';
import '../support/fake_agent_host.dart';
import '../support/fake_log_source.dart';
import '../support/fake_transport.dart';
import '../support/herdr_stub.dart';

class _SpyMachineConnection extends MachineConnection {
  _SpyMachineConnection({
    required super.profile,
    required super.api,
    super.backoff,
    super.pollInterval,
    super.structuralDelay,
  });

  int waitListenerCount = 0;

  bool get hasAnyListeners => hasListeners;

  @override
  bool get isLive => true;

  @override
  void addListener(VoidCallback listener) {
    waitListenerCount++;
    super.addListener(listener);
  }

  @override
  void removeListener(VoidCallback listener) {
    waitListenerCount--;
    super.removeListener(listener);
  }
}

class _ResumeSpySessions implements AgentSessions {
  bool resumeCalled = false;
  String? passedAgent;
  String? passedSessionId;
  String? passedCwd;

  @override
  Future<AgentSessionView> resume({
    required MachineConnection machine,
    required String agent,
    required String cwd,
    required String sessionId,
    String? replaces,
  }) async {
    resumeCalled = true;
    passedAgent = agent;
    passedSessionId = sessionId;
    passedCwd = cwd;
    throw const FormatException('delegated');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  test('ordering and result', () async {
    final h = await CreateHarness.create([
      (
        profile: profileOf('a', 'studio-mac'),
        snapshot: snapshotJson(
          workspaces: [(id: 'w1', label: 'app')],
          panes: [(id: 'w1:p1', ws: 'w1', agent: null, status: 'idle')],
        ),
      ),
    ]);
    addTearDown(h.dispose);
    final host = h.hosts.putIfAbsent('a', FakeAgentHost.new);
    final machine = h.connection('a');
    final previews = PanePreviews(changes: machine, connection: (_) => machine, startGap: Duration.zero);
    addTearDown(previews.dispose);
    final observed = ObservedSessions(
      fleet: h.fleet,
      previews: previews,
      sourceFor: (_) => FakeLogSource(),
      kinds: {'claude': claudeKind},
    );
    addTearDown(observed.dispose);

    final stub = h.stubs['a']!;
    (stub.snapshot['panes'] as List).first['cwd'] = '/r/app';
    await machine.refresh();
    stub.on['tab.create'] = (params) {
      final panes = (stub.snapshot['panes'] as List).cast<Map<String, dynamic>>();
      panes.add({
        'pane_id': 'w1:p2',
        'workspace_id': 'w1',
        'tab_id': 'w1:t2',
        'cwd': params['cwd'] ?? '/r/app',
        'agent': null,
        'agent_status': 'idle',
      });
      return {
        'type': 'tab_created',
        'tab': {'tab_id': 'w1:t2'},
        'root_pane': {'pane_id': 'w1:p2', 'cwd': params['cwd'] ?? '/r/app'},
      };
    };
    stub.on['pane.send_input'] = (params) {
      scheduleMicrotask(() {
        final panes = (stub.snapshot['panes'] as List).cast<Map<String, dynamic>>();
        panes.removeWhere((p) => p['pane_id'] == 'w1:p2');
        panes.add({
          'pane_id': 'w1:p2',
          'workspace_id': 'w1',
          'tab_id': 'w1:t2',
          'cwd': '/r/app',
          'agent': 'claude',
          'agent_status': 'idle',
        });
        stub.emit({'event': 'pane_agent_detected'});
      });
      return {'type': 'input_sent'};
    };

    final wrappedSessions = DeskNativeSessions.wrap(h.agents, observed);
    final vm = NewAgentSessionViewModel(
      fleet: h.fleet,
      sessions: wrappedSessions,
      settings: h.agentSettings,
      machineId: 'a',
    );
    addTearDown(vm.dispose);
    vm.selectAgent('claude');

    final result = await vm.start('/r/app');

    expect(stub.methods, ['tab.create', 'pane.send_input']);
    final tabParams = stub.paramsOf('tab.create').first;
    expect(tabParams['workspace_id'], 'w1');
    expect(tabParams['cwd'], '/r/app');
    expect(tabParams['focus'], false);

    expect(stub.paramsOf('pane.send_input'), [
      {
        'pane_id': 'w1:p2',
        'text': 'claude',
        'keys': ['enter'],
      },
    ]);
    expect(result, isNotNull);
    expect(result!.isObserved, isTrue);
    expect(result.key, 'pane/a/w1:p2');
    expect(agentRefOf(result), const PaneAgent('a', 'w1:p2'));
    expect(host.startCalls, 0);
  });

  test('boundary (non-claude and no registry)', () async {
    final h = await CreateHarness.create([
      (
        profile: profileOf('a', 'studio-mac'),
        snapshot: snapshotJson(workspaces: [(id: 'w1', label: 'Phone sessions')]),
      ),
    ]);
    addTearDown(h.dispose);
    final host = h.hosts.putIfAbsent('a', FakeAgentHost.new);
    final machine = h.connection('a');
    final previews = PanePreviews(changes: machine, connection: (_) => machine, startGap: Duration.zero);
    addTearDown(previews.dispose);
    final observed = ObservedSessions(
      fleet: h.fleet,
      previews: previews,
      sourceFor: (_) => FakeLogSource(),
      kinds: {'claude': claudeKind},
    );
    addTearDown(observed.dispose);

    // Agent omp with decorator
    final wrappedSessions = DeskNativeSessions.wrap(h.agents, observed);
    final vmOmp = NewAgentSessionViewModel(
      fleet: h.fleet,
      sessions: wrappedSessions,
      settings: h.agentSettings,
      machineId: 'a',
    );
    addTearDown(vmOmp.dispose);
    vmOmp.selectAgent('omp');
    await vmOmp.start('/r/app');

    expect(host.startCalls, 1);
    expect(h.stubs['a']!.methods.contains('tab.create'), isFalse);

    // Agent claude through DeskNativeSessions.wrap(h.agents, null)
    final rawSessions = DeskNativeSessions.wrap(h.agents, null);
    expect(identical(rawSessions, h.agents), isTrue);

    final vmClaude = NewAgentSessionViewModel(
      fleet: h.fleet,
      sessions: rawSessions,
      settings: h.agentSettings,
      machineId: 'a',
    );
    addTearDown(vmClaude.dispose);
    vmClaude.selectAgent('claude');
    await vmClaude.start('/r/app');

    expect(host.startCalls, 2);
    expect(h.stubs['a']!.methods.contains('tab.create'), isFalse);
  });

  test('failure, herdr refuses', () async {
    final h = await CreateHarness.create([
      (
        profile: profileOf('a', 'studio-mac'),
        snapshot: snapshotJson(
          workspaces: [(id: 'w1', label: 'app')],
          panes: [(id: 'w1:p1', ws: 'w1', agent: null, status: 'idle')],
        ),
      ),
    ]);
    addTearDown(h.dispose);
    final host = h.hosts.putIfAbsent('a', FakeAgentHost.new);
    final machine = h.connection('a');
    final previews = PanePreviews(changes: machine, connection: (_) => machine, startGap: Duration.zero);
    addTearDown(previews.dispose);
    final observed = ObservedSessions(
      fleet: h.fleet,
      previews: previews,
      sourceFor: (_) => FakeLogSource(),
      kinds: {'claude': claudeKind},
    );
    addTearDown(observed.dispose);

    final stub = h.stubs['a']!;
    (stub.snapshot['panes'] as List).first['cwd'] = '/r/app';
    await machine.refresh();
    stub.on['tab.create'] = (_) => throw const HerdrApiException('x', 'refused');

    final wrappedSessions = DeskNativeSessions.wrap(h.agents, observed);
    final vm = NewAgentSessionViewModel(
      fleet: h.fleet,
      sessions: wrappedSessions,
      settings: h.agentSettings,
      machineId: 'a',
    );
    addTearDown(vm.dispose);
    vm.selectAgent('claude');

    final result = await vm.start('/r/app');
    expect(result, isNull);
    expect(vm.error?.title, 'Couldn’t start the session');
    expect(vm.error?.message, contains('refused'));
    expect(stub.methods.contains('pane.send_input'), isFalse);
    expect(host.startCalls, 0);
  });

  test('failure, claude never reported', () async {
    final h = await CreateHarness.create([
      (
        profile: profileOf('a', 'studio-mac'),
        snapshot: snapshotJson(
          workspaces: [(id: 'w1', label: 'app')],
          panes: [(id: 'w1:p1', ws: 'w1', agent: null, status: 'idle')],
        ),
      ),
    ]);
    addTearDown(h.dispose);
    final host = h.hosts.putIfAbsent('a', FakeAgentHost.new);
    final machine = h.connection('a');
    final previews = PanePreviews(changes: machine, connection: (_) => machine, startGap: Duration.zero);
    addTearDown(previews.dispose);
    final observed = ObservedSessions(
      fleet: h.fleet,
      previews: previews,
      sourceFor: (_) => FakeLogSource(),
      kinds: {'claude': claudeKind},
    );
    addTearDown(observed.dispose);

    final stub = h.stubs['a']!;
    (stub.snapshot['panes'] as List).first['cwd'] = '/r/app';
    await machine.refresh();
    stub.on['tab.create'] = (params) {
      final panes = (stub.snapshot['panes'] as List).cast<Map<String, dynamic>>();
      panes.add({
        'pane_id': 'w1:p2',
        'workspace_id': 'w1',
        'tab_id': 'w1:t2',
        'cwd': params['cwd'] ?? '/r/app',
        'agent': null,
        'agent_status': 'idle',
      });
      return {
        'type': 'tab_created',
        'tab': {'tab_id': 'w1:t2'},
        'root_pane': {'pane_id': 'w1:p2', 'cwd': params['cwd'] ?? '/r/app'},
      };
    };
    stub.on['pane.send_input'] = (_) => {'type': 'input_sent'};

    final deskSessions = DeskNativeSessions(h.agents, observed, reportTimeout: const Duration(milliseconds: 200));
    final vm = NewAgentSessionViewModel(
      fleet: h.fleet,
      sessions: deskSessions,
      settings: h.agentSettings,
      machineId: 'a',
    );
    addTearDown(vm.dispose);
    vm.selectAgent('claude');

    final result = await vm.start('/r/app');

    expect(result, isNull);
    expect(vm.error?.message, contains('didn’t start'));
    expect(host.startCalls, 0);

    // Also assert on a spy machine that wait listener is removed after timeout
    final spy = _SpyMachineConnection(
      profile: profileOf('a', 'studio-mac'),
      api: HerdrApi(stub),
      backoff: (_) => const Duration(hours: 1),
      pollInterval: const Duration(hours: 1),
      structuralDelay: const Duration(milliseconds: 20),
    );
    addTearDown(spy.dispose);
    await spy.refresh();

    try {
      await deskSessions.start(machine: spy, agent: 'claude', cwd: '/r/app');
      fail('should have timed out');
    } on AgentHostException catch (e) {
      expect(e.message, contains('didn’t start'));
    }
    expect(spy.waitListenerCount, 0);
    expect(spy.hasAnyListeners, isFalse);
  });

  test('worktree workspace chosen over Phone sessions when a linked workspace holds the cwd', () async {
    final h = await CreateHarness.create([
      (
        profile: profileOf('a', 'studio-mac'),
        snapshot: snapshotJson(workspaces: [(id: 'w1', label: 'Phone sessions')]),
      ),
    ]);
    addTearDown(h.dispose);
    final machine = h.connection('a');
    final previews = PanePreviews(changes: machine, connection: (_) => machine, startGap: Duration.zero);
    addTearDown(previews.dispose);
    final observed = ObservedSessions(
      fleet: h.fleet,
      previews: previews,
      sourceFor: (_) => FakeLogSource(),
      kinds: {'claude': claudeKind},
    );
    addTearDown(observed.dispose);

    final stub = h.stubs['a']!;
    (stub.snapshot['workspaces'] as List).add({
      'workspace_id': 'w2',
      'number': 2,
      'label': 'wt-feat',
      'focused': false,
      'pane_count': 0,
      'tab_count': 1,
      'agent_status': 'idle',
      'worktree': {
        'checkout_path': '/r/app-wt',
        'is_linked_worktree': true,
        'repo_key': 'k',
        'repo_name': 'r',
        'repo_root': '/r',
      },
    });
    await machine.refresh();

    stub.on['tab.create'] = (params) {
      final panes = (stub.snapshot['panes'] as List).cast<Map<String, dynamic>>();
      panes.add({
        'pane_id': 'w2:p2',
        'workspace_id': 'w2',
        'tab_id': 'w2:t2',
        'cwd': params['cwd'] ?? '/r/app-wt',
        'agent': null,
        'agent_status': 'idle',
      });
      return {
        'type': 'tab_created',
        'tab': {'tab_id': 'w2:t2'},
        'root_pane': {'pane_id': 'w2:p2', 'cwd': params['cwd'] ?? '/r/app-wt'},
      };
    };
    stub.on['pane.send_input'] = (params) {
      scheduleMicrotask(() {
        final panes = (stub.snapshot['panes'] as List).cast<Map<String, dynamic>>();
        panes.removeWhere((p) => p['pane_id'] == 'w2:p2');
        panes.add({
          'pane_id': 'w2:p2',
          'workspace_id': 'w2',
          'tab_id': 'w2:t2',
          'cwd': '/r/app-wt',
          'agent': 'claude',
          'agent_status': 'idle',
        });
        stub.emit({'event': 'pane_agent_detected'});
      });
      return {'type': 'input_sent'};
    };

    final wrappedSessions = DeskNativeSessions.wrap(h.agents, observed);
    final vm = NewAgentSessionViewModel(
      fleet: h.fleet,
      sessions: wrappedSessions,
      settings: h.agentSettings,
      machineId: 'a',
    );
    addTearDown(vm.dispose);
    vm.selectAgent('claude');

    final result = await vm.start('/r/app-wt');
    expect(result, isNotNull);
    final tabParams = stub.paramsOf('tab.create').first;
    expect(tabParams['workspace_id'], 'w2');
    expect(tabParams['cwd'], '/r/app-wt');
  });

  test('routing: checkout workspaces (primary, linked/nested, slash-prefix sibling)', () async {
    final rig = await _buildTestRig(
      rawWorkspaces: [
        {
          'workspace_id': 'w_primary',
          'number': 1,
          'label': 'my-repo',
          'focused': false,
          'pane_count': 1,
          'tab_count': 1,
          'agent_status': 'idle',
          'worktree': {
            'checkout_path': '/repos/project',
            'is_linked_worktree': false,
            'repo_key': 'k1',
            'repo_name': 'my-repo',
            'repo_root': '/repos/project',
          },
        },
        {
          'workspace_id': 'w_linked',
          'number': 2,
          'label': 'feat-wt',
          'focused': false,
          'pane_count': 1,
          'tab_count': 1,
          'agent_status': 'idle',
          'worktree': {
            'checkout_path': '/repos/project/worktrees/feat',
            'is_linked_worktree': true,
            'repo_key': 'k1',
            'repo_name': 'my-repo',
            'repo_root': '/repos/project',
          },
        },
      ],
    );

    // 1. Primary checkout reuse (including subdirectory)
    final r1 = await rig.sessions.start(machine: rig.machine, agent: 'claude', cwd: '/repos/project/src/lib');
    expect(r1.isObserved, isTrue);
    expect(rig.stub.methods, ['tab.create', 'pane.send_input']);
    expect(rig.stub.paramsOf('tab.create').first, {
      'workspace_id': 'w_primary',
      'cwd': '/repos/project/src/lib',
      'label': 'Claude Code · lib',
      'focus': false,
    });

    rig.stub.calls.clear();

    // 2. Linked / nested checkout preference (deepest checkout wins)
    final r2 = await rig.sessions.start(
      machine: rig.machine,
      agent: 'claude',
      cwd: '/repos/project/worktrees/feat/pkg',
    );
    expect(r2.isObserved, isTrue);
    expect(rig.stub.methods, ['tab.create', 'pane.send_input']);
    expect(rig.stub.paramsOf('tab.create').first['workspace_id'], 'w_linked');
    expect(rig.stub.paramsOf('tab.create').first['cwd'], '/repos/project/worktrees/feat/pkg');

    rig.stub.calls.clear();

    // 3. Slash-prefix sibling does not match
    final r3 = await rig.sessions.start(machine: rig.machine, agent: 'claude', cwd: '/repos/project-sibling');
    expect(r3.isObserved, isTrue);
    expect(rig.stub.methods, ['workspace.create', 'pane.send_input']);
    expect(rig.stub.paramsOf('workspace.create').first, {
      'label': 'project-sibling',
      'cwd': '/repos/project-sibling',
      'focus': false,
    });
  });

  test('routing: plain workspaces (exact cwd reuse, duplicate cwd order, duplicate basename rejection, legacy exclusion, trailing slash)', () async {
    final rig = await _buildTestRig(
      rawWorkspaces: [
        {
          'workspace_id': 'w_legacy',
          'number': 1,
          'label': 'Phone sessions',
          'focused': false,
          'pane_count': 1,
          'tab_count': 1,
          'agent_status': 'idle',
        },
        {
          'workspace_id': 'w_plain1',
          'number': 2,
          'label': 'workspace-one',
          'focused': false,
          'pane_count': 1,
          'tab_count': 1,
          'agent_status': 'idle',
        },
        {
          'workspace_id': 'w_plain2',
          'number': 3,
          'label': 'workspace-two',
          'focused': false,
          'pane_count': 1,
          'tab_count': 1,
          'agent_status': 'idle',
        },
        {
          'workspace_id': 'w_plain3',
          'number': 4,
          'label': 'project',
          'focused': false,
          'pane_count': 1,
          'tab_count': 1,
          'agent_status': 'idle',
        },
      ],
      rawPanes: [
        {
          'pane_id': 'w_legacy:p1',
          'workspace_id': 'w_legacy',
          'tab_id': 'w_legacy:t1',
          'cwd': '/srv/legacy-only',
          'agent_status': 'idle',
        },
        {
          'pane_id': 'w_plain1:p1',
          'workspace_id': 'w_plain1',
          'tab_id': 'w_plain1:t1',
          'cwd': '/srv/data',
          'agent_status': 'idle',
        },
        {
          'pane_id': 'w_plain2:p1',
          'workspace_id': 'w_plain2',
          'tab_id': 'w_plain2:t1',
          'cwd': '/srv/data',
          'agent_status': 'idle',
        },
        {
          'pane_id': 'w_plain3:p1',
          'workspace_id': 'w_plain3',
          'tab_id': 'w_plain3:t1',
          'cwd': '/opt/project',
          'agent_status': 'idle',
        },
      ],
    );

    // 1. Exact cwd plain workspace reuse + stable snapshot order (w_plain1 before w_plain2)
    final r1 = await rig.sessions.start(machine: rig.machine, agent: 'claude', cwd: '/srv/data');
    expect(r1.isObserved, isTrue);
    expect(rig.stub.methods, ['tab.create', 'pane.send_input']);
    expect(rig.stub.paramsOf('tab.create').first['workspace_id'], 'w_plain1');

    rig.stub.calls.clear();

    // 2. Trailing slash equivalence: '/srv/data/' matches '/srv/data'
    final r2 = await rig.sessions.start(machine: rig.machine, agent: 'claude', cwd: '/srv/data/');
    expect(r2.isObserved, isTrue);
    expect(rig.stub.methods, ['tab.create', 'pane.send_input']);
    expect(rig.stub.paramsOf('tab.create').first['workspace_id'], 'w_plain1');
    expect(rig.stub.paramsOf('tab.create').first['cwd'], '/srv/data/');

    rig.stub.calls.clear();

    // 3. Duplicate folder basenames do not match across different absolute paths
    final r3 = await rig.sessions.start(machine: rig.machine, agent: 'claude', cwd: '/home/user/project');
    expect(r3.isObserved, isTrue);
    expect(rig.stub.methods, ['workspace.create', 'pane.send_input']);
    expect(rig.stub.paramsOf('workspace.create').first, {
      'label': 'project',
      'cwd': '/home/user/project',
      'focus': false,
    });

    rig.stub.calls.clear();

    // 4. Exclusion of legacy Phone sessions bucket
    final r4 = await rig.sessions.start(machine: rig.machine, agent: 'claude', cwd: '/srv/legacy-only');
    expect(r4.isObserved, isTrue);
    expect(rig.stub.methods, ['workspace.create', 'pane.send_input']);
    expect(rig.stub.paramsOf('workspace.create').first, {
      'label': 'legacy-only',
      'cwd': '/srv/legacy-only',
      'focus': false,
    });

    rig.stub.calls.clear();

    // 5. Slash-prefix sibling rejection on plain workspace
    final r5 = await rig.sessions.start(machine: rig.machine, agent: 'claude', cwd: '/srv/data-sibling');
    expect(r5.isObserved, isTrue);
    expect(rig.stub.methods, ['workspace.create', 'pane.send_input']);
    expect(rig.stub.paramsOf('workspace.create').first['label'], 'data-sibling');
  });

  test('routing: fallback folder naming, root folder, and single-pane reuse', () async {
    final rig = await _buildTestRig();

    // 1. Root folder '/' creates workspace with label '/'
    final r1 = await rig.sessions.start(machine: rig.machine, agent: 'claude', cwd: '/');
    expect(r1.isObserved, isTrue);
    expect(rig.stub.methods, ['workspace.create', 'pane.send_input']);
    expect(rig.stub.paramsOf('workspace.create').first, {'label': '/', 'cwd': '/', 'focus': false});

    rig.stub.calls.clear();

    // 2. Arbitrary path creates workspace with its folder basename
    final r2 = await rig.sessions.start(machine: rig.machine, agent: 'claude', cwd: '/var/log/app-service');
    expect(r2.isObserved, isTrue);
    expect(rig.stub.methods, ['workspace.create', 'pane.send_input']);
    expect(rig.stub.paramsOf('workspace.create').first, {
      'label': 'app-service',
      'cwd': '/var/log/app-service',
      'focus': false,
    });
  });

  test('resume delegates directly to inner sessions', () async {
    final rig = await _buildTestRig();
    final spy = _ResumeSpySessions();
    final sessions = DeskNativeSessions(spy, rig.observed);
    try {
      await sessions.resume(machine: rig.machine, agent: 'claude', cwd: '/r/app', sessionId: 'sess-123');
    } on FormatException catch (e) {
      expect(e.message, 'delegated');
    }
    expect(spy.resumeCalled, isTrue);
    expect(spy.passedAgent, 'claude');
    expect(spy.passedSessionId, 'sess-123');
    expect(spy.passedCwd, '/r/app');
    expect(rig.stub.methods, isEmpty);
  });

  group('safety and routing invariants (round 2)', () {
    test('missing-folder returned fallback prevents send without auto-close (workspace and tab)', () async {
      final rig = await _buildTestRig(
        rawWorkspaces: [
          {
            'workspace_id': 'w_repo',
            'number': 1,
            'label': 'repo',
            'focused': false,
            'pane_count': 1,
            'tab_count': 1,
            'agent_status': 'idle',
            'worktree': {
              'repo_key': 'repo-1',
              'repo_name': 'repo',
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

      // 1. Workspace creation fallback to home directory prevents send and preserves shell (no close)
      rig.stub.on['workspace.create'] = (params) {
        final panes = (rig.stub.snapshot['panes'] as List).cast<Map<String, dynamic>>();
        panes.add({
          'pane_id': 'w_created:p1',
          'workspace_id': 'w_created',
          'tab_id': 'w_created:t1',
          'cwd': '/home/user',
          'agent': null,
          'agent_status': 'idle',
        });
        return {
          'type': 'workspace_created',
          'workspace': {'workspace_id': 'w_created', 'label': 'dir'},
          'tab': {'tab_id': 'w_created:t1'},
          'root_pane': {'pane_id': 'w_created:p1', 'cwd': '/home/user'},
        };
      };

      await expectLater(
        rig.sessions.start(machine: rig.machine, agent: 'claude', cwd: '/missing/dir'),
        throwsA(
          isA<AgentHostException>()
              .having((e) => e.message, 'message', contains('Directory does not exist'))
              .having((e) => e.message, 'message', contains('host opened /home/user'))
              .having((e) => e.message, 'message', contains('no agent was started')),
        ),
      );
      expect(rig.stub.methods, ['workspace.create']);
      expect(rig.stub.methods.contains('pane.send_input'), isFalse);
      expect(rig.stub.methods.contains('workspace.close'), isFalse);

      rig.stub.calls.clear();

      // 2. Tab creation fallback prevents send and preserves tab (no close)
      rig.stub.on['tab.create'] = (params) {
        final panes = (rig.stub.snapshot['panes'] as List).cast<Map<String, dynamic>>();
        panes.add({
          'pane_id': 'w_repo:p2',
          'workspace_id': 'w_repo',
          'tab_id': 'w_repo:t2',
          'cwd': '/home/user',
          'agent': null,
          'agent_status': 'idle',
        });
        return {
          'type': 'tab_created',
          'tab': {'tab_id': 'w_repo:t2'},
          'root_pane': {'pane_id': 'w_repo:p2', 'cwd': '/home/user'},
        };
      };

      await expectLater(
        rig.sessions.start(machine: rig.machine, agent: 'claude', cwd: '/repos/project/missing-sub'),
        throwsA(
          isA<AgentHostException>()
              .having((e) => e.message, 'message', contains('Directory does not exist'))
              .having((e) => e.message, 'message', contains('host opened /home/user'))
              .having((e) => e.message, 'message', contains('no agent was started')),
        ),
      );
      expect(rig.stub.methods, ['tab.create']);
      expect(rig.stub.methods.contains('pane.send_input'), isFalse);
      expect(rig.stub.methods.contains('tab.close'), isFalse);
      expect(rig.stub.methods.contains('workspace.close'), isFalse);
    });

    test('null/unknown cwd return prevents send for workspace and tab', () async {
      final rig = await _buildTestRig(
        rawWorkspaces: [
          {
            'workspace_id': 'w_repo',
            'number': 1,
            'label': 'repo',
            'focused': false,
            'pane_count': 1,
            'tab_count': 1,
            'agent_status': 'idle',
            'worktree': {
              'repo_key': 'repo-1',
              'repo_name': 'repo',
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

      // 1. Workspace creation with null/unknown cwd
      rig.stub.on['workspace.create'] = (params) => {
        'type': 'workspace_created',
        'workspace': {'workspace_id': 'w_unk', 'label': 'unk'},
        'tab': {'tab_id': 'w_unk:t1'},
        'root_pane': {'pane_id': 'w_unk:p1', 'cwd': null},
      };

      await expectLater(
        rig.sessions.start(machine: rig.machine, agent: 'claude', cwd: '/unverified/dir'),
        throwsA(
          isA<AgentHostException>()
              .having((e) => e.message, 'message', contains('Could not verify working directory'))
              .having((e) => e.message, 'message', contains('no agent was started')),
        ),
      );
      expect(rig.stub.methods.contains('pane.send_input'), isFalse);
      expect(rig.stub.methods.contains('workspace.close'), isFalse);

      rig.stub.calls.clear();

      // 2. Tab creation with null/unknown cwd on pane
      rig.stub.on['tab.create'] = (params) {
        final panes = (rig.stub.snapshot['panes'] as List).cast<Map<String, dynamic>>();
        panes.add({
          'pane_id': 'w_repo:p_unk',
          'workspace_id': 'w_repo',
          'tab_id': 'w_repo:t2',
          'cwd': null,
          'agent': null,
          'agent_status': 'idle',
        });
        return {
          'type': 'tab_created',
          'tab': {'tab_id': 'w_repo:t2'},
          'root_pane': {'pane_id': 'w_repo:p_unk'},
        };
      };

      await expectLater(
        rig.sessions.start(machine: rig.machine, agent: 'claude', cwd: '/repos/project/sub'),
        throwsA(
          isA<AgentHostException>()
              .having((e) => e.message, 'message', contains('Could not verify working directory'))
              .having((e) => e.message, 'message', contains('no agent was started')),
        ),
      );
      expect(rig.stub.methods.contains('pane.send_input'), isFalse);
      expect(rig.stub.methods.contains('tab.close'), isFalse);
    });

    test(
      'legacy + normal checkout: same checkout routes to normal, deeper legacy does not pick wrong parent',
      () async {
        final rig = await _buildTestRig(
          rawWorkspaces: [
            {
              'workspace_id': 'w_legacy_same',
              'number': 1,
              'label': 'Phone sessions',
              'focused': false,
              'pane_count': 1,
              'tab_count': 1,
              'agent_status': 'idle',
              'worktree': {
                'repo_key': 'repo-1',
                'repo_name': 'project',
                'repo_root': '/repos/project',
                'checkout_path': '/repos/project',
                'is_linked_worktree': false,
              },
            },
            {
              'workspace_id': 'w_desktop_same',
              'number': 2,
              'label': 'project',
              'focused': false,
              'pane_count': 1,
              'tab_count': 1,
              'agent_status': 'idle',
              'worktree': {
                'repo_key': 'repo-1',
                'repo_name': 'project',
                'repo_root': '/repos/project',
                'checkout_path': '/repos/project',
                'is_linked_worktree': false,
              },
            },
            {
              'workspace_id': 'w_legacy_deep',
              'number': 3,
              'label': 'Phone sessions',
              'focused': false,
              'pane_count': 1,
              'tab_count': 1,
              'agent_status': 'idle',
              'worktree': {
                'repo_key': 'repo-2',
                'repo_name': 'submodule',
                'repo_root': '/repos/project',
                'checkout_path': '/repos/project/submodule',
                'is_linked_worktree': true,
              },
            },
          ],
          rawPanes: [
            {
              'pane_id': 'w_legacy_same:p1',
              'workspace_id': 'w_legacy_same',
              'tab_id': 'w_legacy_same:t1',
              'cwd': '/repos/project',
              'agent_status': 'idle',
            },
            {
              'pane_id': 'w_desktop_same:p1',
              'workspace_id': 'w_desktop_same',
              'tab_id': 'w_desktop_same:t1',
              'cwd': '/repos/project',
              'agent_status': 'idle',
            },
            {
              'pane_id': 'w_legacy_deep:p1',
              'workspace_id': 'w_legacy_deep',
              'tab_id': 'w_legacy_deep:t1',
              'cwd': '/repos/project/submodule',
              'agent_status': 'idle',
            },
          ],
        );

        // 1. Same checkout: legacy does not mask desktop workspace
        final r1 = await rig.sessions.start(machine: rig.machine, agent: 'claude', cwd: '/repos/project/src');
        expect(r1.isObserved, isTrue);
        expect(rig.stub.methods, ['tab.create', 'pane.send_input']);
        expect(rig.stub.paramsOf('tab.create').first['workspace_id'], 'w_desktop_same');

        rig.stub.calls.clear();

        // 2. Deeper legacy checkout: does NOT route to shallower parent w_desktop_same;
        // creates a new folder workspace for 'submodule'
        final r2 = await rig.sessions.start(machine: rig.machine, agent: 'claude', cwd: '/repos/project/submodule/lib');
        expect(r2.isObserved, isTrue);
        expect(rig.stub.methods, ['workspace.create', 'pane.send_input']);
        expect(rig.stub.paramsOf('workspace.create').first['label'], 'lib');
        expect(rig.stub.paramsOf('workspace.create').first['cwd'], '/repos/project/submodule/lib');
      },
    );

    test('deterministic tie-breaking: specificity then lexicographically smallest workspace ID', () async {
      final rig = await _buildTestRig(
        rawWorkspaces: [
          {
            'workspace_id': 'w_repo_b',
            'number': 1,
            'label': 'project-b',
            'focused': false,
            'pane_count': 1,
            'tab_count': 1,
            'agent_status': 'idle',
            'worktree': {
              'repo_key': 'repo-1',
              'repo_name': 'project',
              'repo_root': '/repos/project',
              'checkout_path': '/repos/project',
              'is_linked_worktree': false,
            },
          },
          {
            'workspace_id': 'w_repo_a',
            'number': 2,
            'label': 'project-a',
            'focused': false,
            'pane_count': 1,
            'tab_count': 1,
            'agent_status': 'idle',
            'worktree': {
              'repo_key': 'repo-1',
              'repo_name': 'project',
              'repo_root': '/repos/project',
              'checkout_path': '/repos/project',
              'is_linked_worktree': false,
            },
          },
          {
            'workspace_id': 'w_plain_z',
            'number': 3,
            'label': 'notes-z',
            'focused': false,
            'pane_count': 1,
            'tab_count': 1,
            'agent_status': 'idle',
          },
          {
            'workspace_id': 'w_plain_a',
            'number': 4,
            'label': 'notes-a',
            'focused': false,
            'pane_count': 1,
            'tab_count': 1,
            'agent_status': 'idle',
          },
        ],
        rawPanes: [
          {
            'pane_id': 'w_repo_b:p1',
            'workspace_id': 'w_repo_b',
            'tab_id': 'w_repo_b:t1',
            'cwd': '/repos/project',
            'agent_status': 'idle',
          },
          {
            'pane_id': 'w_repo_a:p1',
            'workspace_id': 'w_repo_a',
            'tab_id': 'w_repo_a:t1',
            'cwd': '/repos/project',
            'agent_status': 'idle',
          },
          {
            'pane_id': 'w_plain_z:p1',
            'workspace_id': 'w_plain_z',
            'tab_id': 'w_plain_z:t1',
            'cwd': '/srv/shared-notes',
            'agent_status': 'idle',
          },
          {
            'pane_id': 'w_plain_a:p1',
            'workspace_id': 'w_plain_a',
            'tab_id': 'w_plain_a:t1',
            'cwd': '/srv/shared-notes',
            'agent_status': 'idle',
          },
        ],
      );

      // 1. Checkout tie-break: w_repo_a < w_repo_b
      final r1 = await rig.sessions.start(machine: rig.machine, agent: 'claude', cwd: '/repos/project/src');
      expect(r1.isObserved, isTrue);
      expect(rig.stub.paramsOf('tab.create').first['workspace_id'], 'w_repo_a');

      rig.stub.calls.clear();

      // 2. Exact-cwd plain workspace tie-break: w_plain_a < w_plain_z
      final r2 = await rig.sessions.start(machine: rig.machine, agent: 'claude', cwd: '/srv/shared-notes');
      expect(r2.isObserved, isTrue);
      expect(rig.stub.paramsOf('tab.create').first['workspace_id'], 'w_plain_a');
    });

    test('exact normalized path matching fails closed on /private symlink alias without typing or closing', () async {
      final rig = await _buildTestRig();

      // 1. Missing target '/private/home/user' with host fallback '/home/user' => no Claude send, error, no close
      rig.stub.on['workspace.create'] = (params) {
        final panes = (rig.stub.snapshot['panes'] as List).cast<Map<String, dynamic>>();
        panes.add({
          'pane_id': 'w_fallback:p1',
          'workspace_id': 'w_fallback',
          'tab_id': 'w_fallback:t1',
          'cwd': '/home/user',
          'agent': null,
          'agent_status': 'idle',
        });
        return {
          'type': 'workspace_created',
          'workspace': {'workspace_id': 'w_fallback', 'label': 'user'},
          'tab': {'tab_id': 'w_fallback:t1'},
          'root_pane': {'pane_id': 'w_fallback:p1', 'cwd': '/home/user'},
        };
      };

      await expectLater(
        rig.sessions.start(machine: rig.machine, agent: 'claude', cwd: '/private/home/user'),
        throwsA(
          isA<AgentHostException>()
              .having((e) => e.message, 'message', contains('Directory does not exist on studio-mac'))
              .having((e) => e.message, 'message', contains('host opened /home/user'))
              .having((e) => e.message, 'message', contains('no agent was started')),
        ),
      );
      expect(rig.stub.methods, ['workspace.create']);
      expect(rig.stub.methods.contains('pane.send_input'), isFalse);
      expect(rig.stub.methods.contains('workspace.close'), isFalse);

      rig.stub.calls.clear();

      // 2. Inverse alias: target '/home/user' with host returning '/private/home/user' fails closed
      rig.stub.on['workspace.create'] = (params) {
        final panes = (rig.stub.snapshot['panes'] as List).cast<Map<String, dynamic>>();
        panes.add({
          'pane_id': 'w_inv:p1',
          'workspace_id': 'w_inv',
          'tab_id': 'w_inv:t1',
          'cwd': '/private/home/user',
          'agent': null,
          'agent_status': 'idle',
        });
        return {
          'type': 'workspace_created',
          'workspace': {'workspace_id': 'w_inv', 'label': 'user'},
          'tab': {'tab_id': 'w_inv:t1'},
          'root_pane': {'pane_id': 'w_inv:p1', 'cwd': '/private/home/user'},
        };
      };

      await expectLater(
        rig.sessions.start(machine: rig.machine, agent: 'claude', cwd: '/home/user'),
        throwsA(
          isA<AgentHostException>()
              .having((e) => e.message, 'message', contains('Directory does not exist on studio-mac'))
              .having((e) => e.message, 'message', contains('host opened /private/home/user')),
        ),
      );
      expect(rig.stub.methods.contains('pane.send_input'), isFalse);

      rig.stub.calls.clear();

      // 3. Distinct Linux dirs: target '/data' with host returning '/private/data' fails closed
      rig.stub.on['workspace.create'] = (params) {
        final panes = (rig.stub.snapshot['panes'] as List).cast<Map<String, dynamic>>();
        panes.add({
          'pane_id': 'w_data:p1',
          'workspace_id': 'w_data',
          'tab_id': 'w_data:t1',
          'cwd': '/private/data',
          'agent': null,
          'agent_status': 'idle',
        });
        return {
          'type': 'workspace_created',
          'workspace': {'workspace_id': 'w_data', 'label': 'data'},
          'tab': {'tab_id': 'w_data:t1'},
          'root_pane': {'pane_id': 'w_data:p1', 'cwd': '/private/data'},
        };
      };

      await expectLater(
        rig.sessions.start(machine: rig.machine, agent: 'claude', cwd: '/data'),
        throwsA(
          isA<AgentHostException>()
              .having((e) => e.message, 'message', contains('Directory does not exist on studio-mac'))
              .having((e) => e.message, 'message', contains('host opened /private/data')),
        ),
      );
      expect(rig.stub.methods.contains('pane.send_input'), isFalse);

      rig.stub.calls.clear();

      // 4. Exact match, trailing slash, and root still succeed
      rig.stub.on['workspace.create'] = (params) {
        final cwd = params['cwd'] as String;
        final norm = cwd.length > 1 && cwd.endsWith('/') ? cwd.substring(0, cwd.length - 1) : cwd;
        final panes = (rig.stub.snapshot['panes'] as List).cast<Map<String, dynamic>>();
        panes.add({
          'pane_id': 'w_ok:p1',
          'workspace_id': 'w_ok',
          'tab_id': 'w_ok:t1',
          'cwd': norm,
          'agent': null,
          'agent_status': 'idle',
        });
        return {
          'type': 'workspace_created',
          'workspace': {'workspace_id': 'w_ok', 'label': 'test'},
          'tab': {'tab_id': 'w_ok:t1'},
          'root_pane': {'pane_id': 'w_ok:p1', 'cwd': norm},
        };
      };

      // 4a. Exact match
      final rExact = await rig.sessions.start(machine: rig.machine, agent: 'claude', cwd: '/srv/valid');
      expect(rExact.isObserved, isTrue);
      expect(rig.stub.methods, ['workspace.create', 'pane.send_input']);

      rig.stub.calls.clear();

      // 4b. Trailing slash
      final rTrailing = await rig.sessions.start(machine: rig.machine, agent: 'claude', cwd: '/srv/valid/');
      expect(rTrailing.isObserved, isTrue);
      expect(rig.stub.methods, ['workspace.create', 'pane.send_input']);

      rig.stub.calls.clear();

      // 4c. Root
      final rRoot = await rig.sessions.start(machine: rig.machine, agent: 'claude', cwd: '/');
      expect(rRoot.isObserved, isTrue);
      expect(rig.stub.methods, ['workspace.create', 'pane.send_input']);
    });

    test('git workspace containing pane cd-ed into unrelated directory does not capture start', () async {
      final rig = await _buildTestRig(
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

      // 1. Requesting /notes must create a separate folder workspace, NEVER createTab in w_repoA
      final r1 = await rig.sessions.start(machine: rig.machine, agent: 'claude', cwd: '/notes');
      expect(r1.isObserved, isTrue);
      expect(rig.stub.methods, ['workspace.create', 'pane.send_input']);
      expect(rig.stub.paramsOf('workspace.create').first, {'label': 'notes', 'cwd': '/notes', 'focus': false});
      expect(rig.stub.methods.contains('tab.create'), isFalse);

      rig.stub.calls.clear();

      // 2. If a valid plain workspace for /notes also exists, it reuses the plain workspace, never repoA
      (rig.stub.snapshot['workspaces'] as List).add({
        'workspace_id': 'w_plain_notes',
        'number': 2,
        'label': 'notes',
        'focused': false,
        'pane_count': 1,
        'tab_count': 1,
        'agent_status': 'idle',
      });
      (rig.stub.snapshot['panes'] as List).add({
        'pane_id': 'w_plain_notes:p1',
        'workspace_id': 'w_plain_notes',
        'tab_id': 'w_plain_notes:t1',
        'cwd': '/notes',
        'agent_status': 'idle',
      });
      await rig.machine.refresh();

      final r2 = await rig.sessions.start(machine: rig.machine, agent: 'claude', cwd: '/notes');
      expect(r2.isObserved, isTrue);
      expect(rig.stub.methods, ['tab.create', 'pane.send_input']);
      expect(rig.stub.paramsOf('tab.create').first['workspace_id'], 'w_plain_notes');
      expect(rig.stub.paramsOf('tab.create').where((p) => p['workspace_id'] == 'w_repoA'), isEmpty);

      rig.stub.calls.clear();

      // 3. Real checkout route in repoA still routes to w_repoA via PlaceIndex
      final r3 = await rig.sessions.start(machine: rig.machine, agent: 'claude', cwd: '/repos/repoA/src');
      expect(r3.isObserved, isTrue);
      expect(rig.stub.methods, ['tab.create', 'pane.send_input']);
      expect(rig.stub.paramsOf('tab.create').first['workspace_id'], 'w_repoA');
    });

    test('uncertain creation outcome distinguishes rejected vs unknown; no blind retry, no send, no close', () async {
      final rig = await _buildTestRig();

      // 1. TimeoutException -> outcome unknown, actionable message indicating tab may have been created
      rig.stub.on['workspace.create'] = (_) => throw TimeoutException('timed out');

      await expectLater(
        rig.sessions.start(machine: rig.machine, agent: 'claude', cwd: '/opt/timeout-test'),
        throwsA(
          isA<AgentHostException>()
              .having((e) => e.message, 'message', contains('Creation timed out on studio-mac'))
              .having((e) => e.message, 'message', contains('A tab or workspace may have been created'))
              .having((e) => e.message, 'message', contains('check the machine before trying again')),
        ),
      );
      expect(rig.stub.methods, ['workspace.create']);
      expect(rig.stub.methods.contains('pane.send_input'), isFalse);
      expect(rig.stub.methods.contains('workspace.close'), isFalse);

      rig.stub.calls.clear();

      // 2. HerdrTransportException -> outcome unknown
      rig.stub.on['workspace.create'] = (_) => throw const HerdrTransportException('connection reset', fatal: false);

      await expectLater(
        rig.sessions.start(machine: rig.machine, agent: 'claude', cwd: '/opt/transport-test'),
        throwsA(
          isA<AgentHostException>()
              .having((e) => e.message, 'message', contains('Connection interrupted during creation on studio-mac'))
              .having((e) => e.message, 'message', contains('A tab or workspace may have been created')),
        ),
      );
      expect(rig.stub.methods, ['workspace.create']);
      expect(rig.stub.methods.contains('pane.send_input'), isFalse);

      rig.stub.calls.clear();

      // 3. HerdrApiException -> request rejected explicitly, no claim that something was created
      rig.stub.on['workspace.create'] = (_) => throw const HerdrApiException('permission_denied', 'Permission denied');

      await expectLater(
        rig.sessions.start(machine: rig.machine, agent: 'claude', cwd: '/opt/rejected-test'),
        throwsA(isA<AgentHostException>().having((e) => e.message, 'message', 'Permission denied')),
      );
      expect(rig.stub.methods, ['workspace.create']);
      expect(rig.stub.methods.contains('pane.send_input'), isFalse);
    });
  });
}

Future<
  ({
    CreateHarness harness,
    MachineConnection machine,
    HerdrStub stub,
    FakeAgentHost host,
    ObservedSessions observed,
    DeskNativeSessions sessions,
  })
>
_buildTestRig({
  List<({String id, String label})> workspaces = const [],
  List<Map<String, Object>> rawWorkspaces = const [],
  List<Map<String, Object>> rawPanes = const [],
}) async {
  final snap = snapshotJson(workspaces: workspaces);
  for (final w in rawWorkspaces) {
    (snap['workspaces'] as List).add(w);
  }
  for (final p in rawPanes) {
    (snap['panes'] as List).add(p);
  }

  final h = await CreateHarness.create([(profile: profileOf('a', 'studio-mac'), snapshot: snap)]);
  final machine = h.connection('a');
  final previews = PanePreviews(changes: machine, connection: (_) => machine, startGap: Duration.zero);
  final observed = ObservedSessions(
    fleet: h.fleet,
    previews: previews,
    sourceFor: (_) => FakeLogSource(),
    kinds: {'claude': claudeKind},
  );
  addTearDown(() {
    observed.dispose();
    previews.dispose();
    h.dispose();
  });
  final stub = h.stubs['a']!;
  final host = h.hosts.putIfAbsent('a', FakeAgentHost.new);

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

  stub.on['pane.send_input'] = (params) {
    final pid = params['pane_id'] as String;
    scheduleMicrotask(() {
      final panes = (stub.snapshot['panes'] as List).cast<Map<String, dynamic>>();
      final existingCwd = panes.where((p) => p['pane_id'] == pid).firstOrNull?['cwd'];
      panes.removeWhere((p) => p['pane_id'] == pid);
      panes.add({
        'pane_id': pid,
        'workspace_id': pid.split(':').first,
        'tab_id': '${pid.split(':').first}:t1',
        'cwd': existingCwd ?? '/test',
        'agent': 'claude',
        'agent_status': 'idle',
      });
      stub.emit({'event': 'pane_agent_detected'});
    });
    return {'type': 'input_sent'};
  };

  final sessions = DeskNativeSessions(h.agents, observed);
  return (harness: h, machine: machine, stub: stub, host: host, observed: observed, sessions: sessions);
}
