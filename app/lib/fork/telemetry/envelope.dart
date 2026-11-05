import 'package:herdr_mobile/data/app_info.dart';

/// Bounded enum of allowed lifecycle stages for telemetry correlation.
/// Trust is never labeled as fact unless confirmed from a reliable source.
enum TelemetryStage {
  boot,
  shellAlloc,
  agentLaunch,
  agentDetect,
  waitingAgent,
  waitingTranscript,
  transcriptLocate,
  logRead,
  fallback,
  userRetry,
  error,
}

/// Bounded enum of constant error categories. Raw error strings are never transmitted.
enum TelemetryCategory { none, network, transport, hostApi, timeout, fs, unknown }

/// Bounded enum of operating system platforms.
enum TelemetryPlatform { android, ios, macos, linux, windows, unknown }

/// Strongly-typed, allowlisted envelope for telemetry events.
///
/// Contains NO freeform message parameters, arbitrary property maps,
/// or raw exception instances.
class TelemetryEnvelope {
  const TelemetryEnvelope({
    required this.event,
    required this.stage,
    required this.category,
    required this.opId,
    required this.timestamp,
    this.retryable,
    this.release = appVersion,
    this.build = 5090,
    this.platform = TelemetryPlatform.unknown,
    this.transportKind,
    this.durationMs,
    this.attempt,
    this.stackTrace,
  });

  final String event;
  final TelemetryStage stage;
  final TelemetryCategory category;
  final String opId;
  final DateTime timestamp;
  final bool? retryable;
  final String release;
  final int build;
  final TelemetryPlatform platform;
  final String? transportKind;
  final int? durationMs;
  final int? attempt;
  final String? stackTrace;

  /// Serializes to a strictly allowlisted map.
  Map<String, Object> toJson() => {
    'event': event,
    'stage': stage.name,
    'category': category.name,
    'opId': opId,
    'release': release,
    'build': build,
    'platform': platform.name,
    'timestamp': timestamp.toIso8601String(),
    'retryable': ?retryable,
    'transportKind': ?transportKind,
    'durationMs': ?durationMs,
    'attempt': ?attempt,
    'stackTrace': ?stackTrace,
  };
}

/// Classifies any runtime error into a bounded [TelemetryCategory] solely by type.
///
/// Under no circumstances is the error message or [error.toString] retained.
TelemetryCategory classifyError(Object error) {
  final name = error.runtimeType.toString();
  if (name.contains('Timeout')) {
    return TelemetryCategory.timeout;
  }
  if (name.contains('Socket') ||
      name.contains('Http') ||
      name.contains('Handshake') ||
      name.contains('Tls') ||
      name.contains('Network') ||
      name.contains('Connection') ||
      name.contains('WebSocket')) {
    return TelemetryCategory.network;
  }
  if (name.contains('FileSystem') ||
      name.contains('PathNotFound') ||
      name.contains('File') ||
      name.contains('Directory')) {
    return TelemetryCategory.fs;
  }
  if (name.contains('Transport') || name.contains('SSH') || name.contains('Ssh') || name.contains('Channel')) {
    return TelemetryCategory.transport;
  }
  if (name.contains('HostApi') || name.contains('HerdrApi') || name.contains('Api')) {
    return TelemetryCategory.hostApi;
  }
  return TelemetryCategory.unknown;
}

/// Strict frame matcher: accepts ONLY standard Dart package or SDK code locations.
///
/// Example:
/// `#0      ClassName.methodName (package:herdr_mobile/path/to/file.dart:12:34)`
/// `#1      _CustomZone.run (dart:async/zone.dart:123:45)`
///
/// Rejects all file URLs, local paths (/Users/..., /home/...), query strings,
/// or freeform text.
final _codeFramePattern = RegExp(
  r'^#\d+\s+([A-Za-z0-9_$.<>\s]+)\s+\(((?:package|dart):[a-zA-Z0-9_./\-]+:\d+)(?::\d+)?\)$',
);

/// Sanitizes a stack trace by reconstructing only verified code-only frames.
///
/// Drops local filesystem paths, file URLs, arguments, and unverified lines.
String? sanitizeStackTrace(StackTrace? stackTrace) {
  if (stackTrace == null) return null;
  final lines = stackTrace.toString().split('\n');
  final sanitizedFrames = <String>[];

  for (final rawLine in lines) {
    final line = rawLine.trim();
    if (line.isEmpty) continue;
    final match = _codeFramePattern.firstMatch(line);
    if (match != null) {
      final symbol = match.group(1)!.trim();
      final location = match.group(2)!.trim();
      sanitizedFrames.add('#${sanitizedFrames.length} $symbol ($location)');
      if (sanitizedFrames.length >= 10) break;
    }
  }

  if (sanitizedFrames.isEmpty) return null;
  return sanitizedFrames.join('\n');
}
