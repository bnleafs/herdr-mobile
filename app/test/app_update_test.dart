import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:herdr_mobile/data/app_info.dart';
import 'package:herdr_mobile/data/models/release_info.dart';
import 'package:herdr_mobile/data/repositories/app_update.dart';
import 'package:herdr_mobile/data/services/apk_installer.dart';
import 'package:herdr_mobile/fork/telemetry/envelope.dart';
import 'package:herdr_mobile/fork/telemetry/telemetry.dart';
import 'package:herdr_mobile/ui/core/kit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/update_fakes.dart';

class _CapturingSink implements TelemetrySink {
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

const _base = 'https://github.com/$appRepository/releases/download/v0.1.7';

ReleaseInfo _release([String version = '0.1.7']) => ReleaseInfo(
  version: version,
  apkUrl: '$_base/herdr-mobile-$version.apk',
  size: 1000,
  pageUrl: 'https://github.com/$appRepository/releases/tag/v$version',
  notes: '### Better\n\n- a thing',
  sha256: 'a' * 64,
);

Map<String, Object?> _github({String tag = 'v0.1.7', List<Map<String, Object?>>? assets}) => {
  'tag_name': tag,
  'html_url': 'https://github.com/$appRepository/releases/tag/$tag',
  'body': '  notes  ',
  'assets':
      assets ??
      [
        {'name': 'herdr-mobile-0.1.7.apk', 'size': 1000, 'browser_download_url': '$_base/herdr-mobile-0.1.7.apk'},
        {'name': 'SHA256SUMS', 'size': 90, 'browser_download_url': '$_base/SHA256SUMS'},
      ],
};

class _BrokenStore implements UpdateStore {
  @override
  Future<UpdateRecord> read() => Future.error(StateError('preferences unreadable'));

