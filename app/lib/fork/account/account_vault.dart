import 'dart:async';
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' show sha256;
import 'package:pointycastle/export.dart';

import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/ssh_transport.dart' show hostKeyChangedMessage;
import 'package:herdr_mobile/data/words/plural.dart';
import 'package:herdr_mobile/ui/features/machines/machine_form_view_model.dart' show TransportFactory;

import 'settings_sync.dart';

const accountBoxHost = '140.245.204.23';
const accountBoxPort = 22;
const accountBoxUser = 'herdrj';
const accountBoxHostKey = 'SHA256:JVAqsSiiRDspdJB3qXz/aBFPmiV00lIoih7NV1b5I0U';

const canonicalUsername = 'jaya';

const vaultIterations = 200000;
const vaultMaxBytes = 1024 * 1024;
const accountTimeout = Duration(seconds: 45);

const accountBox = MachineProfile(
  id: 'account-box',
  label: 'Account box',
  host: accountBoxHost,
  port: accountBoxPort,
  username: accountBoxUser,
  auth: SshAuth.password,
  hostKeyFingerprint: accountBoxHostKey,
);

String canonicalizeUsername(String username) => username.trim().toLowerCase();

class AccountProblem implements Exception {
  const AccountProblem(this.message);

  final String message;

  @override
  String toString() => message;
}

/// Internal control flow: stale/background work must stop without a UI error.
class AccountOperationCancelled implements Exception {
  const AccountOperationCancelled();
}

void _allowOperation() {}

abstract final class AccountWords {
  static const intro = 'One account brings your machines, keys and passwords to this phone. Edits sync automatically.';

  static const invalidUsername = 'Account not found. Only account jaya is supported.';

  static String signInDone(int added, int updated) =>
      'Signed in \u00b7 ${countOf(added, 'machine')} added, $updated updated';

  static const signedIn = 'Signed in as jaya';

  static const signedOut = 'Signed out';

  static const signOutFailed = 'Couldn’t remove the saved login. Sync is stopped. Retry signing out.';

  static const syncStatusSynced = 'All changes saved to box';

  static const syncStatusPending = 'Changes pending sync\u2026';

  static const syncStatusSyncing = 'Syncing changes\u2026';

  static const syncStatusError = 'Changes haven\u2019t synced';

  static const machinesRemainNotice = 'Signed-out machines remain on this phone.';

  static const wrongPassword = 'Wrong password. Nothing was changed.';

  static const badFilePassword = 'This password doesn\u2019t open the saved machines. Nothing was changed.';

  static const nothingSaved = 'Nothing is saved on the box yet.';

  static const hostKeyDiffers = 'The box\u2019s host key isn\u2019t the one this app trusts. Nothing was changed.';

  static const unreadableFile = 'The saved file can\u2019t be read by this version of the app. Nothing was changed.';

  static const overMaxBytes = 'Too much to save: the box takes at most 1 MiB.';

  static const saveTimedOut =
      'The box did not answer in time; the save may or may not have landed. Try again to be sure.';

  static String partialSignIn(int saved, int total) =>
      'Signed in partly: $saved of $total machines saved. Sign in again to finish.';

  static String keyMissing(String label) =>
      '$label uses a key, but its private key isn\u2019t on this phone. Nothing was saved.';

  static const unexpected = 'Something went wrong. Nothing was changed. Try again.';

  static String reachProblem(String message, {bool save = false}) =>
      'Couldn\u2019t reach the box: $message. ${save ? "Nothing was saved." : "Nothing was changed."}';
}

class VaultContents {
  const VaultContents({this.machines = const [], this.secrets = const {}, this.settings});

  final List<MachineProfile> machines;
  final Map<String, MachineSecrets> secrets;
  final Map<String, dynamic>? settings;

