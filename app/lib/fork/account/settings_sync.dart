import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../data/repositories/app_settings.dart';
import '../../data/repositories/app_update.dart';
import '../../data/repositories/notification_settings.dart';
import '../../data/repositories/quick_phrases.dart';
import '../../data/repositories/terminal_settings.dart';

/// Allow-listed preference keys synchronized with the user account vault.
abstract final class SettingsSyncKeys {
  static const theme = 'theme';
  static const darkTerminal = 'darkTerminal';
  static const smoothText = 'smoothText';
  static const openAgentsAs = 'openAgentsAs';
  static const terminalFontSize = 'terminalFontSize';
  static const terminalWrap = 'terminalWrap';
  static const quickPhrases = 'quickPhrases';
  static const notificationEnabled = 'notificationEnabled';
  static const notificationAlsoDone = 'notificationAlsoDone';
  static const autoCheckUpdates = 'autoCheckUpdates';
  static const autoDownloadUpdates = 'autoDownloadUpdates';
  static const autoInstallUpdates = 'autoInstallUpdates';
  static const updatedAt = 'updatedAt';

  static const allowlist = {
    theme,
    darkTerminal,
    smoothText,
    openAgentsAs,
    terminalFontSize,
    terminalWrap,
    quickPhrases,
    notificationEnabled,
    notificationAlsoDone,
    autoCheckUpdates,
    autoDownloadUpdates,
    autoInstallUpdates,
    updatedAt,
  };
}

/// Synchronizes user preferences across devices through the account vault.
///
/// Follows last-writer-wins (LWW) per settings block based on [updatedAt].
/// Applies remote settings only when remote is newer than the local updatedAt.
/// A fresh install with no local history adopts remote settings immediately;
/// a phone with local modifications and an account without settings uploads its own.
class SettingsSync extends ChangeNotifier {
  SettingsSync({
    this.appSettings,
    this.terminalSettings,
    this.notificationSettings,
    this.quickPhrases,
    this.appUpdate,
    Future<SharedPreferences> Function()? getPrefs,
    DateTime Function()? clock,
  }) : _getPrefs = getPrefs ?? SharedPreferences.getInstance,
       _clock = clock ?? (() => DateTime.now().toUtc()) {
    _attachListeners();
  }

  static const localUpdatedAtKey = 'settings.sync.updatedAt.v1';

  static const _legacyPreferenceKeys = [
    'app.theme.v1',
    'app.darkTerminal.v1',
    'app.openAgentsAs.v1',
    'app.smoothText.v1',
    'terminal.fontSize.v1',
    'terminal.wrap.v1',
    'quickPhrases.v1',
    'notify.enabled.v1',
    'notify.alsoDone.v1',
    'update.autoCheck.v1',
    'update.autoDownload.v1',
  ];

  final AppSettings? appSettings;
  final TerminalSettings? terminalSettings;
  final NotificationSettings? notificationSettings;
  final QuickPhrases? quickPhrases;
  final AppUpdate? appUpdate;

  final Future<SharedPreferences> Function() _getPrefs;
  final DateTime Function() _clock;

  bool _initialized = false;
  bool _hasLocalHistory = false;
  DateTime? _localUpdatedAt;
  bool _applyingRemote = false;

  bool get hasLocalHistory => _hasLocalHistory;
  DateTime? get localUpdatedAt => _localUpdatedAt;
  bool get isApplyingRemote => _applyingRemote;

  void _attachListeners() {
    appSettings?.addListener(_onStoreChanged);
    terminalSettings?.addListener(_onStoreChanged);
    notificationSettings?.addListener(_onStoreChanged);
    quickPhrases?.addListener(_onStoreChanged);
    appUpdate?.addListener(_onStoreChanged);
  }

  void _detachListeners() {
    appSettings?.removeListener(_onStoreChanged);
    terminalSettings?.removeListener(_onStoreChanged);
    notificationSettings?.removeListener(_onStoreChanged);
    quickPhrases?.removeListener(_onStoreChanged);
    appUpdate?.removeListener(_onStoreChanged);
  }

