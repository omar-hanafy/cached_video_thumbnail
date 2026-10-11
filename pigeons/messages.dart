// Pigeon schema for the thumbnail plugin channel.
//
// Regenerate with:
//   dart run pigeon --input pigeons/messages.dart
import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/src/pigeon/messages.g.dart',
    kotlinOut: 'android/src/main/kotlin/tech/tomars/cached_video_thumbnail/Messages.g.kt',
    kotlinOptions: KotlinOptions(package: 'tech.tomars.cached_video_thumbnail'),
    swiftOut: 'ios/cached_video_thumbnail/Sources/cached_video_thumbnail/messages.g.swift',
    dartPackageName: 'cached_video_thumbnail',
  ),
)
/// Kind of video source being extracted from.
enum SourceKind { asset, file, network }

/// A single extraction request.
///
/// The native side must decode one frame per the fields below and encode it
/// directly into [destPath] (a `.part` file chosen by the Dart engine). It
/// must never buffer the encoded image in memory for return.
class ExtractRequest {
  ExtractRequest({
    required this.requestId,
    required this.sourceType,
    required this.source,
    this.assetPackage,
    this.headers,
    required this.positionMs,
    required this.exact,
    required this.maxWidth,
    required this.maxHeight,
    required this.format,
    required this.quality,
    required this.destPath,
  });

  /// Engine-unique id; used for native-side cancellation on iOS.
  String requestId;

  SourceKind sourceType;

  /// Asset key, absolute file path, or http(s) URL depending on [sourceType].
  String source;

  /// Package name for package-relative assets.
  String? assetPackage;

  /// Optional HTTP headers for network sources.
  Map<String, String>? headers;

  /// Desired frame position in milliseconds. Natives clamp into the duration.
  int positionMs;

  /// false: nearest sync/key frame (fast). true: exact frame (slow).
  bool exact;

  /// Fit-within box in pixels. 0 means unconstrained on that axis.
  /// Aspect ratio is always preserved; frames are never upscaled.
  int maxWidth;
  int maxHeight;

  /// 'jpeg' or 'png'.
  String format;

  /// 1..100. Ignored for png.
  int quality;

  /// Absolute path of the temp file the native side writes the encoded image to.
  String destPath;
}

/// Result of a successful extraction: the encoded image dimensions.
class ExtractResult {
  ExtractResult({required this.width, required this.height});

  int width;
  int height;
}

@HostApi()
abstract class ThumbnailHostApi {
  /// Extracts one frame and encodes it into `request.destPath`.
  ///
  /// Errors are surfaced as `PlatformException` whose `code` is one of:
  /// invalidSource, assetNotFound, fileNotFound, network, unsupportedMedia,
  /// extractionFailed, encodingFailed, io, cancelled.
  @asyncCallback
  ExtractResult extract(ExtractRequest request);

  /// Best-effort cancellation of an in-flight extraction (iOS only in v1).
  void cancel(String requestId);
}
