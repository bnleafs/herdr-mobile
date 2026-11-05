import 'package:flutter/widgets.dart';

import 'envelope.dart';
import 'telemetry.dart';

/// Tracks session foreground and background transitions.
///
/// At background time, emits an `appSession` telemetry event with foreground/background
/// counts and a bucketed session length. Zero identity is captured.
class AppSessionTracker with WidgetsBindingObserver {
  AppSessionTracker({DateTime Function()? clock})
    : _clock = clock ?? DateTime.now,
      _sessionStart = (clock ?? DateTime.now)();

  final DateTime Function() _clock;
  DateTime _sessionStart;
  int _foregroundCount = 1;
  int _backgroundCount = 0;

  int get foregroundCount => _foregroundCount;
  int get backgroundCount => _backgroundCount;

  static String bucketSessionLength(Duration duration) {
    final s = duration.inSeconds;
    if (s < 10) return '<10s';
    if (s < 60) return '10-60s';
    if (s < 300) return '1-5m';
    if (s < 900) return '5-15m';
    if (s < 3600) return '15-60m';
    return '1h+';
  }

  void attach() {
    WidgetsBinding.instance.addObserver(this);
  }

  void detach() {
    WidgetsBinding.instance.removeObserver(this);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    onLifecycleState(state);
  }

  void onLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _foregroundCount++;
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      _backgroundCount++;
      final duration = _clock().difference(_sessionStart);
      final bucket = bucketSessionLength(duration);
      ForkTelemetry.instance.recordStage(
        opId: ForkTelemetry.instance.generateOpId(),
        stage: TelemetryStage.appSession,
        event: 'app_session',
        foregroundCount: _foregroundCount,
        backgroundCount: _backgroundCount,
        sessionLengthBucket: bucket,
      );
    }
  }

  @visibleForTesting
  void reset(DateTime now) {
    _sessionStart = now;
    _foregroundCount = 1;
    _backgroundCount = 0;
  }
}
