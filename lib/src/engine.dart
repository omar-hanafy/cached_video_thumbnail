import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'cache/cache_key.dart';
import 'cache/disk_cache.dart';
import 'cache/negative_cache.dart';
import 'extractor/pigeon_extractor.dart';
import 'extractor/thumbnail_extractor.dart';
import 'metrics.dart';
import 'scheduler/request_scheduler.dart';
import 'thumbnail_exception.dart';
import 'thumbnail_result.dart';
import 'thumbnail_spec.dart';
import 'video_source.dart';

/// Engine-wide tuning knobs. All fields have production-ready defaults.
@immutable
class ThumbnailEngineConfig {
  /// Creates a config; see the field docs for defaults.
  const ThumbnailEngineConfig({
    this.maxConcurrentExtractions = 2,
    this.defaultTimeout = const Duration(seconds: 15),
    this.negativeCacheTtl = const Duration(seconds: 60),
    this.maxCacheBytes = 256 << 20,
    this.maxCacheEntries = 4000,
    this.defaultSpec = const ThumbnailSpec(),
  });

  /// Native extractions allowed to run at once (1..8). Use 1 for fleets of
  /// very low-end devices.
  final int maxConcurrentExtractions;

  /// Timeout applied to each extraction from the moment it is dispatched to
  /// a native slot (queue wait does not consume it).
  final Duration defaultTimeout;

  /// How long a failed source fast-fails before being retried.
  final Duration negativeCacheTtl;

  /// Soft cap on cached bytes (default 256 MiB).
  final int maxCacheBytes;

  /// Soft cap on cached entry count.
  final int maxCacheEntries;

  /// Spec used when a request does not pass one.
  final ThumbnailSpec defaultSpec;

  /// Throws [ArgumentError] on out-of-range values.
  void validate() {
    if (maxConcurrentExtractions < 1 || maxConcurrentExtractions > 8) {
      throw ArgumentError.value(
        maxConcurrentExtractions,
        'maxConcurrentExtractions',
        'must be in 1..8',
      );
    }
    if (maxCacheBytes <= 0) {
      throw ArgumentError.value(maxCacheBytes, 'maxCacheBytes', 'must be > 0');
    }
    if (maxCacheEntries <= 0) {
      throw ArgumentError.value(
        maxCacheEntries,
        'maxCacheEntries',
        'must be > 0',
      );
    }
    if (defaultTimeout.isNegative) {
      throw ArgumentError.value(
        defaultTimeout,
        'defaultTimeout',
        'must be >= zero',
      );
    }
    if (negativeCacheTtl.isNegative) {
      throw ArgumentError.value(
        negativeCacheTtl,
        'negativeCacheTtl',
        'must be >= zero',
      );
    }
    defaultSpec.validate();
  }
}

/// Handle for one thumbnail request.
///
/// Requests joined onto the same in-flight extraction stay independent:
/// cancelling one never affects the others; the underlying native work is
/// cancelled only when every joiner has cancelled.
abstract class ThumbnailRequest {
  /// Completes with the thumbnail, or a [ThumbnailException] on failure,
  /// cancellation, or timeout.
  Future<Thumbnail> get result;

  /// Detaches this request. Queued work with no other joiners is dequeued
  /// for free; in-flight native work is cancelled natively where supported
  /// (iOS) once the last joiner cancels.
  void cancel();

  /// Raises the request's priority band (never lowers it).
  void bumpPriority(ThumbnailPriority priority);
}

/// The video thumbnail engine: disk-cached, scheduled, cancellable.
///
/// The hot path is built so that thumbnail generation can never be the
/// reason a feed janks:
/// - Cache hits are answered from an in-memory index: no platform channel,
///   no extraction, no disk stat.
/// - Native work is bounded ([ThumbnailEngineConfig.maxConcurrentExtractions])
///   and newest-first, so a fling storm cannot pile up decoders.
/// - Identical requests coalesce into one extraction.
/// - Recent failures fast-fail through a negative cache instead of
///   re-hammering a broken URL while the user scrolls.
class ThumbnailEngine {
  ThumbnailEngine._({
    required this._extractor,
    required this._directoryResolver,
    required ThumbnailEngineConfig config,
    DateTime Function()? now,
  }) : _config = config,
       _now = now ?? DateTime.now,
       _scheduler = RequestScheduler(
         maxConcurrent: config.maxConcurrentExtractions,
       ),
       _negativeCache = NegativeCache(
         ttl: config.negativeCacheTtl,
         now: now ?? DateTime.now,
       );

  /// The shared engine used by production code and [VideoThumbnailImage].
  static ThumbnailEngine get instance => _instance ??= ThumbnailEngine._(
    extractor: PigeonExtractor(),
    directoryResolver: _defaultDirectory,
    config: const ThumbnailEngineConfig(),
  );
  static ThumbnailEngine? _instance;

