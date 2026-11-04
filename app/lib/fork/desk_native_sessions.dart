import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/acp/agent_host.dart';
import '../data/acp/past_session.dart';
import '../data/models/remote_file.dart';
import '../data/repositories/agent_screens.dart';
import '../data/repositories/agent_session.dart';
import '../data/repositories/fleet_agent.dart';
import '../data/repositories/machine_connection.dart';
import '../data/repositories/observed_session.dart';
import '../data/repositories/observed_sessions.dart';
import '../data/services/herdr_api.dart';
import '../data/services/herdr_transport.dart';
import '../ui/core/motion.dart';

export '../data/repositories/observed_sessions.dart' show ObservedSessions;

/// The command typed into the shell to start Claude Code.
const deskCommand = 'claude';

/// The reference the agent screen opens [session] by: a pane for an observed
/// chat, an agent session otherwise (what upstream always passed).
AgentRef agentRefOf(AgentSessionView session) =>
    session is ObservedAgentSession ? PaneAgent(session.machine.profile.id, session.paneId) : SessionAgent(session.key);

/// Wraps [inner]; only `start` for the `claude` route changes.
class DeskNativeSessions implements AgentSessions {
  DeskNativeSessions(this._inner, this._observed, {this.reportTimeout = const Duration(seconds: 30)});

  final AgentSessions _inner;
  final ObservedSessions _observed;

  /// How long to wait for herdr to detect `claude` in the created pane.
  final Duration reportTimeout;

  /// [inner] unchanged when [observed] is null (the app has no observed sessions,
  /// e.g. the test boot), so nothing can differ from upstream there.
  static AgentSessions wrap(AgentSessions inner, ObservedSessions? observed) =>
      observed == null ? inner : DeskNativeSessions(inner, observed);

  @override
  List<AgentSessionView> get sessions => _inner.sessions;

  @override
  AgentSessionView? byKey(String key) => _inner.byKey(key);

  @override
  Future<Set<String>> available(MachineConnection machine) => _inner.available(machine);

  @override
  Future<PastSessions> history({required MachineConnection machine, required String agent, String? cwd}) =>
      _inner.history(machine: machine, agent: agent, cwd: cwd);

  @override
  Future<AgentSessionView> resume({
    required MachineConnection machine,
    required String agent,
    required String cwd,
    required String sessionId,
    String? replaces,
  }) => _inner.resume(machine: machine, agent: agent, cwd: cwd, sessionId: sessionId, replaces: replaces);

  @override
  Future<void> refresh() => _inner.refresh();

  @override
  void setBoardVisible(bool visible) => _inner.setBoardVisible(visible);

  @override
  set keepAliveInBackground(bool value) => _inner.keepAliveInBackground = value;

  @override
  Preconnect preconnect(String sessionKey) => _inner.preconnect(sessionKey);

  @override
  void addListener(VoidCallback listener) => _inner.addListener(listener);

  @override
  void removeListener(VoidCallback listener) => _inner.removeListener(listener);

  @override
  Future<AgentSessionView> start({required MachineConnection machine, required String agent, required String cwd}) {
    if (agent != 'claude') {
      return _inner.start(machine: machine, agent: agent, cwd: cwd);
    }
    return _startClaude(machine: machine, cwd: cwd);
  }

  Future<AgentSessionView> _startClaude({required MachineConnection machine, required String cwd}) async {
    String paneId;
    try {
      final wid = _findWorkspaceForCwd(machine, cwd);
      if (wid != null) {
        final tab = await machine.api.createTab(
          workspaceId: wid,
          cwd: cwd,
          label: 'Claude Code · ${RemotePath.basename(cwd)}',
          focus: false,
        );
        paneId = tab.rootPaneId;
      } else {
        final ws = await machine.api.createWorkspace(cwd: cwd, label: 'Phone sessions', focus: false);
        paneId = ws.rootPaneId;
      }
    } on Exception catch (e) {
      throw AgentHostException(_mapError(e, machine));
    }

    try {
      await machine.api.sendLine(paneId, deskCommand);
    } on Exception catch (e) {
      final reason = _mapError(e, machine);
      throw AgentHostException('A tab was opened on ${machine.profile.label}, but $deskCommand was not typed: $reason');
    }

    await _waitForClaude(machine, paneId);

    final session = _observed.forPane(machine, paneId);
    if (session == null) {
      throw AgentHostException(
        'Claude Code started on ${machine.profile.label}, but this app cannot follow its session.',
      );
    }
    return session;
  }

