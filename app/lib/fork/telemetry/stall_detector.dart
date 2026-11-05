import 'dart:async';

import 'package:flutter/foundation.dart';

import 'envelope.dart';
import 'telemetry.dart';

/// Dart-side event loop delay stall detector.
///
/// Measures event loop stalls periodically and emits `uiStall`
/// (bucketed to 250, 500, 1000, 2000+ ms) throttled to at most once per 30 seconds.
/// Release-only in production, with zero content.
class UiStallDetector {
  UiStallDetector({
    this.interval = const Duration(milliseconds: 100),
    this.throttle = const Duration(seconds: 30),
    DateTime Function()? clock,
    this.forceEnabledForTesting = false,
  }) : _clock = clock ?? DateTime.now;

  final Duration interval;
  final Duration throttle;
  final DateTime Function() _clock;
  final bool forceEnabledForTesting;

  Timer? _timer;
  DateTime? _lastTick;
  DateTime? _lastRecorded;

  static int bucketStall(int delayMs) {
    if (delayMs >= 2000) return 2000;
    if (delayMs >= 1000) return 1000;
    if (delayMs >= 500) return 500;
    return 250;
  }

  void start() {
    if (!kReleaseMode && !forceEnabledForTesting) return;
    _lastTick = _clock();
    _timer?.cancel();
    _timer = Timer.periodic(interval, (_) => _onTick());
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
    _lastTick = null;
  }

  void _onTick() {
    final now = _clock();
    checkTick(now);
  }

  @visibleForTesting
  void checkTick(DateTime now) {
    if (_lastTick != null) {
      final elapsed = now.difference(_lastTick!).inMilliseconds;
      final delay = elapsed - interval.inMilliseconds;
      if (delay >= 250) {
        final bucket = bucketStall(delay);
        if (_lastRecorded == null || now.difference(_lastRecorded!) >= throttle) {
          _lastRecorded = now;
          ForkTelemetry.instance.recordStage(
            opId: ForkTelemetry.instance.generateOpId(),
            stage: TelemetryStage.uiStall,
            durationMs: bucket,
            uiStallMs: bucket,
          );
        }
      }
    }
    _lastTick = now;
  }
}
