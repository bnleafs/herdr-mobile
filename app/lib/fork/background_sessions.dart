import 'dart:convert';

import '../data/models/remote_file.dart';
import '../data/repositories/agent_screens.dart';
import '../data/repositories/machine_connection.dart';
import '../data/repositories/session_launcher.dart' show quoteShell;
import 'desk_native_sessions.dart' show allocateNativeShellPane;
import 'telemetry/envelope.dart';
import 'telemetry/telemetry.dart';

/// Maximum session files scanned from ~/.claude/sessions.
const int maxBackgroundSessionFiles = 64;

/// Maximum size in bytes read per session pid file.
const int maxBackgroundSessionFileSize = 64 * 1024;

/// Represents a Claude background session running under `claude daemon`.
class BackgroundSession {
  const BackgroundSession({
    required this.sessionId,
    required this.cwd,
    this.name,
    this.status,
    this.updatedAt,
    this.pid,
    this.jobId,
  });

  final String sessionId;
  final String cwd;
  final String? name;
  final String? status;
  final DateTime? updatedAt;
  final int? pid;
  final String? jobId;

  bool get isBusy => status == 'busy';

  static final _uuidPattern = RegExp(r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$');

  static bool isValidSessionId(String id) => _uuidPattern.hasMatch(id);

  static BackgroundSession? fromJson(Map<String, dynamic> json) {
    if (json['kind'] != 'bg') return null;
    final sessionId = json['sessionId'];
    if (sessionId is! String || !isValidSessionId(sessionId)) return null;
    final cwd = json['cwd'];
    if (cwd is! String || cwd.isEmpty) return null;

    final name = json['name'] as String?;
    final status = json['status'] as String?;
    final rawUpdatedAt = json['updatedAt'];
    final DateTime? updatedAt = switch (rawUpdatedAt) {
      int ms => DateTime.fromMillisecondsSinceEpoch(ms),
      num n => DateTime.fromMillisecondsSinceEpoch(n.toInt()),
      String s => DateTime.tryParse(s),
      _ => null,
    };
    final rawPid = json['pid'];
    final int? pid = switch (rawPid) {
      int p => p,
      num n => n.toInt(),
      _ => null,
    };
    final jobId = json['jobId'] as String?;

    return BackgroundSession(
      sessionId: sessionId,
      cwd: cwd,
      name: name,
      status: status,
      updatedAt: updatedAt,
      pid: pid,
      jobId: jobId,
    );
  }
}

/// Sorts busy sessions first, then newest updatedAt, then sessionId.
int compareBackgroundSessions(BackgroundSession a, BackgroundSession b) {
  if (a.isBusy && !b.isBusy) return -1;
  if (!a.isBusy && b.isBusy) return 1;
  final aTime = a.updatedAt?.millisecondsSinceEpoch ?? 0;
  final bTime = b.updatedAt?.millisecondsSinceEpoch ?? 0;
  final timeCompare = bTime.compareTo(aTime);
  if (timeCompare != 0) return timeCompare;
  return a.sessionId.compareTo(b.sessionId);
}

/// Lists Claude Code background sessions on [machine] by reading ~/.claude/sessions/*.json.
///
/// Bounded to [maxBackgroundSessionFiles] files and [maxBackgroundSessionFileSize] bytes per file.
/// Errors (no folder, permissions, offline) return an empty list and call [onReason] with a quiet string.
Future<List<BackgroundSession>> listBackgroundSessions(
  MachineConnection machine, {
  void Function(String reason)? onReason,
  bool record = true,
}) async {
  if (!machine.isLive) {
    onReason?.call('Offline');
    return const [];
  }
  final opId = ForkTelemetry.instance.generateOpId();
  try {
    final home = await machine.files.home();
    final dir = '$home/.claude/sessions';
    final entries = await machine.files.list(dir);
    final jsonFiles = entries
        .where((e) => e.isFile && e.name.endsWith('.json'))
        .take(maxBackgroundSessionFiles)
        .toList();

    final sessions = <BackgroundSession>[];
    for (final entry in jsonFiles) {
      final path = '$dir/${entry.name}';
      try {
        final bytes = await machine.files.read(path, length: maxBackgroundSessionFileSize + 1);
        if (bytes.length > maxBackgroundSessionFileSize) continue;
        final decoded = jsonDecode(utf8.decode(bytes, allowMalformed: true));
        if (decoded is Map<String, dynamic>) {
          final session = BackgroundSession.fromJson(decoded);
          if (session != null) {
            sessions.add(session);
          }
        }
      } catch (_) {
        // Skip invalid JSON or read errors silently.
      }
    }

    sessions.sort(compareBackgroundSessions);

    if (record) {
      ForkTelemetry.instance.recordStage(
        opId: opId,
        stage: TelemetryStage.backgroundList,
        backgroundCount: sessions.length,
        outcome: StageOutcome.success,
      );
    }

    return sessions;
  } catch (e) {
    onReason?.call(e.toString());
    if (record) {
      ForkTelemetry.instance.recordStage(
        opId: opId,
        stage: TelemetryStage.backgroundList,
        backgroundCount: 0,
        outcome: StageOutcome.failure,
      );
    }
    return const [];
  }
}

/// Attaches to [session] on [machine] in a new terminal pane.
///
/// Allocates a terminal pane in [session.cwd], sends exactly one command
/// `claude attach '<sessionId>'` + Enter, and returns the [PaneAgent].
Future<PaneAgent> attachBackgroundSession({
  required MachineConnection machine,
  required BackgroundSession session,
}) async {
  final stopwatch = Stopwatch()..start();
  final opId = ForkTelemetry.instance.generateOpId();
  try {
    final paneId = await allocateNativeShellPane(
      machine: machine,
      cwd: session.cwd,
      tabLabel: 'Terminal · ${RemotePath.basename(session.cwd)}',
      startingAgent: false,
    );
    final cmd = 'claude attach ${quoteShell(session.sessionId)}';
    await machine.api.sendLine(paneId, cmd);
    ForkTelemetry.instance.recordStage(
      opId: opId,
      stage: TelemetryStage.backgroundAttach,
      durationMs: stopwatch.elapsedMilliseconds,
      outcome: StageOutcome.success,
    );
    return PaneAgent(machine.profile.id, paneId);
  } catch (e, s) {
    ForkTelemetry.instance.recordError(
      opId: opId,
      stage: TelemetryStage.backgroundAttach,
      durationMs: stopwatch.elapsedMilliseconds,
      error: e,
      stackTrace: s,
      outcome: StageOutcome.failure,
    );
    rethrow;
  }
}
