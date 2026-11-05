import 'dart:async';

import 'package:flutter/material.dart';
import 'package:herdr_mobile/ui/core/kit.dart';

import '../data/acp/agent_host.dart';
import '../data/models/remote_file.dart';
import '../data/repositories/agent_screens.dart';
import '../data/repositories/machine_connection.dart';
import '../ui/features/agents/agent_navigation.dart';
import '../ui/features/files/files_navigation.dart';
import 'desk_native_sessions.dart';

/// Creates a plain terminal pane on [machine] in [cwd] using shared placement:
/// reuses an existing matching checkout or plain workspace with a new tab, or creates
/// a new folder-named workspace and reuses its root pane.
/// Never sends startup commands, queued keystrokes, or prompt text into the shell.
Future<PaneAgent> createTerminal({required MachineConnection machine, required String cwd}) async {
  final paneId = await allocateNativeShellPane(
    machine: machine,
    cwd: cwd,
    tabLabel: 'Terminal · ${RemotePath.basename(cwd)}',
    startingAgent: false,
  );
  return PaneAgent(machine.profile.id, paneId);
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