  /// Builds an isolated engine with injected dependencies. Test-only.
  @visibleForTesting
  factory ThumbnailEngine.forTesting({
    required ThumbnailExtractor extractor,
    required Directory directory,
    ThumbnailEngineConfig config = const ThumbnailEngineConfig(),
    DateTime Function()? now,
  }) {
    return ThumbnailEngine._(
      extractor: extractor,
      directoryResolver: () async => directory,
      config: config,
      now: now,
    );
  }

  static Future<Directory> _defaultDirectory() async {
    final base = await getApplicationCacheDirectory();
    return Directory(p.join(base.path, 'thumbnail', cacheSchemaVersion));
  }

  final ThumbnailExtractor _extractor;
  final Future<Directory> Function() _directoryResolver;
  final DateTime Function() _now;
  final RequestScheduler _scheduler;
  final MetricsRecorder _recorder = MetricsRecorder();
  final Map<String, _Flight> _flights = {};

  ThumbnailEngineConfig _config;
  NegativeCache _negativeCache;
  DiskCache? _diskCache;
  Future<void>? _initFuture;
  bool _cacheSizingLocked = false;
  static int _requestCounter = 0;

  /// Optional structured event hook (logging, tracing).
  ThumbnailEventListener? onEvent;

  /// Point-in-time engine statistics.
  ThumbnailMetrics get metrics => _recorder.snapshot(
    queueDepth: _scheduler.queueDepth,
    activeJobs: _scheduler.activeCount,
  );

  /// Applies [config]. Concurrency, timeout, negative-cache TTL, and the
  /// default spec apply immediately at any time; cache sizing
  /// ([ThumbnailEngineConfig.maxCacheBytes] / maxCacheEntries) can only be
  /// set before the first request and throws [StateError] afterwards.
  Future<void> configure(ThumbnailEngineConfig config) async {
    config.validate();
    final cacheTouched =
        config.maxCacheBytes != _config.maxCacheBytes ||
        config.maxCacheEntries != _config.maxCacheEntries;
    if (cacheTouched && _cacheSizingLocked) {
      throw StateError(
        'cache sizing can only be configured before the first request',
      );
    }
    _config = config;
    _scheduler.maxConcurrent = config.maxConcurrentExtractions;
    _negativeCache = NegativeCache(ttl: config.negativeCacheTtl, now: _now);
  }

  /// Requests a thumbnail. Returns immediately with a cancellable handle.
  ///
  /// Throws [ArgumentError] synchronously for invalid [spec] values.
  ThumbnailRequest thumbnail(
    VideoSource source, {
    ThumbnailSpec? spec,
    ThumbnailPriority priority = ThumbnailPriority.normal,
    Duration? timeout,
  }) {
    final effectiveSpec = spec ?? _config.defaultSpec;
    effectiveSpec.validate();
    final effectiveTimeout = timeout ?? _config.defaultTimeout;
    if (effectiveTimeout.isNegative) {
      throw ArgumentError.value(effectiveTimeout, 'timeout', 'must be >= zero');
    }
    final request = _EngineRequest(this, priority);
    request._completer.future.ignore();
    unawaited(_start(request, source, effectiveSpec, effectiveTimeout));
    return request;
  }

  /// Convenience: `thumbnail(...).result`.
  Future<Thumbnail> getThumbnail(
    VideoSource source, {
    ThumbnailSpec? spec,
    ThumbnailPriority priority = ThumbnailPriority.normal,
    Duration? timeout,
  }) => thumbnail(
    source,
    spec: spec,
    priority: priority,
    timeout: timeout,
  ).result;

  /// Fire-and-forget cache warming in the lowest priority band. Errors are
  /// recorded in [metrics] but never surface.
  void prefetch(VideoSource source, {ThumbnailSpec? spec}) {
    thumbnail(source, spec: spec, priority: ThumbnailPriority.prefetch);
  }

  /// Removes every cached entry (all specs, all content versions) and every
  /// negative-cache entry of [source]. In-flight extractions are left to
  /// finish; call this before re-requesting when a source's content changed.
  Future<void> evict(VideoSource source) async {
    await _ensureInitialized();
    final prefix = CacheKey.sourcePrefixFor(source);
    await _diskCache!.evictSource(prefix);
    _negativeCache.removeByPrefix(prefix);
  }

  /// Deletes the entire cache directory contents and failure memos.
  Future<void> clearCache() async {
    await _ensureInitialized();
    await _diskCache!.clear();
    _negativeCache.clear();
  }

