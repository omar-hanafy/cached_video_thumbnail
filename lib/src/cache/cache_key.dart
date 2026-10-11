import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha1;
import 'package:flutter/foundation.dart';

import '../thumbnail_exception.dart';
import '../thumbnail_spec.dart';
import '../video_source.dart';

/// Schema version baked into every canonical key. Bumping it invalidates the
/// whole cache wholesale (files also live under a directory named after it).
const String cacheSchemaVersion = 'v2';

/// Deterministic identity of one (source, spec) pair.
///
/// [sourceId] is the stable identity of the source (for files: the path
/// only). A file's mtime and size are folded into [canonical] as a version
/// segment instead, so an edited file produces a new cache entry while
/// `evict(source)` still reaches stale generations through the shared
/// [sourcePrefix].
///
/// The [fileName] is `<sha1(sourceId)[0..16)>-<sha1(canonical)[0..24)>.<ext>`;
/// the source-hash prefix lets the cache drop every entry of a source with a
/// single prefix scan.
@immutable
class CacheKey {
  const CacheKey._({
    required this.canonical,
    required this.sourceId,
    required this.sourcePrefix,
    required this.fileName,
  });

  /// Full canonical string, e.g. `v2|a|pkg|assets/v.mp4|320x320|p0|e0|jpeg|q80`.
  final String canonical;

  /// Canonical source identity, e.g. `n|https://cdn.io/v.mp4`.
  final String sourceId;

  /// First 16 hex chars of `sha1(sourceId)`; shared by all specs and all
  /// content versions of a source.
  final String sourcePrefix;

  /// Cache file name for this key.
  final String fileName;

  /// Computes the key for [source] and [spec].
  ///
  /// File sources are stat'ed so their canonical form embeds mtime and size;
  /// a missing file throws [ThumbnailException] with
  /// [ThumbnailErrorCode.fileNotFound].
  static Future<CacheKey> compute(
    VideoSource source,
    ThumbnailSpec spec,
  ) async {
    var version = '';
    if (source is FileVideoSource) {
      final stat = await File(source.path).stat();
      if (stat.type == FileSystemEntityType.notFound) {
        throw ThumbnailException(
          ThumbnailErrorCode.fileNotFound,
          'file does not exist: ${source.path}',
        );
      }
      version = 'm${stat.modified.millisecondsSinceEpoch}s${stat.size}';
    }
    return _build(_sourceIdOf(source), version, spec);
  }

  /// Computes only the source-prefix hash for [source]; used by
  /// `ThumbnailEngine.evict`, which does not know the specs in play. Works
  /// for files that no longer exist.
  static String sourcePrefixFor(VideoSource source) => sha1
      .convert(utf8.encode(_sourceIdOf(source)))
      .toString()
      .substring(0, 16);

  static String _sourceIdOf(VideoSource source) => switch (source) {
    AssetVideoSource(:final assetKey, :final package) =>
      'a|${package ?? ''}|$assetKey',
    FileVideoSource(:final path) => 'f|$path',
    NetworkVideoSource(:final url) => 'n|$url',
  };

  static CacheKey _build(String sourceId, String version, ThumbnailSpec spec) {
    // PNG ignores quality, so normalize it out of the identity to avoid
    // duplicate cache entries that differ only by an irrelevant field.
    final quality = spec.format == ThumbnailFormat.png ? 100 : spec.quality;
    final versionSegment = version.isEmpty ? '' : '|$version';
    final canonical =
        '$cacheSchemaVersion|$sourceId$versionSegment'
        '|${spec.maxWidth}x${spec.maxHeight}'
        '|p${spec.position.inMilliseconds}'
        '|e${spec.exact ? 1 : 0}'
        '|${spec.format.wireName}'
        '|q$quality';
    final sourcePrefix = sha1
        .convert(utf8.encode(sourceId))
        .toString()
        .substring(0, 16);
    final fullHash = sha1
        .convert(utf8.encode(canonical))
        .toString()
        .substring(0, 24);
    return CacheKey._(
      canonical: canonical,
      sourceId: sourceId,
      sourcePrefix: sourcePrefix,
      fileName: '$sourcePrefix-$fullHash.${spec.format.fileExtension}',
    );
  }

  @override
  bool operator ==(Object other) =>
      other is CacheKey && other.canonical == canonical;

  @override
  int get hashCode => canonical.hashCode;

  @override
  String toString() => 'CacheKey($canonical -> $fileName)';
}
