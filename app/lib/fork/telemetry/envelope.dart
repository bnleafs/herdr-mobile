import 'package:herdr_mobile/data/app_info.dart';

import 'scrubber.dart';

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
  linkLive,
  chatContentShown,
  messageDelivery,
  resumeReconnect,
  terminalCreation,
  appUpdateCheck,
  appUpdateDownload,
  uiStall,
  appSession,
}

/// Bounded connection path category for linkLive telemetry.
enum ConnectPath { coldStart, rebuiltResume, refreshedResume }

/// Bounded stage outcome category.
enum StageOutcome { success, failure, cancelled, upToDate, foundUpdate }

/// Bounded enum of constant error categories. Raw error strings are never transmitted.
enum TelemetryCategory { none, network, transport, hostApi, timeout, fs, unknown }

/// Bounded enum of operating system platforms.
enum TelemetryPlatform { android, ios, macos, linux, windows, unknown }

/// Structured envelope for telemetry events.
class TelemetryEnvelope {
  static const defaultBuild = 5091;

  const TelemetryEnvelope({
    required this.event,
    required this.stage,
    required this.category,
    required this.opId,
    required this.timestamp,
    this.retryable,
    this.release = appVersion,
    this.build = defaultBuild,
    this.platform = TelemetryPlatform.unknown,
    this.transportKind,
    this.connectPath,
    this.durationMs,
    this.attempt,
    this.stackTrace,
    this.outcome,
    this.reconnectCount,
    this.uiStallMs,
    this.machineLabel,
    this.agentKind,
    this.routeName,
    this.errorString,
    this.sessionLengthBucket,
    this.foregroundCount,
    this.backgroundCount,
    this.installId,
    this.user = 'jaya',
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
  final ConnectPath? connectPath;
  final int? durationMs;
  final int? attempt;
  final String? stackTrace;
  final StageOutcome? outcome;
  final int? reconnectCount;
  final int? uiStallMs;
  final String? machineLabel;
  final String? agentKind;
  final String? routeName;
  final String? errorString;
  final String? sessionLengthBucket;
  final int? foregroundCount;
  final int? backgroundCount;
  final String? installId;
  final String user;

  /// Serializes to a strongly-typed map.
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
    'connectPath': ?connectPath?.name,
    'durationMs': ?durationMs,
    'attempt': ?attempt,
    'stackTrace': ?stackTrace,
    'outcome': ?outcome?.name,
    'reconnectCount': ?reconnectCount,
    'uiStallMs': ?uiStallMs,
    'machineLabel': ?machineLabel,
    'agentKind': ?agentKind,
    'routeName': ?routeName,
    'errorString': ?errorString,
    'sessionLengthBucket': ?sessionLengthBucket,
    'foregroundCount': ?foregroundCount,
    'backgroundCount': ?backgroundCount,
    'installId': ?installId,
    'user': user,
  };
}

/// Classifies any runtime error into a bounded [TelemetryCategory] by type.
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

/// Sanitizes a stack trace by scrubbing credentials and sensitive text.
/// Preserves full Dart stack traces with code locations.
String? sanitizeStackTrace(StackTrace? stackTrace) {
  if (stackTrace == null) return null;
  return megawattScrubber.scrubText(stackTrace.toString());
}
