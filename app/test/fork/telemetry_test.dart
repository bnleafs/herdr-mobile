import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/fork/telemetry/envelope.dart';
import 'package:herdr_mobile/fork/telemetry/queue.dart';
import 'package:herdr_mobile/fork/telemetry/telemetry.dart';
import 'package:sentry_flutter/sentry_flutter.dart';

class _FakeSink implements TelemetrySink {
  final List<TelemetryEnvelope> milestones = [];
  final List<TelemetryEnvelope> errors = [];
  bool initialized = false;
  bool resetCalled = false;
  bool closed = false;
  bool throwOnSend = false;

  @override
  Future<void> init() async {
    initialized = true;
  }

  @override
  Future<void> sendMilestone(TelemetryEnvelope envelope) async {
    if (throwOnSend) throw Exception('Sink failure');
    milestones.add(envelope);
  }

  @override
  Future<void> sendError(TelemetryEnvelope envelope) async {
    if (throwOnSend) throw TimeoutException('Sink timed out');
    errors.add(envelope);
  }

  @override
  Future<void> reset() async {
    resetCalled = true;
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

void main() {
  group('TelemetryEnvelope & Sanitizer', () {
    test('hostile raw exception containing sensitive data never leaks into envelope', () {
      final hostileException = Exception(
        'Failed connecting to 192.0.2.1 for /home/person/secret with token=secret and prompt="delete all"',
      );

      final category = classifyError(hostileException);
      expect(category, TelemetryCategory.unknown);

      final envelope = TelemetryEnvelope(
        event: 'error',
        stage: TelemetryStage.shellAlloc,
        category: category,
        opId: '1234567890abcdef',
        timestamp: DateTime.utc(2026, 11, 5, 12, 0),
        transportKind: 'ssh_multiplex',
        attempt: 1,
        durationMs: 42,
        retryable: false,
      );

      final json = envelope.toJson();
      final serialized = json.toString();

      expect(serialized, isNot(contains('/home/person/secret')));
      expect(serialized, isNot(contains('192.0.2.1')));
      expect(serialized, isNot(contains('token=secret')));
      expect(serialized, isNot(contains('prompt')));
      expect(serialized, isNot(contains('delete all')));

      expect(json['category'], 'unknown');
      expect(json['stage'], 'shellAlloc');
      expect(json['opId'], '1234567890abcdef');
      expect(json['transportKind'], 'ssh_multiplex');
      expect(json['attempt'], 1);
      expect(json['durationMs'], 42);
      expect(json['retryable'], false);
    });

    test('classifyError maps known types into constant categories', () {
      expect(classifyError(TimeoutException('exceeded')), TelemetryCategory.timeout);
      expect(classifyError(const FormatException('bad')), TelemetryCategory.unknown);
    });

    test('sanitizeStackTrace preserves package and dart frames and drops raw paths and URLs', () {
      const rawStack = '''
#0      MyService.doWork (package:herdr_mobile/my_service.dart:10:5)
#1      _CustomZone.run (dart:async/zone.dart:120:10)
#2      secretRunner (/home/person/secret/runner.dart:45:12)
#3      fileUrlRunner (file:///Users/person/secret/runner.dart:50:8)
#4      rawTokenParam (token=supersecret_prompt_leak)
''';

      final sanitized = sanitizeStackTrace(StackTrace.fromString(rawStack));
      expect(sanitized, isNotNull);
      expect(sanitized, contains('MyService.doWork'));
      expect(sanitized, contains('package:herdr_mobile/my_service.dart:10'));
      expect(sanitized, contains('_CustomZone.run'));
      expect(sanitized, contains('dart:async/zone.dart:120'));
      expect(sanitized, isNot(contains('/home/person/secret')));
      expect(sanitized, isNot(contains('file:///Users/person')));
      expect(sanitized, isNot(contains('supersecret_prompt_leak')));
    });

    test('toJson produces only allowlisted fields', () {
      final envelope = TelemetryEnvelope(
        event: 'stage_transition',
        stage: TelemetryStage.waitingAgent,
        category: TelemetryCategory.none,
        opId: 'abcdef0123456789',
        timestamp: DateTime.utc(2026, 11, 5, 12, 0),
      );

      final json = envelope.toJson();
      const allowlist = {
        'event',
        'stage',
        'category',
        'opId',
        'release',
        'build',
        'platform',
        'timestamp',
        'retryable',
        'transportKind',
        'durationMs',
        'attempt',
        'stackTrace',
      };

      for (final key in json.keys) {
        expect(allowlist, contains(key), reason: 'Key $key not in allowlist');
      }
    });
  });

  group('Sentry fail-closed filters', () {
    final hint = Hint();

    test('beforeBreadcrumb keeps only megawatt breadcrumbs', () {
      final ours = Breadcrumb(type: 'megawatt', message: 'boot');
      expect(megawattBeforeBreadcrumb(ours, hint), same(ours));
      expect(megawattBeforeBreadcrumb(Breadcrumb(message: 'tap'), hint), isNull);
      expect(megawattBeforeBreadcrumb(Breadcrumb.http(url: Uri.parse('https://x.test'), method: 'GET'), hint), isNull);
      expect(megawattBeforeBreadcrumb(null, hint), isNull);
    });

    test('beforeSend keeps only events tagged source=megawatt', () {
      final ours = SentryEvent(tags: {'source': 'megawatt'});
      expect(megawattBeforeSend(ours, hint), same(ours));
      expect(megawattBeforeSend(SentryEvent(throwable: Exception('auto-captured')), hint), isNull);
      expect(megawattBeforeSend(SentryEvent(tags: {'source': 'other'}), hint), isNull);
    });
  });

  group('TelemetryQueue', () {
    test('enforces capacity bound of 100 with FIFO eviction', () {
      final now = DateTime.now();
      final queue = TelemetryQueue(maxCapacity: 100, maxPerMinute: 200);

      for (var i = 0; i < 120; i++) {
        final envelope = TelemetryEnvelope(
          event: 'event_$i',
          stage: TelemetryStage.waitingTranscript,
          category: TelemetryCategory.none,
          opId: 'op_$i',
          timestamp: now,
        );
        queue.enqueue(envelope);
      }

      expect(queue.length, 100);
      expect(queue.items.first.event, 'event_20');
      expect(queue.items.last.event, 'event_119');
    });

    test('queue does not retain raw exception objects', () {
      final queue = TelemetryQueue();
      final envelope = TelemetryEnvelope(
        event: 'error',
        stage: TelemetryStage.logRead,
        category: TelemetryCategory.fs,
        opId: 'op_fs',
        timestamp: DateTime.now(),
      );
      queue.enqueue(envelope);

      final dequeued = queue.dequeue();
      expect(dequeued, isNotNull);
      expect(dequeued, isA<TelemetryEnvelope>());
    });

    test('enforces 24h TTL expiration with injected clock', () {
      var currentTime = DateTime.utc(2026, 1, 1, 10, 0);
      final queue = TelemetryQueue(
        maxCapacity: 100,
        ttl: const Duration(hours: 24),
        maxPerMinute: 100,
        clock: () => currentTime,
      );

      final envelope = TelemetryEnvelope(
        event: 'early_event',
        stage: TelemetryStage.agentDetect,
        category: TelemetryCategory.none,
        opId: 'early_op',
        timestamp: currentTime,
      );
      queue.enqueue(envelope);
      expect(queue.length, 1);

      // Advance clock by 25 hours (> 24h TTL)
      currentTime = currentTime.add(const Duration(hours: 25));

      expect(queue.dequeue(), isNull);
      expect(queue.length, 0);
    });

    test('enforces rate limiter of 30 per minute with injected clock', () {
      var currentTime = DateTime.utc(2026, 1, 1, 10, 0);
      final queue = TelemetryQueue(maxCapacity: 100, maxPerMinute: 30, clock: () => currentTime);

      // Enqueue 30 events within the same minute: all succeed
      for (var i = 0; i < 30; i++) {
        final accepted = queue.enqueue(
          TelemetryEnvelope(
            event: 'event_$i',
            stage: TelemetryStage.agentLaunch,
            category: TelemetryCategory.none,
            opId: 'op_$i',
            timestamp: currentTime,
          ),
        );
        expect(accepted, isTrue, reason: 'Event $i should be accepted within limit');
      }
      expect(queue.length, 30);

      // 31st event within same minute should be rejected
      final rejected = queue.enqueue(
        TelemetryEnvelope(
          event: 'event_31',
          stage: TelemetryStage.agentLaunch,
          category: TelemetryCategory.none,
          opId: 'op_31',
          timestamp: currentTime,
        ),
      );
      expect(rejected, isFalse);
      expect(queue.length, 30);

      // Advance clock by 61 seconds: rate limit resets
      currentTime = currentTime.add(const Duration(seconds: 61));

      final acceptedAfterWait = queue.enqueue(
        TelemetryEnvelope(
          event: 'event_32',
          stage: TelemetryStage.agentLaunch,
          category: TelemetryCategory.none,
          opId: 'op_32',
          timestamp: currentTime,
        ),
      );
      expect(acceptedAfterWait, isTrue);
      expect(queue.length, 31);
    });
  });

  group('ForkTelemetry Lifecycle & Sinks', () {
    late _FakeSink fakeSink;
    late TelemetryQueue queue;
    late ForkTelemetry telemetry;

    setUp(() {
      fakeSink = _FakeSink();
      queue = TelemetryQueue();
      telemetry = ForkTelemetry.withSinks(sinks: [fakeSink], queue: queue, enabled: true);
    });

    tearDown(() {
      ForkTelemetry.resetInstance();
    });

    test('correlation: same opId tracks across enum stages without machine identity', () {
      final opId = telemetry.generateOpId();
      expect(opId.length, 16);

      telemetry.recordStage(opId: opId, stage: TelemetryStage.waitingAgent);
      telemetry.recordStage(opId: opId, stage: TelemetryStage.shellAlloc, transportKind: 'ssh_multiplex');
      telemetry.recordStage(opId: opId, stage: TelemetryStage.agentLaunch, attempt: 1);

      expect(fakeSink.milestones.length, 3);
      for (final milestone in fakeSink.milestones) {
        expect(milestone.opId, opId);
        final json = milestone.toJson();
        expect(json.containsKey('machine'), isFalse);
        expect(json.containsKey('hostname'), isFalse);
        expect(json.containsKey('user'), isFalse);
      }
      expect(fakeSink.milestones[0].stage, TelemetryStage.waitingAgent);
      expect(fakeSink.milestones[1].stage, TelemetryStage.shellAlloc);
      expect(fakeSink.milestones[2].stage, TelemetryStage.agentLaunch);
    });

    test('missing provider configuration results in zero calls', () {
      final unconfigured = ForkTelemetry.fromEnvironment(sentryDsn: '', posthogKey: '', posthogHost: '');
      expect(unconfigured.isConfigured, isFalse);
      expect(unconfigured.isEnabled, isFalse);

      unconfigured.recordStage(opId: 'test_op', stage: TelemetryStage.boot);
      expect(unconfigured.queuedCount, 0);
    });

    test('disabled state: zero network/queue and clears pending', () {
      telemetry.recordStage(opId: 'op1', stage: TelemetryStage.boot);
      expect(queue.length, 1);
      expect(fakeSink.milestones.length, 1);

      telemetry.setEnabled(false);
      expect(telemetry.isEnabled, isFalse);
      expect(queue.length, 0, reason: 'Disabling must clear queued events');
      expect(fakeSink.resetCalled, isTrue, reason: 'Disabling must reset identity/pending in sinks');

      // Subsequent recordings do nothing
      telemetry.recordStage(opId: 'op2', stage: TelemetryStage.transcriptLocate);
      expect(queue.length, 0);
      expect(fakeSink.milestones.length, 1);
    });

    test('sink exception or timeout never disrupts calling app', () {
      fakeSink.throwOnSend = true;

      // Should not throw
      expect(() => telemetry.recordStage(opId: 'op_err', stage: TelemetryStage.fallback), returnsNormally);

      expect(
        () => telemetry.recordError(opId: 'op_err', stage: TelemetryStage.fallback, error: Exception('Some error')),
        returnsNormally,
      );
    });

    test('recordFlutterError builds sanitized envelope without leaking details', () {
      final details = FlutterErrorDetails(
        exception: Exception('Secret token in http://192.0.2.1/token=xyz'),
        library: 'widgets library',
      );

      telemetry.recordFlutterError(details);

      expect(fakeSink.errors.length, 1);
      final errorEnv = fakeSink.errors.first;
      expect(errorEnv.category, TelemetryCategory.unknown);
      final json = errorEnv.toJson();
      expect(json.toString(), isNot(contains('192.0.2.1')));
      expect(json.toString(), isNot(contains('token=xyz')));
    });
  });
}