  Map<String, dynamic> toJson() => {
    'machines': [
      for (final m in machines)
        if (m.id != 'form-draft') m.toJson(),
    ],
    'secrets': {
      for (final entry in secrets.entries)
        if (entry.key != 'form-draft')
          entry.key: {
            if (entry.value.privateKeyPem != null) 'key': entry.value.privateKeyPem,
            if (entry.value.passphrase != null) 'passphrase': entry.value.passphrase,
            if (entry.value.password != null) 'password': entry.value.password,
          },
    },
    if (settings != null) 'settings': settings,
  };

  static VaultContents fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('Expected a JSON map');
    }
    final rawMachines = json['machines'];
    if (rawMachines is! List) {
      throw const FormatException('Expected machines list');
    }

    final seenIds = <String>{};
    final machines = <MachineProfile>[];
    for (final item in rawMachines) {
      if (item is! Map) {
        throw const FormatException('Machine entry must be a map');
      }
      final id = item['id'];
      if (id is! String || id.isEmpty) {
        throw const FormatException('Machine id must be a non-empty string');
      }
      if (id == 'form-draft') {
        throw const FormatException('Reserved id form-draft cannot be saved in vault');
      }
      if (!seenIds.add(id)) {
        throw FormatException('Duplicate machine id in vault: $id');
      }

      final label = item['label'];
      if (label is! String || label.isEmpty) {
        throw const FormatException('Machine label must be a non-empty string');
      }
      final host = item['host'];
      if (host is! String || host.isEmpty) {
        throw const FormatException('Machine host must be a non-empty string');
      }
      final username = item['username'];
      if (username is! String || username.isEmpty) {
        throw const FormatException('Machine username must be a non-empty string');
      }

      final rawPort = item['port'];
      final int port;
      if (rawPort == null) {
        port = 22;
      } else if (rawPort is num && rawPort >= 1 && rawPort <= 65535 && rawPort.toInt() == rawPort) {
        port = rawPort.toInt();
      } else {
        throw const FormatException('Machine port must be an integer between 1 and 65535');
      }

      final rawAuth = item['auth'];
      final SshAuth auth;
      if (rawAuth == null) {
        auth = SshAuth.key;
      } else if (rawAuth is String && SshAuth.values.asNameMap().containsKey(rawAuth)) {
        auth = SshAuth.values.asNameMap()[rawAuth]!;
      } else {
        throw const FormatException('Invalid or unsupported SSH auth method');
      }

      final rawEnabled = item['enabled'];
      if (rawEnabled != null && rawEnabled is! bool) {
        throw const FormatException('Machine enabled must be a boolean');
      }

      final rawSession = item['session'];
      if (rawSession != null && rawSession is! String) {
        throw const FormatException('Machine session must be a string');
      }
      final rawSocketPath = item['socketPath'];
      if (rawSocketPath != null && rawSocketPath is! String) {
        throw const FormatException('Machine socketPath must be a string');
      }
      final rawFingerprint = item['hostKeyFingerprint'];
      if (rawFingerprint != null && rawFingerprint is! String) {
        throw const FormatException('Machine hostKeyFingerprint must be a string');
      }

      machines.add(
        MachineProfile(
          id: id,
          label: label,
          host: host,
          username: username,
          port: port,
          auth: auth,
          session: (rawSession as String?) ?? 'default',
          socketPath: rawSocketPath as String?,
          hostKeyFingerprint: rawFingerprint as String?,
          enabled: rawEnabled != false,
        ),
      );
    }

    final rawSecrets = json['secrets'];
    final secrets = <String, MachineSecrets>{};
    if (rawSecrets != null) {
      if (rawSecrets is! Map) {
        throw const FormatException('Expected secrets map');
      }
      for (final entry in rawSecrets.entries) {
        final id = entry.key;
        final val = entry.value;
        if (id is! String || val is! Map) {
          throw const FormatException('Invalid secret entry structure');
        }
        final keyPem = val['key'];
        final passphrase = val['passphrase'];
        final password = val['password'];
        if (keyPem != null && keyPem is! String) {
          throw const FormatException('Secret key must be a string');
        }
        if (passphrase != null && passphrase is! String) {
          throw const FormatException('Secret passphrase must be a string');
        }
        if (password != null && password is! String) {
          throw const FormatException('Secret password must be a string');
        }
        secrets[id] = MachineSecrets(
          privateKeyPem: keyPem as String?,
          passphrase: passphrase as String?,
          password: password as String?,
        );
      }
    }

    final rawSettings = json['settings'];
    Map<String, dynamic>? settings;
    if (rawSettings != null) {
      if (rawSettings is! Map) {
        throw const FormatException('Expected settings map');
      }
      final sanitized = <String, dynamic>{};
      for (final key in SettingsSyncKeys.allowlist) {
        if (rawSettings.containsKey(key)) {
          sanitized[key] = rawSettings[key];
        }
      }
      settings = sanitized;
    }

    return VaultContents(machines: machines, secrets: secrets, settings: settings);
  }
}

