import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleState;
import 'package:shared_preferences/shared_preferences.dart';

import '../app_info.dart';
import '../models/release_info.dart';
import '../services/apk_installer.dart';
import '../services/release_feed.dart';
import '../services/release_files.dart';
import '../../fork/telemetry/envelope.dart';
import '../../fork/telemetry/telemetry.dart';

/// What is remembered between launches: the person's choice, when GitHub was
/// last asked, and the newer release it named (so the suggestion is still
/// there after a restart, until it is installed).
@immutable
class UpdateRecord {
  const UpdateRecord({
    this.autoCheck = true,
    this.autoDownload = true,
    this.autoInstall = true,
    this.lastCheck,
    this.release,
    this.lastRunVersion,
  });

  final bool autoCheck;
  final bool autoDownload;
  final bool autoInstall;
  final DateTime? lastCheck;
  final ReleaseInfo? release;
  final String? lastRunVersion;
}

abstract interface class UpdateStore {
  Future<UpdateRecord> read();

  Future<void> write(UpdateRecord record);
}

class PrefsUpdateStore implements UpdateStore {
  static const _auto = 'update.auto.v1';
  static const _autoDownload = 'update.autoDownload.v1';
  static const _autoInstall = 'update.autoInstall.v1';
  static const _last = 'update.lastCheck.v1';
  static const _release = 'update.release.v1';
  static const _lastRun = 'update.lastRunVersion.v1';

  @override
  Future<UpdateRecord> read() async {
    final prefs = await SharedPreferences.getInstance();
    final at = prefs.getInt(_last);
    return UpdateRecord(
      autoCheck: prefs.getBool(_auto) ?? true,
      autoDownload: prefs.getBool(_autoDownload) ?? true,
      autoInstall: prefs.getBool(_autoInstall) ?? true,
      lastCheck: at == null ? null : DateTime.fromMillisecondsSinceEpoch(at),
      release: ReleaseInfo.decode(prefs.getString(_release)),
      lastRunVersion: prefs.getString(_lastRun),
    );
  }

  @override
  Future<void> write(UpdateRecord record) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_auto, record.autoCheck);
    await prefs.setBool(_autoDownload, record.autoDownload);
    await prefs.setBool(_autoInstall, record.autoInstall);
    final at = record.lastCheck;
    if (at == null) {
      await prefs.remove(_last);
    } else {
      await prefs.setInt(_last, at.millisecondsSinceEpoch);
    }
    final release = record.release;
    if (release == null) {
      await prefs.remove(_release);
    } else {
      await prefs.setString(_release, release.encode());
    }
    final lastRun = record.lastRunVersion;
    if (lastRun == null) {
      await prefs.remove(_lastRun);
    } else {
      await prefs.setString(_lastRun, lastRun);
    }
  }
}

/// For tests.
class MemoryUpdateStore implements UpdateStore {
  MemoryUpdateStore([this.record = const UpdateRecord()]);

  UpdateRecord record;

  @override
  Future<UpdateRecord> read() async => record;

  @override
  Future<void> write(UpdateRecord record) async => this.record = record;
}

enum UpdateStage {
  /// Nothing running: up to date, or a newer [AppUpdate.release] waiting.
  idle,

  /// Asking GitHub for the newest release.
  checking,

  /// Downloading [AppUpdate.release]'s APK; [AppUpdate.received] bytes so far.
  downloading,

  /// The APK is on the phone and its checksum matched: Install is next.
  ready,
}

/// Looking for a newer herdr mobile on GitHub, downloading it and handing it
/// to Android's installer: the app's own update, for a phone that installs
/// from the release page by hand.
///
/// Quiet by design: an update is never an interruption. It shows as a dot on
/// home's Settings gear and a panel at the top of Settings, never a toast or a
/// notification. GitHub is asked once a [checkEvery] while the app is in
/// front (and the person allows it), or at once on request; the APK is
/// downloaded only when the person taps Download, and installed only after
/// their confirmation in Android's own dialog.
class AppUpdate extends ChangeNotifier {
  AppUpdate({
    required this.store,
    required this.feed,
    required this.files,
    required this.installer,
    AppVersion? current,
    DateTime Function()? now,
    this._autoDownload = true,
    this._autoInstall = true,
  }) : _current = current ?? AppVersion.tryParse(appVersion)!,
       _now = now ?? DateTime.now;

