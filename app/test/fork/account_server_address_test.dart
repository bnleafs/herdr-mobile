import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/fork/account/account_session.dart';
import 'package:herdr_mobile/fork/account/account_vault.dart';

import '../support/fake_exec.dart';
import '../support/fake_transport.dart';
import '../support/memory_stores.dart';
import '../support/shot.dart' show loadAppFonts;

final testAccountKey2 = Uint8List.fromList(List.generate(32, (i) => (i * 11 + 7) % 256));

class MemoryAccountSessionStore2 implements AccountSessionStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

Future<MachineRepository> makeRepo(
  List<MachineProfile> profiles, [
  Map<String, MachineSecrets> secrets = const {},
]) async {
  final profileStore = MemoryProfileStore()..profiles = profiles;
  final secretStore = MemorySecretStore();
  secretStore.secrets.addAll(secrets);
  final repo = MachineRepository(profiles: profileStore, secrets: secretStore);
  await repo.load();
  return repo;
}

FakeTransport keyGetTransport(String file, {List<String>? commands}) {
  final t = FakeTransport();
  t.onExec = (cmd) async {
    commands?.add(cmd);
    if (cmd == 'key') {
      return FakeExecChannel.run(
        stdout: [
          jsonEncode({'v': 1, 'username': 'jaya', 'key': base64Encode(testAccountKey2)}),
        ],
        code: 0,
      );
    } else if (cmd == 'get') {
      return FakeExecChannel.run(stdout: [file], code: 0);
    } else if (cmd == 'put') {
      final ch = FakeExecChannel();
      ch.onInputClosed = () => ch.exit(0);
      return ch;
    }
    return FakeExecChannel.run(code: 1);
  };
  return t;
}