  /// Drops the cache entry backing [thumbnailKey] and its negative entry;
  /// used by the image provider when a cached file fails to decode.
  Future<void> removeCorrupted(VideoSource source, ThumbnailSpec spec) async {
    await _ensureInitialized();
    final key = await CacheKey.compute(source, spec);
    await _diskCache!.remove(key);
    _negativeCache.remove(key.fileName);
  }

  Future<void> _ensureInitialized() {
    _cacheSizingLocked = true;
    return _initFuture ??= _init().onError<Object>((error, stack) {
      _initFuture = null;
      Error.throwWithStackTrace(error, stack);
    });
  }

  Future<void> _init() async {
    try {
      final directory = await _directoryResolver();
      final cache = DiskCache(
        directory: directory,
        maxBytes: _config.maxCacheBytes,
        maxEntries: _config.maxCacheEntries,
        now: _now,
      );
      await cache.init();
      _diskCache = cache;
    } on FileSystemException catch (error) {
      throw ThumbnailException(
        ThumbnailErrorCode.io,
        'failed to initialize thumbnail cache',
        cause: error,
      );
    }
  }

  Future<void> _start(
    _EngineRequest request,
    VideoSource source,
    ThumbnailSpec spec,
    Duration timeout,
  ) async {
    _recorder.incRequest();
    try {
      await _ensureInitialized();
      final key = await CacheKey.compute(source, spec);
      _emit(ThumbnailEvent(ThumbnailEventKind.requested, key.fileName));
      if (request._cancelled) {
        throw const ThumbnailException(
          ThumbnailErrorCode.cancelled,
          'request cancelled',
        );
      }

      // 1. Disk cache.
      final hit = _diskCache!.lookup(key);
      if (hit != null) {
        _recorder.incCacheHit();
        _emit(ThumbnailEvent(ThumbnailEventKind.cacheHit, key.fileName));
        request._complete(
          Thumbnail(
            filePath: hit.path,
            width: hit.width,
            height: hit.height,
            wasCached: true,
          ),
        );
        return;
      }

      // 2. Negative cache: fast-fail without re-counting the failure.
      final memoized = _negativeCache.lookup(key.fileName);
      if (memoized != null) {
        request._fail(memoized, StackTrace.current);
        return;
      }

      // 3. Join an identical in-flight request.
      final existing = _flights[key.fileName];
      if (existing != null) {
        _recorder.incCoalesced();
        existing.join(request);
        _emit(ThumbnailEvent(ThumbnailEventKind.coalesced, key.fileName));
        return;
      }

      // 4. New flight.
      final flight = _Flight(
        this,
        key,
        source,
        spec,
        request._priority,
        timeout,
      );
      _flights[key.fileName] = flight;
      flight.launch();
      flight.join(request);
    } on Object catch (error, stack) {
      final e = mapPlatformError(error);
      _countTerminal(e);
      request._fail(e, stack);
    }
  }

  /// Counting rules: cancellations are counted per caller in
  /// [_EngineRequest.cancel]; everything else is counted once per flight
  /// (or once per request for pre-flight failures such as fileNotFound).
  void _countTerminal(ThumbnailException e) {
    switch (e.code) {
      case ThumbnailErrorCode.cancelled:
        break; // Counted where the caller cancelled.
      case ThumbnailErrorCode.timeout:
        _recorder.incTimeout();
      default:
        _recorder.incFailure(e.code);
    }
  }

  void _emit(ThumbnailEvent event) {
    try {
      onEvent?.call(event);
    } catch (_) {
      // Listener bugs must never break the pipeline.
    }
  }

  Future<void> _cancelNative(String requestId) async {
    try {
      await _extractor.cancel(requestId);
    } on Object {
      // Cancellation is best-effort even for an injected extractor.
    }
  }
}

/// One deduplicated in-flight extraction with N joined requests.
class _Flight {
  _Flight(
    this.engine,
    this.key,
    this.source,
    this.spec,
    this.priority,
    this.timeout,
  ) : requestId = 'r${ThumbnailEngine._requestCounter++}';

  final ThumbnailEngine engine;
  final CacheKey key;
  final VideoSource source;
  final ThumbnailSpec spec;
  final ThumbnailPriority priority;
  final Duration timeout;
  final String requestId;

  final List<_EngineRequest> _joiners = [];
  late final ScheduledJob<Thumbnail> _job;
  bool _nativeCancelRequested = false;

  /// Pipes the job outcome into [request]'s own completer. Joining a flight
  /// whose job has already settled is safe: the callbacks fire immediately.
  /// (A settled flight can still be visible in the flight map for one
  /// microtask before its cleanup runs.)
  void join(_EngineRequest request) {
    if (request._cancelled) return;
    _joiners.add(request);
    request._flight = this;
    _job.bump(request._priority);
    _job.future.then(
      request._complete,
      onError: (Object error, StackTrace stack) =>
          request._fail(mapPlatformError(error), stack),
    );
  }