/// Deterministic SHA-256 digest of a snapshot (used to detect local changes).
String computeSnapshotDigest(VaultContents contents) {
  final sortedMachines = [
    for (final m in contents.machines)
      if (m.id != 'form-draft') m,
  ]..sort((a, b) => a.id.compareTo(b.id));

  final sortedSecrets = Map.fromEntries(
    contents.secrets.entries
        .where(
          (e) =>
              e.key != 'form-draft' &&
              (e.value.privateKeyPem != null || e.value.passphrase != null || e.value.password != null),
        )
        .toList()
      ..sort((a, b) => a.key.compareTo(b.key)),
  );

  final Map<String, dynamic>? canonicalSettings;
  if (contents.settings != null) {
    final sortedKeys = contents.settings!.keys.toList()..sort();
    canonicalSettings = {for (final k in sortedKeys) k: contents.settings![k]};
  } else {
    canonicalSettings = null;
  }

  final canonical = jsonEncode({
    'machines': [for (final m in sortedMachines) m.toJson()],
    'secrets': {
      for (final e in sortedSecrets.entries)
        e.key: {
          if (e.value.privateKeyPem != null) 'key': e.value.privateKeyPem,
          if (e.value.passphrase != null) 'passphrase': e.value.passphrase,
          if (e.value.password != null) 'password': e.value.password,
        },
    },
    'settings': ?canonicalSettings,
  });

  return sha256.convert(utf8.encode(canonical)).toString();
}

/// What the box sees as the SSH password: a one-way PBKDF2 of the password with salt `herdrj-login-v1`.
Future<String> loginSecret(String phrase) => Isolate.run(
  () => base64Url
      .encode(_deriveKey(phrase, Uint8List.fromList(utf8.encode('herdrj-login-v1')), vaultIterations))
      .replaceAll('=', ''),
);

/// Sealing v2 envelope with 256-bit server-provisioned account key:
/// {"v":2,"cipher":"aes-256-gcm","nonce":"BASE64_12_BYTES","ct":"BASE64_CIPHERTEXT_AND_16BYTE_TAG"}
Future<String> sealVault(VaultContents c, Uint8List accountKey) async {
  if (accountKey.length != 32) {
    throw ArgumentError('Account key must be 32 bytes');
  }
  final nonce = Uint8List(12);
  final rng = Random.secure();
  for (var i = 0; i < nonce.length; i++) {
    nonce[i] = rng.nextInt(256);
  }

  final plaintext = jsonEncode(c.toJson());
  final ct = await Isolate.run(() => _runSealV2(plaintext: plaintext, key: accountKey, nonce: nonce));

  return jsonEncode({'v': 2, 'cipher': 'aes-256-gcm', 'nonce': base64Encode(nonce), 'ct': base64Encode(ct)});
}

