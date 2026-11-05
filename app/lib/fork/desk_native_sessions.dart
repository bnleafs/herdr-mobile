import 'dart:async';

import 'package:flutter/foundation.dart';

import '../data/acp/agent_host.dart';
import '../data/acp/past_session.dart';
import '../data/models/places.dart';
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
    final paneId = await allocateNativeShellPane(
      machine: machine,
      cwd: cwd,
      tabLabel: 'Claude Code · ${RemotePath.basename(cwd)}',
      startingAgent: true,
    );

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

/// Allocates and verifies a new shell pane in [cwd] on [machine] following the shared
/// placement contract:
/// - Reuses an existing matching checkout workspace or exact-cwd plain workspace with an
///   unfocused tab (focus: false).
/// - If unmatched, creates a new unfocused workspace (focus: false) named after the
///   folder basename and reuses its initial root pane.
/// Verifies the target directory before returning the pane ID.
/// Does NOT send any startup command into the shell, and does NOT auto-close or
/// delete the shell on mismatch or error.
Future<String> allocateNativeShellPane({
  required MachineConnection machine,
  required String cwd,
  String? tabLabel,
  bool startingAgent = false,
}) async {
  if (!machine.isLive) {
    throw AgentHostException('The connection to ${machine.profile.label} was lost.');
  }

  String paneId;
  String? createdCwd;
  try {
    final wid = findWorkspaceForCwd(machine, cwd);
    if (wid != null) {
      final tab = await machine.api.createTab(workspaceId: wid, cwd: cwd, label: tabLabel, focus: false);
      paneId = tab.rootPaneId;
      createdCwd = machine.paneById(paneId)?.cwd;
    } else {
      final ws = await machine.api.createWorkspace(cwd: cwd, label: RemotePath.basename(cwd), focus: false);
      paneId = ws.rootPaneId;
      createdCwd = ws.cwd ?? machine.paneById(paneId)?.cwd;
    }
  } on Exception catch (e) {
    throw AgentHostException(mapCreationError(e, machine));
  }

  if (createdCwd == null) {
    var pane = machine.paneById(paneId);
    if (pane == null || pane.cwd == null) {
      try {
        await machine.refresh().timeout(Dwell.refreshTimeout);
      } on Exception {
        // Bounded check best-effort
      }
      pane = machine.paneById(paneId);
    }
    createdCwd = pane?.cwd;
  }

  final agentNotice = startingAgent ? ' A shell was opened, but no agent was started.' : '';

  if (createdCwd == null) {
    throw AgentHostException('Could not verify working directory on ${machine.profile.label}: $cwd.$agentNotice');
  }

  if (!isMatchingPath(createdCwd, cwd)) {
    throw AgentHostException(
      'Directory does not exist on ${machine.profile.label}: $cwd (host opened $createdCwd).$agentNotice',
    );
  }

  if (machine.paneById(paneId) == null) {
    try {
      await machine.refresh().timeout(Dwell.refreshTimeout);
    } on Exception {
      // Best-effort cache synchronization
    }
  }

  return paneId;
}

/// Resolves an existing workspace for [cwd] on [machine]:
/// 1. Deepest matching checkout workspace (primary or linked), excluding legacy 'Phone sessions'.
/// 2. Deterministic lowest workspace ID tie-break among equal specificity checkout matches.
/// 3. Exact matching plain workspace cwd, excluding legacy 'Phone sessions'.
/// 4. Deterministic lowest workspace ID tie-break among plain workspace matches.
String? findWorkspaceForCwd(MachineConnection machine, String cwd) {
  final allPlace = PlaceIndex.of(machine.snapshot).of(cwd);
  if (allPlace != null) {
    final deepestPath = allPlace.checkoutPath;
    final matchingCheckouts = [
      for (final w in machine.snapshot.workspaces)
        if (w.label != 'Phone sessions' &&
            w.worktree != null &&
            normalizePath(w.worktree!.checkoutPath) == normalizePath(deepestPath))
          w,
    ];
    if (matchingCheckouts.isNotEmpty) {
      matchingCheckouts.sort((a, b) => a.id.compareTo(b.id));
      return matchingCheckouts.first.id;
    }
  }

  final targetCwd = normalizePath(cwd);
  final matchingPlain = [
    for (final w in machine.snapshot.workspaces)
      if (w.label != 'Phone sessions' &&
          w.worktree == null &&
          machine.snapshot.panes.any(
            (p) => p.workspaceId == w.id && p.cwd != null && normalizePath(p.cwd!) == targetCwd,
          ))
        w,
  ];
  if (matchingPlain.isNotEmpty) {
    matchingPlain.sort((a, b) => a.id.compareTo(b.id));
    return matchingPlain.first.id;
  }
  return null;
}

String normalizePath(String path) {
  if (path.length <= 1) return path;
  var end = path.length;
  while (end > 1 && path.codeUnitAt(end - 1) == 0x2F /* '/' */ ) {
    end--;
  }
  return path.substring(0, end);
}

bool isMatchingPath(String actual, String target) {
  final normActual = normalizePath(actual);
  final normTarget = normalizePath(target);
  // shortcut: legitimate symlink aliases fail closed, until authoritative canonicalisation exists.
  return normActual == normTarget;
}

String mapCreationError(Object e, MachineConnection machine) {
  if (e is HerdrUnsupportedException) {
    final v = machine.snapshot.version;
    return 'herdr${v.isEmpty ? '' : ' $v'} on ${machine.profile.label} can’t do this. '
        'Update herdr on that machine.';
  }
  if (e is HerdrApiException) {
    return e.message;
  }
  if (e is TimeoutException) {
    return 'Creation timed out on ${machine.profile.label}. '
        'A tab or workspace may have been created; check the machine before trying again.';
  }
  if (e is HerdrTransportException) {
    return 'Connection interrupted during creation on ${machine.profile.label}: ${e.message}. '
        'A tab or workspace may have been created; check the machine before trying again.';
  }
  return e.toString();
}
