import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:herdr_mobile/data/app_info.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:sentry_flutter/sentry_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'envelope.dart';
import 'queue.dart';
import 'scrubber.dart';
import 'session_tracker.dart';
import 'stall_detector.dart';

/// Testable sink interface for sending sanitized telemetry to external providers.
abstract interface class TelemetrySink {
  Future<void> init();
  Future<void> sendMilestone(TelemetryEnvelope envelope);
  Future<void> sendError(TelemetryEnvelope envelope);
  Future<void> reset();
  Future<void> close();
}

const _megawattMark = 'megawatt';

/// Deny-list scrubber and allow-list filter for breadcrumbs.
/// Keeps Megawatt milestones, navigation breadcrumbs (route names only), and GitHub HTTP breadcrumbs.
@visibleForTesting
Breadcrumb? megawattBeforeBreadcrumb(Breadcrumb? breadcrumb, Hint hint) {
  if (breadcrumb == null) return null;
  final isMegawatt = breadcrumb.type == _megawattMark;
  final isNav = breadcrumb.category == 'navigation';
  final isHttp = breadcrumb.category == 'http' || breadcrumb.type == 'http';

  if (!isMegawatt && !isNav && !isHttp) {
    return null;
  }

  // Filter HTTP breadcrumbs to GitHub update requests
  if (isHttp) {
    final urlStr = breadcrumb.data?['url']?.toString() ?? '';
    if (!urlStr.contains('github.com') && !urlStr.contains('githubusercontent.com')) {
      return null;
    }
  }

  // Navigation breadcrumbs: preserve route names only, drop arguments/state
  if (isNav && breadcrumb.data != null) {
    breadcrumb.data!.remove('fromArgs');
    breadcrumb.data!.remove('toArgs');
    breadcrumb.data!.remove('arguments');
    breadcrumb.data!.remove('state');
  }

  return megawattScrubber.scrubBreadcrumb(breadcrumb);
}

/// Deny-list scrubber for Sentry events.
/// Scrubs credentials and sensitive text while preserving real exceptions and stack traces.
@visibleForTesting
SentryEvent? megawattBeforeSend(SentryEvent event, Hint hint) => megawattScrubber.scrubEvent(event);

/// Allow-list filter and deny-list scrubber for Sentry logs.
/// Drops any log not marked as Megawatt; scrubs credentials from allowed logs.
@visibleForTesting
SentryLog? megawattBeforeSendLog(SentryLog log, Hint hint) {
  if (log.attributes['source']?.value != _megawattMark) {
    return null;
  }
  return megawattScrubber.scrubLog(log);
}

/// Sentry adapter: structured logs, timing distribution metrics, and native crash/error capture.
class SentryTelemetrySink implements TelemetrySink {
  SentryTelemetrySink({required this.dsn, String? installId}) : _installId = installId ?? 'uninitialized';

  final String dsn;
  String _installId;
  bool _initialized = false;

  void setInstallId(String id) {
    _installId = id;
  }

  @override
  Future<void> init() async {
    if (dsn.isEmpty || _initialized) return;
    try {
      await SentryFlutter.init((options) {
        options.dsn = dsn;
        options.enableNativeCrashHandling = true;
        options.anrEnabled = true;
        options.environment = 'release';
        options.release = '$appVersion+${TelemetryEnvelope.defaultBuild}';
        options.dist = '${TelemetryEnvelope.defaultBuild}';
        options.attachScreenshot = false;
        options.attachViewHierarchy = false;
        options.replay.sessionSampleRate = 0;
        options.replay.onErrorSampleRate = 0;
        options.recordHttpBreadcrumbs = true;
        options.beforeBreadcrumb = megawattBeforeBreadcrumb;
        options.beforeSend = megawattBeforeSend;
        options.beforeSendLog = megawattBeforeSendLog;

        // Remove screenshot, view hierarchy and session replay integrations
        for (final i in List<Integration>.from(options.integrations)) {
          final name = i.runtimeType.toString();
          if (name.contains('Screenshot') || name.contains('ViewHierarchy') || name.contains('Replay')) {
            options.removeIntegration(i);
          }
        }
      }).timeout(const Duration(seconds: 3));
      _initialized = true;
      await Sentry.configureScope((scope) {
        scope.setUser(SentryUser(id: 'jaya'));
        scope.setTag('install_id', _installId);
      });
    } catch (_) {
      // Isolate SDK initialization errors: never disrupt app boot
    }
  }

