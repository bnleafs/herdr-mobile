import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:herdr_mobile/data/models/machine_profile.dart';
import 'package:herdr_mobile/data/repositories/machine_repository.dart';
import 'package:herdr_mobile/data/services/herdr_transport.dart';
import 'package:herdr_mobile/data/services/ssh_transport.dart' show hostKeyChangedMessage;
import 'package:herdr_mobile/ui/features/machines/machine_form_view_model.dart' show TransportFactory;

import 'account_vault.dart';
import 'settings_sync.dart';

const sessionStorageKey = 'herdr.account.v2.session';
const localInitializedKey = 'herdr.account.v2.local_initialized';

abstract class AccountSessionStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class SecureAccountSessionStore implements AccountSessionStore {
  const SecureAccountSessionStore([FlutterSecureStorage? storage]) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  @override
  Future<String?> read(String key) => _storage.read(key: key);

  @override
  Future<void> write(String key, String value) => _storage.write(key: key, value: value);

  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

enum AccountSyncStatus { signedOut, signingIn, synced, pending, syncing, error }

String classifyAccountError(Object error) {
  if (error is AccountProblem) {
    return error.message;
  }
  if (error is HerdrTransportException) {
    if (error.message == hostKeyChangedMessage) {
      return AccountWords.hostKeyDiffers;
    }
    if (error.message.startsWith('SSH authentication failed') ||
        error.message.startsWith('The machine refused the sign-in')) {
      return AccountWords.wrongPassword;
    }
    return AccountWords.reachProblem('connection failed');
  }
  if (error is TimeoutException) {
    return AccountWords.reachProblem('connection timed out');
  }
  return AccountWords.unexpected;
}

class AccountSession extends ChangeNotifier with WidgetsBindingObserver {
  AccountSession({
    required this.machines,
    required this.connect,
    this.settingsSync,
    AccountSessionStore? sessionStore,
    this.debounceDuration = const Duration(milliseconds: 1000),
    this.sealSnapshot = sealVault,
  }) : _sessionStore = sessionStore ?? const SecureAccountSessionStore() {
    machines.addListener(_onRepositoryChanged);
    settingsSync?.addListener(_onSettingsChanged);
    WidgetsBinding.instance.addObserver(this);
  }

  final MachineRepository machines;
  final TransportFactory connect;
  final SettingsSync? settingsSync;
  final AccountSessionStore _sessionStore;
  final Duration debounceDuration;
  final Future<String> Function(VaultContents, Uint8List) sealSnapshot;

  AccountSyncStatus _status = AccountSyncStatus.signedOut;
  String? _username;
  String? _loginSecret;
  Uint8List? _accountKey;
  String? _lastSyncedDigest;
  String? _lastError;
  // The sole upload gate. A restored key alone is never evidence of an import.
  bool _initialized = false;
  bool _suppressRepositoryEvents = false;
  bool _uploading = false;
  bool _pendingUpload = false;
  bool _isBackgrounded = false;
  bool _disposed = false;
  bool _signOutPending = false;
  bool _restorePending = false;
  int _generation = 0;
  int _repoVersion = 0;
  HerdrTransport? _activeTransport;
  Timer? _debounceTimer;
  Future<void>? _activeUpload;
  Future<void> _storageQueue = Future.value();

  Future<void>? get activeUpload => _activeUpload;
  AccountSyncStatus get status => _status;
  bool get isSignedIn => _username != null && _accountKey != null;
  bool get isSigningIn => _status == AccountSyncStatus.signingIn;
  String? get username => _username;
  String? get lastError => _lastError;
  String? get lastSyncedDigest => _lastSyncedDigest;
  bool get isInitialized => _initialized;
  bool get signOutPending => _signOutPending;

  bool _current(int generation) => !_disposed && generation == _generation;

  void _check(int generation) {
    if (!_current(generation) || _isBackgrounded || _signOutPending) {
      throw const AccountOperationCancelled();
    }
  }

  AccountVault _vault(int generation) => AccountVault(
    machines: machines,
    check: () => _check(generation),
    sealSnapshot: sealSnapshot,
    settingsSync: settingsSync,
    connect: (profile, secrets, pin, notice) {
      _check(generation);
      return _activeTransport = connect(profile, secrets, pin, notice);
    },
  );

