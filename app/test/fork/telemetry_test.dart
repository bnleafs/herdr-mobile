import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/fork/telemetry/envelope.dart';
import 'package:herdr_mobile/fork/telemetry/queue.dart';
import 'package:herdr_mobile/fork/telemetry/scrubber.dart';
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
  group('MegawattScrubber & Security Exclusions', () {
    test('removes PEM keys, passwords, tokens, and DSNs while preserving machine labels and error text', () {
      const hostileRaw = '''
SshConnectionException: handshake failed for machine "mac-studio-lane" at /Users/person/prod
with password=mySuperSecretPass and token=ghp_secretToken123
dsn=https://fakekey@o123456.ingest.sentry.io/7890123
-----BEGIN OPENSSH PRIVATE KEY-----
b3BlbnNzaC1rZXktdjEAAAAABG5vbmUAAAAEbm9uZQAAAAAAAAABAAABlwAAAAdzc2gtcn
NhAAAAAwEAAQAAAYEAv78X...secretPEM...
-----END OPENSSH PRIVATE KEY-----
prompt="drop database production;"
''';

      final scrubbed = megawattScrubber.scrubText(hostileRaw);
      expect(scrubbed, isNotNull);

      // Preserved context
      expect(scrubbed, contains('SshConnectionException: handshake failed'));
      expect(scrubbed, contains('machine "mac-studio-lane"'));
      expect(scrubbed, contains('/Users/person/prod'));

      // Scrubbed credentials & secrets
      expect(scrubbed, isNot(contains('mySuperSecretPass')));
      expect(scrubbed, contains('password=[REDACTED]'));
      expect(scrubbed, isNot(contains('ghp_secretToken123')));
      expect(scrubbed, contains('token=[REDACTED]'));
      expect(scrubbed, isNot(contains('fakekey@o123456')));
      expect(scrubbed, contains('[REDACTED_DSN]'));
      expect(scrubbed, isNot(contains('secretPEM')));
      expect(scrubbed, contains('[REDACTED_PEM]'));
      expect(scrubbed, isNot(contains('drop database production;')));
      expect(scrubbed, contains('prompt=[REDACTED]'));
    });

    test('hostile raw exception never leaks credentials or prompt text into envelope or sink', () {
      final sink = _FakeSink();
      final telemetry = ForkTelemetry.withSinks(sinks: [sink], enabled: true);

      final hostileException = Exception(
        'Failed connecting to 192.0.2.1 for /home/person/secret with token=secret and prompt="delete all"',
      );

      telemetry.recordError(
        opId: '1234567890abcdef',
        stage: TelemetryStage.shellAlloc,
        error: hostileException,
        machineLabel: 'production-mac',
      );

      expect(sink.errors.length, 1);
      final envelope = sink.errors.first;
      final json = envelope.toJson();
      final serialized = json.toString();

      // Allowed under 2026-11-06 privacy waiver
      expect(serialized, contains('192.0.2.1'));
      expect(serialized, contains('/home/person/secret'));
      expect(serialized, contains('production-mac'));
      expect(serialized, contains('user: jaya'));

      // Security exclusions strictly enforced:
      expect(serialized, isNot(contains('token=secret')));
      expect(serialized, contains('token=[REDACTED]'));
      expect(serialized, isNot(contains('delete all')));
      expect(serialized, contains('prompt=[REDACTED]'));

      expect(json['category'], 'unknown');
      expect(json['stage'], 'shellAlloc');
      expect(json['opId'], '1234567890abcdef');
      expect(json['machineLabel'], 'production-mac');
      expect(json['user'], 'jaya');
    });

    test('scrubs Bearer tokens, URI credentials, JSON patterns, and camelCase keys in maps', () {
      const rawText =
          'Authorization: Bearer secret_bearer_token and Bearer standalone_secret and connect ssh://user:secret_pass@10.0.0.1:22 '
          'and json {"password": "pwd", "prompt": "cmd"} and passphrase is super_secret';
      final scrubbed = megawattScrubber.scrubText(rawText)!;

      expect(scrubbed, isNot(contains('secret_bearer_token')));
      expect(scrubbed, isNot(contains('standalone_secret')));
      expect(scrubbed, contains('Authorization=[REDACTED]'));
      expect(scrubbed, contains('Bearer [REDACTED]'));
      expect(scrubbed, isNot(contains('secret_pass')));
      expect(scrubbed, contains('ssh://user:[REDACTED]@10.0.0.1:22'));
      expect(scrubbed, isNot(contains('"pwd"')));
      expect(scrubbed, contains('password=[REDACTED]'));
      expect(scrubbed, isNot(contains('"cmd"')));
      expect(scrubbed, contains('prompt=[REDACTED]'));
      expect(scrubbed, isNot(contains('super_secret')));
      expect(scrubbed, contains('passphrase=[REDACTED]'));

      final sensitiveMap = <String, dynamic>{
        'apiKey': 'my_key_123',
        'privateKey': 'my_priv_key',
        'accountPhrase': 'phrase phrase phrase',
        'terminalOutput': 'sensitive command line',
        'fileContent': 'secret source file',
        'safeLabel': 'production-mac',
      };
      final scrubbedMap = megawattScrubber.scrubMap(sensitiveMap)!;
      expect(scrubbedMap['apiKey'], '[REDACTED]');
      expect(scrubbedMap['privateKey'], '[REDACTED]');
      expect(scrubbedMap['accountPhrase'], '[REDACTED]');
      expect(scrubbedMap['terminalOutput'], '[REDACTED]');
      expect(scrubbedMap['fileContent'], '[REDACTED]');
      expect(scrubbedMap['safeLabel'], 'production-mac');
    });

    test('preserves full Dart stack traces with code locations while scrubbing credentials', () {
      final fakeStack = StackTrace.fromString('''
#0      SomeClass.failingMethod (package:herdr_mobile/service.dart:123:45)
#1      AnotherClass.caller (package:herdr_mobile/caller.dart:67:89)
#2      SshClient.connectWithPass (package:herdr_mobile/ssh.dart:10:20)
#3      _CustomZone.run (dart:async/zone.dart:1234:56)
''');
      final sanitized = sanitizeStackTrace(fakeStack);
      expect(sanitized, isNotNull);
      expect(sanitized, contains('#0      SomeClass.failingMethod (package:herdr_mobile/service.dart:123:45)'));
      expect(sanitized, contains('#1      AnotherClass.caller (package:herdr_mobile/caller.dart:67:89)'));
      expect(sanitized, contains('#2      SshClient.connectWithPass (package:herdr_mobile/ssh.dart:10:20)'));
      expect(sanitized, contains('#3      _CustomZone.run (dart:async/zone.dart:1234:56)'));
    });

    test('toJson produces only allowlisted fields', () {
      final envelope = TelemetryEnvelope(
        event: 'stage_transition',
        stage: TelemetryStage.waitingAgent,
        category: TelemetryCategory.none,
        opId: 'abcdef0123456789',
        timestamp: DateTime.utc(2026, 11, 5, 12, 0),
        installId: 'inst_123',
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
        'connectPath',
        'durationMs',
        'attempt',
        'stackTrace',
        'outcome',
        'reconnectCount',
        'uiStallMs',
        'machineLabel',
        'agentKind',
        'routeName',
        'errorString',
        'sessionLengthBucket',
        'foregroundCount',
        'backgroundCount',
        'installId',
        'user',
      };

      for (final key in json.keys) {
        expect(allowlist, contains(key), reason: 'Key $key not in allowlist');
      }
    });
  });

  group('Sentry Filters & Scrubber', () {
    final hint = Hint();

    test('beforeSendLog drops foreign logs and scrubs allowed Megawatt logs', () {
      final foreignLog = SentryLog(
        timestamp: DateTime.now(),
        traceId: SentryId.newId(),
        level: SentryLogLevel.info,
        body: 'Foreign log from third party',
        attributes: {'other_key': SentryAttribute.string('some_val')},
      );
      expect(megawattBeforeSendLog(foreignLog, hint), isNull, reason: 'unmarked logs must be dropped');

      final megawattLog = SentryLog(
        timestamp: DateTime.now(),
        traceId: SentryId.newId(),
        level: SentryLogLevel.info,
        body: 'terminal_output="cat ~/.ssh/id_rsa"',
        attributes: {
          'source': SentryAttribute.string('megawatt'),
          'machineLabel': SentryAttribute.string('m1-max'),
          'password': SentryAttribute.string('unscrubbed_pw'),
        },
      );
      final scrubbed = megawattBeforeSendLog(megawattLog, hint);
      expect(scrubbed, isNotNull);
      expect(scrubbed!.body, isNot(contains('id_rsa')));
      expect(scrubbed.body, contains('terminal_output=[REDACTED]'));
      expect(scrubbed.attributes['machineLabel']?.value, 'm1-max');
      expect(scrubbed.attributes['password']?.value, '[REDACTED]');
    });

    test('beforeBreadcrumb keeps megawatt, navigation, and github http breadcrumbs, scrubbing credentials', () {
      final megawattBc = Breadcrumb(type: 'megawatt', message: 'stage transition');
      expect(megawattBeforeBreadcrumb(megawattBc, hint), isNotNull);

      final navBc = Breadcrumb(
        category: 'navigation',
        message: 'to /agent_session',
        data: {'from': '/agents', 'to': '/agent_session', 'fromArgs': 'secret_arg', 'toArgs': 'another_secret'},
      );
      final scrubbedNav = megawattBeforeBreadcrumb(navBc, hint);
      expect(scrubbedNav, isNotNull);
      expect(scrubbedNav!.data?['from'], '/agents');
      expect(scrubbedNav.data?['to'], '/agent_session');
      expect(scrubbedNav.data?.containsKey('fromArgs'), isFalse);
      expect(scrubbedNav.data?.containsKey('toArgs'), isFalse);

      final githubHttpBc = Breadcrumb.http(
        url: Uri.parse('https://api.github.com/repos/bnleafs/herdr-mobile/releases/latest'),
        method: 'GET',
        statusCode: 200,
      );
      expect(megawattBeforeBreadcrumb(githubHttpBc, hint), isNotNull);

      final otherHttpBc = Breadcrumb.http(
        url: Uri.parse('https://example.com/unrelated/api'),
        method: 'GET',
        statusCode: 200,
      );
      expect(megawattBeforeBreadcrumb(otherHttpBc, hint), isNull, reason: 'non-github http breadcrumb must be dropped');

      final arbitraryBc = Breadcrumb(message: 'random user tap', category: 'ui.click');
      expect(megawattBeforeBreadcrumb(arbitraryBc, hint), isNull);
      expect(megawattBeforeBreadcrumb(null, hint), isNull);
    });

    test('beforeSend scrubs credentials and terminal output from exceptions and breadcrumbs', () {
      final event = SentryEvent(
        exceptions: [
          SentryException(
            type: 'SshConnectionException',
            value: 'Failed with token=secret_token_123 and password=pass123',
          ),
        ],
        breadcrumbs: [
          Breadcrumb(
            type: 'megawatt',
            message: 'prompt="confidential prompt text"',
            data: {'terminal': 'ls -la /root'},
          ),
        ],
      );

      final scrubbedEvent = megawattBeforeSend(event, hint);
      expect(scrubbedEvent, isNotNull);
      final excValue = scrubbedEvent!.exceptions!.first.value!;
      expect(excValue, isNot(contains('secret_token_123')));
      expect(excValue, isNot(contains('pass123')));
      expect(excValue, contains('token=[REDACTED]'));
      expect(excValue, contains('password=[REDACTED]'));

      final bc = scrubbedEvent.breadcrumbs!.first;
      expect(bc.message, isNot(contains('confidential prompt text')));
      expect(bc.message, contains('prompt=[REDACTED]'));
      expect(bc.data?['terminal'], '[REDACTED]');
    });
  });

  group('TelemetryQueue', () {
    test('enforces capacity bound of 200 with FIFO eviction', () {
      final now = DateTime.now();
      final queue = TelemetryQueue(maxCapacity: 200, maxPerMinute: 300);

      for (var i = 0; i < 220; i++) {
        final envelope = TelemetryEnvelope(
          event: 'event_$i',
          stage: TelemetryStage.waitingTranscript,
          category: TelemetryCategory.none,
          opId: 'op_$i',
          timestamp: now,
        );
        queue.enqueue(envelope);
      }

      expect(queue.length, 200);
      expect(queue.items.first.event, 'event_20');
      expect(queue.items.last.event, 'event_219');
    });

    test('enforces 24h TTL expiration with injected clock', () {
      var currentTime = DateTime.utc(2026, 1, 1, 10, 0);
      final queue = TelemetryQueue(
        maxCapacity: 100,
        ttl: const Duration(hours: 24),
        maxPerMinute: 200,
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

      currentTime = currentTime.add(const Duration(hours: 25));
      expect(queue.dequeue(), isNull);
      expect(queue.length, 0);
    });

    test('enforces rate limiter of 120 per minute with injected clock', () {
      var currentTime = DateTime.utc(2026, 1, 1, 10, 0);
      final queue = TelemetryQueue(maxCapacity: 200, maxPerMinute: 120, clock: () => currentTime);

      for (var i = 0; i < 120; i++) {
        final accepted = queue.enqueue(
          TelemetryEnvelope(
            event: 'event_$i',
            stage: TelemetryStage.agentLaunch,
            category: TelemetryCategory.none,
            opId: 'op_$i',
            timestamp: currentTime,
          ),
        );
        expect(accepted, isTrue);
      }
      expect(queue.length, 120);

      final rejected = queue.enqueue(
        TelemetryEnvelope(
          event: 'event_121',
          stage: TelemetryStage.agentLaunch,
          category: TelemetryCategory.none,
          opId: 'op_121',
          timestamp: currentTime,
        ),
      );
      expect(rejected, isFalse);
      expect(queue.length, 120);

      currentTime = currentTime.add(const Duration(seconds: 61));
      final acceptedAfterWait = queue.enqueue(
        TelemetryEnvelope(
          event: 'event_122',
          stage: TelemetryStage.agentLaunch,
          category: TelemetryCategory.none,
          opId: 'op_122',
          timestamp: currentTime,
        ),
      );
      expect(acceptedAfterWait, isTrue);
      expect(queue.length, 121);
    });
  });

  group('ForkTelemetry Lifecycle & Sinks', () {
    late _FakeSink fakeSink;
    late TelemetryQueue queue;
    late ForkTelemetry telemetry;

    setUp(() {
      fakeSink = _FakeSink();
      queue = TelemetryQueue();
      telemetry = ForkTelemetry.withSinks(
        sinks: [fakeSink],
        queue: queue,
        enabled: true,
        installId: 'fixed_install_id',
      );
    });

    tearDown(() {
      ForkTelemetry.resetInstance();
    });

    test('correlation: same opId tracks across enum stages with stable install id and user jaya', () {
      final opId = telemetry.generateOpId();
      expect(opId.length, 16);

      telemetry.recordStage(opId: opId, stage: TelemetryStage.waitingAgent);
      telemetry.recordStage(opId: opId, stage: TelemetryStage.shellAlloc, transportKind: 'ssh_multiplex');
      telemetry.recordStage(opId: opId, stage: TelemetryStage.agentLaunch, attempt: 1);

      expect(fakeSink.milestones.length, 3);
      for (final milestone in fakeSink.milestones) {
        expect(milestone.opId, opId);
        final json = milestone.toJson();
        expect(json['user'], 'jaya');
        expect(json['installId'], 'fixed_install_id');
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

      expect(() => telemetry.recordStage(opId: 'op_err', stage: TelemetryStage.fallback), returnsNormally);

      expect(
        () => telemetry.recordError(opId: 'op_err', stage: TelemetryStage.fallback, error: Exception('Some error')),
        returnsNormally,
      );
    });

    test('recordFlutterError builds sanitized envelope without leaking token credentials', () {
      final details = FlutterErrorDetails(
        exception: Exception('Secret token in http://192.0.2.1/token=xyz'),
        library: 'widgets library',
      );

      telemetry.recordFlutterError(details);

      expect(fakeSink.errors.length, 1);
      final errorEnv = fakeSink.errors.first;
      expect(errorEnv.category, TelemetryCategory.unknown);
      final json = errorEnv.toJson();
      expect(json.toString(), isNot(contains('token=xyz')));
      expect(json.toString(), contains('token=[REDACTED]'));
    });

    test('pre-init events are queued and flushed once a sink completes init', () async {
      final sink = _FakeSink();
      final q = TelemetryQueue();
      final tel = ForkTelemetry.withSinks(sinks: [sink], queue: q, enabled: true, preInitialized: false);

      tel.recordStage(opId: 'pre_op', stage: TelemetryStage.boot);
      expect(q.length, 1);
      expect(sink.milestones, isEmpty);

      await tel.init();

      expect(sink.initialized, isTrue);
      expect(sink.milestones.length, 1);
      expect(sink.milestones.first.opId, 'pre_op');

      tel.recordStage(opId: 'post_op', stage: TelemetryStage.agentLaunch);
      expect(sink.milestones.length, 2);
      expect(sink.milestones.last.opId, 'post_op');
    });

    test('pre-init events are dropped when disabled before init completes', () async {
      final sink = _FakeSink();
      final q = TelemetryQueue();
      final tel = ForkTelemetry.withSinks(sinks: [sink], queue: q, enabled: true, preInitialized: false);

      tel.recordStage(opId: 'drop_op', stage: TelemetryStage.boot);
      expect(q.length, 1);

      tel.setEnabled(false);
      expect(q.length, 0);

      await tel.init();
      expect(sink.milestones, isEmpty);
    });

    test(
      'multiple sinks initialise concurrently; fast sink receives flushed events before slow sink finishes',
      () async {
        final slowInitCompleter = Completer<void>();
        final slowSink = _SlowInitSink(slowInitCompleter.future);
        final fastSink = _FakeSink();
        final q = TelemetryQueue();
        final tel = ForkTelemetry.withSinks(
          sinks: [slowSink, fastSink],
          queue: q,
          enabled: true,
          preInitialized: false,
        );

        tel.recordStage(opId: 'concurrent_op', stage: TelemetryStage.boot);

        final initFuture = tel.init();

        await Future<void>.delayed(Duration.zero);
        expect(fastSink.initialized, isTrue);
        expect(fastSink.milestones.length, 1);
        expect(slowSink.initialized, isFalse);
        expect(slowSink.milestones, isEmpty);

        slowInitCompleter.complete();
        await initFuture;
        expect(slowSink.initialized, isTrue);
        expect(slowSink.milestones.length, 1);
      },
    );
  });
}

class _SlowInitSink implements TelemetrySink {
  _SlowInitSink(this._initSignal);
  final Future<void> _initSignal;
  final List<TelemetryEnvelope> milestones = [];
  final List<TelemetryEnvelope> errors = [];
  bool initialized = false;

  @override
  Future<void> init() async {
    await _initSignal;
    initialized = true;
  }

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
