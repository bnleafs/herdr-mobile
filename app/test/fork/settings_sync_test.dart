import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/app_settings.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/repositories/notification_settings.dart';
import 'package:herdr_mobile/data/repositories/quick_phrases.dart';
import 'package:herdr_mobile/data/repositories/terminal_settings.dart';
import 'package:herdr_mobile/fork/account/account_session.dart';
import 'package:herdr_mobile/fork/account/account_vault.dart';
import 'package:herdr_mobile/fork/account/settings_sync.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../support/fake_exec.dart';
import '../support/fake_transport.dart';
import '../support/memory_app_settings_store.dart';
import '../support/memory_quick_phrases_store.dart';
import '../support/memory_stores.dart';
import '../support/memory_terminal_settings_store.dart';
import 'account_session_test.dart' show MemoryAccountSessionStore, testAccountKey;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('SettingsSync snapshot and apply round trip', () {
    test('round-trips every allow-listed key through public setters and getters', () async {
      SharedPreferences.setMockInitialValues({});
      final appStore = MemoryAppSettingsStore();
      final appSettings = AppSettings(appStore);
      final termStore = MemoryTerminalSettingsStore();
      final termSettings = TerminalSettings(termStore);
      final notifyStore = MemoryNotificationStore();
      final notifySettings = NotificationSettings(notifyStore);
      final phraseStore = MemoryQuickPhrasesStore();
      final phrases = QuickPhrases(phraseStore);

      final clockTime = DateTime.utc(2026, 11, 6, 12, 0, 0);
      final sync1 = SettingsSync(
        appSettings: appSettings,
        terminalSettings: termSettings,
        notificationSettings: notifySettings,
        quickPhrases: phrases,
        clock: () => clockTime,
      );
      await sync1.init();

      // Configure non-default values across all stores
      await appSettings.setTheme(ThemeChoice.dark);
      await appSettings.setDarkTerminal(true);
      await appSettings.setSmoothText(false);
      await appSettings.setOpenAgentsAs(OpenAgentsAs.terminal);
      await termSettings.setFontSize(16.5);
      await termSettings.setWrap(true);
      await phrases.setPhrases(['run tests', 'ship it']);
      await notifySettings.setEnabled(true);
      await notifySettings.setAlsoDone(true);

      final snap = await sync1.snapshot();
      expect(snap, isNotNull);
      final s = snap!;

      // Verify every key in the allow-list is present
      expect(s[SettingsSyncKeys.theme], equals('dark'));
      expect(s[SettingsSyncKeys.darkTerminal], isTrue);
      expect(s[SettingsSyncKeys.smoothText], isFalse);
      expect(s[SettingsSyncKeys.openAgentsAs], equals('terminal'));
      expect(s[SettingsSyncKeys.terminalFontSize], equals(16.5));
      expect(s[SettingsSyncKeys.terminalWrap], isTrue);
      expect(s[SettingsSyncKeys.quickPhrases], equals(['run tests', 'ship it']));
      expect(s[SettingsSyncKeys.notificationEnabled], isTrue);
      expect(s[SettingsSyncKeys.notificationAlsoDone], isTrue);
      expect(s[SettingsSyncKeys.updatedAt], equals('2026-11-06T12:00:00.000Z'));

      // Device 2: fresh phone with clean SharedPreferences and default stores
      SharedPreferences.setMockInitialValues({});
      final appStore2 = MemoryAppSettingsStore();
      final appSettings2 = AppSettings(appStore2);
      final termStore2 = MemoryTerminalSettingsStore();
      final termSettings2 = TerminalSettings(termStore2);
      final notifyStore2 = MemoryNotificationStore();
      final notifySettings2 = NotificationSettings(notifyStore2);
      final phraseStore2 = MemoryQuickPhrasesStore();
      final phrases2 = QuickPhrases(phraseStore2);

      final sync2 = SettingsSync(
        appSettings: appSettings2,
        terminalSettings: termSettings2,
        notificationSettings: notifySettings2,
        quickPhrases: phrases2,
      );
      await sync2.init();

      final applied = await sync2.applyRemote(s);
      expect(applied, isTrue);

      expect(appSettings2.theme, equals(ThemeChoice.dark));
      expect(appSettings2.darkTerminal, isTrue);
      expect(appSettings2.smoothText, isFalse);
      expect(appSettings2.openAgentsAs, equals(OpenAgentsAs.terminal));
      expect(termSettings2.fontSize, equals(16.5));
      expect(termSettings2.wrap, isTrue);
      expect(phrases2.phrases, equals(['run tests', 'ship it']));
      expect(notifySettings2.enabled, isTrue);
      expect(notifySettings2.alsoDone, isTrue);
      expect(sync2.localUpdatedAt, equals(DateTime.utc(2026, 11, 6, 12, 0, 0)));
    });
  });

  group('VaultContents settings format and compatibility', () {
    test('vault JSON with and without settings', () {
      // 1. Without settings
      const withoutSettings = VaultContents(machines: [], secrets: {});
      final jsonWithout = withoutSettings.toJson();
      expect(jsonWithout.containsKey('settings'), isFalse);

      final parsedWithout = VaultContents.fromJson(jsonWithout);
      expect(parsedWithout.settings, isNull);

      // 2. With settings
      final withSettings = VaultContents(
        machines: const [
          MachineProfile(id: 'box1', label: 'Box 1', host: '1.2.3.4', username: 'u', port: 22, auth: SshAuth.password),
        ],
        secrets: const {},
        settings: {'theme': 'dark', 'darkTerminal': true, 'updatedAt': '2026-11-06T12:00:00.000Z'},
      );
      final jsonWith = withSettings.toJson();
      expect(jsonWith['settings'], isNotNull);

      final parsedWith = VaultContents.fromJson(jsonWith);
      expect(parsedWith.settings, isNotNull);
      expect(parsedWith.settings!['theme'], equals('dark'));
      expect(parsedWith.settings!['darkTerminal'], isTrue);
      expect(parsedWith.settings!['updatedAt'], equals('2026-11-06T12:00:00.000Z'));
    });

    test('backward compatibility: old app version parses new vault ignoring settings', () {
      final newVaultJson = {
        'machines': [
          {'id': 'm1', 'label': 'Work Mac', 'host': '192.168.1.10', 'username': 'jaya', 'port': 22, 'auth': 'key'},
        ],
        'secrets': {
          'm1': {'key': 'fake-key'},
        },
        'settings': {'theme': 'dark', 'darkTerminal': true, 'updatedAt': '2026-11-06T12:00:00.000Z'},
        'futureUnknownTopLevel': {'foo': 'bar'},
      };

      // Simulating an older parser: reads machines and secrets, ignores settings and future keys
      final parsed = VaultContents.fromJson(newVaultJson);
      expect(parsed.machines.length, equals(1));
      expect(parsed.machines.first.id, equals('m1'));
      expect(parsed.secrets['m1']?.privateKeyPem, equals('fake-key'));
    });

    test('unknown or injected keys inside settings are discarded during fromJson', () {
      final jsonWithInjected = {
        'machines': <dynamic>[],
        'secrets': <String, dynamic>{},
        'settings': {
          'theme': 'system',
          'darkTerminal': false,
          'updatedAt': '2026-11-06T12:00:00.000Z',
          'maliciousInjectedKey': 'shouldBeStripped',
          'osPermission': true,
          'accountPassword': 'plaintextPassword',
        },
      };

      final parsed = VaultContents.fromJson(jsonWithInjected);
      expect(parsed.settings, isNotNull);
      expect(parsed.settings!.containsKey('theme'), isTrue);
      expect(parsed.settings!.containsKey('maliciousInjectedKey'), isFalse);
      expect(parsed.settings!.containsKey('osPermission'), isFalse);
      expect(parsed.settings!.containsKey('accountPassword'), isFalse);
    });

    test('deterministic digest includes settings in canonical order', () {
      final c1 = VaultContents(
        machines: const [],
        secrets: const {},
        settings: {'theme': 'dark', 'terminalFontSize': 12.0, 'updatedAt': '2026-11-06T12:00:00.000Z'},
      );
      final c2 = VaultContents(
        machines: const [],
        secrets: const {},
        settings: {'updatedAt': '2026-11-06T12:00:00.000Z', 'terminalFontSize': 12.0, 'theme': 'dark'},
      );
      expect(computeSnapshotDigest(c1), equals(computeSnapshotDigest(c2)));

      // Vault without settings matches legacy digest
      const legacyEmpty = VaultContents(machines: [], secrets: {});
      final legacyDigest = computeSnapshotDigest(legacyEmpty);
      expect(legacyDigest, isNotEmpty);
      expect(computeSnapshotDigest(c1), isNot(equals(legacyDigest)));
    });
  });

  group('Last-Writer-Wins (LWW) conflict resolution', () {
    test('newer remote settings apply and older remote settings are ignored', () async {
      SharedPreferences.setMockInitialValues({});
      final appStore = MemoryAppSettingsStore();
      final appSettings = AppSettings(appStore);

      final clockTime = DateTime.utc(2026, 11, 6, 12, 0, 0);
      final sync = SettingsSync(appSettings: appSettings, clock: () => clockTime);
      await sync.init();

      // Make local edit at 12:00 (changing light default to dark)
      await appSettings.setTheme(ThemeChoice.dark);
      expect(sync.localUpdatedAt, equals(DateTime.utc(2026, 11, 6, 12, 0, 0)));

      // Older remote at 11:30 is ignored
      final olderRemote = {SettingsSyncKeys.theme: 'light', SettingsSyncKeys.updatedAt: '2026-11-06T11:30:00.000Z'};
      final appliedOlder = await sync.applyRemote(olderRemote);
      expect(appliedOlder, isFalse);
      expect(appSettings.theme, equals(ThemeChoice.dark));

      // Newer remote at 12:30 applies
      final newerRemote = {SettingsSyncKeys.theme: 'system', SettingsSyncKeys.updatedAt: '2026-11-06T12:30:00.000Z'};
      final appliedNewer = await sync.applyRemote(newerRemote);
      expect(appliedNewer, isTrue);
      expect(appSettings.theme, equals(ThemeChoice.system));
      expect(sync.localUpdatedAt, equals(DateTime.utc(2026, 11, 6, 12, 30, 0)));
    });

    test('first sign-in on phone with no local history adopts remote settings', () async {
      SharedPreferences.setMockInitialValues({});
      final appStore = MemoryAppSettingsStore();
      final appSettings = AppSettings(appStore);

      final sync = SettingsSync(appSettings: appSettings);
      await sync.init();
      expect(sync.hasLocalHistory, isFalse);

      final remote = {SettingsSyncKeys.theme: 'dark', SettingsSyncKeys.updatedAt: '2026-11-01T00:00:00.000Z'};
      final applied = await sync.applyRemote(remote);
      expect(applied, isTrue);
      expect(appSettings.theme, equals(ThemeChoice.dark));
      expect(sync.hasLocalHistory, isTrue);
    });

    test('phone with local changes produces snapshot for account without settings', () async {
      SharedPreferences.setMockInitialValues({});
      final appStore = MemoryAppSettingsStore();
      final appSettings = AppSettings(appStore);

      final sync = SettingsSync(appSettings: appSettings, clock: () => DateTime.utc(2026, 11, 6, 10, 0, 0));
      await sync.init();

      // Fresh phone without changes returns null snapshot
      expect(await sync.snapshot(), isNull);

      // Local change enables snapshot
      await appSettings.setDarkTerminal(true);
      expect(sync.hasLocalHistory, isTrue);
      final snap = await sync.snapshot();
      expect(snap, isNotNull);
      expect(snap![SettingsSyncKeys.darkTerminal], isTrue);
    });
  });

  group('AccountSession debounced settings sync', () {
    test('local setting change triggers exactly one debounced upload with sealed settings', () async {
      SharedPreferences.setMockInitialValues({'herdr.account.v2.local_initialized': true});

      final sessionStore = MemoryAccountSessionStore();
      sessionStore.values['herdr.account.v2.session'] = jsonEncode({
        'v': 2,
        'username': 'jaya',
        'loginSecret': 'dummy-secret',
        'accountKey': base64Encode(testAccountKey),
        'lastSyncedDigest': computeSnapshotDigest(const VaultContents()),
        'initialized': true,
      });

      final machineRepo = MachineRepository(profiles: MemoryProfileStore(), secrets: MemorySecretStore());
      final appStore = MemoryAppSettingsStore();
      final appSettings = AppSettings(appStore);

      final sync = SettingsSync(appSettings: appSettings, clock: () => DateTime.utc(2026, 11, 6, 12, 0, 0));

      final sentCompleter = Completer<void>();
      final putChannels = <FakeExecChannel>[];
      final fakeTransport = FakeTransport();
      fakeTransport.onExec = (cmd) async {
        if (cmd == 'put') {
          final ch = FakeExecChannel();
          ch.onInputClosed = () {
            if (!sentCompleter.isCompleted) sentCompleter.complete();
            ch.exit(0);
          };
          putChannels.add(ch);
          return ch;
        }
        return FakeExecChannel.run(code: 0);
      };

      final session = AccountSession(
        machines: machineRepo,
        connect: (p, s, pin, n) => fakeTransport,
        sessionStore: sessionStore,
        settingsSync: sync,
        debounceDuration: const Duration(milliseconds: 50),
      );

      await session.init();

      expect(session.isSignedIn, isTrue);
      expect(session.status, equals(AccountSyncStatus.synced));

      // Multiple rapid changes within debounce window
      await appSettings.setDarkTerminal(true);
      expect(session.status, equals(AccountSyncStatus.pending));

      await appSettings.setSmoothText(false);
      expect(session.status, equals(AccountSyncStatus.pending));

      // Wait for debounce and upload to complete
      await sentCompleter.future;
      await session.activeUpload;

      // Exactly one put was executed
      expect(fakeTransport.execCommands, equals(['put']));
      expect(session.status, equals(AccountSyncStatus.synced));
      expect(putChannels.length, equals(1));
      final uploaded = putChannels.first.sent.join('\n');
      expect(uploaded, isNotEmpty);

      // Verify the uploaded payload is encrypted and contains the settings
      final sealedJson = jsonDecode(uploaded) as Map<String, dynamic>;
      expect(sealedJson['v'], equals(2));
      expect(sealedJson['cipher'], equals('aes-256-gcm'));

      // Verify openVault successfully recovers the uploaded settings
      final unsealed = await openVault(uploaded, testAccountKey);
      expect(unsealed.settings, isNotNull);
      expect(unsealed.settings![SettingsSyncKeys.darkTerminal], isTrue);
      expect(unsealed.settings![SettingsSyncKeys.smoothText], isFalse);
    });
  });

  group('Adversarial security and device boundary checks', () {
    test('no device-bound keys ever appear in the synced payload', () async {
      SharedPreferences.setMockInitialValues({});
      final appSettings = AppSettings(MemoryAppSettingsStore());
      final termSettings = TerminalSettings(MemoryTerminalSettingsStore());
      final notifySettings = NotificationSettings(MemoryNotificationStore());
      final phrases = QuickPhrases(MemoryQuickPhrasesStore());

      final sync = SettingsSync(
        appSettings: appSettings,
        terminalSettings: termSettings,
        notificationSettings: notifySettings,
        quickPhrases: phrases,
      );
      await sync.init();
      await appSettings.setTheme(ThemeChoice.dark);

      final snap = await sync.snapshot();
      expect(snap, isNotNull);

      const deviceBoundKeys = [
        'osPermission',
        'lastCheck',
        'downloadedRelease',
        'accountSession',
        'token',
        'password',
        'keychain',
        'sent_phrases',
        'slash_usage',
        'telemetryId',
        'cache',
        'sessionId',
        'socketPath',
      ];

      for (final key in deviceBoundKeys) {
        expect(snap!.containsKey(key), isFalse, reason: '$key must not be in synced payload');
      }
    });

    test('no plaintext settings written outside the encrypted envelope', () async {
      const phrase = 'adversarial-canary-secret-phrase';
      final contents = VaultContents(
        machines: const [],
        secrets: const {},
        settings: {
          SettingsSyncKeys.quickPhrases: [phrase],
          SettingsSyncKeys.theme: 'dark',
          SettingsSyncKeys.updatedAt: '2026-11-06T12:00:00.000Z',
        },
      );

      final sealed = await sealVault(contents, testAccountKey);
      final envelope = jsonDecode(sealed) as Map<String, dynamic>;

      expect(envelope['v'], equals(2));
      expect(envelope['cipher'], equals('aes-256-gcm'));
      expect(envelope.containsKey('ct'), isTrue);
      expect(envelope.containsKey('nonce'), isTrue);

      // Verify no plaintext leak in envelope
      expect(sealed.contains(phrase), isFalse);
      expect(sealed.contains('dark'), isFalse);
      expect(sealed.contains('quickPhrases'), isFalse);
      expect(sealed.contains('updatedAt'), isFalse);

      // Verify openVault decrypts it cleanly
      final opened = await openVault(sealed, testAccountKey);
      expect(opened.settings, isNotNull);
      expect(opened.settings![SettingsSyncKeys.quickPhrases], equals([phrase]));
    });

    test('signed out: changes remain local and do not trigger upload; sign-out does not wipe stores', () async {
      SharedPreferences.setMockInitialValues({});
      final appStore = MemoryAppSettingsStore();
      final appSettings = AppSettings(appStore);

      final sync = SettingsSync(appSettings: appSettings);
      await sync.init();

      final fakeTransport = FakeTransport();
      final session = AccountSession(
        machines: MachineRepository(profiles: MemoryProfileStore(), secrets: MemorySecretStore()),
        connect: (p, s, pin, n) => fakeTransport,
        sessionStore: MemoryAccountSessionStore(),
        settingsSync: sync,
        debounceDuration: Duration.zero,
      );

      expect(session.isSignedIn, isFalse);

      // Change setting while signed out
      await appSettings.setTheme(ThemeChoice.dark);
      expect(appSettings.theme, equals(ThemeChoice.dark));
      expect(session.status, equals(AccountSyncStatus.signedOut));
      expect(fakeTransport.execCommands, isEmpty);

      // Signing out does not wipe local preferences
      await session.signOut();
      expect(appSettings.theme, equals(ThemeChoice.dark));
    });
  });
}
