import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/fork/telemetry/envelope.dart';
import 'package:herdr_mobile/fork/telemetry/session_tracker.dart';
import 'package:herdr_mobile/fork/telemetry/telemetry.dart';

class _CapturingSink implements TelemetrySink {
  final List<TelemetryEnvelope> milestones = [];
  final List<TelemetryEnvelope> errors = [];

  @override
  Future<void> init() async {}

  @override
  Future<void> sendMilestone(TelemetryEnvelope envelope) async {
    milestones.add(envelope);
  }

  @override
  Future<void> sendError(TelemetryEnvelope envelope) async {
    errors.add(envelope);
  }

  @override
  Future<void> reset() async {}

  @override
  Future<void> close() async {}
}

void main() {
  group('AppSessionTracker', () {
    late _CapturingSink sink;
    late ForkTelemetry telemetry;

    setUp(() {
      sink = _CapturingSink();
      telemetry = ForkTelemetry.withSinks(sinks: [sink], enabled: true);
      ForkTelemetry.setTestInstance(telemetry);
    });

    tearDown(() {
      ForkTelemetry.resetInstance();
    });

    test('bucketSessionLength buckets durations accurately', () {
      expect(AppSessionTracker.bucketSessionLength(const Duration(seconds: 5)), '<10s');
      expect(AppSessionTracker.bucketSessionLength(const Duration(seconds: 30)), '10-60s');
      expect(AppSessionTracker.bucketSessionLength(const Duration(seconds: 120)), '1-5m');
      expect(AppSessionTracker.bucketSessionLength(const Duration(seconds: 600)), '5-15m');
      expect(AppSessionTracker.bucketSessionLength(const Duration(seconds: 1800)), '15-60m');
      expect(AppSessionTracker.bucketSessionLength(const Duration(seconds: 4000)), '1h+');
    });

    test('records single appSession event at background time with foreground/background counts', () {
      var currentTime = DateTime(2026, 11, 6, 10, 0, 0);
      final tracker = AppSessionTracker(clock: () => currentTime);

      // Initially foregrounded (foregroundCount = 1, backgroundCount = 0)
      expect(tracker.foregroundCount, 1);
      expect(tracker.backgroundCount, 0);
      expect(sink.milestones, isEmpty);

      // App is resumed again (e.g. returning to foreground)
      tracker.onLifecycleState(AppLifecycleState.resumed);
      expect(tracker.foregroundCount, 2);
      expect(sink.milestones, isEmpty);

      // App goes to background 45 seconds later
      currentTime = currentTime.add(const Duration(seconds: 45));
      tracker.onLifecycleState(AppLifecycleState.paused);

      expect(tracker.backgroundCount, 1);
      expect(sink.milestones.length, 1);

      final sessionEvent = sink.milestones.first;
      expect(sessionEvent.stage, TelemetryStage.appSession);
      expect(sessionEvent.event, 'app_session');
      expect(sessionEvent.foregroundCount, 2);
      expect(sessionEvent.backgroundCount, 1);
      expect(sessionEvent.sessionLengthBucket, '10-60s');
      expect(sessionEvent.user, 'jaya');
    });
  });
}
