import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/acp/agent_host.dart';
import 'package:herdr_mobile/data/observed/claude_kind.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
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

void main() {
  test('ordering and result', () async {
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

    final stub = h.stubs['a']!;
    stub.on['tab.create'] = (_) => {
      'type': 'tab_created',
      'tab': {'tab_id': 'w1:t2'},
      'root_pane': {'pane_id': 'w1:p2'},
    };
    stub.on['pane.send_input'] = (params) {
      scheduleMicrotask(() {
        final panes = (stub.snapshot['panes'] as List).cast<Map<String, dynamic>>();
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

    final stub = h.stubs['a']!;
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

    final stub = h.stubs['a']!;
    stub.on['tab.create'] = (_) => {
      'type': 'tab_created',
      'tab': {'tab_id': 'w1:t2'},
      'root_pane': {'pane_id': 'w1:p2'},
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

    final sw = Stopwatch()..start();
    final result = await vm.start('/r/app');
    sw.stop();

    expect(result, isNull);
    expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
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

    stub.on['tab.create'] = (_) => {
      'type': 'tab_created',
      'tab': {'tab_id': 'w2:t2'},
      'root_pane': {'pane_id': 'w2:p2'},
    };
    stub.on['pane.send_input'] = (params) {
      scheduleMicrotask(() {
        final panes = (stub.snapshot['panes'] as List).cast<Map<String, dynamic>>();
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
}
