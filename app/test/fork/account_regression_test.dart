import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/app.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/agent_screens.dart';
import 'package:herdr_mobile/data/repositories/app_settings.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/fork/account/account_screen.dart';
import 'package:herdr_mobile/fork/account/account_session.dart';
import 'package:herdr_mobile/fork/account/account_vault.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_exec.dart';
import '../support/fake_network.dart';
import '../support/fake_transport.dart';
import '../support/memory_app_settings_store.dart';
import '../support/memory_snapshot_cache.dart';
import '../support/memory_stores.dart';
import '../support/memory_terminal_settings_store.dart';
import '../support/shot.dart' show loadAppFonts;
import 'account_session_test.dart' show MemoryAccountSessionStore, testAccountKey;

const remote = MachineProfile(id: 'remote', label: 'Remote', host: 'host', username: 'u', auth: SshAuth.password);
const local = MachineProfile(id: 'local', label: 'Local', host: 'host', username: 'u', auth: SshAuth.password);

class FailingStore extends MemoryAccountSessionStore {
  bool failDelete = true;
  bool failWrite = false;
  @override
  Future<void> delete(String key) async {
    if (failDelete) throw StateError('PRIVATE_SENTINEL');
    await super.delete(key);
  }

  @override
  Future<void> write(String key, String value) async {
    if (failWrite) throw StateError('PRIVATE_SENTINEL');
    await super.write(key, value);
  }
}

class BlockingStore extends MemoryAccountSessionStore {
  final writing = Completer<void>();
  final release = Completer<void>();
  @override
  Future<void> write(String key, String value) async {
    writing.complete();
    await release.future;
    await super.write(key, value);
  }
}

class BlockingSecrets extends MemorySecretStore {
  final reading = Completer<void>();
  final release = Completer<void>();
  @override
  Future<MachineSecrets> read(String id) async {
    if (!reading.isCompleted) reading.complete();
    await release.future;
    return super.read(id);
  }
}

Future<MachineRepository> repository([List<MachineProfile> profiles = const [], SecretStore? secrets]) async {
  final repo = MachineRepository(
    profiles: MemoryProfileStore()..profiles = profiles,
    secrets: secrets ?? MemorySecretStore(),
  );
  await repo.load();
  addTearDown(repo.dispose);
  return repo;
}

Future<MemoryAccountSessionStore> savedSession([String? digest]) async {
  final store = MemoryAccountSessionStore();
  await store.write(
    sessionStorageKey,
    jsonEncode({
      'v': 2,
      'username': 'jaya',
      'loginSecret': 'dummy-login',
      'accountKey': base64Encode(testAccountKey),
      'lastSyncedDigest': digest ?? 'old-remote-digest',
      'initialized': true,
    }),
  );
  return store;
}

Future<FakeTransport> seededBox(VaultContents contents) async {
  final file = await sealVault(contents, testAccountKey);
  return FakeTransport()
    ..onExec = (cmd) async {
      if (cmd == 'key') {
        return FakeExecChannel.run(
          stdout: [
            jsonEncode({'v': 1, 'username': 'jaya', 'key': base64Encode(testAccountKey)}),
          ],
        );
      }
      if (cmd == 'get') return FakeExecChannel.run(stdout: [file]);
      final ch = FakeExecChannel();
      ch.onInputClosed = () => ch.exit(0);
      return ch;
    };
}

