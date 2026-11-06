import 'dart:async';

import 'package:flutter/material.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:provider/provider.dart';

import '../data/repositories/fleet_repository.dart';
import '../data/repositories/machine_connection.dart';
import 'background_sessions.dart';
import 'background_sessions_screen.dart';

/// Compact entry on the home board that appears only when background sessions exist (N > 0).
class BackgroundBoardEntry extends StatefulWidget {
  const BackgroundBoardEntry({super.key, this.machine});

  final MachineConnection? machine;

  @override
  State<BackgroundBoardEntry> createState() => _BackgroundBoardEntryState();
}

class _BackgroundBoardEntryState extends State<BackgroundBoardEntry> {
  Timer? _pollTimer;
  Map<String, List<BackgroundSession>> _counts = const {};

  @override
  void initState() {
    super.initState();
    _refresh();
    // The board is home: a slow count is enough, each pass reads every pid file over SFTP.
    _pollTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) _refresh();
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    final explicit = widget.machine;
    final List<MachineConnection> machines;
    if (explicit != null) {
      machines = [explicit];
    } else {
      final fleet = context.read<FleetRepository?>();
      machines = fleet?.connections.where((c) => c.isLive).toList() ?? const [];
    }

    if (machines.isEmpty) {
      if (mounted && _counts.isNotEmpty) {
        setState(() => _counts = const {});
      }
      return;
    }

    final next = <String, List<BackgroundSession>>{};
    for (final m in machines) {
      final sessions = await listBackgroundSessions(m, record: false);
      if (sessions.isNotEmpty) {
        next[m.profile.id] = sessions;
      }
    }

    if (!mounted) return;
    setState(() => _counts = next);
  }

  @override
  Widget build(BuildContext context) {
    if (_counts.isEmpty) return const SizedBox.shrink();

    final fleet = context.read<FleetRepository?>();
    final entries = <Widget>[];

    for (final entry in _counts.entries) {
      final m = fleet?.connection(entry.key) ?? widget.machine;
      if (m == null) continue;
      final count = entry.value.length;
      entries.add(
        ListRow(
          leading: const Icon(LucideIcons.terminal, size: IconSize.row),
          title: 'Background · $count',
          subtitle: m.profile.label,
          trailing: const Icon(LucideIcons.chevronRight, size: IconSize.row),
          onTap: () =>
              Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => BackgroundSessionsScreen(machine: m))),
        ),
      );
    }

    if (entries.isEmpty) return const SizedBox.shrink();

    return Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: entries);
  }
}
