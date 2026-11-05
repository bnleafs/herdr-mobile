import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/ssh_transport.dart' show hostKeyChangedMessage;
import 'package:herdr_mobile/fork/account/account_screen.dart';
import 'package:herdr_mobile/fork/account/account_vault.dart';
import 'package:herdr_mobile/ui/core/kit.dart';

import '../support/fake_exec.dart';
import '../support/fake_transport.dart';
import '../support/memory_stores.dart';
import '../support/shot.dart' show loadAppFonts;

final testKey = Uint8List.fromList(List.generate(32, (i) => (i * 7 + 3) % 256));

void main() {
  setUpAll(loadAppFonts);

  group('AccountVault v2 crypto and format', () {
    test('round trip with sealVault and openVault', () async {
      const machineA = MachineProfile(
        id: 'm-1',
        label: 'Machine 1',
        host: '10.0.0.1',
        username: 'user1',
        port: 2222,
        auth: SshAuth.key,
        hostKeyFingerprint: 'SHA256:pin1',
      );
      const secretsA = MachineSecrets(
        privateKeyPem: '-----BEGIN OPENSSH PRIVATE KEY-----\ntest\n-----END OPENSSH PRIVATE KEY-----',
        passphrase: 'secret-passphrase',
        password: 'secret-password',
      );
      final c = VaultContents(machines: const [machineA], secrets: const {'m-1': secretsA});

      final sealed = await sealVault(c, testKey);
      final opened = await openVault(sealed, testKey);

      expect(opened.machines.length, equals(1));
      final m = opened.machines.first;
      expect(m.id, equals('m-1'));
      expect(m.label, equals('Machine 1'));
      expect(m.host, equals('10.0.0.1'));
      expect(m.port, equals(2222));
      expect(m.username, equals('user1'));
      expect(m.auth, equals(SshAuth.key));
      expect(m.hostKeyFingerprint, equals('SHA256:pin1'));

      final s = opened.secrets['m-1']!;
      expect(s.privateKeyPem, equals(secretsA.privateKeyPem));
      expect(s.passphrase, equals(secretsA.passphrase));
      expect(s.password, equals(secretsA.password));
    });

    test('v2 envelope shape has expected keys, version and cipher', () async {
      final c = VaultContents(
        machines: const [MachineProfile(id: 'm1', label: 'M1', host: 'h1', username: 'u1')],
      );

      final file = await sealVault(c, testKey);
      final map = jsonDecode(file) as Map<String, dynamic>;

      expect(map.keys.toSet(), equals({'v', 'cipher', 'nonce', 'ct'}));
      expect(map['v'], equals(2));
      expect(map['cipher'], equals('aes-256-gcm'));

      final nonceBytes = base64Decode(map['nonce'] as String);
      final ctBytes = base64Decode(map['ct'] as String);
      expect(nonceBytes.length, equals(12));
      expect(ctBytes.length, greaterThanOrEqualTo(16));
    });

    test('two seals differ in nonce and ciphertext', () async {
      final c = VaultContents(
        machines: const [MachineProfile(id: 'm1', label: 'M1', host: 'h1', username: 'u1')],
      );

      final file1 = await sealVault(c, testKey);
      final file2 = await sealVault(c, testKey);

      final map1 = jsonDecode(file1) as Map<String, dynamic>;
      final map2 = jsonDecode(file2) as Map<String, dynamic>;

      expect(map1['nonce'], isNot(equals(map2['nonce'])));
      expect(map1['ct'], isNot(equals(map2['ct'])));
    });

    test('wrong account key on openVault throws badFilePassword', () async {
      final c = VaultContents(
        machines: const [MachineProfile(id: 'm1', label: 'M1', host: 'h1', username: 'u1')],
      );
      final file = await sealVault(c, testKey);

      final wrongKey = Uint8List.fromList(List.generate(32, (i) => (i * 13 + 5) % 256));

      await expectLater(
        () => openVault(file, wrongKey),
        throwsA(isA<AccountProblem>().having((p) => p.message, 'message', AccountWords.badFilePassword)),
      );
    });

    test('unsupported or corrupted header throws unreadableFile', () async {
      final c = VaultContents(
        machines: const [MachineProfile(id: 'm1', label: 'M1', host: 'h1', username: 'u1')],
      );
      final file = await sealVault(c, testKey);
      final map = jsonDecode(file) as Map<String, dynamic>;

      // v == 1
      final mapV1 = Map<String, dynamic>.from(map)..['v'] = 1;
      await expectLater(
        () => openVault(jsonEncode(mapV1), testKey),
        throwsA(isA<AccountProblem>().having((p) => p.message, 'message', AccountWords.unreadableFile)),
      );

      // cipher unknown
      final mapCipher = Map<String, dynamic>.from(map)..['cipher'] = 'chacha20-poly1305';
      await expectLater(
        () => openVault(jsonEncode(mapCipher), testKey),
        throwsA(isA<AccountProblem>().having((p) => p.message, 'message', AccountWords.unreadableFile)),
      );

      // nonce wrong length
      final mapNonce = Map<String, dynamic>.from(map)..['nonce'] = base64Encode([1, 2, 3]);
      await expectLater(
        () => openVault(jsonEncode(mapNonce), testKey),
        throwsA(isA<AccountProblem>().having((p) => p.message, 'message', AccountWords.unreadableFile)),
      );
    });

    test('strict VaultContents.fromJson rejects invalid, reserved or duplicate machines', () {
      // Reserved id form-draft
      expect(
        () => VaultContents.fromJson({
          'machines': [
            {'id': 'form-draft', 'label': 'Draft', 'host': 'h', 'username': 'u'},
          ],
        }),
        throwsFormatException,
      );

      // Duplicate machine id
      expect(
        () => VaultContents.fromJson({
          'machines': [
            {'id': 'm1', 'label': 'M1', 'host': 'h1', 'username': 'u1'},
            {'id': 'm1', 'label': 'M2', 'host': 'h2', 'username': 'u2'},
          ],
        }),
        throwsFormatException,
      );

      // Invalid port
      expect(
        () => VaultContents.fromJson({
          'machines': [
            {'id': 'm1', 'label': 'M1', 'host': 'h1', 'username': 'u1', 'port': 70000},
          ],
        }),
        throwsFormatException,
      );

      // Unsupported auth
      expect(
        () => VaultContents.fromJson({
          'machines': [
            {'id': 'm1', 'label': 'M1', 'host': 'h1', 'username': 'u1', 'auth': 'kerberos'},
          ],
        }),
        throwsFormatException,
      );

      // Missing required field
      expect(
        () => VaultContents.fromJson({
          'machines': [
            {'id': 'm1', 'label': 'M1'},
          ],
        }),
        throwsFormatException,
      );
    });

    test('computeSnapshotDigest is deterministic and ignores form-draft', () {
      const m1 = MachineProfile(id: 'm1', label: 'M1', host: 'h1', username: 'u1');
      const m2 = MachineProfile(id: 'm2', label: 'M2', host: 'h2', username: 'u2');
      const draft = MachineProfile(id: 'form-draft', label: 'Draft', host: 'hd', username: 'ud');

      final c1 = VaultContents(
        machines: const [m2, m1],
        secrets: const {
          'm1': MachineSecrets(password: 'p1'),
          'm2': MachineSecrets(password: 'p2'),
        },
      );

      final c2 = VaultContents(
        machines: const [draft, m1, m2],
        secrets: const {
          'm2': MachineSecrets(password: 'p2'),
          'm1': MachineSecrets(password: 'p1'),
          'form-draft': MachineSecrets(password: 'pd'),
        },
      );

      expect(computeSnapshotDigest(c1), equals(computeSnapshotDigest(c2)));
    });
  });

  group('Server key command', () {
    test('fetchAccountKey parses valid key response', () async {
      final fakeTransport = FakeTransport();
      fakeTransport.onExec = (cmd) async {
        expect(cmd, equals('key'));
        return FakeExecChannel.run(
          stdout: [
            jsonEncode({'v': 1, 'username': 'jaya', 'key': base64Encode(testKey)}),
          ],
          code: 0,
        );
      };

      final key = await fetchAccountKey(fakeTransport);
      expect(key, equals(testKey));
      expect(fakeTransport.execCommands, equals(['key']));
    });

    test('fetchAccountKey rejects exit code != 0', () async {
      final fakeTransport = FakeTransport();
      fakeTransport.onExec = (_) async => FakeExecChannel.run(code: 1);

      await expectLater(
        () => fetchAccountKey(fakeTransport),
        throwsA(isA<AccountProblem>().having((p) => p.message, 'message', contains('exit code 1'))),
      );
    });

    test('fetchAccountKey rejects invalid version, username, or key length', () async {
      // wrong username
      final t1 = FakeTransport()
        ..onExec = (_) async => FakeExecChannel.run(
          stdout: [
            jsonEncode({'v': 1, 'username': 'other', 'key': base64Encode(testKey)}),
          ],
          code: 0,
        );
      await expectLater(() => fetchAccountKey(t1), throwsA(isA<AccountProblem>()));

      // wrong version
      final t2 = FakeTransport()
        ..onExec = (_) async => FakeExecChannel.run(
          stdout: [
            jsonEncode({'v': 2, 'username': 'jaya', 'key': base64Encode(testKey)}),
          ],
          code: 0,
        );
      await expectLater(() => fetchAccountKey(t2), throwsA(isA<AccountProblem>()));

      // key length != 32
      final t3 = FakeTransport()
        ..onExec = (_) async => FakeExecChannel.run(
          stdout: [
            jsonEncode({
              'v': 1,
              'username': 'jaya',
              'key': base64Encode([1, 2, 3]),
            }),
          ],
          code: 0,
        );
      await expectLater(() => fetchAccountKey(t3), throwsA(isA<AccountProblem>()));
    });
  });

  group('AccountVault signIn and uploadSnapshot', () {
    late List<String> capturedLogs;
    late DebugPrintCallback originalDebugPrint;

    setUp(() {
      capturedLogs = [];
      originalDebugPrint = debugPrint;
      debugPrint = (String? message, {int? wrapWidth}) {
        if (message != null) capturedLogs.add(message);
      };
    });

    tearDown(() {
      debugPrint = originalDebugPrint;
    });

    test('invalid username is rejected BEFORE creating a transport', () async {
      final repo = await _repo([]);
      var connectCalled = 0;
      final vault = AccountVault(
        machines: repo,
        connect: (p, s, pin, notice) {
          connectCalled++;
          return FakeTransport();
        },
      );

      await expectLater(
        () => vault.signIn('not-jaya', 'some-password'),
        throwsA(isA<AccountProblem>().having((p) => p.message, 'message', AccountWords.invalidUsername)),
      );

      expect(connectCalled, equals(0));
    });

    test('case-insensitive jaya with surrounding whitespace is accepted', () async {
      final repo = await _repo([]);
      final fakeTransport = FakeTransport();
      fakeTransport.onExec = (cmd) async {
        if (cmd == 'key') {
          return FakeExecChannel.run(
            stdout: [
              jsonEncode({'v': 1, 'username': 'jaya', 'key': base64Encode(testKey)}),
            ],
            code: 0,
          );
        }
        return FakeExecChannel.run(code: 3);
      };

      final vault = AccountVault(machines: repo, connect: (p, s, pin, notice) => fakeTransport);

      // exit 3 -> nothingSaved
      await expectLater(
        () => vault.signIn('  JaYa  ', 'any-pw'),
        throwsA(isA<AccountProblem>().having((p) => p.message, 'message', AccountWords.nothingSaved)),
      );
      expect(fakeTransport.execCommands, equals(['key', 'get']));
    });

    test('sign in executes key before get, decrypts and merges records', () async {
      final repo = await _repo([]);
      const mOracle = MachineProfile(
        id: 'oracle',
        label: 'Oracle',
        host: '140.245.204.23',
        username: 'jaya',
        auth: SshAuth.password,
      );
      final c = VaultContents(
        machines: const [mOracle],
        secrets: const {'oracle': MachineSecrets(password: 'ora-pass')},
      );
      final file = await sealVault(c, testKey);

      final fakeTransport = FakeTransport();
      fakeTransport.onExec = (cmd) async {
        if (cmd == 'key') {
          return FakeExecChannel.run(
            stdout: [
              jsonEncode({'v': 1, 'username': 'jaya', 'key': base64Encode(testKey)}),
            ],
            code: 0,
          );
        } else if (cmd == 'get') {
          return FakeExecChannel.run(stdout: [file], code: 0);
        }
        return FakeExecChannel.run(code: 1);
      };

      final vault = AccountVault(machines: repo, connect: (p, s, pin, notice) => fakeTransport);
      final res = await vault.signIn('jaya', 'pw');

      expect(res.added, equals(1));
      expect(fakeTransport.execCommands, equals(['key', 'get']));
      expect(fakeTransport.closed, isTrue);
      expect(repo.byId('oracle')?.label, equals('Oracle'));
      expect((await repo.secretsFor('oracle')).password, equals('ora-pass'));
    });

    test('sign in SSH refused maps to wrongPassword and preserves stores', () async {
      final repo = await _repo([]);
      final fakeTransport = FakeTransport();
      fakeTransport.onExec = (_) => Future.error(
        const HerdrTransportException('SSH authentication failed (check username and key/password).', fatal: true),
      );

      final vault = AccountVault(machines: repo, connect: (p, s, pin, notice) => fakeTransport);

      await expectLater(
        () => vault.signIn('jaya', 'wrong-pw'),
        throwsA(isA<AccountProblem>().having((p) => p.message, 'message', AccountWords.wrongPassword)),
      );

      expect(repo.machines, isEmpty);
      expect(capturedLogs.any((l) => l.contains('wrong-pw')), isFalse);
    });

    test('sign in host key changed maps to hostKeyDiffers and preserves stores', () async {
      final repo = await _repo([]);
      final fakeTransport = FakeTransport();
      fakeTransport.onExec = (_) => Future.error(const HerdrTransportException(hostKeyChangedMessage, fatal: true));

      final vault = AccountVault(machines: repo, connect: (p, s, pin, notice) => fakeTransport);

      await expectLater(
        () => vault.signIn('jaya', 'pw'),
        throwsA(isA<AccountProblem>().having((p) => p.message, 'message', AccountWords.hostKeyDiffers)),
      );

      expect(repo.machines, isEmpty);
    });

    test('sign in keeps a local host-key pin and takes the file pin when there is none', () async {
      const pinnedLocal = MachineProfile(
        id: 'P',
        label: 'P',
        host: 'hp',
        username: 'u',
        auth: SshAuth.password,
        hostKeyFingerprint: 'SHA256:local',
      );
      const unpinnedLocal = MachineProfile(id: 'U', label: 'U', host: 'hu', username: 'u', auth: SshAuth.password);
      final repo = await _repo([pinnedLocal, unpinnedLocal]);

      final box = await _boxWith(
        const VaultContents(
          machines: [
            MachineProfile(id: 'P', label: 'P2', host: 'hp', username: 'u', auth: SshAuth.password),
            MachineProfile(
              id: 'U',
              label: 'U2',
              host: 'hu',
              username: 'u',
              auth: SshAuth.password,
              hostKeyFingerprint: 'SHA256:file-u',
            ),
            MachineProfile(
              id: 'N',
              label: 'N',
              host: 'hn',
              username: 'u',
              auth: SshAuth.password,
              hostKeyFingerprint: 'SHA256:file-n',
            ),
          ],
        ),
      );

      await AccountVault(machines: repo, connect: (p, s, pin, notice) => box).signIn('jaya', 'pw');

      expect(repo.byId('P')!.label, equals('P2'));
      expect(repo.byId('P')!.hostKeyFingerprint, equals('SHA256:local'));
      expect(repo.byId('U')!.hostKeyFingerprint, equals('SHA256:file-u'));
      expect(repo.byId('N')!.hostKeyFingerprint, equals('SHA256:file-n'));
    });

    test('sign in keeps working local keys when the file has none for that machine', () async {
      const a = MachineProfile(id: 'A', label: 'A', host: 'ha', username: 'u');
      const b = MachineProfile(id: 'B', label: 'B', host: 'hb', username: 'u');
      final repo = await _repo(
        [a, b],
        {'A': const MachineSecrets(privateKeyPem: 'key-A'), 'B': const MachineSecrets(privateKeyPem: 'key-B')},
      );
      final box = await _boxWith(
        const VaultContents(
          machines: [a, b],
          secrets: {'B': MachineSecrets(privateKeyPem: 'key-B2')},
        ),
      );

      await AccountVault(machines: repo, connect: (p, s, pin, notice) => box).signIn('jaya', 'pw');

      expect((await repo.secretsFor('A')).privateKeyPem, equals('key-A'));
      expect((await repo.secretsFor('B')).privateKeyPem, equals('key-B2'));
    });

    test('uploadSnapshot sends v2 envelope and allows empty list for initialized account', () async {
      final repo = await _repo([]);
      final channel = FakeExecChannel();
      channel.onInputClosed = () => channel.exit(0);

      final fakeTransport = FakeTransport();
      fakeTransport.onExec = (cmd) async {
        expect(cmd, equals('put'));
        return channel;
      };

      final vault = AccountVault(machines: repo, connect: (p, s, pin, notice) => fakeTransport);

      final count = await vault.uploadSnapshot(
        contents: const VaultContents(),
        accountKey: testKey,
        loginSecret: 'derived-login-secret',
      );

      expect(count, equals(0));
      expect(channel.sent.length, equals(1));

      final uploaded = await openVault(channel.sent.single, testKey);
      expect(uploaded.machines, isEmpty);
    });

    test('uploadSnapshot refuses, naming the machine, when a key machine has no stored key', () async {
      final repo = await _repo([]);
      const keyed = MachineProfile(id: 'k', label: 'Keyed Box', host: 'h', username: 'u', auth: SshAuth.key);
      final vault = AccountVault(machines: repo, connect: (p, s, pin, notice) => FakeTransport());

      await expectLater(
        () => vault.uploadSnapshot(
          contents: const VaultContents(machines: [keyed]),
          accountKey: testKey,
          loginSecret: 'secret',
        ),
        throwsA(isA<AccountProblem>().having((p) => p.message, 'message', AccountWords.keyMissing('Keyed Box'))),
      );
    });

    test('uploadSnapshot over 1 MiB throws overMaxBytes', () async {
      final repo = await _repo([]);
      final largePem = 'A' * (1100 * 1024);
      const largeMachine = MachineProfile(id: 'large', label: 'Large', host: 'host', username: 'user');
      final c = VaultContents(
        machines: const [largeMachine],
        secrets: {'large': MachineSecrets(privateKeyPem: largePem)},
      );

      final vault = AccountVault(machines: repo, connect: (p, s, pin, notice) => FakeTransport());

      await expectLater(
        () => vault.uploadSnapshot(contents: c, accountKey: testKey, loginSecret: 'secret'),
        throwsA(isA<AccountProblem>().having((p) => p.message, 'message', AccountWords.overMaxBytes)),
      );
    });

    test('loginSecret matches Python PBKDF2 vector', () async {
      expect(await loginSecret('correct horse battery staple'), equals('EdUwanc0srwKbgx3sXA2s3U4tzl2gAGLrWeqZdAiCQU'));
    });
  });

  group('AccountGroup widget test', () {
    testWidgets('AccountGroup renders with Sign in and opens AccountScreen', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          home: const Scaffold(body: AccountGroup()),
        ),
      );

      expect(find.text('Account'), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);
    });
  });
}

Future<MachineRepository> _repo(List<MachineProfile> profiles, [Map<String, MachineSecrets> secrets = const {}]) async {
  final profileStore = MemoryProfileStore()..profiles = profiles;
  final secretStore = MemorySecretStore();
  secretStore.secrets.addAll(secrets);
  final repo = MachineRepository(profiles: profileStore, secrets: secretStore);
  await repo.load();
  return repo;
}

Future<FakeTransport> _boxWith(VaultContents contents) async {
  final file = await sealVault(contents, testKey);
  return FakeTransport()
    ..onExec = (cmd) async {
      if (cmd == 'key') {
        return FakeExecChannel.run(
          stdout: [
            jsonEncode({'v': 1, 'username': 'jaya', 'key': base64Encode(testKey)}),
          ],
          code: 0,
        );
      } else if (cmd == 'get') {
        return FakeExecChannel.run(stdout: [file], code: 0);
      }
      return FakeExecChannel.run(code: 1);
    };
}