  void _cancelWork() {
    _generation++;
    _restorePending = false;
    _initialized = false;
    _debounceTimer?.cancel();
    _debounceTimer = null;
    final transport = _activeTransport;
    _activeTransport = null;
    // Closing a cancelled link is best-effort; no further operation may use it.
    if (transport != null) transport.close().ignore();
  }

  // Order deletion after any write already handed to secure storage. Checks
  // inside the queue prevent a stale operation from starting a later write.
  Future<void> _storage(Future<void> Function() action) {
    final run = _storageQueue.then((_) => action());
    _storageQueue = run.then((_) {}, onError: (Object _) {});
    return run;
  }

  Future<void> _persist(int generation) => _storage(() async {
    _check(generation);
    await _sessionStore.write(
      sessionStorageKey,
      jsonEncode({
        'v': 2,
        'username': _username,
        'loginSecret': _loginSecret,
        'accountKey': base64Encode(_accountKey!),
        'lastSyncedDigest': _lastSyncedDigest,
        'initialized': true,
      }),
    );
    _check(generation);
  });

  Future<void> init() async {
    final generation = _generation;
    if (_disposed) return;
    await settingsSync?.init();
    _restorePending = true;
    try {
      final raw = await _sessionStore.read(sessionStorageKey);
      _check(generation);
      if (raw == null) return;
      final decoded = jsonDecode(raw);
      if (decoded is! Map || decoded['v'] != 2 || decoded['username'] != canonicalUsername) return;
      final secret = decoded['loginSecret'];
      final keyB64 = decoded['accountKey'];
      final digest = decoded['lastSyncedDigest'];
      if (secret is! String || secret.isEmpty || keyB64 is! String || digest is! String) return;
      final keyBytes = Uint8List.fromList(base64Decode(keyB64));
      if (keyBytes.length != 32) return;
      _username = canonicalUsername;
      _loginSecret = secret;
      _accountKey = keyBytes;
      _lastSyncedDigest = digest;
      final prefs = await SharedPreferences.getInstance();
      _check(generation);
      // This installation previously completed import and session persistence.
      _initialized = decoded['initialized'] == true && prefs.getBool(localInitializedKey) == true;
      if (!_initialized) {
        await _pullAndImport(generation);
      } else {
        final snapshot = await _collectStableSnapshot(generation);
        _check(generation);
        _pendingUpload = computeSnapshotDigest(snapshot) != _lastSyncedDigest;
        _status = _pendingUpload ? AccountSyncStatus.pending : AccountSyncStatus.synced;
        notifyListeners();
      }
      if (_pendingUpload) {
        _scheduleUpload();
        await _activeUpload;
      }
    } on AccountOperationCancelled {
      // Sign-out/disposal owns the new state. Background work remains pending.
    } catch (error) {
      if (!_current(generation)) return;
      _status = AccountSyncStatus.error;
      _lastError = classifyAccountError(error);
      notifyListeners();
    } finally {
      if (_current(generation)) _restorePending = _isBackgrounded;
    }
  }

  Future<void> signIn(String username, String password) async {
    if (_disposed || _signOutPending) return;
    final canonical = canonicalizeUsername(username);
    if (canonical != canonicalUsername) {
      _lastError = AccountWords.invalidUsername;
      _status = AccountSyncStatus.signedOut;
      notifyListeners();
      throw const AccountProblem(AccountWords.invalidUsername);
    }
    _cancelWork();
    final generation = _generation;
    _status = AccountSyncStatus.signingIn;
    _lastError = null;
    notifyListeners();
    _suppressRepositoryEvents = true;
    try {
      final result = await _vault(generation).signIn(username, password);
      _check(generation);
      _username = canonicalUsername;
      _loginSecret = result.loginSecret;
      _accountKey = result.accountKey;
      await _finishImport(generation, result.remoteDigest);
      _check(generation);
    } on AccountOperationCancelled {
      if (_current(generation)) {
        _pendingUpload = isSignedIn;
        _status = isSignedIn ? AccountSyncStatus.pending : AccountSyncStatus.signedOut;
        notifyListeners();
      }
      return;
    } catch (error) {
      if (!_current(generation)) return;
      _initialized = false;
      _status = AccountSyncStatus.signedOut;
      _username = null;
      _loginSecret = null;
      _accountKey = null;
      _lastError = classifyAccountError(error);
      notifyListeners();
      throw AccountProblem(_lastError!);
    } finally {
      if (_current(generation)) _suppressRepositoryEvents = false;
    }
    if (_pendingUpload) _scheduleUpload();
  }

