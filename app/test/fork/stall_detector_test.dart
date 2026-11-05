import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/fork/telemetry/envelope.dart';
import 'package:herdr_mobile/fork/telemetry/stall_detector.dart';
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
  group('UiStallDetector', () {
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

    test('bucketStall categorizes event-loop delays into 250, 500, 1000, 2000+ ms buckets', () {
      expect(UiStallDetector.bucketStall(250), 250);
      expect(UiStallDetector.bucketStall(499), 250);
      expect(UiStallDetector.bucketStall(500), 500);
      expect(UiStallDetector.bucketStall(999), 500);
      expect(UiStallDetector.bucketStall(1000), 1000);
      expect(UiStallDetector.bucketStall(1999), 1000);
      expect(UiStallDetector.bucketStall(2000), 2000);
      expect(UiStallDetector.bucketStall(5000), 2000);
    });

    test('records uiStall with bucketed delay and enforces 30s throttle with fake clock', () {
      var currentTime = DateTime(2026, 11, 6, 12, 0, 0);
      final detector = UiStallDetector(
        interval: const Duration(milliseconds: 100),
        throttle: const Duration(seconds: 30),
        clock: () => currentTime,
        forceEnabledForTesting: true,
      );

      // Initial tick (establishing baseline)
      detector.checkTick(currentTime);
      expect(sink.milestones, isEmpty);

      // Normal tick: 100ms passed, delay = 0 -> no stall
      currentTime = currentTime.add(const Duration(milliseconds: 100));
      detector.checkTick(currentTime);
      expect(sink.milestones, isEmpty);

      // Small stall: 200ms elapsed (delay = 100ms < 250ms) -> no stall recorded
      currentTime = currentTime.add(const Duration(milliseconds: 200));
      detector.checkTick(currentTime);
      expect(sink.milestones, isEmpty);

      // Significant stall: 650ms elapsed (delay = 550ms >= 500ms) -> 500ms bucket
      currentTime = currentTime.add(const Duration(milliseconds: 650));
      detector.checkTick(currentTime);
      expect(sink.milestones.length, 1);
      final stall1 = sink.milestones.first;
      expect(stall1.stage, TelemetryStage.uiStall);
      expect(stall1.durationMs, 500);
      expect(stall1.uiStallMs, 500);

      // Another stall before 30 seconds have passed: should be throttled
      currentTime = currentTime.add(const Duration(milliseconds: 1200)); // 1100ms delay
      detector.checkTick(currentTime);
      expect(sink.milestones.length, 1, reason: 'Must throttle within 30s window');

      // Advance clock by 31 seconds: throttle window has elapsed
      currentTime = currentTime.add(const Duration(seconds: 31));
      detector.checkTick(currentTime); // Baseline for next interval

      // Huge stall: 2500ms elapsed -> 2000ms bucket recorded
      currentTime = currentTime.add(const Duration(milliseconds: 2500));
      detector.checkTick(currentTime);
      expect(sink.milestones.length, 2);
      final stall2 = sink.milestones.last;
      expect(stall2.stage, TelemetryStage.uiStall);
      expect(stall2.durationMs, 2000);
      expect(stall2.uiStallMs, 2000);
    });
  });
}