/// Opening v2 envelope with 256-bit server-provisioned account key.
Future<VaultContents> openVault(String file, Uint8List accountKey) async {
  if (accountKey.length != 32) {
    throw ArgumentError('Account key must be 32 bytes');
  }
  final Object? decoded;
  try {
    decoded = jsonDecode(file);
  } on FormatException {
    throw const AccountProblem(AccountWords.unreadableFile);
  }

  if (decoded is! Map ||
      decoded['v'] != 2 ||
      decoded['cipher'] != 'aes-256-gcm' ||
      decoded['nonce'] is! String ||
      decoded['ct'] is! String) {
    throw const AccountProblem(AccountWords.unreadableFile);
  }

  final Uint8List nonce;
  final Uint8List ct;
  try {
    nonce = Uint8List.fromList(base64Decode(decoded['nonce'] as String));
    ct = Uint8List.fromList(base64Decode(decoded['ct'] as String));
  } on FormatException {
    throw const AccountProblem(AccountWords.unreadableFile);
  }

  if (nonce.length != 12 || ct.length < 16) {
    throw const AccountProblem(AccountWords.unreadableFile);
  }

  final Uint8List decrypted;
  try {
    decrypted = await Isolate.run(() => _runOpenV2(ct: ct, key: accountKey, nonce: nonce));
  } on InvalidCipherTextException {
    throw const AccountProblem(AccountWords.badFilePassword);
  } catch (e) {
    if (e.toString().contains('InvalidCipherTextException')) {
      throw const AccountProblem(AccountWords.badFilePassword);
    }
    throw const AccountProblem(AccountWords.unreadableFile);
  }

  final String plaintext;
  try {
    plaintext = utf8.decode(decrypted);
  } on FormatException {
    throw const AccountProblem(AccountWords.unreadableFile);
  }

  final Object? contentsJson;
  try {
    contentsJson = jsonDecode(plaintext);
  } on FormatException {
    throw const AccountProblem(AccountWords.unreadableFile);
  }

  try {
    return VaultContents.fromJson(contentsJson);
  } catch (_) {
    throw const AccountProblem(AccountWords.unreadableFile);
  }
}

Uint8List _deriveKey(String password, Uint8List salt, int iterations) {
  final derivator = PBKDF2KeyDerivator(HMac(SHA256Digest(), 64))..init(Pbkdf2Parameters(salt, iterations, 32));
  return derivator.process(Uint8List.fromList(utf8.encode(password)));
}

