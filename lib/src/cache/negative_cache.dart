import '../thumbnail_exception.dart';

/// Short-lived in-memory memo of recent failures, keyed by cache file name.
///
/// During a fling, dozens of cells can ask for the same broken source; the
/// negative cache turns those into instant failures instead of repeated
/// network or decode attempts. Entries expire after [ttl].
///
/// [ThumbnailErrorCode.cancelled] is never stored: a cancelled prefetch must
/// not block a later visible request for the same key.
class NegativeCache {
  /// Creates a negative cache. [now] is injectable for tests.
  NegativeCache({required this.ttl, DateTime Function()? now})
    : _now = now ?? DateTime.now;

  /// How long a recorded failure keeps fast-failing lookups.
  final Duration ttl;

  final DateTime Function() _now;
  final Map<String, _Entry> _entries = {};

  /// Records [error] for [key], restarting its TTL.
  void record(String key, ThumbnailException error) {
    if (error.code == ThumbnailErrorCode.cancelled) return;
    _entries[key] = _Entry(error, _now().add(ttl));
  }

  /// Returns the memoized failure for [key], or null when absent or expired.
  ThumbnailException? lookup(String key) {
    final entry = _entries[key];
    if (entry == null) return null;
    if (!_now().isBefore(entry.expiry)) {
      _entries.remove(key);
      return null;
    }
    return entry.error;
  }

  /// Drops the entry for [key], if any.
  void remove(String key) => _entries.remove(key);

  /// Drops every entry whose key starts with [prefix] (source eviction).
  void removeByPrefix(String prefix) =>
      _entries.removeWhere((key, _) => key.startsWith(prefix));

  /// Drops everything.
  void clear() => _entries.clear();

  /// Number of live (possibly expired but unpruned) entries.
  int get length => _entries.length;
}

class _Entry {
  _Entry(this.error, this.expiry);
  final ThumbnailException error;
  final DateTime expiry;
}
