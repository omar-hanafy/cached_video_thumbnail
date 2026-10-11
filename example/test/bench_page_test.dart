import 'dart:async';
import 'dart:io';

import 'package:cached_video_thumbnail/cached_video_thumbnail.dart';
import 'package:cached_video_thumbnail_example/bench_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _FailingExtractor implements ThumbnailExtractor {
  final Completer<void> gate = Completer<void>();
  final Completer<void> started = Completer<void>();
  final Completer<void> settled = Completer<void>();
  final Set<String> _benchmarkKeys = {};
  int _failures = 0;

  void onEvent(ThumbnailEvent event) {
    if (event.kind == ThumbnailEventKind.failed &&
        _benchmarkKeys.contains(event.key)) {
      _failures++;
      if (_failures == 24) settled.complete();
    }
  }

  @override
  Future<ExtractionResult> extract({
    required String requestId,
    required VideoSource source,
    required ThumbnailSpec spec,
    required String destPath,
  }) async {
    if (spec.maxWidth >= 320) {
      // Native destinations are <cache-key>.<nonce>.part. Track the keys of
      // benchmark requests so the independent scroll demo cannot settle them.
      final filename = destPath.split('/').last;
      _benchmarkKeys.add(filename.split('.').take(2).join('.'));
      if (!started.isCompleted) started.complete();
    }
    await gate.future;
    throw const ThumbnailException(
      ThumbnailErrorCode.extractionFailed,
      'No frame',
    );
  }

  @override
  Future<void> cancel(String requestId) async {}
}

void main() {
  late Directory directory;
  late _FailingExtractor extractor;
  late ThumbnailEngine engine;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('benchmark_test');
    extractor = _FailingExtractor();
    engine = ThumbnailEngine.forTesting(
      extractor: extractor,
      directory: directory,
      config: const ThumbnailEngineConfig(negativeCacheTtl: Duration.zero),
    );
    engine.onEvent = extractor.onEvent;
  });

  tearDown(() => directory.delete(recursive: true));

  testWidgets(
    'benchmark handles out-of-order failures and locks its controls',
    (tester) async {
      await tester.runAsync(() async {
        await engine.clearCache();
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(body: BenchPage(engine: engine)),
          ),
        );
        await tester.tap(find.text('Run cold'));
        await extractor.started.future;
      });
      await tester.pump();
      final selectors = tester.widgetList<SegmentedButton<int>>(
        find.byType(SegmentedButton<int>),
      );
      expect(selectors, hasLength(3));
      expect(
        selectors.every((selector) => selector.onSelectionChanged == null),
        isTrue,
      );

      await tester.runAsync(() async {
        extractor.gate.complete();
        await extractor.settled.future;
      });
      await tester.pumpAndSettle();
      expect(
        find.textContaining('COLD run: 24 requests, size 320, concurrency 2'),
        findsOneWidget,
      );
      expect(find.textContaining('failures: 24'), findsOneWidget);
      expect(tester.takeException(), isNull);
      expect(
        tester
            .widget<FilledButton>(find.widgetWithText(FilledButton, 'Run cold'))
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets('finishing a benchmark after disposal does not call setState', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await engine.clearCache();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: BenchPage(engine: engine)),
        ),
      );
      await tester.tap(find.text('Run warm'));
      await extractor.started.future;
    });
    await tester.pump();
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() async {
      extractor.gate.complete();
      await extractor.settled.future;
    });
    await tester.pump();
    expect(tester.takeException(), isNull);
  });
}
