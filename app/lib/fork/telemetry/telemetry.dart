import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:herdr_mobile/data/app_info.dart';
import 'package:posthog_flutter/posthog_flutter.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

import 'envelope.dart';
import 'queue.dart';

/// Testable sink interface for sending sanitized telemetry to external providers.
abstract interface class TelemetrySink {
  Future<void> init();
  Future<void> sendMilestone(TelemetryEnvelope envelope);
  Future<void> sendError(TelemetryEnvelope envelope);
  Future<void> reset();
  Future<void> close();
}

const _megawattMark = 'megawatt';

/// Fail-closed filter: keep only breadcrumbs this sink added itself.
@visibleForTesting
Breadcrumb? megawattBeforeBreadcrumb(Breadcrumb? breadcrumb, Hint hint) =>
    breadcrumb?.type == _megawattMark ? breadcrumb : null;

/// Fail-closed filter: keep only events built in [SentryTelemetrySink.sendError].
@visibleForTesting
SentryEvent? megawattBeforeSend(SentryEvent event, Hint hint) => event.tags?['source'] == _megawattMark ? event : null;

/// Sentry adapter: manual sanitized error envelopes and bounded enum breadcrumbs only.
///
/// Native crash integration, automatic raw Dart error handlers, session replay,
/// screenshots, view hierarchy, and auto HTTP breadcrumbs are strictly disabled/removed.
class SentryTelemetrySink implements TelemetrySink {
  SentryTelemetrySink({required this.dsn});

  final String dsn;
  bool _initialized = false;

  @override
  Future<void> init() async {
    if (dsn.isEmpty || _initialized) return;
    try {
      await SentryFlutter.init((options) {
        options.dsn = dsn;
        options.enableNativeCrashHandling = false;
        options.enableAutoNativeBreadcrumbs = false;
        options.enableAppLifecycleBreadcrumbs = false;
        options.enableWatchdogTerminationTracking = false;
        options.attachScreenshot = false;
        options.attachViewHierarchy = false;
        options.sendDefaultPii = false;
        options.recordHttpBreadcrumbs = false;
        options.captureFailedRequests = false;
        options.enableAutoSessionTracking = false;
        options.enableAutoPerformanceTracing = false;
        options.beforeBreadcrumb = megawattBeforeBreadcrumb;
        options.beforeSend = megawattBeforeSend;

        // Remove all auto-capturing or unsafe integrations
        for (final i in List<Integration>.from(options.integrations)) {
          final name = i.runtimeType.toString();
          if (name.contains('FlutterError') ||
              name.contains('OnError') ||
              name.contains('DebugPrint') ||
              name.contains('Connectivity') ||
              name.contains('Screenshot') ||
              name.contains('ViewHierarchy') ||
              name.contains('Replay')) {
            options.removeIntegration(i);
          }
        }
      }).timeout(const Duration(seconds: 3));
      _initialized = true;
    } catch (_) {
      // Isolate SDK initialization errors: never disrupt app boot
    }
  }

  @override
  Future<void> sendMilestone(TelemetryEnvelope envelope) async {
    if (!_initialized) return;
    try {
      await Sentry.addBreadcrumb(
        Breadcrumb(
          type: _megawattMark,
          message: envelope.stage.name,
          category: envelope.category.name,
          data: {'opId': envelope.opId},
          timestamp: envelope.timestamp,
        ),
      );
    } catch (_) {}
  }

