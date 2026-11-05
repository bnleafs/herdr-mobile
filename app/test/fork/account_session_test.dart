import 'dart:async';
import 'dart:convert';

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
    test('invalid username throws and opens no transport', () async {
      final repo = await _repo([]);
      var transportsOpened = 0;
      final session = AccountSession(
        machines: repo,
        connect: (p, s, pin, n) {
          transportsOpened++;
          return FakeTransport();
        },
        sessionStore: MemoryAccountSessionStore(),
        debounceDuration: Duration.zero,
      );

      await expectLater(() => session.signIn('not-jaya', 'password'), throwsA(isA<AccountProblem>()));

      expect(transportsOpened, equals(0));
      expect(session.isSignedIn, isFalse);
      expect(session.lastError, equals(AccountWords.invalidUsername));
    });

    test('wrong password does not mutate machine repository or session store', () async {
      final repo = await _repo([]);
      final sessionStore = MemoryAccountSessionStore();
      final fakeTransport = FakeTransport();
      fakeTransport.onExec = (_) => Future.error(
        const HerdrTransportException('SSH authentication failed (check username and key/password).', fatal: true),
      );

      final session = AccountSession(
        machines: repo,
        connect: (p, s, pin, n) => fakeTransport,
        sessionStore: sessionStore,
        debounceDuration: Duration.zero,
      );

      await expectLater(() => session.signIn('jaya', 'wrong-pw'), throwsA(isA<AccountProblem>()));

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
          connect: (p, s, pin, n) => fakeTransport,
          sessionStore: sessionStore,
          debounceDuration: Duration.zero,
        );

        await session.signIn('jaya', 'correct-password');

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
        connect: (p, s, pin, n) => fakeTransport,
        sessionStore: MemoryAccountSessionStore(),
        debounceDuration: Duration.zero,
      );

      await expectLater(
        () => session.signIn('jaya', 'pw'),
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
        }),
      );

      final session = AccountSession(
        machines: repo,
        connect: (p, s, pin, n) => FakeTransport(),
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
        }),
      );

      final putChannel = FakeExecChannel();
      putChannel.onInputClosed = () => putChannel.exit(0);

      final fakeTransport = FakeTransport();
      fakeTransport.onExec = (cmd) async {
        expect(cmd, equals('put'));
        return putChannel;
      };

      final session = AccountSession(
        machines: repo,
        connect: (p, s, pin, n) => fakeTransport,
        sessionStore: sessionStore,
        debounceDuration: Duration.zero,
      );

      await session.init();

      // Local edit was NOT overwritten
      expect(repo.byId('m1')?.label, equals('Mac Edited Locally'));
      expect(session.status, equals(AccountSyncStatus.synced));
      expect(fakeTransport.execCommands, equals(['put']));

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
      final fakeTransport = FakeTransport();
      fakeTransport.onExec = (cmd) async {
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

      final putChannel = FakeExecChannel();
      putChannel.onInputClosed = () => putChannel.exit(0);
      final fakeTransport = FakeTransport()..onExec = (_) async => putChannel;

      final session = AccountSession(
        machines: repo,
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

      final putChannel = FakeExecChannel();
      putChannel.onInputClosed = () => putChannel.exit(0);
      final fakeTransport = FakeTransport()..onExec = (_) async => putChannel;

      final session = AccountSession(
        machines: repo,
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
        }),
      );
      await session.init();
      expect(session.status, equals(AccountSyncStatus.synced));

      // Mutate secret only
      await repo.save(m, secrets: const MachineSecrets(password: 'pass-updated'));
      await session.activeUpload;

      expect(session.status, equals(AccountSyncStatus.synced));
      expect(fakeTransport.execCommands, equals(['put']));

      final uploaded = await openVault(putChannel.sent.single, testAccountKey);
      expect(uploaded.secrets['m1']?.password, equals('pass-updated'));
    });

    test('missing key for key-auth machine refuses upload with machine label and sets error', () async {
      const keyed = MachineProfile(id: 'k1', label: 'Production Server', host: 'h1', username: 'u1', auth: SshAuth.key);
      final repo = await _repo([keyed]);
      final sessionStore = MemoryAccountSessionStore();

      final session = AccountSession(
        machines: repo,
        connect: (p, s, pin, n) => FakeTransport(),
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

      final putChannel = FakeExecChannel();
      putChannel.onInputClosed = () => putChannel.exit(0);
      final fakeTransport = FakeTransport()..onExec = (_) async => putChannel;

      final session = AccountSession(
        machines: repo,
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
        }),
      );
      await session.init();

      // Remove the last machine
      await repo.remove('m1');
      await session.activeUpload;

      expect(session.status, equals(AccountSyncStatus.synced));
      expect(fakeTransport.execCommands, equals(['put']));

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
      final fakeTransport = FakeTransport();
      fakeTransport.onExec = (cmd) async {
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
        connect: (p, s, pin, n) => fakeTransport,
        sessionStore: sessionStore,
        debounceDuration: Duration.zero,
      );

      try {
        await session.signIn('jaya', 'pw');
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
        }),
      );

      final session = AccountSession(
        machines: repo,
        connect: (p, s, pin, n) => FakeTransport(),
        sessionStore: sessionStore,
      );
      await session.init();

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
}

Future<MachineRepository> _repo(List<MachineProfile> profiles, [Map<String, MachineSecrets> secrets = const {}]) async {
  final profileStore = MemoryProfileStore()..profiles = profiles;
  final secretStore = MemorySecretStore();
  secretStore.secrets.addAll(secrets);
  final repo = MachineRepository(profiles: profileStore, secrets: secretStore);
  await repo.load();
  return repo;
}