Uint8List _encrypt(Uint8List key, Uint8List nonce, Uint8List plaintext) {
  final cipher = GCMBlockCipher(AESEngine())..init(true, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
  return cipher.process(plaintext);
}

Uint8List _decrypt(Uint8List key, Uint8List nonce, Uint8List ciphertextAndTag) {
  final cipher = GCMBlockCipher(AESEngine())..init(false, AEADParameters(KeyParameter(key), 128, nonce, Uint8List(0)));
  return cipher.process(ciphertextAndTag);
}

Uint8List _runSealV2({required String plaintext, required Uint8List key, required Uint8List nonce}) {
  return _encrypt(key, nonce, Uint8List.fromList(utf8.encode(plaintext)));
}

Uint8List _runOpenV2({required Uint8List ct, required Uint8List key, required Uint8List nonce}) {
  return _decrypt(key, nonce, ct);
}

/// Literal SSH command `key` fetches server-provisioned account key:
/// {"v":1,"username":"jaya","key":"BASE64_32_BYTES"}
Future<Uint8List> fetchAccountKey(HerdrTransport transport, {void Function() check = _allowOperation}) async {
  check();
  final exec = await transport.openExec('key');
  check();
  final lines = await exec.lines.toList();
  check();
  final code = await exec.exitCode;
  check();
  if (code != 0) {
    final detail = code == null ? 'connection dropped' : 'exit code $code';
    throw AccountProblem(AccountWords.reachProblem(detail));
  }
  final raw = lines.join('\n').trim();
  final Object? json;
  try {
    json = jsonDecode(raw);
  } on FormatException {
    throw const AccountProblem(AccountWords.unreadableFile);
  }
  if (json is! Map || json['v'] != 1 || json['username'] != canonicalUsername || json['key'] is! String) {
    throw const AccountProblem(AccountWords.unreadableFile);
  }
  final Uint8List keyBytes;
  try {
    keyBytes = Uint8List.fromList(base64Decode(json['key'] as String));
  } on FormatException {
    throw const AccountProblem(AccountWords.unreadableFile);
  }
  if (keyBytes.length != 32) {
    throw const AccountProblem(AccountWords.unreadableFile);
  }
  return keyBytes;
}

class AccountVault {
  AccountVault({
    required this.machines,
    required this.connect,
    this.settingsSync,
    this.timeout = accountTimeout,
    this.check = _allowOperation,
    this.sealSnapshot = sealVault,
  });

  final MachineRepository machines;
  final TransportFactory connect;
  final SettingsSync? settingsSync;
  final Duration timeout;
  final void Function() check;
  final Future<String> Function(VaultContents, Uint8List) sealSnapshot;

  Future<({int added, int updated, Uint8List accountKey, String loginSecret, String remoteDigest})> signIn(
    String username,
    String password,
  ) async {
    final canonical = canonicalizeUsername(username);
    if (canonical != canonicalUsername) {
      throw const AccountProblem(AccountWords.invalidUsername);
    }
    check();
    final secret = await loginSecret(password);
    check();
    final login = MachineSecrets(password: secret);

    HerdrTransport? opened;
    final (contents, accountKey) = await _runWithTimeout(
      () async {
        check();
        final transport = opened = connect(accountBox, login, (_) {}, (_) {});
        try {
          final key = await fetchAccountKey(transport, check: check);
          check();
          final exec = await transport.openExec('get');
          check();
          final lines = await exec.lines.toList();
          check();
          final code = await exec.exitCode;
          check();
          if (code == 3) {
            throw const AccountProblem(AccountWords.nothingSaved);
          }
          if (code != 0) {
            final detail = code == null ? 'connection dropped' : 'exit code $code';
            throw AccountProblem(AccountWords.reachProblem(detail));
          }
          final c = await openVault(lines.join('\n'), key);
          check();
          return (c, key);
        } finally {
          try {
            await transport.close();
          } catch (_) {}
        }
      },
      isSave: false,
      onTimeout: () => opened?.close(),
    );

    check();
    final counts = await importContents(contents);
    check();
    return (
      added: counts.added,
      updated: counts.updated,
      accountKey: accountKey,
      loginSecret: secret,
      remoteDigest: computeSnapshotDigest(contents),
    );
  }

  /// Prepare and validate the entire import before writing the first record.
  /// Missing fields never replace working local credentials with partial ones.
  Future<({int added, int updated})> importContents(VaultContents contents) async {
    if (settingsSync != null && contents.settings != null) {
      check();
      await settingsSync!.applyRemote(contents.settings!);
      check();
    }
    final prepared = <({MachineProfile profile, MachineSecrets secrets, bool existed})>[];
    for (final imported in contents.machines) {
      check();
      final local = machines.byId(imported.id);
      final old = local == null ? const MachineSecrets() : await machines.secretsFor(imported.id);
      check();
      final incoming = contents.secrets[imported.id];
      final incomingKey = incoming?.privateKeyPem;
      final hasKey = incomingKey != null && incomingKey.isNotEmpty;
      final replacingKey = hasKey && incomingKey != old.privateKeyPem;
      String? keepNonempty(String? value, String? previous) => value == null || value.isEmpty ? previous : value;
      final effective = MachineSecrets(
        privateKeyPem: keepNonempty(incomingKey, old.privateKeyPem),
        // A replacement key carries its own passphrase (null means unencrypted).
        // Without a key, an incoming passphrase cannot belong to the local key.
        passphrase: replacingKey
            ? incoming?.passphrase
            : hasKey
            ? keepNonempty(incoming?.passphrase, old.passphrase)
            : old.passphrase,
        password: keepNonempty(incoming?.password, old.password),
      );
      if (imported.auth == SshAuth.key && (effective.privateKeyPem ?? '').isEmpty) {
        throw AccountProblem(AccountWords.keyMissing(imported.label));
      }
      final pin = local?.hostKeyFingerprint;
      prepared.add((
        profile: pin == null ? imported : imported.copyWith(hostKeyFingerprint: pin),
        secrets: effective,
        existed: local != null,
      ));
    }
    var added = 0;
    var updated = 0;
    try {
      for (final item in prepared) {
        check();
        await machines.save(item.profile, secrets: item.secrets);
        check();
        if (item.existed) {
          updated++;
        } else {
          added++;
        }
      }
    } on AccountOperationCancelled {
      rethrow;
    } catch (_) {
      throw AccountProblem(AccountWords.partialSignIn(added + updated, prepared.length));
    }
    return (added: added, updated: updated);
  }

  Future<int> uploadSnapshot({
    required VaultContents contents,
    required Uint8List accountKey,
    required String loginSecret,
  }) async {
    final allMachines = [
      for (final m in contents.machines)
        if (m.id != 'form-draft') m,
    ];
    for (final m in allMachines) {
      final s = contents.secrets[m.id];
      if (m.auth == SshAuth.key && (s?.privateKeyPem ?? '').isEmpty) {
        throw AccountProblem(AccountWords.keyMissing(m.label));
      }
    }
    check();
    final file = await sealSnapshot(
      VaultContents(machines: allMachines, secrets: contents.secrets, settings: contents.settings),
      accountKey,
    );
    check();
    if (utf8.encode(file).length >= vaultMaxBytes) {
      throw const AccountProblem(AccountWords.overMaxBytes);
    }
    final login = MachineSecrets(password: loginSecret);
    HerdrTransport? opened;
    return await _runWithTimeout(
      () async {
        check();
        final transport = opened = connect(accountBox, login, (_) {}, (_) {});
        try {
          check();
          final exec = await transport.openExec('put');
          check();
          exec.send(file);
          await exec.closeInput();
          check();
          final code = await exec.exitCode;
          check();
          if (code == 0) {
            return allMachines.length;
          }
          final detail = code == null ? 'connection dropped' : 'exit code $code';
          throw AccountProblem(AccountWords.reachProblem(detail, save: true));
        } finally {
          try {
            await transport.close();
          } catch (_) {}
        }
      },
      isSave: true,
      onTimeout: () => opened?.close(),
    );
  }

  Future<T> _runWithTimeout<T>(
    Future<T> Function() action, {
    required bool isSave,
    required Future<void>? Function() onTimeout,
  }) async {
    try {
      return await action().timeout(timeout);
    } on AccountOperationCancelled {
      rethrow;
    } on AccountProblem {
      rethrow;
    } on HerdrTransportException catch (e) {
      if (e.message == hostKeyChangedMessage) {
        throw const AccountProblem(AccountWords.hostKeyDiffers);
      }
      if (e.message.startsWith('SSH authentication failed') ||
          e.message.startsWith('The machine refused the sign-in')) {
        throw const AccountProblem(AccountWords.wrongPassword);
      }
      throw AccountProblem(AccountWords.reachProblem('connection failed', save: isSave));
    } on InvalidCipherTextException {
      throw const AccountProblem(AccountWords.badFilePassword);
    } on FormatException {
      throw const AccountProblem(AccountWords.unreadableFile);
    } on TypeError {
      throw const AccountProblem(AccountWords.unreadableFile);
    } on TimeoutException {
      Future.sync(onTimeout).ignore();
      throw AccountProblem(isSave ? AccountWords.saveTimedOut : AccountWords.reachProblem('connection timed out'));
    } catch (_) {
      throw AccountProblem(AccountWords.reachProblem('connection failed', save: isSave));
    }
  }
}
