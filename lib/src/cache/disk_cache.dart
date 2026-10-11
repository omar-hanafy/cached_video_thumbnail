import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;

import '../thumbnail_exception.dart';
import 'cache_key.dart';

/// A committed cache entry: where the file is and what it contains.
@immutable
class CachedThumbnail {
  /// Creates an entry description.
  const CachedThumbnail({
    required this.path,
    required this.width,
    required this.height,
  });

  /// Absolute path of the encoded image.
  final String path;

  /// Encoded width in pixels.
  final int width;

  /// Encoded height in pixels.
  final int height;
}

/// LRU disk cache of encoded thumbnail files.
///
/// Design rules that keep the request hot path cheap:
/// - The index is fully in memory after [init]; [lookup] performs no disk
///   stat. (If the OS purges a file mid-session, the decode layer detects it
///   and evicts the entry.)
/// - Writers never write final names directly: natives fill an engine-chosen
///   `<name>.<rand>.part` temp file that [commit] renames atomically.
///   Crash leftovers are deleted during [init].
/// - Image dimensions are encoded in the on-disk file name
///   (`<hashes>.<w>x<h>.<ext>`), so cache hits know their size in any
///   session without decoding a single byte.
/// - Eviction runs asynchronously after commits, never blocking a request.
///
/// LRU order approximately survives restarts: hits refresh the in-memory
/// recency immediately and push it to the file mtime at most once per
/// [touchThrottle].
class DiskCache {
  /// Creates a cache rooted at [directory]. [now] is injectable for tests.
  DiskCache({
    required this.directory,
    required this.maxBytes,
    required this.maxEntries,
    this.touchThrottle = const Duration(hours: 1),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  /// Root directory; created by [init].
  final Directory directory;

  /// Soft cap on total cached bytes; eviction targets 90% of it.
  final int maxBytes;

  /// Soft cap on the number of entries; eviction targets 90% of it.
  final int maxEntries;

  /// Minimum interval between mtime writes for the same entry.
  final Duration touchThrottle;

  /// On-disk names look like `<16 hex>-<24 hex>.<w>x<h>.<jpg|png>`.
  static final RegExp _fileNamePattern = RegExp(
    r'^([a-f0-9]{16}-[a-f0-9]{24})\.(\d+)x(\d+)\.(jpg|png)$',
  );

  final DateTime Function() _now;
  final Random _random = Random();

  /// Keyed by the [CacheKey.fileName] (which has no dims segment).
  final Map<String, _Entry> _index = {};
  int _totalBytes = 0;
  Future<void>? _evictionRun;
  Future<void> _mutationTail = Future<void>.value();

  /// Total bytes accounted in the index.
  int get totalBytes => _totalBytes;

  /// Number of committed entries.
  int get entryCount => _index.length;

  /// Creates the directory, deletes orphaned `.part` files and unrecognized
  /// names, and builds the in-memory index from the files on disk.
  Future<void> init() async {
    await directory.create(recursive: true);
    await for (final entity in directory.list()) {
      if (entity is! File) continue;
      final name = p.basename(entity.path);
      final match = _fileNamePattern.firstMatch(name);
      if (match == null) {
        // Orphan .part file or foreign leftover; this directory is our
        // versioned namespace, so anything unrecognized is dead weight.
        try {
          await entity.delete();
        } on FileSystemException {
          // Best-effort.
        }
        continue;
      }
      final stat = await entity.stat();
      final accessMs = stat.modified.millisecondsSinceEpoch;
      _index['${match[1]}.${match[4]}'] = _Entry(
        fullName: name,
        size: stat.size,
        width: int.parse(match[2]!),
        height: int.parse(match[3]!),
        lastAccessMs: accessMs,
        lastTouchMs: accessMs,
      );
      _totalBytes += stat.size;
    }
  }

  /// Returns the entry for [key] if cached, refreshing its recency.
  /// Performs no disk I/O beyond an occasional throttled mtime touch.
  CachedThumbnail? lookup(CacheKey key) {
    final entry = _index[key.fileName];
    if (entry == null) return null;
    final now = _now();
    entry.lastAccessMs = now.millisecondsSinceEpoch;
    final path = _pathOf(entry.fullName);
    if (now.millisecondsSinceEpoch - entry.lastTouchMs >=
        touchThrottle.inMilliseconds) {
      entry.lastTouchMs = now.millisecondsSinceEpoch;
      try {
        File(path).setLastModifiedSync(now);
      } on FileSystemException {
        // Best-effort; recency survives in memory for this session anyway.
      }
    }
    return CachedThumbnail(
      path: path,
      width: entry.width,
      height: entry.height,
    );
  }

  /// Reserves a unique temp path for [key] inside the cache directory.
  String tempPathFor(CacheKey key) {
    final rand = _random.nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    return _pathOf('${key.fileName}.$rand.part');
  }

  /// Atomically publishes [tempPath] as the entry for [key] and returns the
  /// final path. Triggers asynchronous eviction when over the caps.
  Future<String> commit(
    CacheKey key,
    String tempPath, {
    required int width,
    required int height,
  }) => _serialize(() => _commit(key, tempPath, width: width, height: height));

  Future<String> _commit(
    CacheKey key,
    String tempPath, {
    required int width,
    required int height,
  }) async {
    final dot = key.fileName.lastIndexOf('.');
    final fullName =
        '${key.fileName.substring(0, dot)}.${width}x$height${key.fileName.substring(dot)}';
    final finalPath = _pathOf(fullName);
    final int size;
    try {
      size = await File(tempPath).length();
      await File(tempPath).rename(finalPath);
    } on FileSystemException catch (e) {
      throw ThumbnailException(
        ThumbnailErrorCode.io,
        'failed to publish cache entry ${key.fileName}',
        cause: e,
      );
    }
    final previous = _index[key.fileName];
    if (previous != null) {
      _totalBytes -= previous.size;
    }
    final nowMs = _now().millisecondsSinceEpoch;
    _index[key.fileName] = _Entry(
      fullName: fullName,
      size: size,
      width: width,
      height: height,
      lastAccessMs: nowMs,
      lastTouchMs: nowMs,
    );
    _totalBytes += size;
    // Publish the new index entry before removing the previous file so a
    // lookup during asynchronous cleanup never receives a deleted old path.
    if (previous != null && previous.fullName != fullName) {
      try {
        await File(_pathOf(previous.fullName)).delete();
      } on FileSystemException {
        // Already gone.
      }
    }
    if (_totalBytes > maxBytes || _index.length > maxEntries) {
      unawaited(evictIfNeeded());
    }
    return finalPath;
  }

  /// Removes the entry for [key] (used when a cached file turns out to be
  /// unreadable, e.g. purged or corrupted externally).
  Future<void> remove(CacheKey key) =>
      _serialize(() => _deleteEntry(key.fileName));

  /// Deletes every entry whose name starts with [sourcePrefix].
  Future<void> evictSource(String sourcePrefix) => _serialize(() async {
    final names = _index.keys.where((n) => n.startsWith(sourcePrefix)).toList();
    for (final name in names) {
      await _deleteEntry(name);
    }
  });

  /// Deletes all committed entries and stray files, preserving temporary
  /// outputs still owned by active extraction workers.
  Future<void> clear() => _serialize(() async {
    final names = _index.keys.toList();
    for (final name in names) {
      await _deleteEntry(name);
    }
    // Temporary outputs may still have a live writer. The worker cleans up
    // failures; startup removes parts left by a previous process.
    if (directory.existsSync()) {
      await for (final entity in directory.list()) {
        if (entity is File && !entity.path.endsWith('.part')) {
          try {
            await entity.delete();
          } on FileSystemException {
            // Best-effort.
          }
        }
      }
    }
  });

  /// Evicts least-recently-used entries until both caps sit at or below
  /// their 90% watermarks. Serialized: concurrent calls share one run.
  @visibleForTesting
  Future<void> evictIfNeeded() {
    return _evictionRun ??= _serialize(_evict)
        .whenComplete(() => _evictionRun = null);
  }

  // Keep the file mutation and index update of one operation together. An
  // asynchronous rename/delete must not interleave with another mutation of
  // the same key, and a failed operation must not poison later operations.
  Future<T> _serialize<T>(Future<T> Function() operation) {
    final result = _mutationTail.then((_) => operation());
    _mutationTail = result.then<void>(
      (_) {},
      onError: (Object error, StackTrace stack) {},
    );
    return result;
  }

  Future<void> _evict() async {
    final byteTarget = (maxBytes * 0.9).floor();
    final entryTarget = (maxEntries * 0.9).floor();
    if (_totalBytes <= maxBytes && _index.length <= maxEntries) return;
    final names = _index.keys.toList()
      ..sort(
        (a, b) => _index[a]!.lastAccessMs.compareTo(_index[b]!.lastAccessMs),
      );
    for (final name in names) {
      if (_totalBytes <= byteTarget && _index.length <= entryTarget) break;
      await _deleteEntry(name);
    }
  }

  Future<void> _deleteEntry(String name) async {
    final entry = _index.remove(name);
    if (entry == null) return;
    _totalBytes -= entry.size;
    try {
      await File(_pathOf(entry.fullName)).delete();
    } on FileSystemException {
      // Already gone (OS purge, concurrent delete): index is corrected above.
    }
  }

  String _pathOf(String name) => p.join(directory.path, name);
}

class _Entry {
  _Entry({
    required this.fullName,
    required this.size,
    required this.width,
    required this.height,
    required this.lastAccessMs,
    required this.lastTouchMs,
  });

  final String fullName;
  final int size;
  final int width;
  final int height;
  int lastAccessMs;
  int lastTouchMs;
}
