import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:herdr_mobile/fork/telemetry/envelope.dart';
import 'package:herdr_mobile/fork/telemetry/telemetry.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'aside_models.dart';

/// Storage for Aside threads per session on the phone.
class AsideStorage {
  const AsideStorage({this.prefs});

  final SharedPreferences? prefs;

  static const maxThreads = 20;
  static const maxTurnsPerThread = 30;
  static const _keyPrefix = 'herdr_aside_threads_';
  static int _idCounter = 0;

  String _storageKey(String sessionKey) => '$_keyPrefix$sessionKey';

  Future<SharedPreferences> _getPrefs() async => prefs ?? await SharedPreferences.getInstance();

  /// Loads threads for [sessionKey], newest first.
  Future<List<AsideThread>> loadThreads(String sessionKey) async {
    final sp = await _getPrefs();
    final raw = sp.getString(_storageKey(sessionKey));
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is! List) return const [];
      final threads = decoded.whereType<Map<String, dynamic>>().map(AsideThread.fromJson).toList();
      // Ensure newest first.
      threads.sort((a, b) => b.updatedAt.compareTo(a.updatedAt));
      return threads;
    } catch (e) {
      debugPrint('Failed to decode aside threads for $sessionKey: $e');
      return const [];
    }
  }

  /// Saves a turn to thread with [threadId], creating the thread if needed.
  /// Caps threads at 20 and turns at 30.
  Future<AsideThread> recordTurn({required String sessionKey, String? threadId, required AsideTurn turn}) async {
    final sp = await _getPrefs();
    final threads = (await loadThreads(sessionKey)).toList();
    final now = DateTime.now();

    AsideThread thread;
    final existingIdx = threadId != null ? threads.indexWhere((t) => t.id == threadId) : -1;

    if (existingIdx != -1) {
      final old = threads.removeAt(existingIdx);
      final updatedTurns = [...old.turns, turn];
      final cappedTurns = updatedTurns.length > maxTurnsPerThread
          ? updatedTurns.sublist(updatedTurns.length - maxTurnsPerThread)
          : updatedTurns;
      thread = old.copyWith(turns: cappedTurns, updatedAt: now);
    } else {
      final newId = threadId ?? 'aside-thread-${now.microsecondsSinceEpoch}-${++_idCounter}';
      thread = AsideThread(id: newId, turns: [turn], createdAt: now, updatedAt: now);
    }

    threads.insert(0, thread);
    if (threads.length > maxThreads) {
      threads.removeRange(maxThreads, threads.length);
    }

    final encoded = jsonEncode(threads.map((t) => t.toJson()).toList());
    await sp.setString(_storageKey(sessionKey), encoded);
    return thread;
  }

  /// Deletes one thread by [threadId].
  Future<void> clearThread(String sessionKey, String threadId) async {
    final sp = await _getPrefs();
    final threads = (await loadThreads(sessionKey)).toList();
    threads.removeWhere((t) => t.id == threadId);

    if (threads.isEmpty) {
      await sp.remove(_storageKey(sessionKey));
    } else {
      final encoded = jsonEncode(threads.map((t) => t.toJson()).toList());
      await sp.setString(_storageKey(sessionKey), encoded);
    }

    ForkTelemetry.instance.recordStage(
      opId: 'aside-clear-${DateTime.now().millisecondsSinceEpoch}',
      stage: TelemetryStage.asideClear,
      outcome: StageOutcome.success,
    );
  }

  /// Deletes all threads for [sessionKey].
  Future<void> clearAll(String sessionKey) async {
    final sp = await _getPrefs();
    await sp.remove(_storageKey(sessionKey));

    ForkTelemetry.instance.recordStage(
      opId: 'aside-clear-all-${DateTime.now().millisecondsSinceEpoch}',
      stage: TelemetryStage.asideClear,
      outcome: StageOutcome.success,
    );
  }
}
