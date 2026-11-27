import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:fake_async/fake_async.dart';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/fork/account/account_screen.dart';
import 'package:herdr_mobile/fork/account/account_session.dart';
import 'package:herdr_mobile/fork/account/account_vault.dart';
import 'package:herdr_mobile/ui/core/kit.dart';

import '../support/fake_exec.dart';
import '../support/fake_transport.dart';
import '../support/memory_stores.dart';
import '../support/shot.dart' show loadAppFonts;

final testAccountKey = Uint8List.fromList(List.generate(32, (i) => (i * 11 + 7) % 256));

class MemoryAccountSessionStore implements AccountSessionStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read(String key) async => values[key];

  @override
  Future<void> write(String key, String value) async => values[key] = value;

  @override
  Future<void> delete(String key) async => values.remove(key);
}

void main() {
  setUpAll(loadAppFonts);

  setUp(() {
    SharedPreferences.setMockInitialValues({localInitializedKey: true});
  });

  group('AccountSession login and import invariants', () {
    test('wrong password does not mutate machine repository or session store', () async {
      final repo = await _repo([]);
      final sessionStore = MemoryAccountSessionStore();
      final fakeTransport = FakeTransport();
      fakeTransport.onExec = (_) => Future.error(
        const HerdrTransportException('SSH authentication failed (check username and key/password).', fatal: true),
      );

      final session = AccountSession(
        machines: repo,
        probeFingerprint: (host, port) async => 'SHA256:testpin',
        connect: (p, s, pin, n) => fakeTransport,
        sessionStore: sessionStore,
        debounceDuration: Duration.zero,
      );

      await expectLater(
        () => session.signIn('140.245.204.23', 'jaya', 'wrong-pw', trustFingerprint: (_) async => true),
        throwsA(isA<AccountProblem>()),
      );

      expect(session.isSignedIn, isFalse);
      expect(session.lastError, equals(AccountWords.wrongPassword));
      expect(repo.machines, isEmpty);
      expect(sessionStore.values, isEmpty);
    });

    test(
      'first login receives seeded Mac and Oracle; pull happens before any put; unchanged import does not put',
      () async {
        final repo = await _repo([]);
        final sessionStore = MemoryAccountSessionStore();

        const mac = MachineProfile(
          id: '6a61796100000001',
          label: 'Mac',
          host: '140.245.204.23',
          port: 2222,
          username: 'macuser',
          auth: SshAuth.key,
          hostKeyFingerprint: 'SHA256:macpin',
        );
        const oracle = MachineProfile(
          id: '6a61796100000002',
          label: 'Oracle',
          host: '140.245.204.23',
          port: 22,
          username: 'jaya',
          auth: SshAuth.key,
          hostKeyFingerprint: 'SHA256:orapin',
        );
        final seededContents = VaultContents(
          machines: const [mac, oracle],
          secrets: const {
            '6a61796100000001': MachineSecrets(privateKeyPem: 'pem-mac'),
            '6a61796100000002': MachineSecrets(privateKeyPem: 'pem-oracle'),
          },
        );
        final encryptedFile = await sealVault(seededContents, testAccountKey);

        final commandsRun = <String>[];
        final fakeTransport = FakeTransport();
        fakeTransport.onExec = (cmd) async {
          commandsRun.add(cmd);
          if (cmd == 'key') {
            return FakeExecChannel.run(
              stdout: [
                jsonEncode({'v': 1, 'username': 'jaya', 'key': base64Encode(testAccountKey)}),
              ],
              code: 0,
            );
          } else if (cmd == 'get') {
            return FakeExecChannel.run(stdout: [encryptedFile], code: 0);
          }
          return FakeExecChannel.run(code: 1);
        };

        final session = AccountSession(
          machines: repo,
          probeFingerprint: (host, port) async => 'SHA256:testpin',
          connect: (p, s, pin, n) => fakeTransport,
          sessionStore: sessionStore,
          debounceDuration: Duration.zero,
        );

        await session.signIn('140.245.204.23', 'jaya', 'correct-password', trustFingerprint: (_) async => true);

        // Adversarial check: key-before-get and pull-before-put
        expect(commandsRun, equals(['key', 'get']));
        expect(commandsRun.contains('put'), isFalse);

        expect(repo.machines.length, equals(2));
        expect(repo.byId('6a61796100000001')?.label, equals('Mac'));
        expect(repo.byId('6a61796100000002')?.label, equals('Oracle'));
        expect((await repo.secretsFor('6a61796100000001')).privateKeyPem, equals('pem-mac'));
        expect((await repo.secretsFor('6a61796100000002')).privateKeyPem, equals('pem-oracle'));

        expect(session.isSignedIn, isTrue);
        expect(session.status, equals(AccountSyncStatus.synced));
        expect(sessionStore.values.containsKey(sessionStorageKey), isTrue);
      },
    );

    test('empty fresh install cannot wipe seeded server data when server reports nothing saved', () async {
      final repo = await _repo([]);
      final fakeTransport = FakeTransport();
      final commands = <String>[];
      fakeTransport.onExec = (cmd) async {
        commands.add(cmd);
        if (cmd == 'key') {
          return FakeExecChannel.run(
            stdout: [
              jsonEncode({'v': 1, 'username': 'jaya', 'key': base64Encode(testAccountKey)}),
            ],
            code: 0,
          );
        } else if (cmd == 'get') {
          return FakeExecChannel.run(code: 3); // exit 3: nothing saved on box
        }
        return FakeExecChannel.run(code: 1);
      };

      final session = AccountSession(
        machines: repo,
        probeFingerprint: (host, port) async => 'SHA256:testpin',
        connect: (p, s, pin, n) => fakeTransport,
        sessionStore: MemoryAccountSessionStore(),
        debounceDuration: Duration.zero,
      );

      await expectLater(
        () => session.signIn('140.245.204.23', 'jaya', 'pw', trustFingerprint: (_) async => true),
        throwsA(isA<AccountProblem>().having((p) => p.message, 'message', AccountWords.nothingSaved)),
      );

      // Verify no upload was attempted
      expect(commands.contains('put'), isFalse);
      expect(session.isSignedIn, isFalse);
    });
  });

  group('AccountSession restore and persistence', () {
    test('restores signed-in state from persistent store without password', () async {
      const mac = MachineProfile(id: 'm1', label: 'Mac', host: 'h1', username: 'u1');
      final repo = await _repo([mac], {'m1': const MachineSecrets(password: 'pass')});

      final sessionStore = MemoryAccountSessionStore();
      final snapshot = VaultContents(
        machines: const [mac],
        secrets: const {'m1': MachineSecrets(password: 'pass')},
      );
      final digest = computeSnapshotDigest(snapshot);

      await sessionStore.write(
        sessionStorageKey,
        jsonEncode({
          'v': 2,
          'username': 'jaya',
          'loginSecret': 'login-secret-123',
          'accountKey': base64Encode(testAccountKey),
          'lastSyncedDigest': digest,
          'initialized': true,
          'address': '10.0.0.5',
          'port': 2200,
          'pin': 'SHA256:testpin',
        }),
      );

      final sealed = await sealVault(snapshot, testAccountKey);
      final fakeTransport = FakeTransport();
      fakeTransport.onExec = (cmd) async {
        if (cmd == 'get') return FakeExecChannel.run(stdout: [sealed], code: 0);
        return FakeExecChannel.run(code: 1);
      };
      final session = AccountSession(
        machines: repo,
        probeFingerprint: (host, port) async => 'SHA256:testpin',
        connect: (p, s, pin, n) => fakeTransport,
        sessionStore: sessionStore,
        debounceDuration: Duration.zero,
      );

      await session.init();

      expect(session.isSignedIn, isTrue);
      expect(session.username, equals('jaya'));
      expect(session.status, equals(AccountSyncStatus.synced));
    });

    test('preserves pending local edits on restart and uploads them without remote overwrite', () async {
      const macOriginal = MachineProfile(
        id: 'm1',
        label: 'Mac Old',
        host: 'h1',
        username: 'u1',
        auth: SshAuth.password,
      );
      const macEdited = MachineProfile(
        id: 'm1',
        label: 'Mac Edited Locally',
        host: 'h1',
        username: 'u1',
        auth: SshAuth.password,
      );

      // Local repository has the edited profile
      final repo = await _repo([macEdited]);

      final sessionStore = MemoryAccountSessionStore();
      // Saved lastSyncedDigest is from the older profile
      final oldDigest = computeSnapshotDigest(VaultContents(machines: const [macOriginal]));

      await sessionStore.write(
        sessionStorageKey,
        jsonEncode({
          'v': 2,
          'username': 'jaya',
          'loginSecret': 'login-secret-123',
          'accountKey': base64Encode(testAccountKey),
          'lastSyncedDigest': oldDigest,
          'initialized': true,
          'address': '10.0.0.5',
          'port': 2200,
          'pin': 'SHA256:testpin',
        }),
      );

      final oldFile = await sealVault(VaultContents(machines: const [macOriginal]), testAccountKey);

      final putChannel = FakeExecChannel();
      putChannel.onInputClosed = () => putChannel.exit(0);

      final fakeTransport = FakeTransport();
      fakeTransport.onExec = (cmd) async {
        if (cmd == 'get') return FakeExecChannel.run(stdout: [oldFile], code: 0);
        if (cmd == 'put') return putChannel;
        return FakeExecChannel.run(code: 1);
      };

      final session = AccountSession(
        machines: repo,
        probeFingerprint: (host, port) async => 'SHA256:testpin',
        connect: (p, s, pin, n) => fakeTransport,
        sessionStore: sessionStore,
        debounceDuration: Duration.zero,
      );

      await session.init();

      // Local edit was NOT overwritten
      expect(repo.byId('m1')?.label, equals('Mac Edited Locally'));
      expect(session.status, equals(AccountSyncStatus.synced));
      expect(fakeTransport.execCommands, equals(['get', 'put']));

      final uploaded = await openVault(putChannel.sent.single, testAccountKey);
      expect(uploaded.machines.single.label, equals('Mac Edited Locally'));
    });
  });

  group('Autosave, debouncing and serialization', () {
    test('rapid burst of edits coalesces into one debounced upload', () async {
      final repo = await _repo([]);
      final sessionStore = MemoryAccountSessionStore();

      var putsCount = 0;
      final sent = Completer<void>();
      final emptyFile = await sealVault(const VaultContents(), testAccountKey);
      final fakeTransport = FakeTransport();
      fakeTransport.onExec = (cmd) async {
        if (cmd == 'get') return FakeExecChannel.run(stdout: [emptyFile], code: 0);
        if (cmd == 'put') {
          putsCount++;
          final ch = FakeExecChannel();
          ch.onInputClosed = () {
            sent.complete();
            ch.exit(0);
          };
          return ch;
        }
        return FakeExecChannel.run(code: 0);
      };

      final session = AccountSession(
        machines: repo,
        probeFingerprint: (host, port) async => 'SHA256:testpin',
        connect: (p, s, pin, n) => fakeTransport,
        sessionStore: sessionStore,
        debounceDuration: const Duration(milliseconds: 50),
      );

      await sessionStore.write(
        sessionStorageKey,
        jsonEncode({
          'v': 2,
          'username': 'jaya',
          'loginSecret': 'login-secret',
          'accountKey': base64Encode(testAccountKey),
          'lastSyncedDigest': 'initial-empty',
          'initialized': true,
          'address': '10.0.0.5',
          'port': 2200,
          'pin': 'SHA256:testpin',
        }),
      );
      await session.init();

      // 5 rapid saves
      for (var i = 1; i <= 5; i++) {
        await repo.save(
          MachineProfile(id: 'm$i', label: 'Machine $i', host: 'h$i', username: 'u$i', auth: SshAuth.password),
        );
      }

      expect(session.status, equals(AccountSyncStatus.pending));

      // Wait for the upload event, independent of timer/CPU speed.
      await sent.future;
      await session.activeUpload;

      expect(putsCount, equals(1));
      expect(session.status, equals(AccountSyncStatus.synced));
      expect(repo.machines.length, equals(5));
    });

    test('unsaved drafts are excluded from uploaded snapshots', () async {
      const valid = MachineProfile(id: 'valid-1', label: 'Valid', host: 'h', username: 'u', auth: SshAuth.password);
      const draft = MachineProfile(
        id: 'form-draft',
        label: 'Draft',
        host: 'hd',
        username: 'ud',
        auth: SshAuth.password,
      );

      final repo = await _repo([valid, draft]);
      final sessionStore = MemoryAccountSessionStore();

      final emptyFile = await sealVault(const VaultContents(), testAccountKey);
      final putChannel = FakeExecChannel();
      putChannel.onInputClosed = () => putChannel.exit(0);
      final fakeTransport = FakeTransport();
      fakeTransport.onExec = (cmd) async {
        if (cmd == 'get') return FakeExecChannel.run(stdout: [emptyFile], code: 0);
        return putChannel;
      };

      final session = AccountSession(
        machines: repo,
        probeFingerprint: (host, port) async => 'SHA256:testpin',
        connect: (p, s, pin, n) => fakeTransport,
        sessionStore: sessionStore,
        debounceDuration: Duration.zero,
      );

      await sessionStore.write(
        sessionStorageKey,
        jsonEncode({
          'v': 2,
          'username': 'jaya',
          'loginSecret': 'secret',
          'accountKey': base64Encode(testAccountKey),
          'lastSyncedDigest': 'different',
          'initialized': true,
          'address': '10.0.0.5',
          'port': 2200,
          'pin': 'SHA256:testpin',
        }),
      );

      await session.init();

      final uploaded = await openVault(putChannel.sent.single, testAccountKey);
      expect(uploaded.machines.map((m) => m.id).toList(), equals(['valid-1']));
      expect(uploaded.machines.any((m) => m.id == 'form-draft'), isFalse);
    });

    test('secret-only mutation triggers upload and updates stored digest', () async {
      const m = MachineProfile(id: 'm1', label: 'Machine 1', host: 'h1', username: 'u1', auth: SshAuth.password);
      final repo = await _repo([m], {'m1': const MachineSecrets(password: 'pass-1')});
      final sessionStore = MemoryAccountSessionStore();

      final initialFile = await sealVault(
        VaultContents(
          machines: const [m],
          secrets: const {'m1': MachineSecrets(password: 'pass-1')},
        ),
        testAccountKey,
      );
      final putChannel = FakeExecChannel();
      putChannel.onInputClosed = () => putChannel.exit(0);
      final fakeTransport = FakeTransport();
      fakeTransport.onExec = (cmd) async {
        if (cmd == 'get') return FakeExecChannel.run(stdout: [initialFile], code: 0);
        return putChannel;
      };

      final session = AccountSession(
        machines: repo,
        probeFingerprint: (host, port) async => 'SHA256:testpin',
        connect: (p, s, pin, n) => fakeTransport,
        sessionStore: sessionStore,
        debounceDuration: Duration.zero,
      );

      final initialDigest = computeSnapshotDigest(
        VaultContents(
          machines: const [m],
          secrets: const {'m1': MachineSecrets(password: 'pass-1')},
        ),
      );

      await sessionStore.write(
        sessionStorageKey,
        jsonEncode({
          'v': 2,
          'username': 'jaya',
          'loginSecret': 'secret',
          'accountKey': base64Encode(testAccountKey),
          'lastSyncedDigest': initialDigest,
          'initialized': true,
          'address': '10.0.0.5',
          'port': 2200,
          'pin': 'SHA256:testpin',
        }),
      );
      await session.init();
      expect(session.status, equals(AccountSyncStatus.synced));

      // Mutate secret only
      await repo.save(m, secrets: const MachineSecrets(password: 'pass-updated'));
      await session.activeUpload;

      expect(session.status, equals(AccountSyncStatus.synced));
      expect(fakeTransport.execCommands, equals(['get', 'get', 'put']));

      final uploaded = await openVault(putChannel.sent.single, testAccountKey);
      expect(uploaded.secrets['m1']?.password, equals('pass-updated'));
    });

    test('missing key for key-auth machine refuses upload with machine label and sets error', () async {
      const keyed = MachineProfile(id: 'k1', label: 'Production Server', host: 'h1', username: 'u1', auth: SshAuth.key);
      final repo = await _repo([keyed]);
      final sessionStore = MemoryAccountSessionStore();

      final emptyFile = await sealVault(const VaultContents(), testAccountKey);
      final fakeTransport = FakeTransport();
      fakeTransport.onExec = (cmd) async {
        if (cmd == 'get') return FakeExecChannel.run(stdout: [emptyFile], code: 0);
        return FakeExecChannel.run(code: 1);
      };

      final session = AccountSession(
        machines: repo,
        probeFingerprint: (host, port) async => 'SHA256:testpin',
        connect: (p, s, pin, n) => fakeTransport,
        sessionStore: sessionStore,
        debounceDuration: Duration.zero,
      );

      await sessionStore.write(
        sessionStorageKey,
        jsonEncode({
          'v': 2,
          'username': 'jaya',
          'loginSecret': 'secret',
          'accountKey': base64Encode(testAccountKey),
          'lastSyncedDigest': 'different',
          'initialized': true,
          'address': '10.0.0.5',
          'port': 2200,
          'pin': 'SHA256:testpin',
        }),
      );

      await session.init();

      expect(session.status, equals(AccountSyncStatus.error));
      expect(session.lastError, equals(AccountWords.keyMissing('Production Server')));
    });

    test('deletion of last machine on initialized account uploads empty list', () async {
      const m = MachineProfile(id: 'm1', label: 'Machine 1', host: 'h', username: 'u');
      final repo = await _repo([m]);
      final sessionStore = MemoryAccountSessionStore();

      final machineFile = await sealVault(VaultContents(machines: const [m]), testAccountKey);
      final putChannel = FakeExecChannel();
      putChannel.onInputClosed = () => putChannel.exit(0);
      final fakeTransport = FakeTransport();
      fakeTransport.onExec = (cmd) async {
        if (cmd == 'get') return FakeExecChannel.run(stdout: [machineFile], code: 0);
        return putChannel;
      };

      final session = AccountSession(
        machines: repo,
        probeFingerprint: (host, port) async => 'SHA256:testpin',
        connect: (p, s, pin, n) => fakeTransport,
        sessionStore: sessionStore,
        debounceDuration: Duration.zero,
      );

      final digest = computeSnapshotDigest(VaultContents(machines: const [m]));
      await sessionStore.write(
        sessionStorageKey,
        jsonEncode({
          'v': 2,
          'username': 'jaya',
          'loginSecret': 'secret',
          'accountKey': base64Encode(testAccountKey),
          'lastSyncedDigest': digest,
          'initialized': true,
          'address': '10.0.0.5',
          'port': 2200,
          'pin': 'SHA256:testpin',
        }),
      );
      await session.init();

      // Remove the last machine
      await repo.remove('m1');
      await session.activeUpload;

      expect(session.status, equals(AccountSyncStatus.synced));
      expect(fakeTransport.execCommands, equals(['get', 'get', 'put']));

      final uploaded = await openVault(putChannel.sent.single, testAccountKey);
      expect(uploaded.machines, isEmpty);
    });
  });

  group('Sign out, pause and privacy', () {
    test('sign out clears storage, keeps local machines, and stops uploads', () async {
      const m = MachineProfile(id: 'm1', label: 'Machine 1', host: 'h', username: 'u');
      final repo = await _repo([m]);
      final sessionStore = MemoryAccountSessionStore();

      var putsAttempted = 0;
      final fakeTransport = FakeTransport();
      fakeTransport.onExec = (cmd) async {
        if (cmd == 'put') putsAttempted++;
        return FakeExecChannel.run(code: 0);
      };

      final session = AccountSession(
        machines: repo,
        probeFingerprint: (host, port) async => 'SHA256:testpin',
        connect: (p, s, pin, n) => fakeTransport,
        sessionStore: sessionStore,
        debounceDuration: const Duration(milliseconds: 100),
      );

      await sessionStore.write(
        sessionStorageKey,
        jsonEncode({
          'v': 2,
          'username': 'jaya',
          'loginSecret': 'secret',
          'accountKey': base64Encode(testAccountKey),
          'lastSyncedDigest': computeSnapshotDigest(const VaultContents()),
          'initialized': true,
          'address': '10.0.0.5',
          'port': 2200,
          'pin': 'SHA256:testpin',
        }),
      );
      await session.init();

      final clock = FakeAsync();
      clock.run((_) {
        // Schedule the debounce in virtual time, then sign out in the root zone
        // where the session's storage queue was constructed.
        unawaited(repo.save(const MachineProfile(id: 'm2', label: 'Machine 2', host: 'h2', username: 'u2')));
        clock.flushMicrotasks();
        expect(session.status, AccountSyncStatus.pending);
      });
      await session.signOut();
      clock.elapse(const Duration(seconds: 1));
      clock.flushMicrotasks();
      expect(putsAttempted, 0);
      expect(session.isSignedIn, isFalse);
      expect(session.status, AccountSyncStatus.signedOut);
      expect(sessionStore.values.containsKey(sessionStorageKey), isFalse);
      expect(repo.machines.length, 2);
    });

    test('backgrounding pauses upload and resume triggers pending upload', () async {
      final repo = await _repo([]);
      final sessionStore = MemoryAccountSessionStore();

      var putsAttempted = 0;
      final sent = Completer<void>();
      final emptyFile = await sealVault(const VaultContents(), testAccountKey);
      final fakeTransport = FakeTransport();
      fakeTransport.onExec = (cmd) async {
        if (cmd == 'get') return FakeExecChannel.run(stdout: [emptyFile], code: 0);
        if (cmd == 'put') {
          putsAttempted++;
          final ch = FakeExecChannel();
          ch.onInputClosed = () {
            sent.complete();
            ch.exit(0);
          };
          return ch;
        }
        return FakeExecChannel.run(code: 0);
      };

      final session = AccountSession(
        machines: repo,
        probeFingerprint: (host, port) async => 'SHA256:testpin',
        connect: (p, s, pin, n) => fakeTransport,
        sessionStore: sessionStore,
        debounceDuration: const Duration(milliseconds: 100),
      );

      await sessionStore.write(
        sessionStorageKey,
        jsonEncode({
          'v': 2,
          'username': 'jaya',
          'loginSecret': 'secret',
          'accountKey': base64Encode(testAccountKey),
          'lastSyncedDigest': computeSnapshotDigest(const VaultContents()),
          'initialized': true,
          'address': '10.0.0.5',
          'port': 2200,
          'pin': 'SHA256:testpin',
        }),
      );
      await session.init();

      // Pause / background
      session.didChangeAppLifecycleState(AppLifecycleState.paused);

      // Mutate while paused
      await repo.save(const MachineProfile(id: 'm1', label: 'M1', host: 'h1', username: 'u1', auth: SshAuth.password));
      expect(session.status, equals(AccountSyncStatus.pending));

      expect(putsAttempted, equals(0));

      // Resume
      session.didChangeAppLifecycleState(AppLifecycleState.resumed);

      await sent.future;
      await session.activeUpload;
      expect(putsAttempted, equals(1));
      expect(session.status, equals(AccountSyncStatus.synced));
    });

    test('raw error text and dummy secret sentinels do not leak into UI error or logs', () async {
      final repo = await _repo([]);
      final sessionStore = MemoryAccountSessionStore();

      const secretSentinel = 'UNTRUSTED_STDERR_DUMMY_SECRET_SENTINEL_xyz';
      final fakeTransport = FakeTransport();
      fakeTransport.onExec = (_) async => FakeExecChannel.run(code: 1, stderr: secretSentinel);

      final capturedLogs = <String>[];
      final originalDebugPrint = debugPrint;
      debugPrint = (msg, {wrapWidth}) => capturedLogs.add(msg ?? '');

      final session = AccountSession(
        machines: repo,
        probeFingerprint: (host, port) async => 'SHA256:testpin',
        connect: (p, s, pin, n) => fakeTransport,
        sessionStore: sessionStore,
        debounceDuration: Duration.zero,
      );

      try {
        await session.signIn('140.245.204.23', 'jaya', 'pw', trustFingerprint: (_) async => true);
      } catch (_) {}

      debugPrint = originalDebugPrint;

      expect(session.lastError, isNotNull);
      expect(session.lastError!.contains(secretSentinel), isFalse);
      expect(capturedLogs.any((l) => l.contains(secretSentinel)), isFalse);
    });
  });

  group('AccountScreen UI widgets and accessibility', () {
    testWidgets('signed-out screen shows Username, Password, Sign in, IME flags, and no Save button', (tester) async {
      final repo = await _repo([]);
      final session = AccountSession(
        machines: repo,
        probeFingerprint: (host, port) async => 'SHA256:testpin',
        connect: (p, s, pin, n) => FakeTransport(),
        sessionStore: MemoryAccountSessionStore(),
      );

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<MachineRepository>.value(value: repo),
            ChangeNotifierProvider<AccountSession>.value(value: session),
          ],
          child: MaterialApp(theme: AppTheme.light(), home: const AccountScreen()),
        ),
      );

      expect(find.text('Username'), findsOneWidget);
      expect(find.text('Password'), findsOneWidget);
      expect(find.text('Sign in'), findsOneWidget);
      expect(find.text('Save to box'), findsNothing);

      // Verify IME / autocorrect / suggestion flags on password field
      final textFields = tester.widgetList<TextField>(find.byType(TextField)).toList();
      final passwordField = textFields.firstWhere((f) => f.obscureText == true);
      expect(passwordField.enableIMEPersonalizedLearning, isFalse);
      expect(passwordField.autocorrect, isFalse);
      expect(passwordField.enableSuggestions, isFalse);
      expect(passwordField.keyboardType, equals(TextInputType.visiblePassword));
    });

    testWidgets('signed-in screen displays signed in header, sync status, and Sign out button', (tester) async {
      final repo = await _repo([]);
      final sessionStore = MemoryAccountSessionStore();

      await sessionStore.write(
        sessionStorageKey,
        jsonEncode({
          'v': 2,
          'username': 'jaya',
          'loginSecret': 'secret',
          'accountKey': base64Encode(testAccountKey),
          'lastSyncedDigest': computeSnapshotDigest(const VaultContents()),
          'initialized': true,
          'address': '10.0.0.5',
          'port': 2200,
          'pin': 'SHA256:testpin',
        }),
      );

      final sealed = await tester.runAsync(() => sealVault(const VaultContents(), testAccountKey));
      final fakeTransport = FakeTransport();
      fakeTransport.onExec = (cmd) async {
        if (cmd == 'get') return FakeExecChannel.run(stdout: [sealed!], code: 0);
        return FakeExecChannel.run(code: 1);
      };
      final session = AccountSession(
        machines: repo,
        probeFingerprint: (host, port) async => 'SHA256:testpin',
        connect: (p, s, pin, n) => fakeTransport,
        sessionStore: sessionStore,
      );
      await tester.runAsync(() => session.init());

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<MachineRepository>.value(value: repo),
            ChangeNotifierProvider<AccountSession>.value(value: session),
          ],
          child: MaterialApp(theme: AppTheme.light(), home: const AccountScreen()),
        ),
      );

      expect(find.text(AccountWords.signedIn), findsOneWidget);
      expect(find.text(AccountWords.syncStatusSynced), findsOneWidget);
      expect(find.text('Sign out'), findsOneWidget);
      expect(find.text(AccountWords.machinesRemainNotice), findsOneWidget);
    });

    testWidgets('responsive layout renders cleanly at 320dp width and text scale 1.6', (tester) async {
      tester.view.physicalSize = const Size(320 * 3.0, 640 * 3.0);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final repo = await _repo([]);
      final session = AccountSession(
        machines: repo,
        probeFingerprint: (host, port) async => 'SHA256:testpin',
        connect: (p, s, pin, n) => FakeTransport(),
        sessionStore: MemoryAccountSessionStore(),
      );

      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<MachineRepository>.value(value: repo),
            ChangeNotifierProvider<AccountSession>.value(value: session),
          ],
          child: MaterialApp(
            theme: AppTheme.light(),
            home: MediaQuery(
              data: const MediaQueryData(textScaler: TextScaler.linear(1.6)),
              child: const AccountScreen(),
            ),
          ),
        ),
      );

      await tester.pumpAndSettle();

      expect(find.text('Sign in'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('Guarded upload spec E01-E08', () {
    test('test_E01_guarded upload fetches box before put when digest matches', () async {
      final base = const VaultContents();
      final digest = computeSnapshotDigest(base);
      final repo = await _repo([]);
      final store = MemoryAccountSessionStore();
      await store.write(
        sessionStorageKey,
        jsonEncode({
          'v': 2,
          'username': 'jaya',
          'loginSecret': 'login-secret-e01',
          'accountKey': base64Encode(testAccountKey),
          'lastSyncedDigest': digest,
          'initialized': true,
          'address': '10.0.0.5',
          'port': 2200,
          'pin': 'SHA256:testpinE01AAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        }),
      );
      final file = await sealVault(base, testAccountKey);
      final fake = FakeTransport();
      fake.onExec = (cmd) async {
        if (cmd == 'get') return FakeExecChannel.run(stdout: [file], code: 0);
        if (cmd == 'put') {
          final ch = FakeExecChannel();
          ch.onInputClosed = () => ch.exit(0);
          return ch;
        }
        return FakeExecChannel.run(code: 1);
      };
      final session = AccountSession(
        machines: repo,
        probeFingerprint: (host, port) async => 'SHA256:testpinE01AAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        connect: (p, s, pin, n) => fake,
        sessionStore: store,
        debounceDuration: Duration.zero,
      );
      await session.init();
      expect(session.isSignedIn, isTrue);
      fake.execCommands.clear();
      await repo.save(const MachineProfile(id: 'm1', label: 'M1', host: 'h1', username: 'u1', auth: SshAuth.password));
      await session.activeUpload;
      expect(fake.execCommands, isNotEmpty);
      expect(fake.execCommands.first, equals('get'));
      expect(fake.execCommands, contains('put'));
      expect(fake.execCommands.indexOf('get'), lessThan(fake.execCommands.indexOf('put')));
    });

    test('test_E02_box change wins over stale local edit and skips put', () async {
      const oldM = MachineProfile(
        id: 'box1',
        label: 'Box',
        host: '140.245.204.23',
        username: 'u',
        auth: SshAuth.password,
        hostKeyFingerprint: 'SHA256:keep-me-E02AAAAAAAAAAAAAAAAAAAAA',
      );
      const boxM = MachineProfile(
        id: 'box1',
        label: 'Box',
        host: 'codes-and-stories.duckdns.org',
        username: 'u',
        auth: SshAuth.password,
        hostKeyFingerprint: 'SHA256:keep-me-E02AAAAAAAAAAAAAAAAAAAAA',
      );
      final oldDigest = computeSnapshotDigest(const VaultContents(machines: [oldM]));
      final boxDigest = computeSnapshotDigest(const VaultContents(machines: [boxM]));
      final repo = await _repo([oldM]);
      final store = MemoryAccountSessionStore();
      await store.write(
        sessionStorageKey,
        jsonEncode({
          'v': 2,
          'username': 'jaya',
          'loginSecret': 'login-secret-e02',
          'accountKey': base64Encode(testAccountKey),
          'lastSyncedDigest': oldDigest,
          'initialized': true,
          'address': '10.0.0.5',
          'port': 2200,
          'pin': 'SHA256:testpinE02AAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        }),
      );
      final oldFile = await sealVault(const VaultContents(machines: [oldM]), testAccountKey);
      final boxFile = await sealVault(const VaultContents(machines: [boxM]), testAccountKey);
      final fake = FakeTransport();
      var getCall = 0;
      fake.onExec = (cmd) async {
        if (cmd == 'get') {
          getCall++;
          if (getCall == 1) return FakeExecChannel.run(stdout: [oldFile], code: 0);
          return FakeExecChannel.run(stdout: [boxFile], code: 0);
        }
        if (cmd == 'put') {
          final ch = FakeExecChannel();
          ch.onInputClosed = () => ch.exit(0);
          return ch;
        }
        return FakeExecChannel.run(code: 1);
      };
      final session = AccountSession(
        machines: repo,
        probeFingerprint: (host, port) async => 'SHA256:testpinE02AAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        connect: (p, s, pin, n) => fake,
        sessionStore: store,
        debounceDuration: Duration.zero,
      );
      await session.init();
      fake.execCommands.clear();
      await repo.save(
        const MachineProfile(
          id: 'box1',
          label: 'Locally edited',
          host: '140.245.204.23',
          username: 'u',
          auth: SshAuth.password,
          hostKeyFingerprint: 'SHA256:keep-me-E02AAAAAAAAAAAAAAAAAAAAA',
        ),
      );
      await session.activeUpload;
      expect(fake.execCommands, contains('get'));
      expect(fake.execCommands, isNot(contains('put')));
      expect(repo.byId('box1')?.host, equals('codes-and-stories.duckdns.org'));
      expect(repo.byId('box1')?.hostKeyFingerprint, equals('SHA256:keep-me-E02AAAAAAAAAAAAAAAAAAAAA'));
      expect(session.lastSyncedDigest, equals(boxDigest));
    });

    test('test_E03_phone-only machine survives box import and is uploaded', () async {
      const baseOld = MachineProfile(id: 'base', label: 'Base', host: 'h-old', username: 'u', auth: SshAuth.password);
      const baseNew = MachineProfile(
        id: 'base',
        label: 'Base',
        host: 'codes-and-stories.duckdns.org',
        username: 'u',
        auth: SshAuth.password,
      );
      const phoneOnly = MachineProfile(
        id: 'phone-only',
        label: 'Phone',
        host: 'h-phone',
        username: 'u',
        auth: SshAuth.password,
      );
      final oldDigest = computeSnapshotDigest(const VaultContents(machines: [baseOld]));
      final repo = await _repo([baseOld]);
      final store = MemoryAccountSessionStore();
      await store.write(
        sessionStorageKey,
        jsonEncode({
          'v': 2,
          'username': 'jaya',
          'loginSecret': 'login-secret-e03',
          'accountKey': base64Encode(testAccountKey),
          'lastSyncedDigest': oldDigest,
          'initialized': true,
          'address': '10.0.0.5',
          'port': 2200,
          'pin': 'SHA256:testpinE03AAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        }),
      );
      final boxFile = await sealVault(const VaultContents(machines: [baseNew]), testAccountKey);
      final putChannels = <FakeExecChannel>[];
      final fake = FakeTransport();
      fake.onExec = (cmd) async {
        if (cmd == 'get') return FakeExecChannel.run(stdout: [boxFile], code: 0);
        if (cmd == 'put') {
          final ch = FakeExecChannel();
          ch.onInputClosed = () => ch.exit(0);
          putChannels.add(ch);
          return ch;
        }
        return FakeExecChannel.run(code: 1);
      };
      final session = AccountSession(
        machines: repo,
        probeFingerprint: (host, port) async => 'SHA256:testpinE03AAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        connect: (p, s, pin, n) => fake,
        sessionStore: store,
        debounceDuration: Duration.zero,
      );
      await session.init();
      fake.execCommands.clear();
      await repo.save(phoneOnly);
      await session.activeUpload;
      expect(fake.execCommands.first, equals('get'));
      expect(fake.execCommands, contains('put'));
      expect(repo.byId('base')?.host, equals('codes-and-stories.duckdns.org'));
      expect(repo.byId('phone-only'), isNotNull);
      expect(putChannels, isNotEmpty);
      final uploaded = await openVault(putChannels.last.sent.single, testAccountKey);
      expect(uploaded.machines.map((m) => m.id).toSet(), containsAll(['base', 'phone-only']));
      expect(uploaded.machines.firstWhere((m) => m.id == 'base').host, equals('codes-and-stories.duckdns.org'));
    });

    test('test_E04_timeout_fetch fails with no put and error shown', () async {
      final digest = computeSnapshotDigest(const VaultContents());
      final repo = await _repo([]);
      final store = MemoryAccountSessionStore();
      await store.write(
        sessionStorageKey,
        jsonEncode({
          'v': 2,
          'username': 'jaya',
          'loginSecret': 'login-secret-e04t',
          'accountKey': base64Encode(testAccountKey),
          'lastSyncedDigest': digest,
          'initialized': true,
          'address': '10.0.0.5',
          'port': 2200,
          'pin': 'SHA256:testpinE04TAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        }),
      );
      final fake = FakeTransport();
      fake.onExec = (cmd) async {
        if (cmd == 'get') throw TimeoutException('timed out');
        if (cmd == 'put') {
          final ch = FakeExecChannel();
          ch.onInputClosed = () => ch.exit(0);
          return ch;
        }
        return FakeExecChannel.run(code: 1);
      };
      final session = AccountSession(
        machines: repo,
        probeFingerprint: (host, port) async => 'SHA256:testpinE04TAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        connect: (p, s, pin, n) => fake,
        sessionStore: store,
        debounceDuration: Duration.zero,
      );
      await session.init();
      fake.execCommands.clear();
      await repo.save(const MachineProfile(id: 'm1', label: 'M1', host: 'h1', username: 'u1', auth: SshAuth.password));
      await session.activeUpload;
      expect(fake.execCommands, equals(['get']));
      expect(session.status, equals(AccountSyncStatus.error));
      expect(session.lastError, isNotNull);
    });

    test('test_E04_exit_fetch fails with no put and error shown', () async {
      final digest = computeSnapshotDigest(const VaultContents());
      final repo = await _repo([]);
      final store = MemoryAccountSessionStore();
      await store.write(
        sessionStorageKey,
        jsonEncode({
          'v': 2,
          'username': 'jaya',
          'loginSecret': 'login-secret-e04e',
          'accountKey': base64Encode(testAccountKey),
          'lastSyncedDigest': digest,
          'initialized': true,
          'address': '10.0.0.5',
          'port': 2200,
          'pin': 'SHA256:testpinE04EAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        }),
      );
      final fake = FakeTransport();
      fake.onExec = (cmd) async {
        if (cmd == 'get') return FakeExecChannel.run(code: 1);
        if (cmd == 'put') {
          final ch = FakeExecChannel();
          ch.onInputClosed = () => ch.exit(0);
          return ch;
        }
        return FakeExecChannel.run(code: 1);
      };
      final session = AccountSession(
        machines: repo,
        probeFingerprint: (host, port) async => 'SHA256:testpinE04EAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        connect: (p, s, pin, n) => fake,
        sessionStore: store,
        debounceDuration: Duration.zero,
      );
      await session.init();
      fake.execCommands.clear();
      await repo.save(const MachineProfile(id: 'm1', label: 'M1', host: 'h1', username: 'u1', auth: SshAuth.password));
      await session.activeUpload;
      expect(fake.execCommands, equals(['get']));
      expect(session.status, equals(AccountSyncStatus.error));
      expect(session.lastError, isNotNull);
    });

    test('test_E09_empty box (get exit 3) is refilled by the upload', () async {
      final digest = computeSnapshotDigest(const VaultContents());
      final repo = await _repo([]);
      final store = MemoryAccountSessionStore();
      await store.write(
        sessionStorageKey,
        jsonEncode({
          'v': 2,
          'username': 'jaya',
          'loginSecret': 'login-secret-e09',
          'accountKey': base64Encode(testAccountKey),
          'lastSyncedDigest': digest,
          'initialized': true,
          'address': '10.0.0.5',
          'port': 2200,
          'pin': 'SHA256:testpinE09AAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        }),
      );
      final fake = FakeTransport();
      fake.onExec = (cmd) async {
        if (cmd == 'get') return FakeExecChannel.run(code: 3);
        if (cmd == 'put') {
          final ch = FakeExecChannel();
          ch.onInputClosed = () => ch.exit(0);
          return ch;
        }
        return FakeExecChannel.run(code: 1);
      };
      final session = AccountSession(
        machines: repo,
        probeFingerprint: (host, port) async => 'SHA256:testpinE09AAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        connect: (p, s, pin, n) => fake,
        sessionStore: store,
        debounceDuration: Duration.zero,
      );
      await session.init();
      fake.execCommands.clear();
      await repo.save(const MachineProfile(id: 'm1', label: 'M1', host: 'h1', username: 'u1', auth: SshAuth.password));
      await session.activeUpload;
      expect(fake.execCommands, equals(['get', 'put']));
      expect(session.status, equals(AccountSyncStatus.synced));
    });

    test('test_E04_decrypt_fetch fails with no put and error shown', () async {
      final digest = computeSnapshotDigest(const VaultContents());
      final repo = await _repo([]);
      final store = MemoryAccountSessionStore();
      await store.write(
        sessionStorageKey,
        jsonEncode({
          'v': 2,
          'username': 'jaya',
          'loginSecret': 'login-secret-e04d',
          'accountKey': base64Encode(testAccountKey),
          'lastSyncedDigest': digest,
          'initialized': true,
          'address': '10.0.0.5',
          'port': 2200,
          'pin': 'SHA256:testpinE04DAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        }),
      );
      final fake = FakeTransport();
      fake.onExec = (cmd) async {
        if (cmd == 'get') return FakeExecChannel.run(stdout: ['not-an-encrypted-vault!!!'], code: 0);
        if (cmd == 'put') {
          final ch = FakeExecChannel();
          ch.onInputClosed = () => ch.exit(0);
          return ch;
        }
        return FakeExecChannel.run(code: 1);
      };
      final session = AccountSession(
        machines: repo,
        probeFingerprint: (host, port) async => 'SHA256:testpinE04DAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        connect: (p, s, pin, n) => fake,
        sessionStore: store,
        debounceDuration: Duration.zero,
      );
      await session.init();
      fake.execCommands.clear();
      await repo.save(const MachineProfile(id: 'm1', label: 'M1', host: 'h1', username: 'u1', auth: SshAuth.password));
      await session.activeUpload;
      expect(fake.execCommands, equals(['get']));
      expect(session.status, equals(AccountSyncStatus.error));
      expect(session.lastError, isNotNull);
    });

    test('test_E05_init while signed in pulls box copy changed elsewhere', () async {
      const oldM = MachineProfile(
        id: 'box1',
        label: 'Box',
        host: '140.245.204.23',
        username: 'u',
        auth: SshAuth.password,
      );
      const boxM = MachineProfile(
        id: 'box1',
        label: 'Box',
        host: 'codes-and-stories.duckdns.org',
        username: 'u',
        auth: SshAuth.password,
      );
      final oldDigest = computeSnapshotDigest(const VaultContents(machines: [oldM]));
      final boxDigest = computeSnapshotDigest(const VaultContents(machines: [boxM]));
      final repo = await _repo([oldM]);
      final store = MemoryAccountSessionStore();
      await store.write(
        sessionStorageKey,
        jsonEncode({
          'v': 2,
          'username': 'jaya',
          'loginSecret': 'login-secret-e05',
          'accountKey': base64Encode(testAccountKey),
          'lastSyncedDigest': oldDigest,
          'initialized': true,
          'address': '10.0.0.5',
          'port': 2200,
          'pin': 'SHA256:testpinE05AAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        }),
      );
      final boxFile = await sealVault(const VaultContents(machines: [boxM]), testAccountKey);
      final fake = FakeTransport();
      fake.onExec = (cmd) async {
        if (cmd == 'get') return FakeExecChannel.run(stdout: [boxFile], code: 0);
        if (cmd == 'put') {
          final ch = FakeExecChannel();
          ch.onInputClosed = () => ch.exit(0);
          return ch;
        }
        return FakeExecChannel.run(code: 1);
      };
      final session = AccountSession(
        machines: repo,
        probeFingerprint: (host, port) async => 'SHA256:testpinE05AAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        connect: (p, s, pin, n) => fake,
        sessionStore: store,
        debounceDuration: Duration.zero,
      );
      await session.init();
      expect(fake.execCommands, contains('get'));
      expect(repo.byId('box1')?.host, equals('codes-and-stories.duckdns.org'));
      expect(session.lastSyncedDigest, equals(boxDigest));
      expect(fake.execCommands, isNot(contains('put')));
      expect(session.status, equals(AccountSyncStatus.synced));
    });

    test('test_E06_no built-in box address or host key in app lib', () async {
      final hits = <String>[];
      // Synchronous reads: the async walk timed out under full-suite load.
      for (final entity in Directory('lib').listSync(recursive: true)) {
        if (entity is File && entity.path.endsWith('.dart')) {
          final text = entity.readAsStringSync();
          if (text.contains('accountBoxHost') ||
              text.contains('accountBoxHostKey') ||
              text.contains('140.245.204.23') ||
              text.contains('SHA256:JVAqsSiiRDspdJB3qXz/aBFPmiV00lIoih7NV1b5I0U')) {
            hits.add(entity.path);
          }
        }
      }
      expect(hits, isEmpty, reason: 'retired built-in box address remains in ${hits.join(', ')}');
      expect(accountBoxPort, equals(22));
      expect(accountBoxUser, equals('herdrj'));
    });

    test('test_E07_missing address stays signed out and opens no connection', () async {
      final repo = await _repo([
        const MachineProfile(id: 'm1', label: 'M1', host: 'h1', username: 'u1', auth: SshAuth.password),
      ]);
      final store = MemoryAccountSessionStore();
      await store.write(
        sessionStorageKey,
        jsonEncode({
          'v': 2,
          'username': 'jaya',
          'loginSecret': 'login-secret-e07',
          'accountKey': base64Encode(testAccountKey),
          'lastSyncedDigest': computeSnapshotDigest(const VaultContents()),
          'initialized': true,
        }),
      );
      var connects = 0;
      final fake = FakeTransport();
      fake.onExec = (cmd) async {
        final ch = FakeExecChannel();
        ch.onInputClosed = () => ch.exit(0);
        return ch;
      };
      final session = AccountSession(
        machines: repo,
        probeFingerprint: (host, port) async => 'SHA256:testpinE07AAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        connect: (p, s, pin, n) {
          connects++;
          return fake;
        },
        sessionStore: store,
        debounceDuration: Duration.zero,
      );
      await session.init();
      expect(session.isSignedIn, isFalse);
      expect(session.status, equals(AccountSyncStatus.signedOut));
      expect(connects, equals(0));
    });

    testWidgets('test_E07b_missing address screen asks to sign in', (tester) async {
      final repo = await _repo([]);
      final store = MemoryAccountSessionStore();
      await store.write(
        sessionStorageKey,
        jsonEncode({
          'v': 2,
          'username': 'jaya',
          'loginSecret': 'login-secret-e07b',
          'accountKey': base64Encode(testAccountKey),
          'lastSyncedDigest': computeSnapshotDigest(const VaultContents()),
          'initialized': true,
        }),
      );
      final session = AccountSession(
        machines: repo,
        probeFingerprint: (host, port) async => 'SHA256:testpinE07BAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
        connect: (p, s, pin, n) => FakeTransport(),
        sessionStore: store,
        debounceDuration: Duration.zero,
      );
      await tester.runAsync(session.init);
      expect(session.isSignedIn, isFalse);
      await tester.pumpWidget(
        MultiProvider(
          providers: [
            ChangeNotifierProvider<MachineRepository>.value(value: repo),
            ChangeNotifierProvider<AccountSession>.value(value: session),
          ],
          child: MaterialApp(theme: AppTheme.light(), home: const AccountScreen()),
        ),
      );
      expect(find.text('Sign in'), findsOneWidget);
    });

    test('test_E08_typed address probe trust import and guarded upload', () async {
      final repo = await _repo([]);
      final file = await sealVault(const VaultContents(), testAccountKey);
      const probed = 'SHA256:testpinE08AAAAAAAAAAAAAAAAAAAAAAAAAAAAA';
      final profiles = <MachineProfile>[];
      String? probedHost;
      int? probedPort;
      String? trustedFp;
      final transport = FakeTransport();
      transport.onExec = (cmd) async {
        if (cmd == 'key') {
          return FakeExecChannel.run(
            stdout: [
              jsonEncode({'v': 1, 'username': 'jaya', 'key': base64Encode(testAccountKey)}),
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
        probeFingerprint: (host, port) async {
          probedHost = host;
          probedPort = port;
          return probed;
        },
        sessionStore: MemoryAccountSessionStore(),
        debounceDuration: Duration.zero,
      );
      await session.signIn(
        '10.0.0.5:2200',
        'jaya',
        'pw-e08',
        trustFingerprint: (fp) async {
          trustedFp = fp;
          return true;
        },
      );
      expect(probedHost, equals('10.0.0.5'));
      expect(probedPort, equals(2200));
      expect(trustedFp, equals(probed));
      expect(session.isSignedIn, isTrue);
      for (final p in profiles) {
        expect(p.host, equals('10.0.0.5'));
        expect(p.port, equals(2200));
        expect(p.hostKeyFingerprint, equals(probed));
      }
      profiles.clear();
      transport.execCommands.clear();
      await repo.save(
        const MachineProfile(id: 'm08', label: 'M08', host: 'h08', username: 'u08', auth: SshAuth.password),
      );
      await session.activeUpload;
      expect(transport.execCommands.first, equals('get'));
      expect(transport.execCommands, contains('put'));
      expect(profiles, isNotEmpty);
      expect(profiles.last.host, equals('10.0.0.5'));
      expect(profiles.last.port, equals(2200));
      expect(profiles.last.hostKeyFingerprint, equals(probed));
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
