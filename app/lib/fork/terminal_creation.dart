import 'dart:async';

import 'package:flutter/material.dart';
import 'package:herdr_mobile/ui/core/kit.dart';

import '../data/acp/agent_host.dart';
import '../data/models/remote_file.dart';
import '../data/repositories/agent_screens.dart';
import '../data/repositories/machine_connection.dart';
import '../data/words/place_name.dart';
import '../ui/features/agents/agent_navigation.dart';
import '../ui/features/create/session_start_support.dart';
export '../ui/features/create/session_start_support.dart' show NewSessionError;
import '../ui/features/files/files_navigation.dart';
import 'desk_native_sessions.dart';
import 'telemetry/envelope.dart';
import 'telemetry/telemetry.dart';

/// Creates a plain terminal pane on [machine] in [cwd] using shared placement:
/// reuses an existing matching checkout or plain workspace with a new tab, or creates
/// a new folder-named workspace and reuses its root pane.
/// Never sends startup commands, queued keystrokes, or prompt text into the shell.
Future<PaneAgent> createTerminal({required MachineConnection machine, required String cwd}) async {
  final stopwatch = Stopwatch()..start();
  final opId = ForkTelemetry.instance.generateOpId();
  try {
    final paneId = await allocateNativeShellPane(
      machine: machine,
      cwd: cwd,
      tabLabel: 'Terminal · ${RemotePath.basename(cwd)}',
      startingAgent: false,
    );
    ForkTelemetry.instance.recordStage(
      opId: opId,
      stage: TelemetryStage.terminalCreation,
      durationMs: stopwatch.elapsedMilliseconds,
      machineLabel: machine.profile.label,
      outcome: StageOutcome.success,
    );
    return PaneAgent(machine.profile.id, paneId);
  } catch (e, s) {
    ForkTelemetry.instance.recordError(
      opId: opId,
      stage: TelemetryStage.terminalCreation,
      durationMs: stopwatch.elapsedMilliseconds,
      machineLabel: machine.profile.label,
      error: e,
      stackTrace: s,
      outcome: StageOutcome.failure,
    );
    rethrow;
  }
}

/// Tracks machine IDs currently creating a terminal to guard against
/// duplicate submits from rapid taps.
final _creatingTerminals = <String>{};

@visibleForTesting
void resetTerminalCreationLocks() {
  _creatingTerminals.clear();
}

/// Prompts the user to pick a folder on [machine], creates a plain terminal in that
/// folder using shared placement, and navigates to [PaneScreen].
Future<void> createTerminalFromChooser(BuildContext context, MachineConnection machine) async {
  if (!machine.isLive) {
    Toaster.of(context).show('The connection to ${machine.profile.label} was lost.', kind: ToastKind.failed);
    return;
  }
  if (!machineSupportsFiles(machine)) {
    Toaster.of(context).show(
      'herdr on ${machine.profile.label} can’t browse files. Update herdr on that machine.',
      kind: ToastKind.failed,
    );
    return;
  }

  final key = machine.profile.id;
  if (!_creatingTerminals.add(key)) return;

  try {
    final picked = await pickRemoteDirectory(context, machine);
    if (picked == null || !context.mounted) return;

    final paneAgent = await createTerminal(machine: machine, cwd: picked);
    if (!context.mounted) return;
    await openAgent(context, paneAgent);
  } on AgentHostException catch (e) {
    if (context.mounted) {
      Toaster.of(context).show(e.message, kind: ToastKind.failed);
    }
  } on Exception catch (e) {
    if (context.mounted) {
      Toaster.of(context).show(mapCreationError(e, machine), kind: ToastKind.failed);
    }
  } finally {
    _creatingTerminals.remove(key);
  }
}

/// Starts a plain terminal from the unified "New session" form on [machine] in [cwd].
///
/// Guards against offline machines and rapid double-taps.
/// Allocates a native shell pane (sending zero commands), then:
/// - If [open] is true: replaces the route with [PaneScreen].
/// - If [open] is false: pops the form, staying on the board with the house "started" toast.
Future<void> startTerminalFromForm({
  required BuildContext context,
  required MachineConnection machine,
  required String cwd,
  required bool open,
  required void Function(bool busy) onBusy,
  required void Function(NewSessionError? error) onError,
}) async {
  if (!machine.isLive) {
    Toaster.of(context).show('The connection to ${machine.profile.label} was lost.', kind: ToastKind.failed);
    return;
  }

  final key = machine.profile.id;
  if (!_creatingTerminals.add(key)) return;

  final nav = Navigator.of(context);
  final toaster = Toaster.of(context);
  onBusy(true);
  onError(null);

  try {
    final paneAgent = await createTerminal(machine: machine, cwd: cwd);
    if (!context.mounted) return;

    if (open) {
      unawaited(openAgent(context, paneAgent, replace: true));
    } else {
      nav.pop();
      showStartedToast(
        toaster,
        message: 'Terminal started in ${placeName(machine.places, cwd)} · ${machine.profile.label}',
        onOpen: () {
          if (nav.mounted) {
            unawaited(openAgent(nav.context, paneAgent));
          }
        },
      );
    }
  } on AgentHostException catch (e) {
    if (context.mounted) {
      onError(NewSessionError('Couldn’t create terminal', e.message));
      toaster.show(e.message, kind: ToastKind.failed);
    }
  } on Exception catch (e) {
    if (context.mounted) {
      final msg = mapCreationError(e, machine);
      onError(NewSessionError('Couldn’t create terminal', msg));
      toaster.show(msg, kind: ToastKind.failed);
    }
  } finally {
    _creatingTerminals.remove(key);
    onBusy(false);
  }
}