  Future<void> _finishImport(int generation, String remoteDigest) async {
    _check(generation);
    // Only the validated REMOTE data is a saved baseline; local additions and
    // preserved local credentials still need an upload.
    _lastSyncedDigest = remoteDigest;
    await _persist(generation);
    _check(generation);
    final prefs = await SharedPreferences.getInstance();
    _check(generation);
    // Serialize the marker too so sign-out cannot leave it behind a deletion.
    await _storage(() async {
      _check(generation);
      if (!await prefs.setBool(localInitializedKey, true)) throw const AccountProblem(AccountWords.unexpected);
      _check(generation);
    });
    _check(generation);
    _initialized = true;
    final snapshot = await _collectStableSnapshot(generation);
    _check(generation);
    _pendingUpload = computeSnapshotDigest(snapshot) != remoteDigest;
    _status = _pendingUpload ? AccountSyncStatus.pending : AccountSyncStatus.synced;
    _lastError = null;
    notifyListeners();
  }

  Future<void> signOut() async {
    if (_disposed) return;
    _cancelWork();
    final generation = _generation;
    _signOutPending = true;
    _suppressRepositoryEvents = false;
    _pendingUpload = false;
    _username = null;
    _loginSecret = null;
    _accountKey = null;
    _lastSyncedDigest = null;
    _lastError = null;
    try {
      await _storage(() async {
        if (!_current(generation)) return;
        await _sessionStore.delete(sessionStorageKey);
        if (!_current(generation)) return;
        final prefs = await SharedPreferences.getInstance();
        if (!_current(generation)) return;
        if (!await prefs.remove(localInitializedKey)) throw const AccountProblem(AccountWords.signOutFailed);
      });
      if (!_current(generation)) return;
      _signOutPending = false;
      _status = AccountSyncStatus.signedOut;
    } catch (_) {
      if (!_current(generation)) return;
      _status = AccountSyncStatus.error;
      _lastError = AccountWords.signOutFailed;
    }
    notifyListeners();
  }

  Future<void> retry() async {
    if (_disposed || _isBackgrounded) return;
    if (_signOutPending) return signOut();
    if (!isSignedIn) return;
    _lastError = null;
    final generation = _generation;
    if (!_initialized) {
      try {
        await _pullAndImport(generation);
        _check(generation);
        if (_pendingUpload) _scheduleUpload();
      } on AccountOperationCancelled {
        return;
      } catch (error) {
        if (!_current(generation)) return;
        _status = AccountSyncStatus.error;
        _lastError = classifyAccountError(error);
        notifyListeners();
      }
    } else {
      await (_activeUpload = _triggerUpload());
    }
  }

  void _onRepositoryChanged() {
    _repoVersion++;
    if (_suppressRepositoryEvents || !isSignedIn || _disposed || _signOutPending) return;
    // Dirtiness starts at the edit, not when a debounce eventually fires.
    _pendingUpload = true;
    _status = AccountSyncStatus.pending;
    notifyListeners();
    if (_initialized && !_isBackgrounded) _scheduleUpload();
  }

  void _onSettingsChanged() {
    _repoVersion++;
    if (_suppressRepositoryEvents || !isSignedIn || _disposed || _signOutPending) return;
    _pendingUpload = true;
    _status = AccountSyncStatus.pending;
    notifyListeners();
    if (_initialized && !_isBackgrounded) _scheduleUpload();
  }

  void _scheduleUpload() {
    _debounceTimer?.cancel();
    if (!_initialized || _disposed || _isBackgrounded) return;
    if (debounceDuration == Duration.zero) {
      _activeUpload = _triggerUpload();
    } else {
      _debounceTimer = Timer(debounceDuration, () {
        _activeUpload = _triggerUpload();
      });
    }
  }