  @override
  Future<void> sendMilestone(TelemetryEnvelope envelope) async {
    if (!_initialized) return;
    try {
      // 1. Structured Sentry Log
      final level = switch (envelope.stage) {
        TelemetryStage.error => SentryLogLevel.error,
        TelemetryStage.fallback ||
        TelemetryStage.userRetry ||
        TelemetryStage.chatReload ||
        TelemetryStage.uiStall => SentryLogLevel.warn,
        _ when envelope.category != TelemetryCategory.none => SentryLogLevel.warn,
        _ => SentryLogLevel.info,
      };

      final attributes = <String, SentryAttribute>{
        'source': SentryAttribute.string(_megawattMark),
        'stage': SentryAttribute.string(envelope.stage.name),
        'category': SentryAttribute.string(envelope.category.name),
        'opId': SentryAttribute.string(envelope.opId),
        'release': SentryAttribute.string(envelope.release),
        'build': SentryAttribute.int(envelope.build),
        'platform': SentryAttribute.string(envelope.platform.name),
        if (envelope.durationMs != null) 'durationMs': SentryAttribute.int(envelope.durationMs!),
        if (envelope.attempt != null) 'attempt': SentryAttribute.int(envelope.attempt!),
        if (envelope.retryable != null) 'retryable': SentryAttribute.bool(envelope.retryable!),
        if (envelope.transportKind != null) 'transportKind': SentryAttribute.string(envelope.transportKind!),
        if (envelope.connectPath != null) 'connectPath': SentryAttribute.string(envelope.connectPath!.name),
        if (envelope.outcome != null) 'outcome': SentryAttribute.string(envelope.outcome!.name),
        if (envelope.reconnectCount != null) 'reconnectCount': SentryAttribute.int(envelope.reconnectCount!),
        if (envelope.uiStallMs != null) 'uiStallMs': SentryAttribute.int(envelope.uiStallMs!),
        if (envelope.machineLabel != null) 'machineLabel': SentryAttribute.string(envelope.machineLabel!),
        if (envelope.agentKind != null) 'agentKind': SentryAttribute.string(envelope.agentKind!),
        if (envelope.routeName != null) 'routeName': SentryAttribute.string(envelope.routeName!),
        if (envelope.errorString != null) 'errorString': SentryAttribute.string(envelope.errorString!),
        if (envelope.sessionLengthBucket != null)
          'sessionLengthBucket': SentryAttribute.string(envelope.sessionLengthBucket!),
        if (envelope.foregroundCount != null) 'foregroundCount': SentryAttribute.int(envelope.foregroundCount!),
        if (envelope.backgroundCount != null) 'backgroundCount': SentryAttribute.int(envelope.backgroundCount!),
        if (envelope.locateRoute != null) 'locateRoute': SentryAttribute.string(envelope.locateRoute!),
        if (envelope.sessionMismatch != null) 'sessionMismatch': SentryAttribute.bool(envelope.sessionMismatch!),
      };

      switch (level) {
        case SentryLogLevel.info:
          Sentry.logger.info(envelope.stage.name, attributes: attributes);
        case SentryLogLevel.warn:
          Sentry.logger.warn(envelope.stage.name, attributes: attributes);
        case SentryLogLevel.error:
          Sentry.logger.error(envelope.stage.name, attributes: attributes);
        default:
          Sentry.logger.info(envelope.stage.name, attributes: attributes);
      }

      // 2. Sentry Distribution Metrics for durations
      if (envelope.durationMs != null) {
        final metricTags = <String, SentryAttribute>{
          'stage': SentryAttribute.string(envelope.stage.name),
          'category': SentryAttribute.string(envelope.category.name),
          if (envelope.connectPath != null) 'connectPath': SentryAttribute.string(envelope.connectPath!.name),
          if (envelope.outcome != null) 'outcome': SentryAttribute.string(envelope.outcome!.name),
        };
        Sentry.metrics.distribution(
          'megawatt.${envelope.stage.name}_ms',
          envelope.durationMs!,
          unit: SentryMetricUnit.millisecond,
          attributes: metricTags,
        );
      }

      // 3. Sentry Counts for anomalies
      final isAnomaly =
          envelope.stage == TelemetryStage.fallback ||
          envelope.stage == TelemetryStage.userRetry ||
          envelope.stage == TelemetryStage.chatReload ||
          envelope.stage == TelemetryStage.uiStall ||
          envelope.stage == TelemetryStage.error ||
          envelope.outcome == StageOutcome.failure ||
          envelope.category != TelemetryCategory.none;
      if (isAnomaly) {
        Sentry.metrics.count(
          'megawatt.anomaly',
          1,
          attributes: {
            'stage': SentryAttribute.string(envelope.stage.name),
            'category': SentryAttribute.string(envelope.category.name),
          },
        );
      }

      // 4. Breadcrumb
      await Sentry.addBreadcrumb(
        Breadcrumb(
          type: _megawattMark,
          message: envelope.stage.name,
          category: envelope.category.name,
          data: {
            'opId': envelope.opId,
            if (envelope.durationMs != null) 'durationMs': envelope.durationMs,
            if (envelope.outcome != null) 'outcome': envelope.outcome!.name,
            if (envelope.machineLabel != null) 'machineLabel': envelope.machineLabel,
            if (envelope.agentKind != null) 'agentKind': envelope.agentKind,
          },
          timestamp: envelope.timestamp,
        ),
      );
    } catch (_) {}
  }

