/// Real-internet smoke tests against public Big Buck Bunny media
/// (download.blender.org and the Mux HLS test stream).
///
/// These need the DEVICE to have internet access and are therefore kept out
/// of the hermetic suite. Run explicitly:
///
///   cd example
///   `flutter test integration_test/remote_media_test.dart -d <device-id>`
library;

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:cached_video_thumbnail/src/extractor/pigeon_extractor.dart';
import 'package:cached_video_thumbnail/cached_video_thumbnail.dart';
import 'package:cached_video_thumbnail_example/demo_catalog.dart';

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

  setUp(() async {
    root = await Directory.systemTemp.createTemp('thumbnail_remote');
    engine = ThumbnailEngine.forTesting(
      extractor: PigeonExtractor(),
      directory: Directory('${root.path}/cache'),
      config: const ThumbnailEngineConfig(
        defaultTimeout: Duration(seconds: 60),
      ),
    );
  });

  tearDown(() async {
    try {
      await root.delete(recursive: true);
    } on FileSystemException {
      // Orphan commits from cancelled work may still be landing.
    }
  });

  testWidgets('BBB MP4 direct link extracts a frame at 10s', (_) async {
    final result = await engine.getThumbnail(
      VideoSource.network(Uri.parse(bbbMp4Url)),
      spec: const ThumbnailSpec(
        maxWidth: 160,
        maxHeight: 160,
        position: Duration(seconds: 10),
      ),
    );
    expect(result.wasCached, isFalse);
    expect(result.width, 160);
    expect(
      result.height,
      inInclusiveRange(89, 90),
      reason: '320x180 fit into 160 is 160x90, +-1px decoder rounding',
    );
    final bytes = await File(result.filePath).readAsBytes();
    expect(bytes[0], 0xFF);
    expect(bytes[1], 0xD8, reason: 'jpeg magic');
  });

  testWidgets('BBB M4V direct link extracts an exact frame at 30s', (_) async {
    final result = await engine.getThumbnail(
      VideoSource.network(Uri.parse(bbbM4vUrl)),
      spec: const ThumbnailSpec(
        maxWidth: 160,
        maxHeight: 160,
        position: Duration(seconds: 30),
        exact: true,
      ),
    );
    expect(result.width, 160);
    // Platform decoders round aspect-fit differently on media we do not
    // encode ourselves: Android yields 90, iOS 89 for this file.
    expect(result.height, inInclusiveRange(89, 90));
  });

  testWidgets(
    'BBB HLS stream either extracts or fails with a classified error',
    (_) async {
      // Stream thumbnailing is platform-dependent: some OS versions extract
      // a frame, others cannot. The contract under test is that the engine
      // never hangs and never throws anything but ThumbnailException.
      try {
        final result = await engine.getThumbnail(
          VideoSource.network(Uri.parse(bbbHlsUrl)),
          spec: const ThumbnailSpec(maxWidth: 160, maxHeight: 160),
        );
        expect(result.width, greaterThan(0));
        expect(result.height, greaterThan(0));
        expect(File(result.filePath).existsSync(), isTrue);
      } on ThumbnailException catch (e) {
        expect(
          e.code,
          isIn([
            ThumbnailErrorCode.network,
            ThumbnailErrorCode.unsupportedMedia,
            ThumbnailErrorCode.extractionFailed,
            ThumbnailErrorCode.timeout,
          ]),
        );
      }
    },
  );

  testWidgets('a real 404 fails with a classified error', (_) async {
    await expectLater(
      engine.getThumbnail(
        VideoSource.network(Uri.parse(missing404Url)),
        timeout: const Duration(seconds: 20),
      ),
      throwsA(
        isA<ThumbnailException>().having(
          (e) => e.code,
          'code',
          isIn([
            ThumbnailErrorCode.network,
            ThumbnailErrorCode.unsupportedMedia,
            ThumbnailErrorCode.extractionFailed,
            // Android's MediaMetadataRetriever retries failing HTTP sources
            // internally; the engine then fails with a bounded timeout.
            ThumbnailErrorCode.timeout,
          ]),
        ),
      ),
    );
  });

  testWidgets('the second request for a remote video is a disk cache hit', (
    _,
  ) async {
    const spec = ThumbnailSpec(maxWidth: 120, maxHeight: 120);
    final first = await engine.getThumbnail(
      VideoSource.network(Uri.parse(bbbMp4Url)),
      spec: spec,
    );
    final second = await engine.getThumbnail(
      VideoSource.network(Uri.parse(bbbMp4Url)),
      spec: spec,
    );
    expect(first.wasCached, isFalse);
    expect(second.wasCached, isTrue);
    expect(second.filePath, first.filePath);
  });
}