  /// Loads the local settings timestamp or detects existing local preferences.
  Future<void> init() async {
    if (_initialized) return;
    try {
      final prefs = await _getPrefs();
      final savedTime = prefs.getString(localUpdatedAtKey);
      if (savedTime != null) {
        _localUpdatedAt = DateTime.tryParse(savedTime)?.toUtc();
        _hasLocalHistory = _localUpdatedAt != null;
      } else {
        final hasAny = _legacyPreferenceKeys.any(prefs.containsKey);
        if (hasAny) {
          _hasLocalHistory = true;
          _localUpdatedAt = DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);
        }
      }
    } catch (_) {}
    _initialized = true;
  }

  void _onStoreChanged() {
    if (_applyingRemote) return;
    _hasLocalHistory = true;
    _localUpdatedAt = _clock();
    unawaited(_saveLocalUpdatedAt());
    notifyListeners();
  }

  Future<void> _saveLocalUpdatedAt() async {
    if (_localUpdatedAt == null) return;
    try {
      final prefs = await _getPrefs();
      await prefs.setString(localUpdatedAtKey, _localUpdatedAt!.toIso8601String());
    } catch (_) {}
  }

  /// Builds a map of allow-listed preference keys to persist in [VaultContents].
  ///
  /// Returns null if the device has no local settings history and has never
  /// changed any preference.
  Future<Map<String, dynamic>?> snapshot() async {
    if (!_initialized) await init();
    if (!_hasLocalHistory) return null;

    final map = <String, dynamic>{};
    if (appSettings != null) {
      map[SettingsSyncKeys.theme] = appSettings!.theme.name;
      map[SettingsSyncKeys.darkTerminal] = appSettings!.darkTerminal;
      map[SettingsSyncKeys.smoothText] = appSettings!.smoothText;
      map[SettingsSyncKeys.openAgentsAs] = appSettings!.openAgentsAs.name;
    }
    if (terminalSettings != null) {
      map[SettingsSyncKeys.terminalFontSize] = terminalSettings!.fontSize;
      map[SettingsSyncKeys.terminalWrap] = terminalSettings!.wrap;
    }
    if (quickPhrases != null) {
      map[SettingsSyncKeys.quickPhrases] = List<String>.from(quickPhrases!.phrases);
    }
    if (notificationSettings != null) {
      map[SettingsSyncKeys.notificationEnabled] = notificationSettings!.enabled;
      map[SettingsSyncKeys.notificationAlsoDone] = notificationSettings!.alsoDone;
    }
    if (appUpdate != null) {
      map[SettingsSyncKeys.autoCheckUpdates] = appUpdate!.autoCheck;
      map[SettingsSyncKeys.autoDownloadUpdates] = appUpdate!.autoDownload;
      map[SettingsSyncKeys.autoInstallUpdates] = appUpdate!.autoInstall;
    }
    map[SettingsSyncKeys.updatedAt] = (_localUpdatedAt ?? _clock()).toIso8601String();
    return map;
  }

  /// Applies remote settings to local stores if remote is newer (LWW).
  ///
  /// Returns true if settings were applied, false if remote was ignored.
  Future<bool> applyRemote(Map<String, dynamic> remoteSettings) async {
    if (!_initialized) await init();

    final remoteUpdatedAtRaw = remoteSettings[SettingsSyncKeys.updatedAt];
    final remoteUpdatedAt = remoteUpdatedAtRaw is String ? DateTime.tryParse(remoteUpdatedAtRaw)?.toUtc() : null;

    final shouldApply =
        !_hasLocalHistory ||
        _localUpdatedAt == null ||
        (remoteUpdatedAt != null && remoteUpdatedAt.isAfter(_localUpdatedAt!));

    if (!shouldApply) return false;

    _applyingRemote = true;
    try {
      if (remoteSettings[SettingsSyncKeys.theme] case final String themeName) {
        for (final choice in ThemeChoice.values) {
          if (choice.name == themeName) {
            await appSettings?.setTheme(choice);
            break;
          }
        }
      }
      if (remoteSettings[SettingsSyncKeys.darkTerminal] case final bool dark) {
        await appSettings?.setDarkTerminal(dark);
      }
      if (remoteSettings[SettingsSyncKeys.smoothText] case final bool smooth) {
        await appSettings?.setSmoothText(smooth);
      }
      if (remoteSettings[SettingsSyncKeys.openAgentsAs] case final String openAsName) {
        for (final choice in OpenAgentsAs.values) {
          if (choice.name == openAsName) {
            await appSettings?.setOpenAgentsAs(choice);
            break;
          }
        }
      }
      if (remoteSettings[SettingsSyncKeys.terminalFontSize] case final num size) {
        await terminalSettings?.setFontSize(size.toDouble());
      }
      if (remoteSettings[SettingsSyncKeys.terminalWrap] case final bool wrap) {
        await terminalSettings?.setWrap(wrap);
      }
      if (remoteSettings[SettingsSyncKeys.quickPhrases] case final List rawPhrases) {
        final phrases = [
          for (final p in rawPhrases)
            if (p is String) p,
        ];
        await quickPhrases?.setPhrases(phrases);
      }
      if (remoteSettings[SettingsSyncKeys.notificationEnabled] case final bool enabled) {
        await notificationSettings?.setEnabled(enabled);
      }
      if (remoteSettings[SettingsSyncKeys.notificationAlsoDone] case final bool alsoDone) {
        await notificationSettings?.setAlsoDone(alsoDone);
      }
      if (remoteSettings[SettingsSyncKeys.autoCheckUpdates] case final bool autoCheck) {
        await appUpdate?.setAutoCheck(autoCheck);
      }
      if (remoteSettings[SettingsSyncKeys.autoDownloadUpdates] case final bool autoDownload) {
        await appUpdate?.setAutoDownload(autoDownload);
      }
      if (remoteSettings[SettingsSyncKeys.autoInstallUpdates] case final bool autoInstall) {
        await appUpdate?.setAutoInstall(autoInstall);
      }

      _hasLocalHistory = true;
      _localUpdatedAt = remoteUpdatedAt ?? _clock();
      await _saveLocalUpdatedAt();
      return true;
    } finally {
      _applyingRemote = false;
    }
  }

  @override
  void dispose() {
    _detachListeners();
    super.dispose();
  }
}