  Future<void> _triggerUpload() async {
    if (!_initialized || !isSignedIn || _disposed || _isBackgrounded || _signOutPending) return;
    if (_uploading) {
      _pendingUpload = true;
      return;
    }
    final generation = _generation;
    _uploading = true;
    try {
      while (_initialized) {
        _check(generation);
        _pendingUpload = false;
        _status = AccountSyncStatus.syncing;
        notifyListeners();
        final snapshot = await _collectStableSnapshot(generation);
        _check(generation);
        final digest = computeSnapshotDigest(snapshot);
        if (digest != _lastSyncedDigest) {
          await _vault(generation)
              .uploadSnapshot(contents: snapshot, accountKey: _accountKey!, loginSecret: _loginSecret!);
          _check(generation);
          _lastSyncedDigest = digest;
          await _persist(generation);
          _check(generation);
        }
        final current = await _collectStableSnapshot(generation);
        _check(generation);
        _pendingUpload = computeSnapshotDigest(current) != digest;
        _status = _pendingUpload ? AccountSyncStatus.pending : AccountSyncStatus.synced;
        _lastError = null;
        notifyListeners();
        if (!_pendingUpload) break;
      }
    } on AccountOperationCancelled {
      if (_current(generation) && isSignedIn) {
        _pendingUpload = true;
        _status = AccountSyncStatus.pending;
        notifyListeners();
      }
    } catch (error) {
      if (!_current(generation)) return;
      _pendingUpload = true;
      _status = AccountSyncStatus.error;
      _lastError = classifyAccountError(error);
      notifyListeners();
    } finally {
      _uploading = false;
      // A newer sign-in may have queued work while an old generation unwound.
      if (!_current(generation) && !_disposed && _initialized && _pendingUpload) _scheduleUpload();
    }
  }

  Future<void> _pullAndImport(int generation) async {
    _check(generation);
    _initialized = false;
    _status = AccountSyncStatus.signingIn;
    notifyListeners();
    _suppressRepositoryEvents = true;
    final vault = _vault(generation);
    try {
      _check(generation);
      final transport = _activeTransport = connect(accountBox, MachineSecrets(password: _loginSecret!), (_) {}, (_) {});
      try {
        _check(generation);
        final exec = await transport.openExec('get');
        _check(generation);
        final lines = await exec.lines.toList();
        _check(generation);
        final code = await exec.exitCode;
        _check(generation);
        if (code == 3) throw const AccountProblem(AccountWords.nothingSaved);
        if (code != 0) throw AccountProblem(AccountWords.reachProblem('connection failed'));
        final contents = await openVault(lines.join('\n'), _accountKey!);
        _check(generation);
        await vault.importContents(contents);
        _check(generation);
        await _finishImport(generation, computeSnapshotDigest(contents));
        _check(generation);
      } finally {
        try {
          await transport.close();
        } catch (_) {
          /* Already cancelled or dropped. */
        }
      }
    } finally {
      if (_current(generation)) _suppressRepositoryEvents = false;
    }
  }

  Future<VaultContents> _collectStableSnapshot(int generation) async {
    while (true) {
      _check(generation);
      final startRev = _repoVersion;
      final profiles = [
        for (final m in machines.machines)
          if (m.id != 'form-draft') m,
      ];
      final secrets = <String, MachineSecrets>{};
      for (final m in profiles) {
        secrets[m.id] = await machines.secretsFor(m.id);
        _check(generation);
      }
      final settings = await settingsSync?.snapshot();
      _check(generation);
      if (startRev == _repoVersion) {
        return VaultContents(machines: profiles, secrets: secrets, settings: settings);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused || state == AppLifecycleState.inactive || state == AppLifecycleState.hidden) {
      _isBackgrounded = true;
      _debounceTimer?.cancel();
      if (_uploading || _status == AccountSyncStatus.pending) {
        _pendingUpload = true;
        _status = AccountSyncStatus.pending;
        notifyListeners();
      }
    } else if (state == AppLifecycleState.resumed) {
      _isBackgrounded = false;
      if (_restorePending) {
        init();
        return;
      }
      if (isSignedIn && _pendingUpload) _scheduleUpload();
      if (isSignedIn && !_initialized && !_signOutPending) retry();
    }
  }

  @override
  void dispose() {
    _cancelWork();
    _disposed = true;
    machines.removeListener(_onRepositoryChanged);
    settingsSync?.removeListener(_onSettingsChanged);
    settingsSync?.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }
}