  @override
  Future<void> sendError(TelemetryEnvelope envelope) async {
    if (!_initialized) return;
    // Prevent duplicate capture of FlutterError.onError events already caught by FlutterErrorIntegration
    if (envelope.stage == TelemetryStage.error && envelope.opId.startsWith('flutter_err_')) {
      return;
    }
    try {
      // Also emit structured Sentry log, metric distribution/count, and breadcrumb
      await sendMilestone(envelope);

      final sentryEvent = SentryEvent(
        message: SentryMessage(envelope.errorString ?? envelope.category.name),
        level: SentryLevel.error,
        tags: {
          'source': _megawattMark,
          'stage': envelope.stage.name,
          'category': envelope.category.name,
          'opId': envelope.opId,
          'platform': envelope.platform.name,
          if (envelope.transportKind != null) 'transportKind': envelope.transportKind!,
          if (envelope.machineLabel != null) 'machineLabel': envelope.machineLabel!,
          if (envelope.agentKind != null) 'agentKind': envelope.agentKind!,
        },
        timestamp: envelope.timestamp,
      );
      await Sentry.captureEvent(sentryEvent).timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  @override
  Future<void> reset() async {
    if (!_initialized) return;
    try {
      await Sentry.configureScope((scope) => scope.clear());
    } catch (_) {}
  }

  @override
  Future<void> close() async {
    if (!_initialized) return;
    try {
      await Sentry.close();
      _initialized = false;
    } catch (_) {}
  }
}

/// PostHog adapter: milestone events and errors with rich properties.
class PostHogTelemetrySink implements TelemetrySink {
  PostHogTelemetrySink({required this.apiKey, required this.host});

  final String apiKey;
  final String host;
  bool _initialized = false;

  @override
  Future<void> init() async {
    if (apiKey.isEmpty || _initialized) return;
    try {
      final config = PostHogConfig(apiKey);
      if (host.isNotEmpty) {
        config.host = host;
      }
      config.captureApplicationLifecycleEvents = false;
      config.preloadFeatureFlags = false;
      config.sendFeatureFlagEvent = false;
      config.surveys = false;
      config.sessionReplay = false;
      config.capturePushNotificationSubscriptions = false;
      config.personProfiles = PostHogPersonProfiles.never;
      config.errorTrackingConfig.captureFlutterErrors = false;
      config.errorTrackingConfig.captureSilentFlutterErrors = false;
      config.errorTrackingConfig.capturePlatformDispatcherErrors = false;
      config.errorTrackingConfig.captureNativeExceptions = false;

      await Posthog().setup(config).timeout(const Duration(seconds: 3));
      _initialized = true;
    } catch (_) {
      // Isolate SDK initialization errors: never disrupt app boot
    }
  }

  @override
  Future<void> sendMilestone(TelemetryEnvelope envelope) async {
    if (!_initialized) return;
    try {
      await Posthog()
          .capture(eventName: envelope.event, properties: envelope.toJson())
          .timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  @override
  Future<void> sendError(TelemetryEnvelope envelope) async {
    if (!_initialized) return;
    try {
      await Posthog().capture(eventName: 'error', properties: envelope.toJson()).timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  @override
  Future<void> reset() async {
    if (!_initialized) return;
    try {
      await Posthog().reset().timeout(const Duration(seconds: 2));
    } catch (_) {}
  }

  @override
  Future<void> close() async {
    if (!_initialized) return;
    try {
      await Posthog().close().timeout(const Duration(seconds: 2));
      _initialized = false;
    } catch (_) {}
  }
}

/// Main observability module for Megawatt fork.
class ForkTelemetry {
  ForkTelemetry._({
    required this._sinks,
    TelemetryQueue? queue,
    required this._enabled,
    required this._isConfigured,
    String? installId,
    DateTime Function()? clock,
  }) : _queue = queue ?? TelemetryQueue(clock: clock),
       _clock = clock ?? DateTime.now,
       _installId = installId ?? _generateHex(16),
       stallDetector = UiStallDetector(clock: clock),
       sessionTracker = AppSessionTracker(clock: clock);

  /// Creates a telemetry instance configured from compile-time environment variables.
  factory ForkTelemetry.fromEnvironment({
    String sentryDsn = const String.fromEnvironment('MEGAWATT_SENTRY_DSN'),
    String posthogKey = const String.fromEnvironment('MEGAWATT_POSTHOG_KEY'),
    String posthogHost = const String.fromEnvironment('MEGAWATT_POSTHOG_HOST'),
  }) {
    final sinks = <TelemetrySink>[];
    final hasSentry = sentryDsn.isNotEmpty;
    final hasPostHog = posthogKey.isNotEmpty;

    if (hasSentry) {
      sinks.add(SentryTelemetrySink(dsn: sentryDsn));
    }
    if (hasPostHog) {
      sinks.add(PostHogTelemetrySink(apiKey: posthogKey, host: posthogHost));
    }

    final isConfigured = hasSentry || hasPostHog;
    // Default enabled ONLY in release mode when at least one provider is configured
    final enabled = kReleaseMode && isConfigured;

    return ForkTelemetry._(sinks: sinks, enabled: enabled, isConfigured: isConfigured);
  }

  /// Internal constructor for tests with injected sinks.
  @visibleForTesting
  factory ForkTelemetry.withSinks({
    required List<TelemetrySink> sinks,
    TelemetryQueue? queue,
    bool enabled = true,
    bool preInitialized = true,
    String? installId,
    DateTime Function()? clock,
  }) {
    final t = ForkTelemetry._(
      sinks: sinks,
      queue: queue,
      enabled: enabled,
      isConfigured: sinks.isNotEmpty,
      installId: installId,
      clock: clock,
    );
    if (preInitialized) {
      t._readySinks.addAll(sinks);
      t._initialized = true;
    }
    return t;
  }

  static ForkTelemetry? _instance;

  /// Singleton access to the app-wide telemetry coordinator.
  static ForkTelemetry get instance => _instance ??= ForkTelemetry.fromEnvironment();

  @visibleForTesting
  static void setTestInstance(ForkTelemetry testInstance) {
    _instance = testInstance;
  }

  @visibleForTesting
  static void resetInstance() {
    _instance = null;
  }

  final List<TelemetrySink> _sinks;
  final Set<TelemetrySink> _readySinks = {};
  final TelemetryQueue _queue;
  final bool _isConfigured;
  final DateTime Function() _clock;
  String _installId;

  final UiStallDetector stallDetector;
  final AppSessionTracker sessionTracker;

  bool _enabled;
  bool _initialized = false;
  Future<void>? _initFuture;

  bool get isEnabled => _enabled;
  bool get isConfigured => _isConfigured;
  bool get hasSentry => _sinks.any((s) => s is SentryTelemetrySink);
  bool get hasPostHog => _sinks.any((s) => s is PostHogTelemetrySink);
  int get queuedCount => _queue.length;
  String get installId => _installId;

  /// Initializes configured provider sinks concurrently.
  Future<void> init() {
    if (_initialized || !_enabled) return Future.value();
    return _initFuture ??= _doInit();
  }

  Future<void> _doInit() async {
    try {
      await _loadInstallId();
      for (final sink in _sinks) {
        if (sink is SentryTelemetrySink) {
          sink.setInstallId(_installId);
        }
      }
      stallDetector.start();
      await Future.wait(_sinks.map(_initSink));
    } catch (_) {
      // Errors stay isolated
    } finally {
      _initialized = true;
    }
  }

  Future<void> _loadInstallId() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString('megawatt_install_id');
      if (stored != null && stored.isNotEmpty) {
        _installId = stored;
      } else {
        await prefs.setString('megawatt_install_id', _installId);
      }
    } catch (_) {}
  }

  Future<void> _initSink(TelemetrySink sink) async {
    try {
      await sink.init();
      if (!_enabled) return;
      final pending = List<TelemetryEnvelope>.from(_queue.items);
      _readySinks.add(sink);
      for (final envelope in pending) {
        if (envelope.event == 'error') {
          sink.sendError(envelope).ignore();
        } else {
          sink.sendMilestone(envelope).ignore();
        }
      }
    } catch (_) {
      // Isolate SDK initialization errors: never disrupt app boot
    }
  }

  /// Changes the telemetry opt-in state at runtime.
  void setEnabled(bool enabled) {
    if (_enabled == enabled) return;
    _enabled = enabled;
    if (!_enabled) {
      _queue.clear();
      _readySinks.clear();
      stallDetector.stop();
      for (final sink in _sinks) {
        sink.reset().ignore();
      }
    } else if (!_initialized) {
      init().ignore();
    }
  }

  /// Generates a random 16-character hex operation ID.
  String generateOpId() => _generateHex(16);

  /// Records a typed lifecycle stage transition.
  void recordStage({
    required String opId,
    required TelemetryStage stage,
    String event = 'stage_transition',
    int? attempt,
    int? durationMs,
    String? transportKind,
    ConnectPath? connectPath,
    bool? retryable,
    StageOutcome? outcome,
    int? reconnectCount,
    int? uiStallMs,
    String? machineLabel,
    String? agentKind,
    String? routeName,
    String? errorString,
    String? sessionLengthBucket,
    int? foregroundCount,
    int? backgroundCount,
    String? locateRoute,
    bool? sessionMismatch,
  }) {
    if (!_enabled) return;
    final envelope = TelemetryEnvelope(
      event: event,
      stage: stage,
      category: TelemetryCategory.none,
      opId: opId,
      timestamp: _clock(),
      attempt: attempt,
      durationMs: durationMs,
      transportKind: transportKind ?? connectPath?.name,
      connectPath: connectPath,
      retryable: retryable,
      platform: _currentPlatform(),
      release: appVersion,
      outcome: outcome,
      reconnectCount: reconnectCount,
      uiStallMs: uiStallMs,
      machineLabel: machineLabel,
      agentKind: agentKind,
      routeName: routeName,
      errorString: errorString,
      sessionLengthBucket: sessionLengthBucket,
      foregroundCount: foregroundCount,
      backgroundCount: backgroundCount,
      installId: _installId,
      locateRoute: locateRoute,
      sessionMismatch: sessionMismatch,
    );

    if (_queue.enqueue(envelope)) {
      for (final sink in _readySinks) {
        sink.sendMilestone(envelope).ignore();
      }
    }
  }

  /// Records an operation failure as a rich, scrubbed error envelope.
  void recordError({
    required String opId,
    required TelemetryStage stage,
    required Object error,
    StackTrace? stackTrace,
    int? attempt,
    int? durationMs,
    String? transportKind,
    ConnectPath? connectPath,
    bool? retryable,
    StageOutcome? outcome,
    String? machineLabel,
    String? agentKind,
    String? routeName,
  }) {
    if (!_enabled) return;
    final category = classifyError(error);
    final sanitizedStack = sanitizeStackTrace(stackTrace);
    final scrubbedError = megawattScrubber.scrubText(error.toString());

    final envelope = TelemetryEnvelope(
      event: 'error',
      stage: stage,
      category: category,
      opId: opId,
      timestamp: _clock(),
      attempt: attempt,
      durationMs: durationMs,
      transportKind: transportKind ?? connectPath?.name,
      connectPath: connectPath,
      retryable: retryable,
      platform: _currentPlatform(),
      release: appVersion,
      stackTrace: sanitizedStack,
      outcome: outcome ?? StageOutcome.failure,
      machineLabel: machineLabel,
      agentKind: agentKind,
      routeName: routeName,
      errorString: scrubbedError,
      installId: _installId,
    );

    if (_queue.enqueue(envelope)) {
      for (final sink in _readySinks) {
        sink.sendError(envelope).ignore();
      }
    }
  }

  /// Hook for Flutter framework errors.
  void recordFlutterError(FlutterErrorDetails details) {
    if (!_enabled) return;
    try {
      recordError(
        opId: 'flutter_err_${generateOpId()}',
        stage: TelemetryStage.error,
        error: details.exception,
        stackTrace: details.stack,
      );
    } catch (_) {
      // Isolate error handling failure: never disrupt Flutter
    }
  }

  static String _generateHex(int length) {
    final random = Random.secure();
    final bytes = List<int>.generate((length / 2).ceil(), (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join().substring(0, length);
  }

  static TelemetryPlatform _currentPlatform() {
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return TelemetryPlatform.android;
      case TargetPlatform.iOS:
        return TelemetryPlatform.ios;
      case TargetPlatform.macOS:
        return TelemetryPlatform.macos;
      case TargetPlatform.linux:
        return TelemetryPlatform.linux;
      case TargetPlatform.windows:
        return TelemetryPlatform.windows;
      default:
        return TelemetryPlatform.unknown;
    }
  }
}