  /// How long a check stays fresh. Also the wait after a failed one: a phone
  /// on a bad radio is not asked again every time the app is opened.
  static const checkEvery = Duration(hours: 1);

  /// How old the last check must be for an app resume to trigger another check.
  static const resumeCheckFreshness = Duration(minutes: 15);

  final UpdateStore store;
  final ReleaseFeed feed;
  final ReleaseFiles files;
  final ApkInstaller installer;
  final AppVersion _current;
  final DateTime Function() _now;

  bool _autoCheck = true;
  bool _autoDownload;
  bool _autoInstall;
  DateTime? _lastCheck;
  ReleaseInfo? _release;
  UpdateStage _stage = UpdateStage.idle;
  int _received = 0;
  String? _problem;
  String? _checkProblem;
  bool _upToDate = false;
  bool _needsPermission = false;
  bool _installing = false;
  File? _apk;
  UpdateDownload? _job;
  String? _autoDownloadedVersion;
  String? _autoInstalledVersion;
  String? _updatedToVersion;
  bool _disposed = false;

  /// Whether GitHub is asked about twice a day without the person asking.
  bool get autoCheck => _autoCheck;

  /// Whether a newer version is downloaded automatically once found.
  bool get autoDownload => _autoDownload;

  /// Whether a verified newer version is installed automatically.
  bool get autoInstall => _autoInstall;

  /// The version updated to on the first launch of a new version, or null.
  String? get updatedToVersion => _updatedToVersion;

  /// The verified APK on disk, or null.
  File? get apk => _apk;

  /// Retrieves and clears the version updated to, so the toast shows once.
  String? takeUpdatedToVersion() {
    final version = _updatedToVersion;
    _updatedToVersion = null;
    return version;
  }

  static const _pendingUserActionKey = 'update.pendingUserAction.v1';
  static const _installStatusKey = 'update.installStatus.v1';
  static const _installErrorKey = 'update.installError.v1';

  /// Whether Android reported that user confirmation is needed for the
  /// downloaded APK (e.g. because silent install was blocked in background).
  /// If set and a verified APK is ready, clears the flag and returns true.
  Future<bool> takePendingUserAction() async {
    if (_stage != UpdateStage.ready || _release == null || _apk == null) {
      return false;
    }
    try {
      final prefs = await SharedPreferences.getInstance();
      final pending = prefs.getBool(_pendingUserActionKey) ?? false;
      if (pending) {
        await prefs.remove(_pendingUserActionKey);
        return true;
      }
    } on Object {
      // Best-effort.
    }
    return false;
  }

  /// The newer release the person can install, or null.
  ReleaseInfo? get release => _release;

  UpdateStage get stage => _stage;

  /// Bytes of [release] received while [stage] is downloading.
  int get received => _received;

  /// What went wrong in the last download or install, in words for the
  /// person. Cleared by the next step.
  String? get problem => _problem;

  /// Why the last check the person asked for failed (a check that runs by
  /// itself stays silent). Kept apart from [problem]: a failed check must
  /// never turn the panel's button into a 50 MB retry.
  String? get checkProblem => _checkProblem;

  /// The last check found nothing newer than this version.
  bool get upToDate => _upToDate && _release == null;

  /// Install was tapped before Android allowed this app to install apps: the
  /// page that allows it is open, and Install works once it is allowed.
  bool get needsInstallPermission => _needsPermission;

  /// Reads what was remembered. Before the first frame: the suggestion is
  /// there from the start.
  Future<void> load() async {
    try {
      final saved = await store.read();
      _autoCheck = saved.autoCheck;
      _autoDownload = saved.autoDownload;
      _autoInstall = saved.autoInstall;
      _lastCheck = saved.lastCheck;
      final lastRun = saved.lastRunVersion;
      if (lastRun != null && lastRun != _current.toString()) {
        _updatedToVersion = _current.toString();
      }
      final release = saved.release;
      if (release != null) {
        final known = AppVersion.tryParse(release.version)!;
        if (known.compareTo(_current) <= 0) {
          // Installed (or older than what is installed): its file is not needed.
          unawaited(files.prune());
        } else {
          _release = release;
          _apk = await files.verified(release);
          if (_apk != null) _stage = UpdateStage.ready;
          unawaited(files.prune(keep: release));
        }
      }
      await _save();
    } on Object {
      // Looking for updates is never worth keeping the person from their
      // agents: unreadable preferences or storage start it as if new.
    } finally {
      await checkNativeInstallStatus();
    }
  }