  @override
  Future<void> write(UpdateRecord record) => Future.error(StateError('preferences unreadable'));
}

void main() {
  group('release parsing', () {
    test('takes the APK named for the tag and its checksum file', () {
      final r = ReleaseInfo.fromGitHub(_github())!;
      expect(r.version, '0.1.7');
      expect(r.size, 1000);
      expect(r.apkUrl, '$_base/herdr-mobile-0.1.7.apk');
      expect(r.sumsUrl, '$_base/SHA256SUMS');
      expect(r.notes, 'notes');
    });

    test('prefers the digest GitHub states with the asset', () {
      final hex = 'ab' * 32;
      final r = ReleaseInfo.fromGitHub(
        _github(
          assets: [
            {
              'name': 'herdr-mobile-0.1.7.apk',
              'size': 5,
              'digest': 'sha256:${hex.toUpperCase()}',
              'browser_download_url': '$_base/herdr-mobile-0.1.7.apk',
            },
          ],
        ),
      )!;
      expect(r.sha256, hex);
    });

    test('never fetches from a host the release names outside the repository', () {
      final r = ReleaseInfo.fromGitHub(
        _github(
          assets: [
            {
              'name': 'herdr-mobile-0.1.7.apk',
              'size': 5,
              'browser_download_url': 'https://evil.example/herdr-mobile-0.1.7.apk',
            },
            {'name': 'SHA256SUMS', 'size': 5, 'browser_download_url': '$_base/SHA256SUMS'},
          ],
        ),
      );
      expect(r, isNull);
    });

    test('a release that is not x.y.z or has no APK is not offered', () {
      expect(ReleaseInfo.fromGitHub(_github(tag: 'v0.2.0-rc1')), isNull);
      expect(ReleaseInfo.fromGitHub(_github(assets: const [])), isNull);
    });

    test('an APK that cannot be checked is refused with a reason', () {
      expect(
        () => ReleaseInfo.fromGitHub(
          _github(
            assets: [
              {'name': 'herdr-mobile-0.1.7.apk', 'size': 5, 'browser_download_url': '$_base/herdr-mobile-0.1.7.apk'},
            ],
          ),
        ),
        throwsA(isA<UpdateException>()),
      );
    });

    test('files outside this repository\'s release downloads are never taken', () {
      String asset(String url) =>
          ReleaseInfo.fromGitHub(
                _github(
                  assets: [
                    {
                      'name': 'herdr-mobile-0.1.7.apk',
                      'size': 5,
                      'digest': 'sha256:${'a' * 64}',
                      'browser_download_url': url,
                    },
                  ],
                ),
              ) ==
              null
          ? 'refused'
          : 'taken';
      expect(asset('$_base/herdr-mobile-0.1.7.apk'), 'taken');
      expect(asset('$_base/../../../../other/repo/releases/download/v1/herdr-mobile-0.1.7.apk'), 'refused');
      expect(asset('$_base/herdr-mobile-0.1.7.apk?x=1'), 'refused');
      expect(
        asset('https://github.com:8443/$appRepository/releases/download/v0.1.7/herdr-mobile-0.1.7.apk'),
        'refused',
      );
      expect(
        asset('https://user@github.com/$appRepository/releases/download/v0.1.7/herdr-mobile-0.1.7.apk'),
        'refused',
      );
      expect(asset('https://github.com/other/repo/releases/download/v0.1.7/herdr-mobile-0.1.7.apk'), 'refused');
      expect(asset('http://github.com/$appRepository/releases/download/v0.1.7/herdr-mobile-0.1.7.apk'), 'refused');
    });

    test('a field of the wrong type is read as missing', () {
      final json = _github();
      expect(json['assets'], isA<List<Object?>>());
      expect(ReleaseInfo.fromGitHub({...json, 'tag_name': 7}), isNull);
      expect(ReleaseInfo.fromGitHub({...json, 'assets': 'x'}), isNull);
      expect(ReleaseInfo.fromGitHub({..._github(), 'body': 5})?.notes, '');
    });

    test('a remembered release survives a restart, but not tampering', () {
      final r = _release();
      expect(ReleaseInfo.decode(r.encode()), r);
      expect(ReleaseInfo.decode(r.encode().replaceAll('github.com', 'evil.example')), isNull);
      expect(ReleaseInfo.decode('not json'), isNull);
    });

    test('versions compare by number, not by text', () {
      final a = AppVersion.tryParse('v0.1.10')!;
      final b = AppVersion.tryParse('0.1.9')!;
      expect(a.compareTo(b), greaterThan(0));
      expect(AppVersion.tryParse('0.1'), isNull);
    });
  });

  group('AppUpdate', () {
    late FakeReleaseFeed feed;
    late FakeReleaseFiles files;
    late FakeApkInstaller installer;
    late MemoryUpdateStore store;
    late DateTime now;
    late AppUpdate update;

    setUp(() {
      feed = FakeReleaseFeed();
      files = FakeReleaseFiles();
      installer = FakeApkInstaller();
      store = MemoryUpdateStore(const UpdateRecord(autoDownload: false));
      now = DateTime(2026, 10, 9, 12);
      update = AppUpdate(
        store: store,
        feed: feed,
        files: files,
        installer: installer,
        current: AppVersion.tryParse('0.1.6'),
        now: () => now,
        autoDownload: false,
      );
    });

    tearDown(() => update.dispose());

    test('a newer release is suggested, remembered, and its notes are kept', () async {
      feed.answer = _release();
      await update.check();
      expect(update.release?.version, '0.1.7');
      expect(update.stage, UpdateStage.idle);
      expect(store.record.release?.version, '0.1.7');
      expect(feed.askedFor.toString(), '0.1.6');
    });

    test('nothing newer says so, and clears an earlier suggestion', () async {
      feed.answer = _release();
      await update.check();
      feed.answer = null;
      await update.check();
      expect(update.release, isNull);
      expect(update.upToDate, isTrue);
      expect(store.record.release, isNull);
    });

    test('a failed check the person asked for says why; a daily one stays silent', () async {
      feed.error = const UpdateException('Could not reach GitHub.');
      await update.check();
      expect(update.checkProblem, isNotNull);
      expect(update.stage, UpdateStage.idle);

      final quiet = AppUpdate(
        store: MemoryUpdateStore(),
        feed: feed,
        files: files,
        installer: installer,
        current: AppVersion.tryParse('0.1.6'),
        now: () => now,
      );
      addTearDown(quiet.dispose);
      await quiet.checkIfDue();
      expect(quiet.checkProblem, isNull);
    });

    test('the daily check waits out its interval, also after a failure', () async {
      feed.error = const UpdateException('offline');
      await update.checkIfDue();
      expect(feed.asked, 1);

      now = now.add(const Duration(minutes: 10));
      update.onLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(feed.asked, 1, reason: 'not due yet');

      now = now.add(const Duration(minutes: 55));
      await update.checkIfDue();
      expect(feed.asked, 2);
    });

    test('the daily check does nothing when the person turned it off, or is already offered an update', () async {
      await update.setAutoCheck(false);
      await update.checkIfDue();
      expect(feed.asked, 0);

      await update.setAutoCheck(true);
      expect(feed.asked, 1, reason: 'turning it on asks at once when due');
      await Future<void>.delayed(Duration.zero);
      feed.answer = _release();
      await update.check();
      now = now.add(const Duration(days: 2));
      final before = feed.asked;
      await update.checkIfDue();
      expect(feed.asked, before);
    });

    test('download reports progress, then is ready to install; install hands the file over', () async {
      feed.answer = _release();
      await update.check();

      final done = update.download();
      expect(update.stage, UpdateStage.downloading);
      files.report(400);
      expect(update.received, 400);
      files.running!.complete(File('/cache/updates/herdr-mobile-0.1.7.apk'));
      await done;
      expect(update.stage, UpdateStage.ready);

      await update.install();
      expect(installer.installed, ['/cache/updates/herdr-mobile-0.1.7.apk']);
      expect(update.needsInstallPermission, isFalse);
    });

    test('cancelling a download returns to Download with no error', () async {
      feed.answer = _release();
      await update.check();
      final done = update.download();
      update.cancelDownload();
      await done;
      expect(files.cancelled, isTrue);
      expect(update.stage, UpdateStage.idle);
      expect(update.problem, isNull);
      expect(update.release, isNotNull);
    });

    test('a failed download keeps the release and says what to do', () async {
      feed.answer = _release();
      await update.check();
      final done = update.download();
      files.running!.completeError(const UpdateException('The download stopped at 1 MB of 48 MB.'));
      await done;
      expect(update.stage, UpdateStage.idle);
      expect(update.problem, isNotNull);
      expect(update.release, isNotNull);
    });

    test('Install without the permission to install apps says so and can be tapped again', () async {
      feed.answer = _release();
      await update.check();
      final done = update.download();
      files.running!.complete(File('/x.apk'));
      await done;

      installer.answer = InstallStart.needsPermission;
      await update.install();
      expect(update.needsInstallPermission, isTrue);
      expect(update.stage, UpdateStage.ready);

      installer.answer = InstallStart.started;
      await update.install();
      expect(update.needsInstallPermission, isFalse);
      expect(installer.installed, hasLength(2));
    });

    test('a download that finished before a restart is ready at once', () async {
      store.record = UpdateRecord(release: _release());
      files.onPhone = File('/cache/updates/herdr-mobile-0.1.7.apk');
      await update.load();
      expect(update.release?.version, '0.1.7');
      expect(update.stage, UpdateStage.ready);
    });

    test('a failed check the person asked for is not a failed download: the panel button stays Download', () async {
      feed.answer = _release();
      await update.check();
      feed.error = const UpdateException('offline');
      await update.check();
      expect(update.checkProblem, isNotNull);
      expect(update.problem, isNull);
      expect(update.release, isNotNull);
    });

    test('a download that is not the release asks GitHub again before the next try', () async {
      feed.answer = _release();
      await update.check();
      final done = update.download();
      // The same version was published again, with another file.
      feed.answer = ReleaseInfo(
        version: '0.1.7',
        apkUrl: _release().apkUrl,
        size: 1200,
        pageUrl: _release().pageUrl,
        notes: 'again',
        sha256: 'b' * 64,
      );
      files.running!.completeError(const StaleRelease('The download did not match.'));
      await done;
      expect(feed.asked, 2);
      expect(update.release?.size, 1200);
      expect(update.problem, isNotNull, reason: 'the person still sees why it stopped');
      expect(update.stage, UpdateStage.idle);
    });

    test('Install never opens the installer on a file that is gone or was changed', () async {
      feed.answer = _release();
      await update.check();
      final done = update.download();
      files.running!.complete(File('/x.apk'));
      await done;

      files.intactAnswer = false;
      await update.install();
      expect(installer.installed, isEmpty);
      expect(update.stage, UpdateStage.idle);
      expect(update.problem, isNotNull);
      expect(update.release, isNotNull);
    });

    test('storage that cannot be read starts the updater empty instead of stopping the app', () async {
      final broken = AppUpdate(
        store: _BrokenStore(),
        feed: feed,
        files: files,
        installer: installer,
        current: AppVersion.tryParse('0.1.6'),
      );
      addTearDown(broken.dispose);
      await broken.load();
      expect(broken.release, isNull);
      expect(broken.stage, UpdateStage.idle);
    });

    test('after the update is installed the suggestion and its file are gone', () async {
      store.record = UpdateRecord(autoCheck: false, release: _release('0.1.6'));
      await update.load();
      expect(update.release, isNull);
      expect(store.record.release, isNull);
      expect(store.record.autoCheck, isFalse);
      expect(files.pruned, contains(null));
    });
  });

  group('automatic APK update checks and download', () {
    late FakeReleaseFeed feed;
    late FakeReleaseFiles files;
    late FakeApkInstaller installer;
    late MemoryUpdateStore store;
    late DateTime now;
    late AppUpdate autoUpdate;

    setUp(() {
      feed = FakeReleaseFeed();
      files = FakeReleaseFiles();
      installer = FakeApkInstaller();
      store = MemoryUpdateStore();
      now = DateTime(2026, 10, 9, 12);
      autoUpdate = AppUpdate(
        store: store,
        feed: feed,
        files: files,
        installer: installer,
        current: AppVersion.tryParse('0.1.6'),
        now: () => now,
      );
    });

    tearDown(() => autoUpdate.dispose());

    test('checking finds newer -> exactly1 automatic download -> verified Ready state', () async {
      feed.answer = _release('0.1.7');
      expect(autoUpdate.autoDownload, isTrue);
      expect(autoUpdate.stage, UpdateStage.idle);

      await autoUpdate.check();
      expect(autoUpdate.stage, UpdateStage.downloading);
      expect(files.running, isNotNull);

      files.running!.complete(File('/cache/updates/herdr-mobile-0.1.7.apk'));
      await Future<void>.delayed(Duration.zero);

      expect(autoUpdate.stage, UpdateStage.ready);
      expect(installer.installed, isEmpty, reason: 'install is never triggered silently');

      // Subsequent checks do not start duplicate downloads:
      await autoUpdate.check();
      expect(autoUpdate.stage, UpdateStage.ready);
    });

    test('off no download/manual still works', () async {
      await autoUpdate.setAutoDownload(false);
      expect(autoUpdate.autoDownload, isFalse);

      feed.answer = _release('0.1.7');
      await autoUpdate.check();
      expect(autoUpdate.stage, UpdateStage.idle);
      expect(files.running, isNull);
      expect(autoUpdate.release?.version, '0.1.7');

      final done = autoUpdate.download();
      expect(autoUpdate.stage, UpdateStage.downloading);
      expect(files.running, isNotNull);
      files.running!.complete(File('/cache/updates/herdr-mobile-0.1.7.apk'));
      await done;
      expect(autoUpdate.stage, UpdateStage.ready);
    });

    test('known/latest/no update: stays idle, no download', () async {
      feed.answer = null;
      await autoUpdate.check();
      expect(autoUpdate.stage, UpdateStage.idle);
      expect(autoUpdate.release, isNull);
      expect(autoUpdate.upToDate, isTrue);
      expect(files.running, isNull);
    });

    test('throttled resume: respects checkEvery interval and offered release guard', () async {
      feed.answer = _release('0.1.7');
      await autoUpdate.check();
      final asked = feed.asked;
      expect(asked, 1);

      autoUpdate.onLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(feed.asked, asked);

      now = now.add(const Duration(days: 1));
      autoUpdate.onLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(feed.asked, asked);
    });

    test('concurrent check/manual/download: cannot start simultaneous duplicate jobs', () async {
      feed.answer = _release('0.1.7');
      final checkFuture = autoUpdate.check();
      expect(autoUpdate.stage, UpdateStage.checking);

      await autoUpdate.check();
      expect(feed.asked, 1);

      await autoUpdate.download();
      expect(files.running, isNull);

      await checkFuture;
      expect(autoUpdate.stage, UpdateStage.downloading);
      final runningJob = files.running;

      await autoUpdate.download();
      expect(files.running, same(runningJob));

      await autoUpdate.check();
      expect(feed.asked, 1);
    });

    test('download error: no install and no automatic retry loop', () async {
      feed.answer = _release('0.1.7');
      await autoUpdate.check();
      expect(autoUpdate.stage, UpdateStage.downloading);

      files.running!.completeError(const UpdateException('Connection reset by peer'));
      await Future<void>.delayed(Duration.zero);

      expect(autoUpdate.stage, UpdateStage.idle);
      expect(autoUpdate.problem, 'Connection reset by peer');
      expect(installer.installed, isEmpty);

      now = now.add(const Duration(hours: 15));
      autoUpdate.onLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(autoUpdate.stage, UpdateStage.idle);

      final retryDone = autoUpdate.download();
      expect(autoUpdate.stage, UpdateStage.downloading);
      files.running!.complete(File('/cache/updates/herdr-mobile-0.1.7.apk'));
      await retryDone;
      expect(autoUpdate.stage, UpdateStage.ready);
    });

    test('download cancel: returns to idle with no error and no retry loop', () async {
      feed.answer = _release('0.1.7');
      await autoUpdate.check();
      expect(autoUpdate.stage, UpdateStage.downloading);

      autoUpdate.cancelDownload();
      await Future<void>.delayed(Duration.zero);

      expect(autoUpdate.stage, UpdateStage.idle);
      expect(autoUpdate.problem, isNull);
      expect(installer.installed, isEmpty);

      now = now.add(const Duration(hours: 15));
      autoUpdate.onLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(autoUpdate.stage, UpdateStage.idle);
    });

    test('download hash mismatch (stale release): no install and no retry loop', () async {
      feed.answer = _release('0.1.7');
      await autoUpdate.check();
      expect(autoUpdate.stage, UpdateStage.downloading);

      files.running!.completeError(const StaleRelease('SHA-256 digest did not match'));
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(autoUpdate.stage, UpdateStage.idle);
      expect(autoUpdate.problem, 'SHA-256 digest did not match');
      expect(installer.installed, isEmpty);
      expect(autoUpdate.stage, UpdateStage.idle);
    });

    test('restored Ready no duplicate: existing verified file on disk restores ready state', () async {
      final release = _release('0.1.7');
      files.onPhone = File('/cache/updates/herdr-mobile-0.1.7.apk');
      store.record = UpdateRecord(autoCheck: true, autoDownload: true, release: release);

      final fresh = AppUpdate(
        store: store,
        feed: feed,
        files: files,
        installer: installer,
        current: AppVersion.tryParse('0.1.6'),
      );
      addTearDown(fresh.dispose);

      await fresh.load();
      expect(fresh.stage, UpdateStage.ready);
      expect(fresh.release?.version, '0.1.7');
      expect(files.running, isNull, reason: 'must not trigger duplicate download on restore');
    });

    test('turning on autoDownload can start currently available release once', () async {
      await autoUpdate.setAutoDownload(false);
      feed.answer = _release('0.1.7');
      await autoUpdate.check();
      expect(autoUpdate.stage, UpdateStage.idle);
      expect(files.running, isNull);

      await autoUpdate.setAutoDownload(true);
      expect(autoUpdate.stage, UpdateStage.downloading);
      expect(files.running, isNotNull);

      files.running!.complete(File('/cache/updates/herdr-mobile-0.1.7.apk'));
      await Future<void>.delayed(Duration.zero);
      expect(autoUpdate.stage, UpdateStage.ready);
    });

    test('toggle off prevents new automatic download', () async {
      await autoUpdate.setAutoDownload(false);
      feed.answer = _release('0.1.7');
      await autoUpdate.check();
      expect(autoUpdate.stage, UpdateStage.idle);
      expect(files.running, isNull);
    });

    test('persistence backward compatible: old store missing autoDownload defaults to true', () async {
      SharedPreferences.setMockInitialValues({'update.auto.v1': false, 'update.lastCheck.v1': 1000});
      final prefsStore = PrefsUpdateStore();
      final record = await prefsStore.read();
      expect(record.autoCheck, isFalse);
      expect(record.autoDownload, isTrue, reason: 'missing autoDownload in prefs defaults to true');
    });

    test('explicit fork source: default is bnleafs/herdr-mobile', () {
      expect(appRepository, 'bnleafs/herdr-mobile');
      expect(appRepositoryUrl, 'https://github.com/bnleafs/herdr-mobile');
    });

    test('auto-install fires on background when ready and autoInstall is on', () async {
      feed.answer = _release('0.1.7');
      await autoUpdate.check();
      files.running!.complete(File('/cache/updates/herdr-mobile-0.1.7.apk'));
      await Future<void>.delayed(Duration.zero);
      expect(autoUpdate.stage, UpdateStage.ready);
      expect(installer.installed, isEmpty, reason: 'does not install in foreground');

      autoUpdate.onLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(Duration.zero);
      expect(installer.installed, ['/cache/updates/herdr-mobile-0.1.7.apk']);
    });

    test('auto-install does not fire when autoInstall is off', () async {
      await autoUpdate.setAutoInstall(false);
      feed.answer = _release('0.1.7');
      await autoUpdate.check();
      files.running!.complete(File('/cache/updates/herdr-mobile-0.1.7.apk'));
      await Future<void>.delayed(Duration.zero);
      expect(autoUpdate.stage, UpdateStage.ready);

      autoUpdate.onLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(Duration.zero);
      expect(installer.installed, isEmpty);
    });

    test('auto-install does not fire twice for the same version', () async {
      feed.answer = _release('0.1.7');
      await autoUpdate.check();
      files.running!.complete(File('/cache/updates/herdr-mobile-0.1.7.apk'));
      await Future<void>.delayed(Duration.zero);

      autoUpdate.onLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(Duration.zero);
      expect(installer.installed.length, 1);

      autoUpdate.onLifecycleState(AppLifecycleState.resumed);
      autoUpdate.onLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(Duration.zero);
      expect(installer.installed.length, 1, reason: 'at most one attempt per version');
    });

    test('auto-install does not fire when nothing is downloaded', () async {
      feed.answer = _release('0.1.7');
      await autoUpdate.check();
      expect(autoUpdate.stage, UpdateStage.downloading);

      autoUpdate.onLifecycleState(AppLifecycleState.paused);
      await Future<void>.delayed(Duration.zero);
      expect(installer.installed, isEmpty);
    });

    test(
      'cold start with ready APK installs right away if no session screen is open, but waits if one is open',
      () async {
        final release = _release('0.1.7');
        files.onPhone = File('/cache/updates/herdr-mobile-0.1.7.apk');
        store.record = UpdateRecord(release: release);

        // Session open: does not install right away
        final sessionOpenUpdate = AppUpdate(
          store: store,
          feed: feed,
          files: files,
          installer: installer,
          current: AppVersion.tryParse('0.1.0'),
        );
        addTearDown(sessionOpenUpdate.dispose);
        await sessionOpenUpdate.load();
        expect(sessionOpenUpdate.stage, UpdateStage.ready);
        await sessionOpenUpdate.maybeColdStartInstall(hasOpenSession: true);
        expect(installer.installed, isEmpty, reason: 'waits when session is open');

        sessionOpenUpdate.onLifecycleState(AppLifecycleState.paused);
        await Future<void>.delayed(Duration.zero);
        expect(installer.installed, ['/cache/updates/herdr-mobile-0.1.7.apk'], reason: 'installs on next background');

        // No session open: installs right away on cold start
        final freshInstaller = FakeApkInstaller();
        final noSessionUpdate = AppUpdate(
          store: store,
          feed: feed,
          files: files,
          installer: freshInstaller,
          current: AppVersion.tryParse('0.1.0'),
        );
        addTearDown(noSessionUpdate.dispose);
        await noSessionUpdate.load();
        await noSessionUpdate.maybeColdStartInstall(hasOpenSession: false);
        expect(freshInstaller.installed, ['/cache/updates/herdr-mobile-0.1.7.apk'], reason: 'installs on cold start');
      },
    );

    test('resume triggers a check only after 15 min', () async {
      feed.answer = null;
      await autoUpdate.check();
      expect(feed.asked, 1);

      now = now.add(const Duration(minutes: 14));
      autoUpdate.onLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(feed.asked, 1, reason: '14 min is within 15 min freshness');

      now = now.add(const Duration(minutes: 2));
      autoUpdate.onLifecycleState(AppLifecycleState.resumed);
      await Future<void>.delayed(Duration.zero);
      expect(feed.asked, 2, reason: '16 min triggers a resume check');
    });

    test('the toast shows once after a version change', () async {
      store.record = const UpdateRecord(lastRunVersion: '0.1.58');
      final updateWithBump = AppUpdate(
        store: store,
        feed: feed,
        files: files,
        installer: installer,
        current: AppVersion.tryParse('0.1.59'),
      );
      addTearDown(updateWithBump.dispose);
      await updateWithBump.load();

      expect(updateWithBump.updatedToVersion, '0.1.59');
      expect(updateWithBump.takeUpdatedToVersion(), '0.1.59');
      expect(updateWithBump.takeUpdatedToVersion(), isNull, reason: 'cleared on take');

      // Restart without version change: no toast
      final sameVersionUpdate = AppUpdate(
        store: store,
        feed: feed,
        files: files,
        installer: installer,
        current: AppVersion.tryParse('0.1.59'),
      );
      addTearDown(sameVersionUpdate.dispose);
      await sameVersionUpdate.load();
      expect(sameVersionUpdate.takeUpdatedToVersion(), isNull, reason: 'no toast when version unchanged');
    });

    test('takePendingUserAction returns true and clears flag when update is ready', () async {
      SharedPreferences.setMockInitialValues({'update.pendingUserAction.v1': true});
      feed.answer = _release('0.1.7');
      await autoUpdate.check();
      files.running!.complete(File('/cache/updates/herdr-mobile-0.1.7.apk'));
      await Future<void>.delayed(Duration.zero);
      expect(autoUpdate.stage, UpdateStage.ready);

      final needed = await autoUpdate.takePendingUserAction();
      expect(needed, isTrue);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('update.pendingUserAction.v1'), isNull, reason: 'flag cleared');

      // Second check returns false
      expect(await autoUpdate.takePendingUserAction(), isFalse);
    });

    test('takePendingUserAction returns false when no update is ready', () async {
      SharedPreferences.setMockInitialValues({'update.pendingUserAction.v1': true});
      expect(autoUpdate.stage, UpdateStage.idle);

      final needed = await autoUpdate.takePendingUserAction();
      expect(needed, isFalse, reason: 'not ready yet');

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('update.pendingUserAction.v1'), isTrue, reason: 'not cleared when not ready');
    });

    test('checkNativeInstallStatus reads, clears status and records telemetry on start', () async {
      final sink = _CapturingSink();
      final telemetry = ForkTelemetry.withSinks(sinks: [sink], enabled: true);
      ForkTelemetry.setTestInstance(telemetry);
      addTearDown(ForkTelemetry.resetInstance);

      SharedPreferences.setMockInitialValues({
        'update.installStatus.v1': 3,
        'update.installError.v1': 'INSTALL_FAILED_INVALID_APK',
      });

      final update = AppUpdate(
        store: store,
        feed: feed,
        files: files,
        installer: installer,
        current: AppVersion.tryParse('0.1.59'),
      );
      addTearDown(update.dispose);
      await update.load();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getInt('update.installStatus.v1'), isNull, reason: 'cleared status');
      expect(prefs.getString('update.installError.v1'), isNull, reason: 'cleared error');

      final installEvents = sink.milestones.where((m) => m.stage == TelemetryStage.appUpdateInstall).toList();
      expect(installEvents.length, 1);
      final event = installEvents.first;
      expect(event.stage, TelemetryStage.appUpdateInstall);
      expect(event.outcome, StageOutcome.failure);
      expect(event.errorString, 'status_3');
      final json = event.toJson();
      expect(
        json.values.toString().contains('INSTALL_FAILED_INVALID_APK'),
        isFalse,
        reason: 'error message text is not leaked in telemetry',
      );
    });

