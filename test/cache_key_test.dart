import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' show sha1;
import 'package:flutter_test/flutter_test.dart';
import 'package:cached_video_thumbnail/src/cache/cache_key.dart';
import 'package:cached_video_thumbnail/cached_video_thumbnail.dart';

void main() {
  const spec = ThumbnailSpec(maxWidth: 320, maxHeight: 320);

  group('CacheKey canonical form', () {
    test('asset source golden', () async {
      final key = await CacheKey.compute(
        VideoSource.asset('assets/v.mp4', package: 'pkg'),
        spec,
      );
      expect(key.sourceId, 'a|pkg|assets/v.mp4');
      expect(key.canonical, 'v2|a|pkg|assets/v.mp4|320x320|p0|e0|jpeg|q80');
    });

    test('asset without package uses empty package slot', () async {
      final key = await CacheKey.compute(
        VideoSource.asset('assets/v.mp4'),
        spec,
      );
      expect(key.sourceId, 'a||assets/v.mp4');
    });

    test('network source golden and headers are excluded', () async {
      final url = Uri.parse('https://cdn.io/v.mp4?sig=1');
      final a = await CacheKey.compute(VideoSource.network(url), spec);
      final b = await CacheKey.compute(
        VideoSource.network(url, headers: {'Authorization': 'Bearer zzz'}),
        spec,
      );
      expect(a.sourceId, 'n|https://cdn.io/v.mp4?sig=1');
      expect(a.canonical, b.canonical);
      expect(a.fileName, b.fileName);
    });

    test('file source embeds mtime and size and self-invalidates', () async {
      final dir = await Directory.systemTemp.createTemp('ck_test');
      addTearDown(() => dir.delete(recursive: true));
      final f = File('${dir.path}/v.mp4');
      await f.writeAsBytes(List.filled(100, 7));
      final stat = await f.stat();
      final key1 = await CacheKey.compute(VideoSource.file(f.path), spec);
      expect(key1.sourceId, 'f|${f.path}');
      expect(
        key1.canonical,
        contains('|m${stat.modified.millisecondsSinceEpoch}s100|'),
      );

      // Change content size -> new cache entry, same logical source.
      await f.writeAsBytes(List.filled(150, 7));
      final key2 = await CacheKey.compute(VideoSource.file(f.path), spec);
      expect(key2.canonical, isNot(key1.canonical));
      expect(key2.fileName, isNot(key1.fileName));
      // Same source prefix: evict(source) must reach stale generations too.
      expect(key2.sourcePrefix, key1.sourcePrefix);
    });

    test('missing file throws fileNotFound', () async {
      expect(
        () => CacheKey.compute(VideoSource.file('/nonexistent/v.mp4'), spec),
        throwsA(
          isA<ThumbnailException>().having(
            (e) => e.code,
            'code',
            ThumbnailErrorCode.fileNotFound,
          ),
        ),
      );
    });

    test('every spec field affects the canonical form', () async {
      final source = VideoSource.asset('a.mp4');
      final base = await CacheKey.compute(source, spec);
      final variants = [
        spec.copyWith(maxWidth: 321),
        spec.copyWith(maxHeight: 100),
        spec.copyWith(position: const Duration(milliseconds: 1500)),
        spec.copyWith(exact: true),
        spec.copyWith(format: ThumbnailFormat.png),
        spec.copyWith(quality: 55),
      ];
      for (final v in variants) {
        final other = await CacheKey.compute(source, v);
        expect(other.canonical, isNot(base.canonical), reason: v.toString());
      }
    });

    test('png normalizes quality out of the key', () async {
      final source = VideoSource.asset('a.mp4');
      final a = await CacheKey.compute(
        source,
        spec.copyWith(format: ThumbnailFormat.png, quality: 10),
      );
      final b = await CacheKey.compute(
        source,
        spec.copyWith(format: ThumbnailFormat.png, quality: 90),
      );
      expect(a.canonical, b.canonical);
      expect(a.canonical, contains('|q100'));
    });
  });

  group('CacheKey file name', () {
    test('is <sourceHash16>-<keyHash24>.<ext> and deterministic', () async {
      final key = await CacheKey.compute(
        VideoSource.asset('assets/v.mp4', package: 'pkg'),
        spec,
      );
      expect(
        key.fileName,
        matches(RegExp(r'^[a-f0-9]{16}-[a-f0-9]{24}\.jpg$')),
      );
      expect(key.fileName, startsWith(key.sourcePrefix));

      final expectedSource = sha1
          .convert(utf8.encode('a|pkg|assets/v.mp4'))
          .toString()
          .substring(0, 16);
      final expectedFull = sha1
          .convert(utf8.encode('v2|a|pkg|assets/v.mp4|320x320|p0|e0|jpeg|q80'))
          .toString()
          .substring(0, 24);
      expect(key.fileName, '$expectedSource-$expectedFull.jpg');

      final again = await CacheKey.compute(
        VideoSource.asset('assets/v.mp4', package: 'pkg'),
        spec,
      );
      expect(again.fileName, key.fileName);
    });

    test('png keys use the png extension', () async {
      final key = await CacheKey.compute(
        VideoSource.asset('a.mp4'),
        spec.copyWith(format: ThumbnailFormat.png),
      );
      expect(key.fileName, endsWith('.png'));
    });

    test(
      'different Unicode source names never alias through byte truncation',
      () async {
        final first = VideoSource.asset('\u0101.mp4');
        final second = VideoSource.asset('\u0201.mp4');
        final firstKey = await CacheKey.compute(first, spec);
        final secondKey = await CacheKey.compute(second, spec);
        expect(firstKey.fileName, isNot(secondKey.fileName));
        expect(firstKey.sourcePrefix, isNot(secondKey.sourcePrefix));
        expect(CacheKey.sourcePrefixFor(first), firstKey.sourcePrefix);
        expect(CacheKey.sourcePrefixFor(second), secondKey.sourcePrefix);
      },
    );
  });
}
