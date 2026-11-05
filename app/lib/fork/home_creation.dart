import 'dart:async';

import 'package:flutter/material.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../data/repositories/fleet_repository.dart';
import '../data/repositories/machine_connection.dart';
import '../ui/features/create/new_agent_session_screen.dart';
import 'terminal_creation.dart';

bool _openingHomeChooser = false;

@visibleForTesting
void resetHomeCreationLocks() {
  _openingHomeChooser = false;
}

/// Opens the creation chooser when the user taps '+' on the home board.
/// Lets the person choose between starting an agent session or creating a terminal.
Future<void> showHomeCreationChooser(BuildContext context) async {
  if (_openingHomeChooser) return;
  _openingHomeChooser = true;

  try {
    final fleet = context.read<FleetRepository>();
    final connections = fleet.connections;

    await showActionSheet(
      context,
      title: 'New',
      actions: [
        SheetAction(
          label: 'Agent session',
          icon: HerdrIcons.agents,
          onTap: () {
            if (context.mounted) {
              unawaited(openNewAgentSession(context));
            }
          },
        ),
        SheetAction(
          label: 'Terminal',
          icon: LucideIcons.terminal,
          onTap: () {
            if (context.mounted) {
              unawaited(_startTerminal(context, connections));
            }
          },
        ),
      ],
    );
  } finally {
    _openingHomeChooser = false;
  }
}

Future<void> _startTerminal(BuildContext context, List<MachineConnection> connections) async {
  if (!context.mounted) return;
  if (connections.isEmpty) {
    Toaster.of(context).show('No machines available.', kind: ToastKind.failed);
    return;
  }

  // If there is only one machine and it is live, follow the house convention
  // (auto-select that machine).
  if (connections.length == 1 && connections.first.isLive) {
    await createTerminalFromChooser(context, connections.first);
    return;
  }

  // When multiple machines exist, or the single machine is offline, prompt
  // with honest availability.
  await showActionSheet(
    context,
    title: 'Machine',
    actions: [
      for (final m in connections)
        SheetAction(
          label: m.profile.label,
          icon: HerdrIcons.machines,
          unavailable: !m.isLive ? 'Offline' : null,
          onTap: () {
            if (context.mounted) {
              unawaited(createTerminalFromChooser(context, m));
            }
          },
        ),
    ],
  );
}