void main() {
  setUpAll(loadAppFonts);

  setUp(() {
    SharedPreferences.setMockInitialValues({localInitializedKey: true});
  });

  test('E01: sign-in to host with explicit port uses that host port and user for every connect', () async {
    final repo = await makeRepo([]);
    final file = await sealVault(const VaultContents(), testAccountKey2);
    final profiles = <MachineProfile>[];
    final transport = keyGetTransport(file);
    final session = AccountSession(
      machines: repo,
      connect: (p, s, pin, n) {
        profiles.add(p);
        return transport;
      },
      probeFingerprint: (host, port) async => 'SHA256:e01pinAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      sessionStore: MemoryAccountSessionStore2(),
      debounceDuration: Duration.zero,
    );

    await session.signIn('10.0.0.5:2200', 'jaya', 'pw-e01', trustFingerprint: (_) async => true);

    expect(session.isSignedIn, isTrue);
    expect(profiles, isNotEmpty);
    for (final p in profiles) {
      expect(p.host, equals('10.0.0.5'));
      expect(p.port, equals(2200));
      expect(p.username, equals('herdrj'));
    }
  });

  test('E02: sign-in to bare hostname defaults to port 22', () async {
    final repo = await makeRepo([]);
    final file = await sealVault(const VaultContents(), testAccountKey2);
    final profiles = <MachineProfile>[];
    final transport = keyGetTransport(file);
    final session = AccountSession(
      machines: repo,
      connect: (p, s, pin, n) {
        profiles.add(p);
        return transport;
      },
      probeFingerprint: (host, port) async => 'SHA256:e02pinBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB',
      sessionStore: MemoryAccountSessionStore2(),
      debounceDuration: Duration.zero,
    );

    await session.signIn('box.example.com', 'jaya', 'pw-e02', trustFingerprint: (_) async => true);

    expect(session.isSignedIn, isTrue);
    expect(profiles, isNotEmpty);
    for (final p in profiles) {
      expect(p.host, equals('box.example.com'));
      expect(p.port, equals(22));
      expect(p.username, equals('herdrj'));
    }
  });

  test('E03: blank address with space sets address error and probes and connects never', () async {
    final repo = await makeRepo([]);
    var probes = 0;
    final profiles = <MachineProfile>[];
    final session = AccountSession(
      machines: repo,
      connect: (p, s, pin, n) {
        profiles.add(p);
        return FakeTransport();
      },
      probeFingerprint: (host, port) async {
        probes++;
        return 'SHA256:e03pinCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCCC';
      },
      sessionStore: MemoryAccountSessionStore2(),
      debounceDuration: Duration.zero,
    );

    try {
      await session.signIn('a b', 'jaya', 'pw-e03', trustFingerprint: (_) async => true);
    } catch (_) {}

    expect(session.lastError, equals('Enter a server address like 203.0.113.5 or box.example.com.'));
    expect(probes, equals(0));
    expect(profiles, isEmpty);
    expect(session.isSignedIn, isFalse);
  });

  test('E04: probe runs before trust before first connect with typed host and port', () async {
    final repo = await makeRepo([]);
    final file = await sealVault(const VaultContents(), testAccountKey2);
    const probed = 'SHA256:e04pinDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDDD';
    final order = <String>[];
    String? probedHost;
    int? probedPort;
    String? trustedFp;
    final transport = keyGetTransport(file);
    final session = AccountSession(
      machines: repo,
      connect: (p, s, pin, n) {
        order.add('connect');
        return transport;
      },
      probeFingerprint: (host, port) async {
        probedHost = host;
        probedPort = port;
        order.add('probe');
        return probed;
      },
      sessionStore: MemoryAccountSessionStore2(),
      debounceDuration: Duration.zero,
    );

    await session.signIn(
      '10.0.0.5:2200',
      'jaya',
      'pw-e04',
      trustFingerprint: (fp) async {
        trustedFp = fp;
        order.add('trust');
        return true;
      },
    );

    expect(probedHost, equals('10.0.0.5'));
    expect(probedPort, equals(2200));
    expect(trustedFp, equals(probed));
    expect(order.indexOf('probe'), equals(0));
    expect(order.indexOf('trust'), equals(1));
    expect(order.indexOf('connect'), greaterThan(order.indexOf('trust')));
  });

  test('E05: declining the fingerprint connects never and stores nothing', () async {
    final repo = await makeRepo([]);
    final store = MemoryAccountSessionStore2();
    var connects = 0;
    final session = AccountSession(
      machines: repo,
      connect: (p, s, pin, n) {
        connects++;
        return FakeTransport();
      },
      probeFingerprint: (host, port) async => 'SHA256:e05pinEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEEE',
      sessionStore: store,
      debounceDuration: Duration.zero,
    );

    try {
      await session.signIn('10.0.0.5:2200', 'jaya', 'pw-e05', trustFingerprint: (_) async => false);
    } catch (_) {}

    expect(connects, equals(0));
    expect(store.values, isEmpty);
    expect(repo.machines, isEmpty);
    expect(session.isSignedIn, isFalse);
  });

  test('E06: accepted pin is pinned on every connect and import counts match', () async {
    final repo = await makeRepo([]);
    const probed = 'SHA256:e06pinFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF';
    const mac = MachineProfile(
      id: '6a61796100000001',
      label: 'Mac',
      host: '10.9.9.9',
      port: 2222,
      username: 'macuser',
      auth: SshAuth.key,
      hostKeyFingerprint: 'SHA256:macpin',
    );
    const oracle = MachineProfile(
      id: '6a61796100000002',
      label: 'Oracle',
      host: '10.9.9.9',
      port: 22,
      username: 'someuser',
      auth: SshAuth.key,
      hostKeyFingerprint: 'SHA256:orapin',
    );
    final seeded = VaultContents(
      machines: const [mac, oracle],
      secrets: const {
        '6a61796100000001': MachineSecrets(privateKeyPem: 'pem-mac'),
        '6a61796100000002': MachineSecrets(privateKeyPem: 'pem-oracle'),
      },
    );
    final file = await sealVault(seeded, testAccountKey2);
    final profiles = <MachineProfile>[];
    final transport = keyGetTransport(file);
    final session = AccountSession(
      machines: repo,
      connect: (p, s, pin, n) {
        profiles.add(p);
        return transport;
      },
      probeFingerprint: (host, port) async => probed,
      sessionStore: MemoryAccountSessionStore2(),
      debounceDuration: Duration.zero,
    );

    await session.signIn('10.0.0.5:2200', 'jaya', 'pw-e06', trustFingerprint: (_) async => true);

    expect(session.isSignedIn, isTrue);
    expect(profiles, isNotEmpty);
    for (final p in profiles) {
      expect(p.hostKeyFingerprint, equals(probed));
    }
    expect(repo.machines.length, equals(2));
    expect(repo.byId('6a61796100000001')?.label, equals('Mac'));
    expect(repo.byId('6a61796100000002')?.label, equals('Oracle'));
    expect(session.status, equals(AccountSyncStatus.synced));
  });

  test('E07: mismatched typed username saves nothing and runs no put', () async {
    final repo = await makeRepo([]);
    final store = MemoryAccountSessionStore2();
    final seeded = VaultContents(
      machines: const [MachineProfile(id: 'm1', label: 'M1', host: 'h1', username: 'u1')],
    );
    final file = await sealVault(seeded, testAccountKey2);
    final commands = <String>[];
    final transport = keyGetTransport(file, commands: commands);
    final session = AccountSession(
      machines: repo,
      connect: (p, s, pin, n) => transport,
      probeFingerprint: (host, port) async => 'SHA256:e07pinGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGGG',
      sessionStore: store,
      debounceDuration: Duration.zero,
    );

    try {
      await session.signIn('10.0.0.5:2200', 'Alice', 'pw-e07', trustFingerprint: (_) async => true);
    } catch (_) {}

    expect(session.lastError, equals('Account not found.'));
    expect(repo.machines, isEmpty);
    expect(store.values, isEmpty);
    expect(commands.contains('put'), isFalse);
    expect(session.isSignedIn, isFalse);
  });

  test('E08: padded mixed-case username matching metadata signs in', () async {
    final repo = await makeRepo([]);
    final file = await sealVault(const VaultContents(), testAccountKey2);
    final transport = keyGetTransport(file);
    final session = AccountSession(
      machines: repo,
      connect: (p, s, pin, n) => transport,
      probeFingerprint: (host, port) async => 'SHA256:e08pinHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHHH',
      sessionStore: MemoryAccountSessionStore2(),
      debounceDuration: Duration.zero,
    );

    await session.signIn('10.0.0.5:2200', '  JAYA ', 'pw-e08', trustFingerprint: (_) async => true);

    expect(session.isSignedIn, isTrue);
  });

  test('E09: persisted record keeps address port and pin and never the password', () async {
    final repo = await makeRepo([]);
    final file = await sealVault(const VaultContents(), testAccountKey2);
    const probed = 'SHA256:e09pinIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIIII';
    const password = 'correct-horse-pw-09-unique';
    final store = MemoryAccountSessionStore2();
    final transport = keyGetTransport(file);
    final session = AccountSession(
      machines: repo,
      connect: (p, s, pin, n) => transport,
      probeFingerprint: (host, port) async => probed,
      sessionStore: store,
      debounceDuration: Duration.zero,
    );

    await session.signIn('10.0.0.5:2200', 'jaya', password, trustFingerprint: (_) async => true);

    expect(session.isSignedIn, isTrue);
    final raw = store.values[sessionStorageKey];
    expect(raw, isNotNull);
    expect(raw!.contains(password), isFalse);
    final decoded = jsonDecode(raw);
    expect(decoded, isA<Map>());
    expect(decoded['address'], equals('10.0.0.5'));
    expect(decoded['port'], equals(2200));
    expect(decoded['pin'], equals(probed));
  });

  test('E10: edit after sign-in uploads to the typed address with the accepted pin', () async {
    final repo = await makeRepo([]);
    final file = await sealVault(const VaultContents(), testAccountKey2);
    const probed = 'SHA256:e10pinJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJJ';
    final profiles = <MachineProfile>[];
    final transport = FakeTransport();
    transport.onExec = (cmd) async {
      if (cmd == 'key') {
        return FakeExecChannel.run(
          stdout: [
            jsonEncode({'v': 1, 'username': 'jaya', 'key': base64Encode(testAccountKey2)}),
          ],
          code: 0,
        );
      } else if (cmd == 'get') {
        return FakeExecChannel.run(stdout: [file], code: 0);
      } else if (cmd == 'put') {
        final ch = FakeExecChannel();
        ch.onInputClosed = () => ch.exit(0);
        return ch;
      }
      return FakeExecChannel.run(code: 1);
    };
    final session = AccountSession(
      machines: repo,
      connect: (p, s, pin, n) {
        profiles.add(p);
        return transport;
      },
      probeFingerprint: (host, port) async => probed,
      sessionStore: MemoryAccountSessionStore2(),
      debounceDuration: Duration.zero,
    );

    await session.signIn('10.0.0.5:2200', 'jaya', 'pw-e10', trustFingerprint: (_) async => true);
    profiles.clear();

    await repo.save(
      const MachineProfile(id: 'm10', label: 'M10', host: 'h10', username: 'u10', auth: SshAuth.password),
    );
    await session.activeUpload;

    expect(profiles, isNotEmpty);
    final last = profiles.last;
    expect(last.host, equals('10.0.0.5'));
    expect(last.port, equals(2200));
    expect(last.hostKeyFingerprint, equals(probed));
  });

  test('E11: legacy record restores signed in and next connect uses legacy box pin', () async {
    final repo = await makeRepo([]);
    final store = MemoryAccountSessionStore2();
    final digest = computeSnapshotDigest(const VaultContents());
    await store.write(
      sessionStorageKey,
      jsonEncode({
        'v': 2,
        'username': 'jaya',
        'loginSecret': 'legacy-secret-e11',
        'accountKey': base64Encode(testAccountKey2),
        'lastSyncedDigest': digest,
        'initialized': true,
      }),
    );
    final profiles = <MachineProfile>[];
    final transport = FakeTransport();
    transport.onExec = (cmd) async {
      final ch = FakeExecChannel();
      ch.onInputClosed = () => ch.exit(0);
      return ch;
    };
    final session = AccountSession(
      machines: repo,
      connect: (p, s, pin, n) {
        profiles.add(p);
        return transport;
      },
      probeFingerprint: (host, port) async => 'SHA256:unused-e11-pinxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
      sessionStore: store,
      debounceDuration: Duration.zero,
    );

    await session.init();

    expect(session.isSignedIn, isTrue);

    await repo.save(
      const MachineProfile(id: 'm11', label: 'M11', host: 'h11', username: 'u11', auth: SshAuth.password),
    );
    await session.activeUpload;

    expect(profiles, isNotEmpty);
    final last = profiles.last;
    expect(last.host, equals('140.245.204.23'));
    expect(last.port, equals(22));
    expect(last.hostKeyFingerprint, equals('SHA256:JVAqsSiiRDspdJB3qXz/aBFPmiV00lIoih7NV1b5I0U'));
  });

  test('E12: legacy record migrates persisted fields to legacy address port and pin', () async {
    final repo = await makeRepo([]);
    final store = MemoryAccountSessionStore2();
    final digest = computeSnapshotDigest(const VaultContents());
    await store.write(
      sessionStorageKey,
      jsonEncode({
        'v': 2,
        'username': 'jaya',
        'loginSecret': 'legacy-secret-e12',
        'accountKey': base64Encode(testAccountKey2),
        'lastSyncedDigest': digest,
        'initialized': true,
      }),
    );
    final transport = FakeTransport();
    transport.onExec = (cmd) async {
      final ch = FakeExecChannel();
      ch.onInputClosed = () => ch.exit(0);
      return ch;
    };
    final session = AccountSession(
      machines: repo,
      connect: (p, s, pin, n) => transport,
      probeFingerprint: (host, port) async => 'SHA256:unused-e12-pinxxxxxxxxxxxxxxxxxxxxxxxxxxxx',
      sessionStore: store,
      debounceDuration: Duration.zero,
    );

    await session.init();
    expect(session.isSignedIn, isTrue);

    await repo.save(
      const MachineProfile(id: 'm12', label: 'M12', host: 'h12', username: 'u12', auth: SshAuth.password),
    );
    await session.activeUpload;

    final raw = store.values[sessionStorageKey];
    expect(raw, isNotNull);
    final decoded = jsonDecode(raw!);
    expect(decoded['address'], equals('140.245.204.23'));
    expect(decoded['port'], equals(22));
    expect(decoded['pin'], equals('SHA256:JVAqsSiiRDspdJB3qXz/aBFPmiV00lIoih7NV1b5I0U'));
  });
}