AccountSession sessionFor(
  MachineRepository repo,
  MemoryAccountSessionStore store,
  FakeTransport box, {
  Duration debounce = Duration.zero,
}) {
  final session = AccountSession(
    machines: repo,
    sessionStore: store,
    connect: (p, s, pin, n) => box,
    debounceDuration: debounce,
  );
  addTearDown(session.dispose);
  return session;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(loadAppFonts);
  setUp(() => SharedPreferences.setMockInitialValues({localInitializedKey: true}));

  test('F1 restored login with failed get retries pull and never puts', () async {
    SharedPreferences.setMockInitialValues({});
    final repo = await repository();
    final store = await savedSession();
    final box = FakeTransport()..onExec = (_) async => FakeExecChannel.run(code: 1);
    final session = sessionFor(repo, store, box);
    await session.init();
    await session.retry();
    expect(box.execCommands, ['get', 'get']);
    expect(session.isInitialized, isFalse);
    expect(session.status, AccountSyncStatus.error);
  });

  test('F1 failed session persistence keeps upload gate closed', () async {
    final repo = await repository();
    final store = FailingStore()..failWrite = true;
    final box = await seededBox(const VaultContents(machines: [remote]));
    final session = sessionFor(repo, store, box);
    await expectLater(session.signIn('jaya', 'pw'), throwsA(isA<Object>()));
    await repo.save(local);
    await session.retry();
    expect(box.execCommands.contains('put'), isFalse);
    expect(session.isInitialized, isFalse);
  });

  test('F4 sign out during sign in closes transport and never imports or persists', () async {
    final repo = await repository();
    final store = MemoryAccountSessionStore();
    final box = await seededBox(const VaultContents(machines: [remote]));
    final original = box.onExec!;
    final entered = Completer<void>();
    final release = Completer<void>();
    box.onExec = (cmd) async {
      if (cmd == 'key') {
        entered.complete();
        await release.future;
      }
      return original(cmd);
    };
    final session = sessionFor(repo, store, box);
    final signingIn = session.signIn('jaya', 'pw');
    await entered.future;
    await session.signOut();
    final closedAtSignOut = box.closed;
    release.complete();
    await signingIn;
    expect(closedAtSignOut, isTrue);
    expect(store.values, isEmpty);
    expect(repo.machines, isEmpty);
    expect(box.execCommands, ['key']);
    expect(session.status, AccountSyncStatus.signedOut);
  });

  test('F4 sign out orders deletion after an in-flight credential write', () async {
    final repo = await repository();
    final store = BlockingStore();
    final box = await seededBox(const VaultContents(machines: [remote]));
    final session = sessionFor(repo, store, box);
    final signingIn = session.signIn('jaya', 'pw');
    await store.writing.future;
    final signingOut = session.signOut();
    store.release.complete();
    await Future.wait([signingIn, signingOut]);
    expect(store.values, isEmpty);
    expect((await SharedPreferences.getInstance()).getBool(localInitializedKey), isNull);
    expect(session.status, AccountSyncStatus.signedOut);
  });

  test('F4 backgrounding sign in stops before get without leaving a busy session', () async {
    final repo = await repository();
    final store = MemoryAccountSessionStore();
    final box = await seededBox(const VaultContents(machines: [remote]));
    final original = box.onExec!;
    final entered = Completer<void>();
    final release = Completer<void>();
    box.onExec = (cmd) async {
      if (cmd == 'key') {
        entered.complete();
        await release.future;
      }
      return original(cmd);
    };
    final session = sessionFor(repo, store, box);
    final signingIn = session.signIn('jaya', 'pw');
    await entered.future;
    session.didChangeAppLifecycleState(AppLifecycleState.paused);
    release.complete();
    await signingIn;
    expect(session.isSigningIn, isFalse);
    expect(box.execCommands, ['key']);
    expect(store.values, isEmpty);
  });

  test('F4 background after import persistence resumes pending sync', () async {
    final secrets = BlockingSecrets();
    final repo = await repository([], secrets);
    final store = MemoryAccountSessionStore();
    final box = await seededBox(const VaultContents(machines: [remote]));
    final session = sessionFor(repo, store, box);
    final signingIn = session.signIn('jaya', 'pw');
    await secrets.reading.future;
    session.didChangeAppLifecycleState(AppLifecycleState.paused);
    secrets.release.complete();
    await signingIn;
    expect(session.status, AccountSyncStatus.pending);
    session.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await session.activeUpload;
    expect(session.status, AccountSyncStatus.synced);
    expect(box.execCommands, ['key', 'get']);
  });

  for (final action in ['sign out', 'dispose', 'background']) {
    test('F4 $action during encryption prevents later connect and put', () async {
      final repo = await repository();
      final store = await savedSession(computeSnapshotDigest(const VaultContents()));
      final entered = Completer<void>();
      final release = Completer<void>();
      var connections = 0;
      final session = AccountSession(
        machines: repo,
        sessionStore: store,
        debounceDuration: Duration.zero,
        connect: (p, s, pin, n) {
          connections++;
          return FakeTransport();
        },
        sealSnapshot: (contents, key) async {
          entered.complete();
          await release.future;
          return sealVault(contents, key);
        },
      );
      if (action != 'dispose') addTearDown(session.dispose);
      await session.init();
      await repo.save(remote);
      final upload = session.activeUpload;
      await entered.future;
      if (action == 'sign out') {
        await session.signOut();
      } else if (action == 'dispose') {
        session.dispose();
      } else {
        session.didChangeAppLifecycleState(AppLifecycleState.paused);
      }
      release.complete();
      await upload;
      expect(connections, 0);
      expect(
        session.status,
        action == 'background'
            ? AccountSyncStatus.pending
            : action == 'sign out'
            ? AccountSyncStatus.signedOut
            : AccountSyncStatus.syncing,
      );
    });
  }

  test('F5 failed sign out is visible and retry removes persistent login', () async {
    final repo = await repository();
    final store = FailingStore();
    store.values.addAll((await savedSession(computeSnapshotDigest(const VaultContents()))).values);
    final session = sessionFor(repo, store, FakeTransport());
    await session.init();
    await session.signOut();
    expect(session.status, AccountSyncStatus.error);
    expect(session.lastError, isNot(contains('PRIVATE_SENTINEL')));
    expect(store.values, isNotEmpty);
    store.failDelete = false;
    await session.retry();
    expect(session.status, AccountSyncStatus.signedOut);
    expect(store.values, isEmpty);
  });

  testWidgets('F5 screen confirms sign out only after storage deletion succeeds', (tester) async {
    final repo = await repository();
    final store = FailingStore();
    store.values.addAll((await savedSession(computeSnapshotDigest(const VaultContents()))).values);
    final session = sessionFor(repo, store, FakeTransport());
    await session.init();
    await tester.pumpWidget(
      ChangeNotifierProvider.value(
        value: session,
        child: MaterialApp(theme: AppTheme.light(), home: const AccountScreen()),
      ),
    );
    await tester.tap(find.text('Sign out'));
    await tester.pumpAndSettle();
    expect(find.text(AccountWords.signedOut), findsNothing);
    expect(find.text('Retry'), findsOneWidget);
    store.failDelete = false;
    await tester.tap(find.text('Retry'));
    await tester.pumpAndSettle();
    expect(session.status, AccountSyncStatus.signedOut);
  });

  testWidgets('F6 real app constructs account session before Settings is visited', (tester) async {
    var reads = 0;
    const channel = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'read' && (call.arguments as Map)['key'] == sessionStorageKey) reads++;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final repo = await repository();
    final screens = AgentScreens();
    addTearDown(screens.dispose);
    await tester.pumpWidget(
      HerdrMobileApp(
        machines: repo,
        network: FakeNetwork(),
        snapshotCache: MemorySnapshotCache(),
        terminalSettings: TerminalSettings(MemoryTerminalSettingsStore()),
        appSettings: AppSettings(MemoryAppSettingsStore()),
        agentScreens: screens,
      ),
    );
    await tester.pump();
    expect(reads, 1);
    await tester.pumpWidget(const SizedBox());
  });

  test('F7 upload A then edit B and background keeps B pending until resumed upload', () async {
    final repo = await repository();
    final store = await savedSession(computeSnapshotDigest(const VaultContents()));
    final box = FakeTransport();
    final first = FakeExecChannel();
    final second = FakeExecChannel();
    final firstSent = Completer<void>();
    first.onInputClosed = firstSent.complete;
    var puts = 0;
    final secondSent = Completer<void>();
    second.onInputClosed = () {
      secondSent.complete();
      second.exit(0);
    };
    box.onExec = (_) async => ++puts == 1 ? first : second;
    final session = sessionFor(repo, store, box, debounce: const Duration(seconds: 1));
    await session.init();
    await repo.save(remote);
    final uploading = session.retry();
    await firstSent.future;
    await repo.save(remote.copyWith(label: 'B'));
    session.didChangeAppLifecycleState(AppLifecycleState.paused);
    first.exit(0);
    await uploading;
    expect(session.status, AccountSyncStatus.pending);
    session.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await secondSent.future;
    await session.activeUpload;
    expect(puts, 2);
    expect((await openVault(second.sent.single, testAccountKey)).machines.single.label, 'B');
    expect(session.status, AccountSyncStatus.synced);
  });

  test('F8 local-only machines upload once after login against remote baseline', () async {
    final repo = await repository([local]);
    final store = MemoryAccountSessionStore();
    final box = await seededBox(const VaultContents(machines: [remote]));
    final session = sessionFor(repo, store, box);
    await session.signIn('jaya', 'pw');
    await session.activeUpload;
    expect(box.execCommands, ['key', 'get', 'put']);
    expect(session.status, AccountSyncStatus.synced);
  });

  for (final error in [const HerdrTransportException('PRIVATE_SENTINEL'), StateError('PRIVATE_SENTINEL')]) {
    test('F9 ${error.runtimeType} text never reaches UI status or logs', () async {
      final repo = await repository();
      final store = await savedSession();
      final box = FakeTransport()..onExec = (_) async => throw error;
      final session = sessionFor(repo, store, box);
      final logs = <String>[];
      final previous = debugPrint;
      debugPrint = (message, {wrapWidth}) => logs.add(message ?? '');
      addTearDown(() => debugPrint = previous);
      await session.init();
      expect(session.status, AccountSyncStatus.error);
      expect(session.lastError, isNot(contains('PRIVATE_SENTINEL')));
      expect(logs.join(), isNot(contains('PRIVATE_SENTINEL')));
    });
  }

  for (final restore in [false, true]) {
    test('F10 ${restore ? "restore" : "login"} validates all keys before any import', () async {
      SharedPreferences.setMockInitialValues({});
      final repo = await repository();
      final store = restore ? await savedSession() : MemoryAccountSessionStore();
      const missing = MachineProfile(id: 'missing', label: 'Missing', host: 'host', username: 'u');
      final box = await seededBox(const VaultContents(machines: [remote, missing]));
      final session = sessionFor(repo, store, box);
      if (restore) {
        await session.init();
      } else {
        await expectLater(session.signIn('jaya', 'pw'), throwsA(isA<AccountProblem>()));
      }
      expect(repo.machines, isEmpty);
      expect(session.isInitialized, isFalse);
      expect(box.execCommands.contains('put'), isFalse);
    });

    test(
      'F10 ${restore ? "restore" : "login"} preserves working key and paired secrets for partial incoming fields',
      () async {
        SharedPreferences.setMockInitialValues({});
        const keyed = MachineProfile(id: 'keyed', label: 'Keyed', host: 'host', username: 'u');
        final secrets = MemorySecretStore()
          ..secrets['keyed'] = const MachineSecrets(
            privateKeyPem: 'working-key',
            passphrase: 'working-phrase',
            password: 'working-password',
          );
        final repo = await repository([keyed], secrets);
        final store = restore ? await savedSession() : MemoryAccountSessionStore();
        final box = await seededBox(
          const VaultContents(
            machines: [keyed],
            secrets: {'keyed': MachineSecrets(privateKeyPem: '', passphrase: 'unrelated-phrase', password: '')},
          ),
        );
        final session = sessionFor(repo, store, box);
        if (restore) {
          await session.init();
        } else {
          await session.signIn('jaya', 'pw');
        }
        await session.activeUpload;
        final effective = await repo.secretsFor('keyed');
        expect(effective.privateKeyPem, 'working-key');
        expect(effective.passphrase, 'working-phrase');
        expect(effective.password, 'working-password');
      },
    );
  }
}
