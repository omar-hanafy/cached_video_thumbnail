import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:cached_video_thumbnail/src/extractor/pigeon_extractor.dart';
import 'package:cached_video_thumbnail/cached_video_thumbnail.dart';

const landscape = 'assets/fixtures/landscape.mp4';
const portrait = 'assets/fixtures/portrait_rot90.mp4';

bool isJpeg(List<int> bytes) => bytes[0] == 0xFF && bytes[1] == 0xD8;
bool isPng(List<int> bytes) =>
    bytes[0] == 0x89 &&
    bytes[1] == 0x50 &&
    bytes[2] == 0x4E &&
    bytes[3] == 0x47;

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() {
    // iOS simulators enable semantics when their first view appears. Establish
    // that platform-owned handle before widget tests record their leak counts.
    binding.platformDispatcher.semanticsEnabledTestValue = true;
  });
  tearDownAll(binding.platformDispatcher.clearSemanticsEnabledTestValue);

  late Directory root;
  late ThumbnailEngine engine;

  ThumbnailEngine newEngine({ThumbnailEngineConfig? config}) =>
      ThumbnailEngine.forTesting(
        extractor: PigeonExtractor(),
        directory: Directory('${root.path}/cache'),
        config: config ?? const ThumbnailEngineConfig(),
      );

  setUp(() async {
    root = await Directory.systemTemp.createTemp('thumbnail_it');
    engine = newEngine();
  });

  tearDown(() async {
    try {
      await root.delete(recursive: true);
    } on FileSystemException {
      // Orphan commits from cancelled work may still be landing.
    }
  });

  group('asset extraction', () {
    testWidgets('landscape jpeg fits the box and preserves aspect', (_) async {
      final result = await engine.getThumbnail(
        VideoSource.asset(landscape),
        spec: const ThumbnailSpec(maxWidth: 320, maxHeight: 320),
      );
      expect(result.wasCached, isFalse);
      expect(result.width, 320);
      expect(result.height, 180, reason: '640x360 fit in 320 box is 320x180');

      final bytes = await File(result.filePath).readAsBytes();
      expect(isJpeg(bytes), isTrue, reason: 'default format is jpeg');

      final again = await engine.getThumbnail(
        VideoSource.asset(landscape),
        spec: const ThumbnailSpec(maxWidth: 320, maxHeight: 320),
      );
      expect(again.wasCached, isTrue);
      expect(again.filePath, result.filePath);
    });

    testWidgets('rotation metadata yields a portrait thumbnail', (_) async {
      final result = await engine.getThumbnail(
        VideoSource.asset(portrait),
        spec: const ThumbnailSpec(maxWidth: 320, maxHeight: 320),
      );
      expect(
        result.height,
        greaterThan(result.width),
        reason: 'the 90-degree display matrix must be applied',
      );
      expect(result.height, 320);
      expect(result.width, 180);
    });

    testWidgets('png output produces a png file', (_) async {
      final result = await engine.getThumbnail(
        VideoSource.asset(landscape),
        spec: const ThumbnailSpec(
          maxWidth: 64,
          maxHeight: 64,
          format: ThumbnailFormat.png,
        ),
      );
      final bytes = await File(result.filePath).readAsBytes();
      expect(isPng(bytes), isTrue);
      expect(result.filePath, endsWith('.png'));
    });

    testWidgets('unconstrained spec keeps the native size', (_) async {
      final result = await engine.getThumbnail(VideoSource.asset(landscape));
      expect(result.width, 640);
      expect(result.height, 360);
    });

    testWidgets('keyframe and exact extraction both succeed mid-video', (
      _,
    ) async {
      final keyframe = await engine.getThumbnail(
        VideoSource.asset(landscape),
        spec: const ThumbnailSpec(
          maxWidth: 160,
          maxHeight: 160,
          position: Duration(milliseconds: 500),
        ),
      );
      final exact = await engine.getThumbnail(
        VideoSource.asset(landscape),
        spec: const ThumbnailSpec(
          maxWidth: 160,
          maxHeight: 160,
          position: Duration(milliseconds: 500),
          exact: true,
        ),
      );
      expect(keyframe.width, 160);
      expect(exact.width, 160);
    });

    testWidgets('position beyond the duration is clamped, not failed', (
      _,
    ) async {
      final result = await engine.getThumbnail(
        VideoSource.asset(landscape),
        spec: const ThumbnailSpec(
          maxWidth: 64,
          maxHeight: 64,
          position: Duration(minutes: 90),
        ),
      );
      expect(result.width, 64);
    });

    testWidgets('a missing asset fails with assetNotFound', (_) async {
      await expectLater(
        engine.getThumbnail(VideoSource.asset('assets/fixtures/nope.mp4')),
        throwsA(
          isA<ThumbnailException>().having(
            (e) => e.code,
            'code',
            ThumbnailErrorCode.assetNotFound,
          ),
        ),
      );
    });
  });

  group('file extraction', () {
    testWidgets('works and re-keys when the file changes', (_) async {
      final data = await rootBundle.load(landscape);
      final file = File('${root.path}/local.mp4');
      await file.writeAsBytes(data.buffer.asUint8List());

      final first = await engine.getThumbnail(
        VideoSource.file(file.path),
        spec: const ThumbnailSpec(maxWidth: 128, maxHeight: 128),
      );
      expect(first.wasCached, isFalse);
      expect(first.width, 128);

      // Touch the file: same path, new mtime -> new cache identity.
      await file.setLastModified(DateTime.now().add(const Duration(hours: 1)));
      final second = await engine.getThumbnail(
        VideoSource.file(file.path),
        spec: const ThumbnailSpec(maxWidth: 128, maxHeight: 128),
      );
      expect(
        second.wasCached,
        isFalse,
        reason: 'modified files must self-invalidate',
      );
    });
  });

  group('network extraction', () {
    late HttpServer server;
    late Uri baseUrl;

    setUp(() async {
      final fixture = await rootBundle.load(landscape);
      final bytes = fixture.buffer.asUint8List();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      baseUrl = Uri.parse('http://127.0.0.1:${server.port}');
      server.listen((request) async {
        final path = request.uri.path;
        if (path == '/secured.mp4' &&
            request.headers.value('x-test-auth') != 'letmein') {
          request.response.statusCode = HttpStatus.unauthorized;
          await request.response.close();
          return;
        }
        if (path == '/landscape.mp4' || path == '/secured.mp4') {
          final response = request.response;
          response.statusCode = HttpStatus.ok;
          response.headers.contentType = ContentType('video', 'mp4');
          // Support range requests minimally: AVFoundation insists on them.
          final range = request.headers.value(HttpHeaders.rangeHeader);
          if (range != null && range.startsWith('bytes=')) {
            final parts = range.substring(6).split('-');
            final start = int.parse(parts[0]);
            final end = (parts.length > 1 && parts[1].isNotEmpty)
                ? int.parse(parts[1])
                : bytes.length - 1;
            response.statusCode = HttpStatus.partialContent;
            response.headers.set(
              HttpHeaders.contentRangeHeader,
              'bytes $start-$end/${bytes.length}',
            );
            response.add(bytes.sublist(start, end + 1));
          } else {
            response.headers.set(HttpHeaders.acceptRangesHeader, 'bytes');
            response.add(bytes);
          }
          await response.close();
          return;
        }
        if (path == '/garbage.mp4') {
          request.response.statusCode = HttpStatus.ok;
          request.response.add(List<int>.filled(4096, 0x42));
          await request.response.close();
          return;
        }
        request.response.statusCode = HttpStatus.notFound;
        await request.response.close();
      });
    });

    tearDown(() => server.close(force: true));

    testWidgets('extracts from a url', (_) async {
      final result = await engine.getThumbnail(
        VideoSource.network(baseUrl.replace(path: '/landscape.mp4')),
        spec: const ThumbnailSpec(maxWidth: 160, maxHeight: 160),
      );
      expect(result.width, 160);
      expect(result.height, 90);
    });

    testWidgets('passes request headers through to the platform stack', (
      _,
    ) async {
      final result = await engine.getThumbnail(
        VideoSource.network(
          baseUrl.replace(path: '/secured.mp4'),
          headers: {'x-test-auth': 'letmein'},
        ),
        spec: const ThumbnailSpec(maxWidth: 160, maxHeight: 160),
      );
      expect(result.width, 160);
    });

    testWidgets('a 404 fails with a classified error', (_) async {
      await expectLater(
        engine.getThumbnail(
          VideoSource.network(baseUrl.replace(path: '/missing.mp4')),
          timeout: const Duration(seconds: 15),
        ),
        throwsA(
          isA<ThumbnailException>().having(
            (e) => e.code,
            'code',
            isIn([
              ThumbnailErrorCode.network,
              ThumbnailErrorCode.unsupportedMedia,
              ThumbnailErrorCode.extractionFailed,
              // Android's MediaMetadataRetriever can retry a failing HTTP
              // source internally past any deadline; the engine then fails
              // with a bounded, negative-cached timeout instead.
              ThumbnailErrorCode.timeout,
            ]),
          ),
        ),
      );
    });

    testWidgets('garbage bytes fail with a classified error', (_) async {
      await expectLater(
        engine.getThumbnail(
          VideoSource.network(baseUrl.replace(path: '/garbage.mp4')),
          timeout: const Duration(seconds: 15),
        ),
        throwsA(
          isA<ThumbnailException>().having(
            (e) => e.code,
            'code',
            isIn([
              ThumbnailErrorCode.network,
              ThumbnailErrorCode.unsupportedMedia,
              ThumbnailErrorCode.extractionFailed,
              // Android's MediaMetadataRetriever can retry a failing HTTP
              // source internally past any deadline; the engine then fails
              // with a bounded, negative-cached timeout instead.
              ThumbnailErrorCode.timeout,
            ]),
          ),
        ),
      );
    });
  });

  group('cache and API lifecycle', () {
    testWidgets('prefetch warms the cache for a later visible request', (
      _,
    ) async {
      const spec = ThumbnailSpec(maxWidth: 144, maxHeight: 144);
      engine.prefetch(VideoSource.asset(landscape), spec: spec);

      // Prefetch is fire-and-forget; wait for the extraction to land.
      final deadline = DateTime.now().add(const Duration(seconds: 15));
      while (engine.metrics.extractions < 1) {
        expect(
          DateTime.now().isBefore(deadline),
          isTrue,
          reason: 'prefetch extraction never completed',
        );
        await Future<void>.delayed(const Duration(milliseconds: 50));
      }

      final result = await engine.getThumbnail(
        VideoSource.asset(landscape),
        spec: spec,
        priority: ThumbnailPriority.visible,
      );
      expect(result.wasCached, isTrue, reason: 'prefetch must have warmed it');
      expect(engine.metrics.extractions, 1);
    });

    testWidgets('identical concurrent requests coalesce into one extraction', (
      _,
    ) async {
      const spec = ThumbnailSpec(maxWidth: 152, maxHeight: 152);
      final results = await Future.wait([
        for (var i = 0; i < 4; i++)
          engine.getThumbnail(VideoSource.asset(landscape), spec: spec),
      ]);
      for (final r in results) {
        expect(r.filePath, results.first.filePath);
      }
      expect(engine.metrics.extractions, 1);
      expect(engine.metrics.coalescedJoins, 3);
    });

    testWidgets('evict removes every thumbnail of one source only', (_) async {
      const specA = ThumbnailSpec(maxWidth: 96, maxHeight: 96);
      const specB = ThumbnailSpec(maxWidth: 128, maxHeight: 128);
      await engine.getThumbnail(VideoSource.asset(landscape), spec: specA);
      await engine.getThumbnail(VideoSource.asset(landscape), spec: specB);
      await engine.getThumbnail(VideoSource.asset(portrait), spec: specA);

      await engine.evict(VideoSource.asset(landscape));

      final a = await engine.getThumbnail(
        VideoSource.asset(landscape),
        spec: specA,
      );
      final b = await engine.getThumbnail(
        VideoSource.asset(landscape),
        spec: specB,
      );
      final other = await engine.getThumbnail(
        VideoSource.asset(portrait),
        spec: specA,
      );
      expect(a.wasCached, isFalse);
      expect(b.wasCached, isFalse);
      expect(other.wasCached, isTrue, reason: 'evict must be source-scoped');
    });

    testWidgets('clearCache forces every source to re-extract', (_) async {
      const spec = ThumbnailSpec(maxWidth: 88, maxHeight: 88);
      await engine.getThumbnail(VideoSource.asset(landscape), spec: spec);
      await engine.getThumbnail(VideoSource.asset(portrait), spec: spec);

      await engine.clearCache();

      final a = await engine.getThumbnail(
        VideoSource.asset(landscape),
        spec: spec,
      );
      final b = await engine.getThumbnail(
        VideoSource.asset(portrait),
        spec: spec,
      );
      expect(a.wasCached, isFalse);
      expect(b.wasCached, isFalse);
    });

    testWidgets('VideoThumbnailImage resolves inside a widget tree', (
      tester,
    ) async {
      // Goes through ThumbnailEngine.instance: the exact production path.
      final provider = VideoThumbnailImage(
        VideoSource.asset(landscape),
        spec: const ThumbnailSpec(maxWidth: 200, maxHeight: 200),
      );
      await tester.pumpWidget(MaterialApp(home: Image(image: provider)));
      final context = tester.element(find.byType(Image));
      await precacheImage(provider, context);
      await tester.pump();

      final rawImage = tester.widget<RawImage>(find.byType(RawImage));
      expect(rawImage.image, isNotNull);
      expect(rawImage.image!.width, greaterThan(0));
      expect(
        rawImage.image!.width / rawImage.image!.height,
        closeTo(640 / 360, 0.05),
        reason: 'aspect ratio must survive the fit box',
      );
    });
  });

  group('load behavior', () {
    testWidgets('a 24-request mixed-priority burst completes', (_) async {
      final futures = <Future<Thumbnail>>[];
      for (var i = 0; i < 24; i++) {
        final source = VideoSource.asset(i.isEven ? landscape : portrait);
        final priority = ThumbnailPriority.values[i % 3];
        futures.add(
          engine
              .thumbnail(
                source,
                spec: ThumbnailSpec(maxWidth: 40 + i, maxHeight: 40 + i),
                priority: priority,
              )
              .result,
        );
      }
      final results = await Future.wait(futures);
      expect(results, hasLength(24));
      for (final r in results) {
        expect(r.width, greaterThan(0));
        expect(File(r.filePath).existsSync(), isTrue);
      }
      final m = engine.metrics;
      expect(m.extractions, 24, reason: 'all specs distinct: no coalescing');
      expect(m.activeJobs, 0);
      expect(m.queueDepth, 0);
    });

    testWidgets('a cancel storm leaves the engine healthy', (_) async {
      final requests = [
        for (var i = 0; i < 30; i++)
          engine.thumbnail(
            VideoSource.asset(landscape),
            spec: ThumbnailSpec(maxWidth: 100 + i, maxHeight: 100 + i),
            priority: ThumbnailPriority.prefetch,
          ),
      ];
      for (final r in requests) {
        r.result.ignore();
        r.cancel();
      }

      final result = await engine.getThumbnail(
        VideoSource.asset(portrait),
        spec: const ThumbnailSpec(maxWidth: 90, maxHeight: 90),
        priority: ThumbnailPriority.visible,
      );
      expect(result.height, 90);
      expect(engine.metrics.cancellations, 30);
    });
  });
}