  @override
  Future<void> sendError(TelemetryEnvelope envelope) async {
    if (!_initialized) return;
    try {
      final sentryEvent = SentryEvent(
        message: SentryMessage(envelope.category.name),
        level: SentryLevel.error,
        tags: {
          'source': _megawattMark,
          'stage': envelope.stage.name,
          'category': envelope.category.name,
          'opId': envelope.opId,
          'platform': envelope.platform.name,
          if (envelope.transportKind != null) 'transportKind': envelope.transportKind!,
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

/// PostHog adapter: explicit milestone events only.
///
/// All session replay, UI screenshots, surveys, autocapture, and person profiles
/// are strictly disabled.
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

/// Main privacy-bounded telemetry module for Megawatt fork.
///
/// Features:
/// - Allowlisted schema ONLY (no `Map<String, dynamic>` public sink, no freeform message).
/// - Missing compile-time provider config leaves telemetry completely disabled.
/// - In-memory bounded queue (100 capacity, 24h TTL, 30/minute rate limiter).
/// - Random anonymous launch ID and short operation IDs.
/// - Complete failure isolation: vendor timeouts or exceptions never disrupt the app.
class ForkTelemetry {
  ForkTelemetry._({
    required this._sinks,
    TelemetryQueue? queue,
    required this._enabled,
    required this._isConfigured,
    DateTime Function()? clock,
  }) : _queue = queue ?? TelemetryQueue(clock: clock),
       _clock = clock ?? DateTime.now,
       _anonymousLaunchId = _generateHex(16);

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
    DateTime Function()? clock,
  }) => ForkTelemetry._(sinks: sinks, queue: queue, enabled: enabled, isConfigured: sinks.isNotEmpty, clock: clock);

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
  final TelemetryQueue _queue;
  final bool _isConfigured;
  final DateTime Function() _clock;
  final String _anonymousLaunchId;

  bool _enabled;
  bool _initialized = false;

  bool get isEnabled => _enabled;
  bool get isConfigured => _isConfigured;
  int get queuedCount => _queue.length;
  String get anonymousLaunchId => _anonymousLaunchId;

  /// Initializes configured provider sinks. Idempotent and never throws.
  Future<void> init() async {
    if (_initialized || !_enabled) return;
    for (final sink in _sinks) {
      await sink.init();
    }
    _initialized = true;
  }

  /// Changes the telemetry opt-in state at runtime.
  ///
  /// Disabling clears all queued events and instructs active sinks to reset
  /// identity and pending dispatches.
  void setEnabled(bool enabled) {
    if (_enabled == enabled) return;
    _enabled = enabled;
    if (!_enabled) {
      _queue.clear();
      for (final sink in _sinks) {
        sink.reset().ignore();
      }
    } else if (!_initialized) {
      init().ignore();
    }
  }

  /// Generates a random 16-character hex operation ID.
  /// Never hashes machine names, pane IDs, or paths.
  String generateOpId() => _generateHex(16);

  /// Records a typed lifecycle stage transition.
  void recordStage({
    required String opId,
    required TelemetryStage stage,
    String event = 'stage_transition',
    int? attempt,
    int? durationMs,
    String? transportKind,
    bool? retryable,
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
      transportKind: transportKind,
      retryable: retryable,
      platform: _currentPlatform(),
      release: appVersion,
    );

    if (_queue.enqueue(envelope)) {
      for (final sink in _sinks) {
        sink.sendMilestone(envelope).ignore();
      }
    }
  }

  /// Records an operation failure as a sanitized, constant-category error envelope.
  ///
  /// The raw [error] object and its message are NEVER transmitted or queued.
  void recordError({
    required String opId,
    required TelemetryStage stage,
    required Object error,
    StackTrace? stackTrace,
    int? attempt,
    int? durationMs,
    String? transportKind,
    bool? retryable,
  }) {
    if (!_enabled) return;
    final category = classifyError(error);
    final sanitizedStack = sanitizeStackTrace(stackTrace);

    final envelope = TelemetryEnvelope(
      event: 'error',
      stage: stage,
      category: category,
      opId: opId,
      timestamp: _clock(),
      attempt: attempt,
      durationMs: durationMs,
      transportKind: transportKind,
      retryable: retryable,
      platform: _currentPlatform(),
      release: appVersion,
      stackTrace: sanitizedStack,
    );

    if (_queue.enqueue(envelope)) {
      for (final sink in _sinks) {
        sink.sendError(envelope).ignore();
      }
    }
  }

  /// Hook for Flutter framework errors. Builds a sanitized error envelope.
  void recordFlutterError(FlutterErrorDetails details) {
    if (!_enabled) return;
    try {
      recordError(
        opId: generateOpId(),
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
