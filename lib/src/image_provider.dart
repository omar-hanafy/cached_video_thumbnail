import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';

import 'engine.dart';
import 'thumbnail_exception.dart';
import 'thumbnail_result.dart';
import 'thumbnail_spec.dart';
import 'video_source.dart';

/// A 1x1 transparent PNG used to quietly settle an image stream whose
/// request was cancelled after its last listener detached: nothing is
/// listening, so failing the stream would only spam FlutterError.
final Uint8List _kTransparentPixel = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// An [ImageProvider] that resolves a video's thumbnail through
/// [ThumbnailEngine].
///
/// Drop it into any `Image` widget:
///
/// ```dart
/// Image(image: VideoThumbnailImage(
///   VideoSource.network(Uri.parse('https://cdn.io/v.mp4')),
///   spec: const ThumbnailSpec(maxWidth: 480, maxHeight: 480),
/// ))
/// ```
///
/// Behavior tuned for feeds:
/// - Identity (`==`) covers source + spec + engine, so Flutter's
///   [ImageCache] deduplicates identical cells for free (priority is
///   deliberately excluded from identity).
/// - When the last listener detaches before the thumbnail is ready, the
///   engine request is cancelled; combined with Flutter's own
///   scroll-aware resolution this keeps fling storms off the decoders.
/// - If a cached file was purged or corrupted externally, the entry is
///   evicted so the next resolve regenerates it.
class VideoThumbnailImage extends ImageProvider<VideoThumbnailImage> {
  /// Creates a provider for [source] rendered per [spec].
  VideoThumbnailImage(
    this.source, {
    this.spec = const ThumbnailSpec(),
    this.priority = ThumbnailPriority.visible,
    this._engine,
  });

  /// The video to thumbnail.
  final VideoSource source;

  /// Size/position/encoding of the generated thumbnail.
  final ThumbnailSpec spec;

  /// Scheduling band used when this provider triggers generation.
  /// Not part of the provider's identity.
  final ThumbnailPriority priority;

  final ThumbnailEngine? _engine;

  // ImageCache.putIfAbsent registers listeners synchronously. A depth counter
  // also handles nested provider resolution without mutating provider identity.
  static int _imageCacheRegistrationDepth = 0;

  /// The engine this provider resolves through.
  ThumbnailEngine get engine => _engine ?? ThumbnailEngine.instance;

  @override
  Future<VideoThumbnailImage> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture<VideoThumbnailImage>(this);
  }

  @override
  void resolveStreamForKey(
    ImageConfiguration configuration,
    ImageStream stream,
    VideoThumbnailImage key,
    ImageErrorListener handleError,
  ) {
    final ImageStreamCompleter? completer;
    _imageCacheRegistrationDepth++;
    try {
      completer = PaintingBinding.instance.imageCache.putIfAbsent(
        key,
        () =>
            stream.completer ??
            loadImage(
              key,
              PaintingBinding.instance.instantiateImageCodecWithSize,
            ),
        onError: handleError,
      );
    } finally {
      _imageCacheRegistrationDepth--;
    }
    if (completer is _ThumbnailImageStreamCompleter) {
      completer.finishCacheRegistration();
    }
    if (completer != null && stream.completer == null) {
      stream.setCompleter(completer);
    }
  }

  @override
  ImageStreamCompleter loadImage(
    VideoThumbnailImage key,
    ImageDecoderCallback decode,
  ) {
    final request = engine.thumbnail(source, spec: spec, priority: priority);
    late _ThumbnailImageStreamCompleter completer;
    completer = _ThumbnailImageStreamCompleter(
      codec: _decodeThumbnail(
        request,
        decode,
      ).whenComplete(() => completer.finishLoading()),
      cancel: () {
        PaintingBinding.instance.imageCache.evict(key);
        request.cancel();
      },
      registeringCache: _imageCacheRegistrationDepth > 0,
      scale: 1.0,
      debugLabel: 'VideoThumbnailImage(${source.describe()})',
      informationCollector: () => [
        DiagnosticsProperty<VideoSource>('source', source),
        DiagnosticsProperty<ThumbnailSpec>('spec', spec),
      ],
    );
    return completer;
  }

  Future<ui.Codec> _decodeThumbnail(
    ThumbnailRequest request,
    ImageDecoderCallback decode,
  ) async {
    final Thumbnail thumbnail;
    try {
      thumbnail = await request.result;
    } on ThumbnailException catch (e) {
      if (e.code == ThumbnailErrorCode.cancelled) {
        // Cancelled because the last listener detached; settle the dead
        // stream with an inert pixel instead of reporting a phantom error.
        return decode(
          await ui.ImmutableBuffer.fromUint8List(_kTransparentPixel),
        );
      }
      PaintingBinding.instance.imageCache.evict(this);
      rethrow;
    }
    try {
      final buffer = await ui.ImmutableBuffer.fromFilePath(thumbnail.filePath);
      return await decode(buffer);
    } catch (_) {
      // The cached file is unreadable (purged by the OS or corrupted):
      // evict it so the next resolve regenerates, then surface the error.
      await engine.removeCorrupted(source, spec);
      PaintingBinding.instance.imageCache.evict(this);
      rethrow;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is VideoThumbnailImage &&
      other.source == source &&
      other.spec == spec &&
      identical(other.engine, engine);

  @override
  int get hashCode => Object.hash(source, spec, engine);

  @override
  String toString() => 'VideoThumbnailImage(${source.describe()}, $spec)';
}

/// The image cache adds its own pending-image listener. Count listeners added
/// outside cache registration so a recycled widget can cancel unfinished work
/// even while that cache listener is still attached.
class _ThumbnailImageStreamCompleter extends MultiFrameImageStreamCompleter {
  _ThumbnailImageStreamCompleter({
    required super.codec,
    required super.scale,
    required this._cancel,
    required this._registeringCache,
    super.debugLabel,
    super.informationCollector,
  });

  final void Function() _cancel;
  final Map<ImageStreamListener, int> _externalListeners = {};
  bool _registeringCache;
  bool _loading = true;
  bool _cancelled = false;

  void finishCacheRegistration() => _registeringCache = false;

  void finishLoading() => _loading = false;

  @override
  void addListener(ImageStreamListener listener) {
    if (!_registeringCache) {
      _externalListeners.update(
        listener,
        (count) => count + 1,
        ifAbsent: () => 1,
      );
    }
    super.addListener(listener);
  }

  @override
  void removeListener(ImageStreamListener listener) {
    final count = _externalListeners[listener];
    if (count != null) {
      if (count == 1) {
        _externalListeners.remove(listener);
      } else {
        _externalListeners[listener] = count - 1;
      }
    }
    super.removeListener(listener);
    if (count != null &&
        _externalListeners.isEmpty &&
        _loading &&
        !_cancelled) {
      _cancelled = true;
      _cancel();
    }
  }
}
