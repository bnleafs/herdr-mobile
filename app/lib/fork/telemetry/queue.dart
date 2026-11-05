import 'envelope.dart';

/// In-memory bounded queue for telemetry envelopes.
///
/// Limits:
/// - Maximum 200 events (FIFO eviction of oldest events).
/// - 24-hour time-to-live (TTL).
/// - Sliding window rate limiter: maximum 120 events per minute.
///
/// Contains NO disk persistence or shared_preferences backing.
class TelemetryQueue {
  TelemetryQueue({
    this.maxCapacity = 200,
    this.ttl = const Duration(hours: 24),
    this.maxPerMinute = 120,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  final int maxCapacity;
  final Duration ttl;
  final int maxPerMinute;
  final DateTime Function() _clock;

  final List<TelemetryEnvelope> _events = [];
  final List<DateTime> _recentTimestamps = [];

  int get length {
    _pruneExpired(_clock());
    return _events.length;
  }

  List<TelemetryEnvelope> get items {
    _pruneExpired(_clock());
    return List.unmodifiable(_events);
  }

  /// Attempts to enqueue [envelope].
  ///
  /// Returns `true` if accepted, `false` if dropped by the 120/minute rate limiter.
  /// If capacity is exceeded, the oldest event is evicted (FIFO).
  bool enqueue(TelemetryEnvelope envelope) {
    final now = _clock();
    _pruneExpired(now);

    // Sliding window rate limiter: max 120 per minute
    final oneMinuteAgo = now.subtract(const Duration(minutes: 1));
    _recentTimestamps.removeWhere((t) => t.isBefore(oneMinuteAgo));
    if (_recentTimestamps.length >= maxPerMinute) {
      return false; // Dropped by rate limiter
    }

    _recentTimestamps.add(now);

    // Bounded capacity: FIFO drop oldest
    while (_events.length >= maxCapacity) {
      _events.removeAt(0);
    }

    _events.add(envelope);
    return true;
  }

  /// Removes and returns the oldest valid envelope, or `null` if empty.
  TelemetryEnvelope? dequeue() {
    _pruneExpired(_clock());
    if (_events.isEmpty) return null;
    return _events.removeAt(0);
  }

  /// Clears all queued events and rate-limiter history.
  void clear() {
    _events.clear();
    _recentTimestamps.clear();
  }

  void _pruneExpired(DateTime now) {
    final cutoff = now.subtract(ttl);
    _events.removeWhere((e) => e.timestamp.isBefore(cutoff));
  }
}