    testWidgets('foreground prompt displays toast with Install action and triggers installer', (tester) async {
      SharedPreferences.setMockInitialValues({'update.pendingUserAction.v1': true});
      feed.answer = _release('0.1.7');
      await autoUpdate.check();
      files.running!.complete(File('/cache/updates/herdr-mobile-0.1.7.apk'));
      await tester.pump();
      expect(autoUpdate.stage, UpdateStage.ready);

      final needed = await autoUpdate.takePendingUserAction();
      expect(needed, isTrue);

      late BuildContext ctx;
      await tester.pumpWidget(
        MaterialApp(
          theme: AppTheme.light(),
          navigatorObservers: [ToastRouteObserver()],
          home: Scaffold(
            body: Builder(
              builder: (context) {
                ctx = context;
                return const SizedBox.expand();
              },
            ),
          ),
        ),
      );

      final overlay = Overlay.of(ctx);
      Toaster(overlay).show(
        'Update v${autoUpdate.release!.version} is ready',
        action: ToastAction('Install', () => unawaited(autoUpdate.install())),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('Update v0.1.7 is ready'), findsOneWidget);
      expect(find.text('Install'), findsOneWidget);

      await tester.tap(find.text('Install'));
      await tester.pump();
      await tester.pump();
      expect(installer.installed, ['/cache/updates/herdr-mobile-0.1.7.apk']);

      await tester.pumpWidget(const SizedBox());
      await tester.pump(const Duration(seconds: 10));
    });
  });
}
