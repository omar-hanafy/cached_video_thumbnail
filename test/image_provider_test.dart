import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cached_video_thumbnail/cached_video_thumbnail.dart';

import 'support/fake_extractor.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late FakeExtractor extractor;
  late ThumbnailEngine engine;

  final asset = VideoSource.asset('assets/v.mp4');

  setUp(() async {
    root = await Directory.systemTemp.createTemp('provider_test');
    extractor = FakeExtractor();
    engine = ThumbnailEngine.forTesting(
      extractor: extractor,
      directory: Directory('${root.path}/cache'),
    );
    PaintingBinding.instance.imageCache.clear();
    PaintingBinding.instance.imageCache.clearLiveImages();
  });

  tearDown(() => root.delete(recursive: true));

  Future<ImageInfo> resolveInfo(VideoThumbnailImage provider) {
    final completer = Completer<ImageInfo>();
    final stream = provider.resolve(ImageConfiguration.empty);
    late ImageStreamListener listener;
    listener = ImageStreamListener(
      (info, _) {
        stream.removeListener(listener);
        completer.complete(info);
      },
      onError: (error, stack) {
        stream.removeListener(listener);
        completer.completeError(error, stack);
      },
    );
    stream.addListener(listener);
    return completer.future;
  }

  test('resolves the engine result into a decoded image', () async {
    final provider = VideoThumbnailImage(asset, engine: engine);
    final info = await resolveInfo(provider);
    expect(info.image.width, 1);
    expect(info.image.height, 1);
    expect(extractor.callCount, 1);
  });

  test(
    'equal providers share one ImageCache entry and one extraction',
    () async {
      final a = VideoThumbnailImage(asset, engine: engine);
      final b = VideoThumbnailImage(asset, engine: engine);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);

      await resolveInfo(a);
      await resolveInfo(b);
      expect(extractor.callCount, 1, reason: 'second resolve is a cache hit');
    },
  );

  test('providers with different specs are distinct', () {
    final a = VideoThumbnailImage(asset, engine: engine);
    final b = VideoThumbnailImage(
      asset,
      spec: const ThumbnailSpec(maxWidth: 64, maxHeight: 64),
      engine: engine,
    );
    expect(a, isNot(equals(b)));
  });

  test(
    'removing the last listener before completion cancels the request',
    () async {
      extractor.gated = true;
      final provider = VideoThumbnailImage(asset, engine: engine);
      // Drive loadImage directly so the ImageCache's pending-image listener
      // does not keep the stream alive.
      final completer = provider.loadImage(
        provider,
        PaintingBinding.instance.instantiateImageCodecWithSize,
      );
      final listener = ImageStreamListener((_, _) {});
      completer.addListener(listener);
      await pumpEventQueue();
      expect(extractor.callCount, 1);

      completer.removeListener(listener);
      await pumpEventQueue();
      expect(
        extractor.cancelled,
        isNotEmpty,
        reason: 'last-listener removal must cancel the in-flight extraction',
      );

      extractor.release();
      await pumpEventQueue();
      expect(engine.metrics.cancellations, 1);
    },
  );

  test('a corrupted cache file is evicted and the error surfaces', () async {
    // First extraction writes garbage that cannot be decoded.
    extractor.bytes = Uint8List.fromList(List.filled(32, 0x00));
    final provider = VideoThumbnailImage(asset, engine: engine);
    await expectLater(resolveInfo(provider), throwsA(anything));
    expect(extractor.callCount, 1);

    // The corrupted entry was evicted: a retry extracts again and succeeds.
    extractor.bytes = kTinyPng;
    final info = await resolveInfo(VideoThumbnailImage(asset, engine: engine));
    expect(info.image.width, 1);
    expect(extractor.callCount, 2);
  });

  test(
    'resolve cancels when the last consumer leaves a pending image',
    () async {
      extractor.gated = true;
      final provider = VideoThumbnailImage(asset, engine: engine);
      final stream = provider.resolve(ImageConfiguration.empty);
      final listener = ImageStreamListener((info, _) => info.dispose());
      stream.addListener(listener);
      await pumpEventQueue();
      expect(extractor.callCount, 1);
      expect(
        PaintingBinding.instance.imageCache.statusForKey(provider).pending,
        isTrue,
      );

      stream.removeListener(listener);
      await pumpEventQueue();
      expect(extractor.cancelled, hasLength(1));
      expect(
        PaintingBinding.instance.imageCache.statusForKey(provider).pending,
        isFalse,
      );

      extractor.release();
      await pumpEventQueue();
      expect(engine.metrics.cancellations, 1);
    },
  );

  test(
    'a shared pending image survives until its last consumer leaves',
    () async {
      extractor.gated = true;
      final a = VideoThumbnailImage(asset, engine: engine);
      final b = VideoThumbnailImage(asset, engine: engine);
      final first = a.resolve(ImageConfiguration.empty);
      final second = b.resolve(ImageConfiguration.empty);
      final firstListener = ImageStreamListener((info, _) => info.dispose());
      final secondListener = ImageStreamListener((info, _) => info.dispose());
      first.addListener(firstListener);
      second.addListener(secondListener);
      await pumpEventQueue();
      expect(extractor.callCount, 1);

      first.removeListener(firstListener);
      await pumpEventQueue();
      expect(extractor.cancelled, isEmpty);
      expect(
        PaintingBinding.instance.imageCache.statusForKey(a).pending,
        isTrue,
      );

      second.removeListener(secondListener);
      await pumpEventQueue();
      expect(extractor.cancelled, hasLength(1));
      extractor.release();
      await pumpEventQueue();
    },
  );

  test(
    'extraction failures do not leave a failed Flutter cache entry',
    () async {
      await engine.configure(
        const ThumbnailEngineConfig(negativeCacheTtl: Duration.zero),
      );
      extractor.failWith = const ThumbnailException(
        ThumbnailErrorCode.extractionFailed,
        'Unavailable frame',
      );
      final provider = VideoThumbnailImage(asset, engine: engine);
      await expectLater(
        resolveInfo(provider),
        throwsA(isA<ThumbnailException>()),
      );
      expect(
        PaintingBinding.instance.imageCache.statusForKey(provider).pending,
        isFalse,
      );

      extractor.failWith = null;
      final info = await resolveInfo(
        VideoThumbnailImage(asset, engine: engine),
      );
      expect(info.image.width, 1);
      info.dispose();
      expect(extractor.callCount, 2);
    },
  );

  testWidgets('disposing an Image widget cancels its pending thumbnail', (
    tester,
  ) async {
    final settled = Completer<void>();
    engine.onEvent = (event) {
      if (event.kind == ThumbnailEventKind.extracted) settled.complete();
    };
    extractor.gated = true;
    await tester.runAsync(() async {
      await engine.clearCache();
      await tester.pumpWidget(
        SizedBox(
          width: 20,
          height: 20,
          child: Image(image: VideoThumbnailImage(asset, engine: engine)),
        ),
      );
      await extractor.waitForCalls(1);
    });
    expect(extractor.callCount, 1);

    await tester.pumpWidget(const SizedBox());
    expect(extractor.cancelled, hasLength(1));
    await tester.runAsync(() async {
      extractor.release();
      await settled.future;
    });
    expect(tester.takeException(), isNull);
  });
}