  void launch() {
    final enqueuedAt = engine._now();
    _job = engine._scheduler.submit<Thumbnail>(
      key.fileName,
      priority,
      timeout,
      () => _work(enqueuedAt),
    );
    // Flight-level bookkeeping happens exactly once, independent of joiners.
    _job.future
        .then<void>(
          (_) {},
          onError: (Object error, StackTrace stack) {
            final e = mapPlatformError(error);
            engine._countTerminal(e);
            engine._negativeCache.record(key.fileName, e);
            if (e.code == ThumbnailErrorCode.timeout &&
                !_nativeCancelRequested) {
              // The deadline passed: abort native work where supported so a
              // hung remote source cannot pin a decoder thread.
              _nativeCancelRequested = true;
              unawaited(engine._cancelNative(requestId));
            }
            engine._emit(
              ThumbnailEvent(
                switch (e.code) {
                  ThumbnailErrorCode.cancelled => ThumbnailEventKind.cancelled,
                  ThumbnailErrorCode.timeout => ThumbnailEventKind.timedOut,
                  _ => ThumbnailEventKind.failed,
                },
                key.fileName,
                errorCode: e.code,
              ),
            );
          },
        )
        .whenComplete(_removeFlight);
  }

  Future<Thumbnail> _work(DateTime enqueuedAt) async {
    final dispatchedAt = engine._now();
    // An orphaned (cancelled/timed-out) earlier worker may have committed
    // this key after we checked the cache; recheck before extracting.
    final hit = engine._diskCache!.lookup(key);
    if (hit != null) {
      return Thumbnail(
        filePath: hit.path,
        width: hit.width,
        height: hit.height,
        wasCached: true,
      );
    }
    final temp = engine._diskCache!.tempPathFor(key);
    var committed = false;
    try {
      final extraction = await engine._extractor.extract(
        requestId: requestId,
        source: source,
        spec: spec,
        destPath: temp,
      );
      final path = await engine._diskCache!.commit(
        key,
        temp,
        width: extraction.width,
        height: extraction.height,
      );
      committed = true;
      engine._recorder.recordExtraction(
        queueWait: dispatchedAt.difference(enqueuedAt),
        extract: engine._now().difference(dispatchedAt),
      );
      engine._emit(
        ThumbnailEvent(
          ThumbnailEventKind.extracted,
          key.fileName,
          elapsed: engine._now().difference(enqueuedAt),
        ),
      );
      return Thumbnail(
        filePath: path,
        width: extraction.width,
        height: extraction.height,
        wasCached: false,
      );
    } finally {
      if (!committed) {
        try {
          await File(temp).delete();
        } on FileSystemException {
          // The native writer has settled; leftover output is best-effort.
        }
      }
    }
  }

  void onJoinerCancelled(_EngineRequest request) {
    _joiners.remove(request);
    if (_joiners.isNotEmpty || _job.isDone) return;
    _removeFlight();
    if (_job.isRunning && !_nativeCancelRequested) {
      _nativeCancelRequested = true;
      unawaited(engine._cancelNative(requestId));
    }
    _job.cancel();
  }

  void bump(ThumbnailPriority newPriority) => _job.bump(newPriority);

  void _removeFlight() {
    if (identical(engine._flights[key.fileName], this)) {
      engine._flights.remove(key.fileName);
    }
  }
}

class _EngineRequest implements ThumbnailRequest {
  _EngineRequest(this.engine, this._priority);

  final ThumbnailEngine engine;
  final Completer<Thumbnail> _completer = Completer<Thumbnail>();
  _Flight? _flight;
  bool _cancelled = false;
  ThumbnailPriority _priority;

  @override
  Future<Thumbnail> get result => _completer.future;

  @override
  void cancel() {
    if (_cancelled || _completer.isCompleted) return;
    _cancelled = true;
    _flight?.onJoinerCancelled(this);
    engine._recorder.incCancelled();
    _completer.completeError(
      const ThumbnailException(
        ThumbnailErrorCode.cancelled,
        'request cancelled',
      ),
    );
  }

  @override
  void bumpPriority(ThumbnailPriority priority) {
    if (_completer.isCompleted || priority.index <= _priority.index) return;
    _priority = priority;
    _flight?.bump(priority);
  }

  void _complete(Thumbnail thumbnail) {
    if (!_completer.isCompleted) _completer.complete(thumbnail);
  }

  void _fail(ThumbnailException error, StackTrace stack) {
    if (!_completer.isCompleted) _completer.completeError(error, stack);
  }
}