  String? _findWorkspaceForCwd(MachineConnection machine, String cwd) {
    final here = cwd.endsWith('/') ? cwd.substring(0, cwd.length - 1) : cwd;
    String? bestWid;
    var bestLen = -1;

    for (final w in machine.snapshot.workspaces) {
      final wt = w.worktree;
      if (wt == null || !wt.isLinked) continue;
      final rawPath = wt.checkoutPath;
      if (rawPath.isEmpty) continue;
      final checkoutPath = rawPath.endsWith('/') ? rawPath.substring(0, rawPath.length - 1) : rawPath;
      if (here == checkoutPath || here.startsWith('$checkoutPath/')) {
        if (checkoutPath.length > bestLen) {
          bestWid = w.id;
          bestLen = checkoutPath.length;
        }
      }
    }
    if (bestWid != null) return bestWid;

    for (final w in machine.snapshot.workspaces) {
      if (w.label == 'Phone sessions') {
        return w.id;
      }
    }
    return null;
  }

  Future<void> _waitForClaude(MachineConnection machine, String paneId) async {
    if (!machine.isLive) {
      throw AgentHostException('The connection to ${machine.profile.label} was lost.');
    }
    final pane = machine.paneById(paneId);
    if (pane != null && FleetAgent.kindOf(pane) == 'claude') {
      return;
    }

    final completer = Completer<void>();
    var seenPane = pane != null;

    void check() {
      if (!machine.isLive) {
        if (!completer.isCompleted) {
          completer.completeError(AgentHostException('The connection to ${machine.profile.label} was lost.'));
        }
        return;
      }
      final p = machine.paneById(paneId);
      if (p != null) {
        seenPane = true;
        if (FleetAgent.kindOf(p) == 'claude') {
          if (!completer.isCompleted) completer.complete();
        }
      } else if (seenPane) {
        if (!completer.isCompleted) {
          completer.completeError(AgentHostException('The tab on ${machine.profile.label} was closed.'));
        }
      }
    }

    machine.addListener(check);
    final timer = Timer(reportTimeout, () {
      if (!completer.isCompleted) {
        final timeDesc = reportTimeout.inSeconds > 0
            ? '${reportTimeout.inSeconds} s'
            : '${reportTimeout.inMilliseconds} ms';
        completer.completeError(
          AgentHostException(
            'Claude Code didn’t start in the new tab within $timeDesc. '
            'It may still be starting; check the tab on the machine.',
          ),
        );
      }
    });

    try {
      try {
        await machine.refresh().timeout(Dwell.refreshTimeout);
      } on Exception {
        // Best effort: slow or offline hosts will update via events or poll.
      }
      check();
      await completer.future;
    } finally {
      timer.cancel();
      machine.removeListener(check);
    }
  }

  String _mapError(Object e, MachineConnection machine) {
    if (e is HerdrUnsupportedException) {
      final v = machine.snapshot.version;
      return 'herdr${v.isEmpty ? '' : ' $v'} on ${machine.profile.label} can’t do this. '
          'Update herdr on that machine.';
    }
    if (e is HerdrApiException) {
      return e.message;
    }
    if (e is HerdrTransportException) {
      return e.message;
    }
    if (e is TimeoutException) {
      return 'The machine didn’t answer in time.';
    }
    return e.toString();
  }
}