  Future<void> checkNativeInstallStatus() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final status = prefs.getInt(_installStatusKey);
      if (status != null) {
        await prefs.remove(_installStatusKey);
        await prefs.remove(_installErrorKey);
        ForkTelemetry.instance.recordStage(
          opId: ForkTelemetry.instance.generateOpId(),
          stage: TelemetryStage.appUpdateInstall,
          outcome: StageOutcome.failure,
          errorString: 'status_$status',
        );
      }
    } on Object {
      // Native install status is best-effort.
    }
  }

  Future<void> setAutoCheck(bool on) async {
    if (on == _autoCheck) return;
    _autoCheck = on;
    _notify();
    await _save();
    if (on) unawaited(checkIfDue());
  }

  Future<void> setAutoDownload(bool on) async {
    if (on == _autoDownload) return;
    _autoDownload = on;
    _notify();
    await _save();
    if (on && _release != null && _apk == null && _stage == UpdateStage.idle) {
      _autoDownloadedVersion = null;
      unawaited(download());
    }
  }

  Future<void> setAutoInstall(bool on) async {
    if (on == _autoInstall) return;
    _autoInstall = on;
    _notify();
    await _save();
  }

  /// The app came to the front or background.
  void onLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      unawaited(checkIfDue(freshness: resumeCheckFreshness));
    } else if (state == AppLifecycleState.paused || state == AppLifecycleState.hidden) {
      maybeAutoInstall();
    }
  }

  /// Installs a verified APK automatically in the background.
  void maybeAutoInstall() {
    if (!_autoInstall || _disposed || _installing) return;
    final release = _release;
    final apk = _apk;
    if (_stage != UpdateStage.ready || release == null || apk == null) return;
    if (_autoInstalledVersion == release.version) return;
    _autoInstalledVersion = release.version;
    unawaited(install(auto: true));
  }

  /// Installs a ready APK on cold start if no session screen is open.
  Future<void> maybeColdStartInstall({required bool hasOpenSession}) async {
    if (!_autoInstall || _disposed || _installing || hasOpenSession) return;
    final release = _release;
    final apk = _apk;
    if (_stage != UpdateStage.ready || release == null || apk == null) return;
    if (_autoInstalledVersion == release.version) return;
    _autoInstalledVersion = release.version;
    await install(auto: true);
  }

  Future<void> checkIfDue({Duration? freshness}) async {
    if (!_autoCheck || _stage != UpdateStage.idle || _release != null) return;
    final last = _lastCheck;
    final interval = freshness ?? checkEvery;
    if (last != null && _now().difference(last) < interval) return;
    await check(manual: false);
  }

  /// Asks GitHub for the newest release. A request by the person ([manual])
  /// says why it failed; a daily one stays silent and tries again later.
  Future<void> check({bool manual = true}) async {
    if (_stage != UpdateStage.idle) return;
    _stage = UpdateStage.checking;
    if (manual) _checkProblem = null;
    _notify();
    final stopwatch = Stopwatch()..start();
    var outcome = StageOutcome.upToDate;
    try {
      final found = await feed.newerThan(_current);
      if (_disposed) return;
      if (found == null) {
        outcome = StageOutcome.upToDate;
        _release = null;
        _apk = null;
        _upToDate = true;
        _problem = null;
        _autoDownloadedVersion = null;
        unawaited(files.prune());
      } else {
        outcome = StageOutcome.foundUpdate;
        if (found != _release) {
          _release = found;
          _upToDate = false;
          _problem = null;
          _autoDownloadedVersion = null;
          _apk = await files.verified(found);
          unawaited(files.prune(keep: found));
        }
      }
      _checkProblem = null;
    } on Object catch (e) {
      outcome = StageOutcome.failure;
      if (manual) _checkProblem = e is UpdateException ? e.message : 'Couldn’t look for updates.';
    } finally {
      ForkTelemetry.instance.recordStage(
        opId: ForkTelemetry.instance.generateOpId(),
        stage: TelemetryStage.appUpdateCheck,
        durationMs: stopwatch.elapsedMilliseconds,
        outcome: outcome,
      );
      if (!_disposed) {
        _lastCheck = _now();
        _stage = _apk != null && _release != null ? UpdateStage.ready : UpdateStage.idle;
        _notify();
        await _save();
        _maybeAutoDownload();
      }
    }
  }

  void _maybeAutoDownload() {
    if (!_autoDownload || _disposed) return;
    final release = _release;
    if (release == null || _apk != null || _stage != UpdateStage.idle) return;
    if (_autoDownloadedVersion == release.version) return;
    _autoDownloadedVersion = release.version;
    unawaited(download());
  }

  /// Downloads [release]'s APK and checks it. The person's tap: it costs
  /// [ReleaseInfo.size] bytes of whatever connection the phone is on.
  Future<void> download() async {
    final release = _release;
    if (release == null || _stage != UpdateStage.idle) return;
    _stage = UpdateStage.downloading;
    _received = 0;
    _problem = null;
    _needsPermission = false;
    _autoDownloadedVersion = release.version;
    _notify();
    final stopwatch = Stopwatch()..start();
    var outcome = StageOutcome.success;
    final job = _job = files.download(release, (n) {
      if (!_disposed) {
        _received = n;
        _notify();
      }
    });
    var stale = false;
    try {
      final apk = await job.done;
      if (_disposed) return;
      _apk = apk;
      _stage = UpdateStage.ready;
    } on UpdateCancelled {
      outcome = StageOutcome.cancelled;
      if (_disposed) return;
      _stage = UpdateStage.idle;
    } on StaleRelease catch (e) {
      outcome = StageOutcome.failure;
      if (_disposed) return;
      _stage = UpdateStage.idle;
      _problem = e.message;
      stale = true;
    } on UpdateException catch (e) {
      outcome = StageOutcome.failure;
      if (_disposed) return;
      _stage = UpdateStage.idle;
      _problem = e.message;
    } finally {
      ForkTelemetry.instance.recordStage(
        opId: ForkTelemetry.instance.generateOpId(),
        stage: TelemetryStage.appUpdateDownload,
        durationMs: stopwatch.elapsedMilliseconds,
        outcome: outcome,
      );
      _job = null;
      if (!_disposed) _notify();
    }
    // The release was probably published again under the same tag: read it
    // again now (one small request), so the next Download is for what is
    // there, not another 50 MB for the old description of it.
    if (stale && !_disposed) await _refresh();
  }

  Future<void> _refresh() async {
    final message = _problem;
    await check(manual: false);
    // A check clears what it is not about; the download's reason stays.
    if (_release != null) {
      _problem = message;
      _notify();
    }
  }

  /// Stops a download. What was received is kept for the next try.
  void cancelDownload() => _job?.cancel();

  /// Opens Android's installer on the verified APK. Without the permission to
  /// install apps Android's page for it opens instead, and Install is tapped
  /// again once it is allowed.
  Future<void> install({bool auto = false}) async {
    final release = _release;
    final apk = _apk;
    if (_stage != UpdateStage.ready || release == null || apk == null || _installing) return;
    _installing = true;
    _problem = null;
    _needsPermission = false;
    final stopwatch = Stopwatch()..start();
    var outcome = auto ? StageOutcome.silent : StageOutcome.confirmed;
    String? statusCode;
    try {
      // Android may have cleared the cache, or something cut the file, since
      // it was verified: say so and offer the download again, rather than
      // open an installer on bytes that are not the release.
      if (!await files.intact(release, apk)) {
        _apk = null;
        _stage = UpdateStage.idle;
        _problem = 'The update file is gone or changed. Download it again.';
        outcome = StageOutcome.failure;
        statusCode = 'file_tampered';
      } else {
        final result = await installer.install(apk);
        if (result == InstallStart.needsPermission) {
          _needsPermission = true;
          outcome = StageOutcome.pendingUserAction;
        }
      }
    } on UpdateException catch (e) {
      outcome = StageOutcome.failure;
      _problem = e.message;
      statusCode = 'installer_error';
    } finally {
      _installing = false;
      _notify();
      ForkTelemetry.instance.recordStage(
        opId: ForkTelemetry.instance.generateOpId(),
        stage: TelemetryStage.appUpdateInstall,
        durationMs: stopwatch.elapsedMilliseconds,
        outcome: outcome,
        errorString: statusCode,
      );
    }
  }

  Future<void> _save() => store.write(
    UpdateRecord(
      autoCheck: _autoCheck,
      autoDownload: _autoDownload,
      autoInstall: _autoInstall,
      lastCheck: _lastCheck,
      release: _release,
      lastRunVersion: _current.toString(),
    ),
  );

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _job?.cancel();
    super.dispose();
  }
}
