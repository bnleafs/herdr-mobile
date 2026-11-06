import 'dart:async';

import 'package:flutter/material.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

import '../data/models/herdr_models.dart' show AgentStatus;
import '../data/observed/claude_locator.dart';
import '../data/observed/session_log_locator.dart';
import '../data/repositories/machine_connection.dart';
import '../data/words/elapsed.dart' show formatAgo;
import '../ui/features/agents/agent_navigation.dart';
import '../ui/features/history/past_sessions_navigation.dart';
import 'background_sessions.dart';

/// Screen listing Claude Code background sessions on [machine].
///
/// Refreshes on pull-to-refresh and polls on a periodic timer only while on screen.
class BackgroundSessionsScreen extends StatefulWidget {
  const BackgroundSessionsScreen({super.key, required this.machine});

  final MachineConnection machine;

  @override
  State<BackgroundSessionsScreen> createState() => _BackgroundSessionsScreenState();
}

class _BackgroundSessionsScreenState extends State<BackgroundSessionsScreen> {
  Timer? _pollTimer;
  List<BackgroundSession>? _sessions;
  bool _loading = true;
  String? _reason;
  final Set<String> _attachingIds = {};

  @override
  void initState() {
    super.initState();
    _load();
    _pollTimer = Timer.periodic(const Duration(seconds: 4), (_) {
      if (mounted) _load(silent: true);
    });
  }

  @override
  void dispose() {
    _pollTimer?.cancel();
    super.dispose();
  }

  Future<void> _load({bool silent = false}) async {
    if (!silent && mounted) {
      setState(() => _loading = true);
    }
    final result = await listBackgroundSessions(
      widget.machine,
      onReason: (r) => _reason = r,
    );
    if (!mounted) return;
    setState(() {
      _sessions = result;
      _loading = false;
    });
  }

  Future<void> _attach(BackgroundSession session) async {
    final toaster = Toaster.of(context);
    if (!_attachingIds.add(session.sessionId)) return;
    setState(() {});
    try {
      final paneAgent = await attachBackgroundSession(
        machine: widget.machine,
        session: session,
      );
      if (!mounted) return;
      await openAgent(context, paneAgent);
    } catch (e) {
      if (mounted) {
        toaster.show('Failed to attach: $e', kind: ToastKind.failed);
      }
    } finally {
      if (mounted) {
        setState(() => _attachingIds.remove(session.sessionId));
      }
    }
  }

  Future<void> _openTranscript(BackgroundSession session) async {
    final toaster = Toaster.of(context);
    final loc = await ClaudeLocator().locateById(
      widget.machine.files,
      session.sessionId,
      cwd: session.cwd,
    );
    if (!mounted) return;
    if (loc is Located) {
      await openPastSessionTranscript(context, widget.machine, loc.path);
    } else if (loc is NotYet) {
      toaster.show(loc.why, kind: ToastKind.info);
    } else if (loc is Unlinked) {
      toaster.show(loc.why, kind: ToastKind.info);
    }
  }

  void _showActions(BackgroundSession session) {
    showActionSheet(
      context,
      title: session.name != null && session.name!.isNotEmpty ? session.name! : 'Claude session',
      actions: [
        SheetAction(
          label: 'Attach in terminal',
          icon: LucideIcons.terminal,
          onTap: () => unawaited(_attach(session)),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ds = context.ds;
    final sessions = _sessions ?? const [];
    final inset = MediaQuery.paddingOf(context).bottom;

    Widget filler(Widget child) => SliverFillRemaining(
      hasScrollBody: false,
      child: Padding(padding: EdgeInsets.only(bottom: inset), child: child),
    );

    return Scaffold(
      backgroundColor: ds.bg,
      body: RefreshIndicator(
        onRefresh: () => _load(silent: true),
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            SliverLargeTitle.back(
              title: 'Background sessions',
              subtitle: Text(
                widget.machine.profile.label,
                style: Type.secondary.copyWith(color: ds.textSecondary),
              ),
            ),
            if (_loading && _sessions == null)
              filler(
                const Center(
                  child: BusySpinner(size: IconSize.lead),
                ),
              )
            else if (sessions.isEmpty)
              filler(
                EmptyState(
                  icon: LucideIcons.terminal,
                  title: 'No background sessions',
                  message: _reason ?? 'Claude background sessions running on ${widget.machine.profile.label} appear here.',
                ),
              )
            else
              SliverList.builder(
                itemCount: sessions.length,
                itemBuilder: (context, i) {
                  final session = sessions[i];
                  final isBusy = session.isBusy;
                  final isAttaching = _attachingIds.contains(session.sessionId);
                  final title = session.name != null && session.name!.isNotEmpty
                      ? session.name!
                      : 'Claude session';
                  final subtitle = cwdTail(session.cwd);
                  final subtitle2 = [
                    if (session.updatedAt != null) formatAgo(session.updatedAt!, DateTime.now()),
                    isBusy ? 'Busy' : 'Idle',
                  ].join(' · ');

                  return ListRow(
                    leading: StatusGlyph(status: isBusy ? AgentStatus.working : AgentStatus.idle),
                    title: title,
                    subtitle: subtitle.isEmpty ? null : subtitle,
                    subtitle2: subtitle2,
                    onTap: isAttaching ? null : () => unawaited(_openTranscript(session)),
                    trailing: isAttaching
                        ? const BusySpinner(size: IconSize.row)
                        : IconButton(
                            icon: const Icon(LucideIcons.ellipsis, size: IconSize.row),
                            tooltip: 'Actions',
                            onPressed: () => _showActions(session),
                          ),
                  );
                },
              ),
          ],
        ),
      ),
    );
  }
}
