import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cached_video_thumbnail/cached_video_thumbnail.dart';

/// A valid 1x1 PNG, so provider tests can decode real bytes.
final Uint8List kTinyPng = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// Records one extract call.
class FakeExtraction {
  FakeExtraction(this.requestId, this.source, this.spec, this.destPath);

  final String requestId;
  final VideoSource source;
  final ThumbnailSpec spec;
  final String destPath;
}

/// Deterministic in-memory extractor for engine and provider tests.
///
/// By default every call writes [kTinyPng] into `destPath` and reports 1x1.
/// Tests can add latency, force failures, or gate completion manually.
class FakeExtractor implements ThumbnailExtractor {
  /// Calls received, in order.
  final List<FakeExtraction> calls = [];

  /// Request ids passed to [cancel].
  final List<String> cancelled = [];

  /// Optional failure from the best-effort native cancel call.
  Object? cancelFailure;

  /// Artificial latency before completing.
  Duration delay = Duration.zero;

  /// When set, every call throws this instead of producing a file.
  ThumbnailException? failWith;

  /// Writes a partial output before throwing [failWith].
  bool writeBeforeFailure = false;

  /// When true, calls block until [release] is invoked.
  bool gated = false;

  /// Bytes written to destPath.
  Uint8List bytes = kTinyPng;

  /// Reported dimensions.
  int width = 1;
  int height = 1;

  Completer<void> _gate = Completer<void>();

  /// Number of extract calls seen.
  int get callCount => calls.length;

  final List<(int, Completer<void>)> _callWaiters = [];

  /// Completes when at least [count] extractions have actually dispatched.
  Future<void> waitForCalls(int count) {
    if (callCount >= count) return Future<void>.value();
    final completer = Completer<void>();
    _callWaiters.add((count, completer));
    return completer.future;
  }

  /// Releases every call currently blocked on the gate.
  void release() {
    _gate.complete();
    _gate = Completer<void>();
  }

  @override
  Future<ExtractionResult> extract({
    required String requestId,
    required VideoSource source,
    required ThumbnailSpec spec,
    required String destPath,
  }) async {
    calls.add(FakeExtraction(requestId, source, spec, destPath));
    for (final waiter in _callWaiters.toList()) {
      if (callCount >= waiter.$1) {
        _callWaiters.remove(waiter);
        waiter.$2.complete();
      }
    }
    if (delay != Duration.zero) {
      await Future<void>.delayed(delay);
    }
    if (gated) {
      await _gate.future;
    }
    final failure = failWith;
    if (failure != null) {
      if (writeBeforeFailure) await File(destPath).writeAsBytes(bytes);
      throw failure;
    }
    await File(destPath).writeAsBytes(bytes);
    return ExtractionResult(width: width, height: height);
  }

  @override
  Future<void> cancel(String requestId) async {
    cancelled.add(requestId);
    final failure = cancelFailure;
    if (failure != null) throw failure;
  }
}
