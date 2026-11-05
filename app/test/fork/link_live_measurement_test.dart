import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
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

class _CollectingSink implements TelemetrySink {
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

MachineProfile _machine(String id, String label) =>
    MachineProfile(id: id, label: label, host: '$id.megawatt.lan', username: 'secretuser');

void main() {
  test('records linkLive telemetry with bounded paths and enum/duration fields only', () {
    fakeAsync((async) {
      final sink = _CollectingSink();
      final telemetry = ForkTelemetry.withSinks(sinks: [sink], enabled: true);
      ForkTelemetry.setTestInstance(telemetry);

      final network = FakeNetwork();
      final cache = MemorySnapshotCache();
      final machines = MachineRepository(profiles: MemoryProfileStore(), secrets: MemorySecretStore());
      final transports = <String, FakeTransport>{};
      var now = DateTime(2026, 11, 6, 12, 0);

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
        final profile = _machine('m1', 'My Workstation');
        transports[profile.id] = FakeTransport(snapshotJson());

        // 1. Cold start connect
        machines.save(profile, secrets: const MachineSecrets(password: 'secretpass'));
        async.flushMicrotasks();

        final liveEvents = sink.milestones.where((m) => m.stage == TelemetryStage.linkLive).toList();
        expect(liveEvents.length, 1, reason: 'recorded once on cold start connect reaching live');

        final coldStart = liveEvents.first;
        expect(coldStart.stage, TelemetryStage.linkLive);
        expect(coldStart.connectPath, ConnectPath.coldStart);
        expect(coldStart.transportKind, 'coldStart');
        expect(coldStart.attempt, 0);
        expect(coldStart.durationMs, isNotNull);
        expect(coldStart.durationMs! >= 0, isTrue);
        expect(coldStart.category, TelemetryCategory.none);

        // Verify privacy: no host, machine id, username, or passwords in envelope JSON
        final coldJson = coldStart.toJson();
        final serialized = coldJson.toString();
        expect(serialized, isNot(contains('m1')));
        expect(serialized, isNot(contains('My Workstation')));
        expect(serialized, isNot(contains('megawatt.lan')));
        expect(serialized, isNot(contains('secretuser')));
        expect(serialized, isNot(contains('secretpass')));

        // Subsequent normal refresh does not record linkLive again
        fleet.connections.first.refresh();
        async.flushMicrotasks();
        expect(sink.milestones.where((m) => m.stage == TelemetryStage.linkLive).length, 1);

        // 2. Refreshed resume (< 5 s away)
        now = now.add(const Duration(seconds: 2));
        fleet.onForeground(away: const Duration(seconds: 2));
        async.flushMicrotasks();

        final liveAfterRefresh = sink.milestones.where((m) => m.stage == TelemetryStage.linkLive).toList();
        expect(liveAfterRefresh.length, 2, reason: 'refreshed resume records linkLive once');

        final refreshed = liveAfterRefresh[1];
        expect(refreshed.stage, TelemetryStage.linkLive);
        expect(refreshed.connectPath, ConnectPath.refreshedResume);
        expect(refreshed.transportKind, 'refreshedResume');
        expect(refreshed.durationMs, isNotNull);
        expect(refreshed.durationMs! >= 0, isTrue);

        // 3. Rebuilt resume (> 5 s away)
        now = now.add(const Duration(seconds: 10));
        fleet.onForeground(away: const Duration(seconds: 10));
        async.flushMicrotasks();

        final liveAfterRebuilt = sink.milestones.where((m) => m.stage == TelemetryStage.linkLive).toList();
        expect(liveAfterRebuilt.length, 3, reason: 'rebuilt resume records linkLive once');

        final rebuilt = liveAfterRebuilt[2];
        expect(rebuilt.stage, TelemetryStage.linkLive);
        expect(rebuilt.connectPath, ConnectPath.rebuiltResume);
        expect(rebuilt.transportKind, 'rebuiltResume');
        expect(rebuilt.durationMs, isNotNull);
        expect(rebuilt.durationMs! >= 0, isTrue);

        // Check allowlist adherence on all recorded linkLive events
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
          'installId',
          'user',
        };
        for (final event in liveAfterRebuilt) {
          for (final key in event.toJson().keys) {
            expect(allowlist, contains(key), reason: 'Key $key must be strictly allowlisted');
          }
        }
      } finally {
        fleet.dispose();
        ForkTelemetry.resetInstance();
      }
    });
  });
}
