import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/models/release_info.dart';
import 'package:herdr_mobile/data/repositories/app_update.dart';
import 'package:herdr_mobile/data/repositories/fleet_repository.dart';
import 'package:herdr_mobile/data/repositories/machine_connection.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/services/herdr_api.dart';
import 'package:herdr_mobile/fork/telemetry/envelope.dart';
import 'package:herdr_mobile/fork/telemetry/telemetry.dart';

import '../support/fake_network.dart';
import '../support/fake_transport.dart';
import '../support/memory_snapshot_cache.dart';
import '../support/memory_stores.dart';
import '../support/update_fakes.dart';

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
  group('New bounded stages', () {
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

    test('reconnect count per resume records on fleet onForeground', () async {
      final network = FakeNetwork();
      final cache = MemorySnapshotCache();
      final machines = MachineRepository(profiles: MemoryProfileStore(), secrets: MemorySecretStore());
      final transports = <String, FakeTransport>{};
      final now = DateTime(2026, 11, 6, 12, 0);

      final fleet = FleetRepository(
        machines: machines,
        network: network,
        clock: () => now,
        connect: (profile, secrets) {
          final t = transports.putIfAbsent(profile.id, FakeTransport.new);
          return MachineConnection(
            profile: profile,
            api: HerdrApi(t),
            cache: cache,
            clock: () => now,
            backoff: (_) => const Duration(milliseconds: 10),
            pollInterval: const Duration(hours: 1),
          );
        },
      );

      try {
        final m1 = MachineProfile(id: 'm1', label: 'Machine 1', host: 'm1.lan', username: 'user');
        machines.save(m1, secrets: const MachineSecrets());
        await Future<void>.delayed(Duration.zero);

        // Resume after long away (> 5 seconds triggers reconnect)
        await fleet.onForeground(away: const Duration(seconds: 10));

        final resumeEvents = sink.milestones.where((m) => m.stage == TelemetryStage.resumeReconnect).toList();
        expect(resumeEvents.length, 1, reason: 'resumeReconnect recorded once per resume');
        final event = resumeEvents.first;
        expect(event.reconnectCount, 1);
        expect(event.stage, TelemetryStage.resumeReconnect);
      } finally {
        fleet.dispose();
      }
    });

    test('update check records appUpdateCheck stage with duration and outcome', () async {
      final feed = FakeReleaseFeed();
      final files = FakeReleaseFiles();
      final installer = FakeApkInstaller();
      final store = MemoryUpdateStore(const UpdateRecord(autoDownload: false));
      final update = AppUpdate(
        store: store,
        feed: feed,
        files: files,
        installer: installer,
        current: AppVersion.tryParse('0.1.6'),
      );

      await update.check(manual: true);

      final checkEvents = sink.milestones.where((m) => m.stage == TelemetryStage.appUpdateCheck).toList();
      expect(checkEvents.length, 1);
      final event = checkEvents.first;
      expect(event.stage, TelemetryStage.appUpdateCheck);
      expect(event.outcome, StageOutcome.upToDate);
      expect(event.durationMs, isNotNull);
      expect(event.durationMs! >= 0, isTrue);
    });

    test('message delivery stage records with duration and outcome and zero content', () {
      telemetry.recordStage(
        opId: telemetry.generateOpId(),
        stage: TelemetryStage.messageDelivery,
        durationMs: 45,
        outcome: StageOutcome.success,
      );

      final msgEvents = sink.milestones.where((m) => m.stage == TelemetryStage.messageDelivery).toList();
      expect(msgEvents.length, 1);
      final event = msgEvents.first;
      expect(event.durationMs, 45);
      expect(event.outcome, StageOutcome.success);

      final json = event.toJson();
      expect(json.containsKey('content'), isFalse);
      expect(json.containsKey('text'), isFalse);
      expect(json.containsKey('prompt'), isFalse);
    });

    test('terminal creation records duration, machine label, and outcome', () {
      telemetry.recordStage(
        opId: telemetry.generateOpId(),
        stage: TelemetryStage.terminalCreation,
        durationMs: 120,
        machineLabel: 'Dev Mac Mini',
        outcome: StageOutcome.success,
      );

      final termEvents = sink.milestones.where((m) => m.stage == TelemetryStage.terminalCreation).toList();
      expect(termEvents.length, 1);
      final event = termEvents.first;
      expect(event.durationMs, 120);
      expect(event.machineLabel, 'Dev Mac Mini');
      expect(event.outcome, StageOutcome.success);
    });

    test('chat content shown records duration, agent kind, machine label, and outcome', () {
      telemetry.recordStage(
        opId: telemetry.generateOpId(),
        stage: TelemetryStage.chatContentShown,
        durationMs: 250,
        agentKind: 'acp',
        machineLabel: 'Workstation',
        outcome: StageOutcome.success,
      );

      final chatEvents = sink.milestones.where((m) => m.stage == TelemetryStage.chatContentShown).toList();
      expect(chatEvents.length, 1);
      final event = chatEvents.first;
      expect(event.durationMs, 250);
      expect(event.agentKind, 'acp');
      expect(event.machineLabel, 'Workstation');
      expect(event.outcome, StageOutcome.success);
    });

    test('update download records appUpdateDownload stage with duration and outcome', () {
      telemetry.recordStage(
        opId: telemetry.generateOpId(),
        stage: TelemetryStage.appUpdateDownload,
        durationMs: 850,
        outcome: StageOutcome.success,
      );

      final dlEvents = sink.milestones.where((m) => m.stage == TelemetryStage.appUpdateDownload).toList();
      expect(dlEvents.length, 1);
      final event = dlEvents.first;
      expect(event.durationMs, 850);
      expect(event.outcome, StageOutcome.success);
    });
  });
}
