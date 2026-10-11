import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:cached_video_thumbnail/cached_video_thumbnail.dart';

import 'support/fake_extractor.dart';

void main() {
  late Directory root;
  late FakeExtractor extractor;
  var fakeNow = DateTime(2026, 1, 1);

  ThumbnailEngine newEngine({ThumbnailEngineConfig? config}) {
    return ThumbnailEngine.forTesting(
      extractor: extractor,
      directory: Directory('${root.path}/cache'),
      config: config ?? const ThumbnailEngineConfig(),
      now: () => fakeNow,
    );
  }

  setUp(() async {
    root = await Directory.systemTemp.createTemp('engine_test');
    extractor = FakeExtractor();
    fakeNow = DateTime(2026, 1, 1);
  });

  tearDown(() => root.delete(recursive: true));

  Future<void> waitForEvents(
    ThumbnailEngine engine,
    ThumbnailEventKind kind, {
    int count = 1,
  }) {
    final completed = Completer<void>();
    final previous = engine.onEvent;
    var observed = 0;
    engine.onEvent = (event) {
      previous?.call(event);
      if (event.kind == kind && ++observed == count) {
        completed.complete();
      }
    };
    return completed.future;
  }

  final asset = VideoSource.asset('assets/v.mp4');

  test('miss extracts once, then identical requests hit the cache', () async {
    final engine = newEngine();
    final first = await engine.getThumbnail(asset);
    expect(first.wasCached, isFalse);
    expect(first.width, 1);
    expect(File(first.filePath).existsSync(), isTrue);
    expect(extractor.callCount, 1);

    final second = await engine.getThumbnail(asset);
    expect(second.wasCached, isTrue);
    expect(second.filePath, first.filePath);
    expect(extractor.callCount, 1, reason: 'hit must not touch the extractor');

    final m = engine.metrics;
    expect(m.requests, 2);
    expect(m.cacheHits, 1);
    expect(m.extractions, 1);
  });

  test('identical concurrent requests coalesce into one extraction', () async {
    final engine = newEngine();
    extractor.gated = true;
    final joined = waitForEvents(
      engine,
      ThumbnailEventKind.coalesced,
      count: 4,
    );
    final futures = [
      for (var i = 0; i < 5; i++) engine.thumbnail(asset).result,
    ];
    await extractor.waitForCalls(1);
    await joined;
    extractor.release();
    final results = await Future.wait(futures);
    expect(extractor.callCount, 1);
    expect(results.map((r) => r.filePath).toSet().length, 1);
    expect(engine.metrics.coalescedJoins, 4);
  });

  test('request IDs are unique across engines sharing an extractor', () async {
    final firstEngine = newEngine();
    final secondEngine = ThumbnailEngine.forTesting(
      extractor: extractor,
      directory: Directory('${root.path}/second-cache'),
    );
    extractor.gated = true;
    final first = firstEngine.getThumbnail(asset);
    final second = secondEngine.getThumbnail(asset);
    await extractor.waitForCalls(2);
    expect(extractor.callCount, 2);
    expect(extractor.calls.map((call) => call.requestId).toSet().length, 2);
    extractor.release();
    await Future.wait([first, second]);
  });

  test(
    'a coalesced event cannot cancel the incoming joiner indirectly',
    () async {
      final engine = newEngine();
      extractor.gated = true;
      final first = engine.thumbnail(asset);
      first.result.ignore();
      await extractor.waitForCalls(1);
      engine.onEvent = (event) {
        if (event.kind == ThumbnailEventKind.coalesced) first.cancel();
      };
      final joined = waitForEvents(engine, ThumbnailEventKind.coalesced);
      final second = engine.getThumbnail(asset);
      await joined;

      expect(extractor.cancelled, isEmpty);
      extractor.release();
      expect((await second).width, 1);
      await expectLater(
        first.result,
        throwsA(
          isA<ThumbnailException>().having(
            (error) => error.code,
            'code',
            ThumbnailErrorCode.cancelled,
          ),
        ),
      );
      expect(extractor.callCount, 1);
    },
  );

  test('different specs of one source extract separately', () async {
    final engine = newEngine();
    await engine.getThumbnail(asset);
    await engine.getThumbnail(
      asset,
      spec: const ThumbnailSpec(maxWidth: 100, maxHeight: 100),
    );
    expect(extractor.callCount, 2);
  });

  test(
    'cancelling the only pre-dispatch request never calls the extractor',
    () async {
      final engine = newEngine(
        config: const ThumbnailEngineConfig(maxConcurrentExtractions: 1),
      );
      extractor.gated = true;
      // Occupy the single slot.
      final blocker = engine.thumbnail(VideoSource.asset('other.mp4'));
      await extractor.waitForCalls(1);

      final requested = waitForEvents(engine, ThumbnailEventKind.requested);
      final request = engine.thumbnail(asset);
      request.result.ignore();
      await requested;
      request.cancel();

      extractor.release();
      await blocker.result;
      expect(extractor.calls.where((c) => c.source == asset), isEmpty);
      await expectLater(
        request.result,
        throwsA(
          isA<ThumbnailException>().having(
            (e) => e.code,
            'code',
            ThumbnailErrorCode.cancelled,
          ),
        ),
      );
    },
  );

  test('cancelling one joiner leaves the other unaffected', () async {
    final engine = newEngine();
    extractor.gated = true;
    final a = engine.thumbnail(asset);
    await extractor.waitForCalls(1);
    final joined = waitForEvents(engine, ThumbnailEventKind.coalesced);
    final b = engine.thumbnail(asset);
    await joined;

    b.cancel();
    await expectLater(
      b.result,
      throwsA(
        isA<ThumbnailException>().having(
          (e) => e.code,
          'code',
          ThumbnailErrorCode.cancelled,
        ),
      ),
    );

    extractor.release();
    final result = await a.result;
    expect(result.width, 1);
    expect(engine.metrics.cancellations, 1);
  });

  test('native cancel failures remain best-effort and do not escape', () async {
    final engine = newEngine();
    extractor.gated = true;
    extractor.cancelFailure = StateError('native cancel failed');
    final committed = Completer<void>();
    engine.onEvent = (event) {
      if (event.kind == ThumbnailEventKind.extracted) committed.complete();
    };
    final request = engine.thumbnail(asset);
    await extractor.waitForCalls(1);
    request.cancel();
    await expectLater(
      request.result,
      throwsA(
        isA<ThumbnailException>().having(
          (error) => error.code,
          'code',
          ThumbnailErrorCode.cancelled,
        ),
      ),
    );

    extractor.release();
    await committed.future;
    expect((await engine.getThumbnail(asset)).wasCached, isTrue);
    expect(extractor.cancelled, hasLength(1));
  });

  test(
    'cancelling all joiners of an in-flight request calls extractor.cancel',
    () async {
      final engine = newEngine();
      extractor.gated = true;
      final joined = waitForEvents(engine, ThumbnailEventKind.coalesced);
      final committed = waitForEvents(engine, ThumbnailEventKind.extracted);
      final a = engine.thumbnail(asset);
      final b = engine.thumbnail(asset);
      a.result.ignore();
      b.result.ignore();
      await extractor.waitForCalls(1);
      await joined;
      expect(extractor.callCount, 1);

      a.cancel();
      b.cancel();
      expect(extractor.cancelled, [extractor.calls.single.requestId]);

      // Wait for the orphaned worker's post-commit event before retrying.
      extractor.release();
      await committed;
      final next = await engine.getThumbnail(asset);
      expect(next.wasCached, isTrue);
      expect(extractor.callCount, 1);
    },
  );

  test('visible requests dispatch before earlier prefetch requests', () async {
    final engine = newEngine(
      config: const ThumbnailEngineConfig(maxConcurrentExtractions: 1),
    );
    extractor.gated = true;
    final committed = waitForEvents(
      engine,
      ThumbnailEventKind.extracted,
      count: 3,
    );
    final blocker = engine.getThumbnail(VideoSource.asset('blocker.mp4'));
    await extractor.waitForCalls(1);

    final prefetchRequested = waitForEvents(
      engine,
      ThumbnailEventKind.requested,
    );
    engine.prefetch(VideoSource.asset('p.mp4'));
    await prefetchRequested;
    final visibleRequested = waitForEvents(
      engine,
      ThumbnailEventKind.requested,
    );
    final visible = engine.thumbnail(
      VideoSource.asset('v.mp4'),
      priority: ThumbnailPriority.visible,
    );
    await visibleRequested;

    extractor.gated = false;
    extractor.release();
    await Future.wait([blocker, visible.result]);
    await committed;
    // blocker ran first (it held the slot), then the visible one.
    final order = extractor.calls
        .map((c) => (c.source as AssetVideoSource).assetKey)
        .toList();
    expect(order[0], 'blocker.mp4');
    expect(order[1], 'v.mp4');
  });

  test('a visible joiner promotes its queued prefetch flight', () async {
    final engine = newEngine(
      config: const ThumbnailEngineConfig(maxConcurrentExtractions: 1),
    );
    extractor.gated = true;
    final blocker = engine.getThumbnail(VideoSource.asset('blocker.mp4'));
    await extractor.waitForCalls(1);

    final queued = waitForEvents(
      engine,
      ThumbnailEventKind.requested,
      count: 2,
    );
    engine.prefetch(asset);
    final normal = engine.getThumbnail(VideoSource.asset('normal.mp4'));
    // requested is emitted before synchronous flight registration finishes;
    // its future resumes only after those flights are registered.
    await queued;
    final joined = waitForEvents(engine, ThumbnailEventKind.coalesced);
    final visible = engine.getThumbnail(
      asset,
      priority: ThumbnailPriority.visible,
    );
    await joined;

    extractor.gated = false;
    extractor.release();
    await Future.wait([blocker, normal, visible]);
    expect(extractor.calls.map((call) => call.source), [
      VideoSource.asset('blocker.mp4'),
      asset,
      VideoSource.asset('normal.mp4'),
    ]);
    expect(extractor.callCount, 3, reason: 'the prefetch is coalesced');
  });

  test('priority bumps before request initialization are retained', () async {
    final engine = newEngine(
      config: const ThumbnailEngineConfig(maxConcurrentExtractions: 1),
    );
    extractor.gated = true;
    final blocker = engine.getThumbnail(VideoSource.asset('blocker.mp4'));
    await extractor.waitForCalls(1);

    final queued = waitForEvents(
      engine,
      ThumbnailEventKind.requested,
      count: 2,
    );
    final request = engine.thumbnail(
      asset,
      priority: ThumbnailPriority.prefetch,
    );
    request.bumpPriority(ThumbnailPriority.visible);
    final normal = engine.getThumbnail(VideoSource.asset('normal.mp4'));
    await queued;

    extractor.gated = false;
    extractor.release();
    await Future.wait([blocker, request.result, normal]);
    expect(extractor.calls.map((call) => call.source), [
      VideoSource.asset('blocker.mp4'),
      asset,
      VideoSource.asset('normal.mp4'),
    ]);
  });

  test('failures are negative-cached within the ttl, then retried', () async {
    final engine = newEngine();
    extractor.failWith = const ThumbnailException(
      ThumbnailErrorCode.network,
      '404',
    );

    await expectLater(
      engine.getThumbnail(asset),
      throwsA(
        isA<ThumbnailException>().having(
          (e) => e.code,
          'code',
          ThumbnailErrorCode.network,
        ),
      ),
    );
    expect(extractor.callCount, 1);

    // Within the TTL: fast-fail without calling the extractor.
    await expectLater(
      engine.getThumbnail(asset),
      throwsA(
        isA<ThumbnailException>().having(
          (e) => e.code,
          'code',
          ThumbnailErrorCode.network,
        ),
      ),
    );
    expect(extractor.callCount, 1);

    // After the TTL: retried.
    fakeNow = fakeNow.add(const Duration(seconds: 61));
    extractor.failWith = null;
    final result = await engine.getThumbnail(asset);
    expect(result.wasCached, isFalse);
    expect(extractor.callCount, 2);
    expect(engine.metrics.failures[ThumbnailErrorCode.network], 1);
  });

  test('evict removes disk and negative entries for one source only', () async {
    final engine = newEngine();
    final other = VideoSource.asset('other.mp4');
    await engine.getThumbnail(asset);
    await engine.getThumbnail(other);
    expect(extractor.callCount, 2);

    await engine.evict(asset);
    await engine.getThumbnail(asset);
    expect(extractor.callCount, 3, reason: 'evicted source re-extracts');
    await engine.getThumbnail(other);
    expect(extractor.callCount, 3, reason: 'other source still cached');
  });

  test('clearCache drops everything', () async {
    final engine = newEngine();
    await engine.getThumbnail(asset);
    await engine.clearCache();
    await engine.getThumbnail(asset);
    expect(extractor.callCount, 2);
  });

  test('failed extraction removes its partial output immediately', () async {
    final engine = newEngine();
    extractor.writeBeforeFailure = true;
    extractor.failWith = const ThumbnailException(
      ThumbnailErrorCode.encodingFailed,
      'partial encode failed',
    );
    await expectLater(
      engine.getThumbnail(asset),
      throwsA(
        isA<ThumbnailException>().having(
          (error) => error.code,
          'code',
          ThumbnailErrorCode.encodingFailed,
        ),
      ),
    );

    expect(await Directory('${root.path}/cache').list().toList(), isEmpty);
    expect(engine.metrics.failures[ThumbnailErrorCode.encodingFailed], 1);
  });

  test('a transient cache initialization failure can be retried', () async {
    final cachePath = '${root.path}/cache';
    await File(cachePath).writeAsString('temporary obstruction');
    final engine = newEngine();
    await expectLater(
      engine.getThumbnail(asset),
      throwsA(
        isA<ThumbnailException>().having(
          (error) => error.code,
          'code',
          ThumbnailErrorCode.io,
        ),
      ),
    );
    expect(extractor.callCount, 0);

    await File(cachePath).delete();
    final result = await engine.getThumbnail(asset);
    expect(File(result.filePath).existsSync(), isTrue);
    expect(extractor.callCount, 1);
  });

  test('spec validation fails synchronously', () {
    final engine = newEngine();
    expect(
      () => engine.thumbnail(asset, spec: const ThumbnailSpec(quality: 0)),
      throwsArgumentError,
    );
  });

  test('missing file source fails with fileNotFound', () async {
    final engine = newEngine();
    await expectLater(
      engine.getThumbnail(VideoSource.file('/definitely/not/here.mp4')),
      throwsA(
        isA<ThumbnailException>().having(
          (e) => e.code,
          'code',
          ThumbnailErrorCode.fileNotFound,
        ),
      ),
    );
    expect(extractor.callCount, 0);
  });

  test('events stream the request lifecycle', () async {
    final engine = newEngine();
    final events = <ThumbnailEvent>[];
    engine.onEvent = events.add;

    await engine.getThumbnail(asset);
    await engine.getThumbnail(asset);
    expect(events.map((e) => e.kind), [
      ThumbnailEventKind.requested,
      ThumbnailEventKind.extracted,
      ThumbnailEventKind.requested,
      ThumbnailEventKind.cacheHit,
    ]);
  });

  test(
    'configure adjusts concurrency live but refuses cache resizing after init',
    () async {
      final engine = newEngine();
      await engine.getThumbnail(asset);
      await engine.configure(
        const ThumbnailEngineConfig(maxConcurrentExtractions: 4),
      );
      expect(
        () => engine.configure(const ThumbnailEngineConfig(maxCacheBytes: 1)),
        throwsStateError,
      );
    },
  );

  test('config validation rejects out-of-range concurrency', () {
    expect(
      () => const ThumbnailEngineConfig(maxConcurrentExtractions: 0).validate(),
      throwsArgumentError,
    );
    expect(
      () => const ThumbnailEngineConfig(maxConcurrentExtractions: 9).validate(),
      throwsArgumentError,
    );
  });

  test('config and request validation reject negative durations', () {
    const negative = Duration(microseconds: -1);
    expect(
      () => const ThumbnailEngineConfig(defaultTimeout: negative).validate(),
      throwsArgumentError,
    );
    expect(
      () => const ThumbnailEngineConfig(negativeCacheTtl: negative).validate(),
      throwsArgumentError,
    );
    expect(
      () => newEngine().thumbnail(asset, timeout: negative),
      throwsArgumentError,
    );
  });

  test('prefetch never surfaces errors', () async {
    final engine = newEngine();
    extractor.failWith = const ThumbnailException(ThumbnailErrorCode.io, 'x');
    final failed = waitForEvents(engine, ThumbnailEventKind.failed);
    engine.prefetch(asset);
    await failed;
    // The terminal event proves the fire-and-forget failure was handled.
    expect(engine.metrics.failures[ThumbnailErrorCode.io], 1);
  });
}
