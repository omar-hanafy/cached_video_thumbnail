import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:cached_video_thumbnail/src/cache/cache_key.dart';
import 'package:cached_video_thumbnail/src/cache/disk_cache.dart';
import 'package:cached_video_thumbnail/cached_video_thumbnail.dart';

void main() {
  late Directory root;
  var fakeNow = DateTime(2026, 1, 1);

  DiskCache newCache({int maxBytes = 1 << 20, int maxEntries = 100}) =>
      DiskCache(
        directory: Directory('${root.path}/cache'),
        maxBytes: maxBytes,
        maxEntries: maxEntries,
        now: () => fakeNow,
      );

  Future<CacheKey> keyFor(
    String asset, {
    ThumbnailSpec spec = const ThumbnailSpec(),
  }) => CacheKey.compute(VideoSource.asset(asset), spec);

  /// Simulates a native extraction: writes [size] bytes into the temp path.
  Future<String> fakeExtract(
    DiskCache cache,
    CacheKey key, {
    int size = 100,
  }) async {
    final temp = cache.tempPathFor(key);
    await File(temp).writeAsBytes(List.filled(size, 1));
    return temp;
  }

  String? lookupPath(DiskCache cache, CacheKey key) => cache.lookup(key)?.path;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('disk_cache_test');
    fakeNow = DateTime(2026, 1, 1);
  });

  tearDown(() => root.delete(recursive: true));

  test('init creates a missing directory', () async {
    final cache = newCache();
    await cache.init();
    expect(Directory('${root.path}/cache').existsSync(), isTrue);
    expect(cache.entryCount, 0);
    expect(cache.totalBytes, 0);
  });

  test(
    'init removes orphaned .part files and keeps committed entries',
    () async {
      final a = newCache();
      await a.init();
      final key = await keyFor('v.mp4');
      await a.commit(key, await fakeExtract(a, key), width: 32, height: 18);
      File('${root.path}/cache/orphan.1234abcd.part')
          .writeAsBytesSync(List.filled(10, 9));

      final b = newCache();
      await b.init();
      expect(
        File('${root.path}/cache/orphan.1234abcd.part').existsSync(),
        isFalse,
      );
      expect(lookupPath(b, key), isNotNull);
      expect(b.entryCount, 1);
      expect(b.totalBytes, 100);
    },
  );

  test('commit renames atomically and lookup hits afterwards', () async {
    final cache = newCache();
    await cache.init();
    final key = await keyFor('v.mp4');
    expect(lookupPath(cache, key), isNull);

    final temp = await fakeExtract(cache, key);
    expect(temp, endsWith('.part'));
    final path = await cache.commit(key, temp, width: 320, height: 180);

    expect(File(temp).existsSync(), isFalse);
    expect(File(path).existsSync(), isTrue);
    expect(path, endsWith('.320x180.jpg'));
    final hit = cache.lookup(key);
    expect(hit, isNotNull);
    expect(hit!.path, path);
    expect(hit.width, 320);
    expect(hit.height, 180);
    expect(cache.totalBytes, 100);
    expect(cache.entryCount, 1);
  });

  test(
    'double commit of the same key keeps one entry with the new size',
    () async {
      final cache = newCache();
      await cache.init();
      final key = await keyFor('v.mp4');
      await cache.commit(
        key,
        await fakeExtract(cache, key, size: 100),
        width: 32,
        height: 18,
      );
      await cache.commit(
        key,
        await fakeExtract(cache, key, size: 250),
        width: 64,
        height: 36,
      );
      expect(cache.entryCount, 1);
      expect(cache.totalBytes, 250);
    },
  );

  test('commit with a missing temp file throws io', () async {
    final cache = newCache();
    await cache.init();
    final key = await keyFor('v.mp4');
    expect(
      () => cache.commit(key, cache.tempPathFor(key), width: 1, height: 1),
      throwsA(
        isA<ThumbnailException>().having(
          (e) => e.code,
          'code',
          ThumbnailErrorCode.io,
        ),
      ),
    );
  });

  test(
    'evicts least recently used entries down to the byte watermark',
    () async {
      final cache = newCache(maxBytes: 350);
      await cache.init();
      final keys = <CacheKey>[];
      for (var i = 0; i < 5; i++) {
        final key = await keyFor('v$i.mp4');
        keys.add(key);
        await cache.commit(
          key,
          await fakeExtract(cache, key),
          width: 32,
          height: 18,
        );
        fakeNow = fakeNow.add(const Duration(minutes: 1));
      }
      await cache.evictIfNeeded();

      // Watermark is 90% of 350 = 315 bytes -> 3 entries of 100 bytes remain.
      expect(cache.totalBytes, 300);
      expect(cache.entryCount, 3);
      expect(lookupPath(cache, keys[0]), isNull, reason: 'oldest evicted');
      expect(lookupPath(cache, keys[1]), isNull);
      expect(lookupPath(cache, keys[4]), isNotNull, reason: 'newest kept');
    },
  );

  test('lookup refreshes recency so hot entries survive eviction', () async {
    final cache = newCache(maxBytes: 350);
    await cache.init();
    final keys = <CacheKey>[];
    for (var i = 0; i < 3; i++) {
      final key = await keyFor('v$i.mp4');
      keys.add(key);
      await cache.commit(
        key,
        await fakeExtract(cache, key),
        width: 32,
        height: 18,
      );
      fakeNow = fakeNow.add(const Duration(minutes: 1));
    }
    // Touch the oldest so it becomes the hottest.
    lookupPath(cache, keys[0]);
    fakeNow = fakeNow.add(const Duration(minutes: 1));

    final k3 = await keyFor('v3.mp4');
    await cache.commit(k3, await fakeExtract(cache, k3), width: 32, height: 18);
    final k4 = await keyFor('v4.mp4');
    await cache.commit(k4, await fakeExtract(cache, k4), width: 32, height: 18);
    await cache.evictIfNeeded();

    expect(lookupPath(cache, keys[0]), isNotNull, reason: 'recently used');
    expect(lookupPath(cache, keys[1]), isNull, reason: 'now the coldest');
  });

  test('enforces the entry count limit as well', () async {
    final cache = newCache(maxEntries: 3);
    await cache.init();
    for (var i = 0; i < 5; i++) {
      final key = await keyFor('v$i.mp4');
      await cache.commit(
        key,
        await fakeExtract(cache, key, size: 1),
        width: 32,
        height: 18,
      );
      fakeNow = fakeNow.add(const Duration(minutes: 1));
    }
    await cache.evictIfNeeded();
    // Auto-eviction may interleave with the commits, so the settled state is
    // anywhere at or below the cap (the watermark target is 2); the contract
    // is that it never stays above maxEntries.
    expect(cache.entryCount, lessThanOrEqualTo(3));
    expect(cache.entryCount, greaterThanOrEqualTo(2));
  });

  test('evictSource removes every spec of one source only', () async {
    final cache = newCache();
    await cache.init();
    final a1 = await keyFor('a.mp4');
    final a2 = await keyFor(
      'a.mp4',
      spec: const ThumbnailSpec(maxWidth: 100, maxHeight: 100),
    );
    final b1 = await keyFor('b.mp4');
    for (final key in [a1, a2, b1]) {
      await cache.commit(
        key,
        await fakeExtract(cache, key),
        width: 32,
        height: 18,
      );
    }
    expect(a1.sourcePrefix, a2.sourcePrefix);

    await cache.evictSource(a1.sourcePrefix);
    expect(lookupPath(cache, a1), isNull);
    expect(lookupPath(cache, a2), isNull);
    expect(lookupPath(cache, b1), isNotNull);
    expect(cache.entryCount, 1);
    expect(cache.totalBytes, 100);
  });

  test('clear removes everything', () async {
    final cache = newCache();
    await cache.init();
    final key = await keyFor('v.mp4');
    await cache.commit(
      key,
      await fakeExtract(cache, key),
      width: 32,
      height: 18,
    );
    await cache.clear();
    expect(cache.entryCount, 0);
    expect(cache.totalBytes, 0);
    expect(lookupPath(cache, key), isNull);
    expect(Directory('${root.path}/cache').listSync(), isEmpty);
  });

  test('a fresh instance rebuilds the index from disk', () async {
    final a = newCache();
    await a.init();
    final key = await keyFor('v.mp4');
    await a.commit(
      key,
      await fakeExtract(a, key, size: 42),
      width: 32,
      height: 18,
    );

    final b = newCache();
    await b.init();
    final hit = b.lookup(key);
    expect(hit, isNotNull);
    expect(hit!.width, 32, reason: 'dims survive restarts via the file name');
    expect(hit.height, 18);
    expect(b.totalBytes, 42);
    expect(b.entryCount, 1);
  });

  test('double commit with new dims replaces the old file on disk', () async {
    final cache = newCache();
    await cache.init();
    final key = await keyFor('v.mp4');
    final p1 = await cache.commit(
      key,
      await fakeExtract(cache, key),
      width: 32,
      height: 18,
    );
    final p2 = await cache.commit(
      key,
      await fakeExtract(cache, key),
      width: 64,
      height: 36,
    );
    expect(File(p1).existsSync(), isFalse, reason: 'stale dims file removed');
    expect(File(p2).existsSync(), isTrue);
    expect(cache.lookup(key)!.width, 64);
    expect(cache.entryCount, 1);
  });

  test('remove drops a single entry', () async {
    final cache = newCache();
    await cache.init();
    final key = await keyFor('v.mp4');
    final path = await cache.commit(
      key,
      await fakeExtract(cache, key),
      width: 32,
      height: 18,
    );
    await cache.remove(key);
    expect(cache.lookup(key), isNull);
    expect(File(path).existsSync(), isFalse);
    expect(cache.totalBytes, 0);
  });

  test(
    'concurrent replacement commits keep bytes and files consistent',
    () async {
      final cache = newCache();
      await cache.init();
      final key = await keyFor('v.mp4');
      await cache.commit(
        key,
        await fakeExtract(cache, key, size: 100),
        width: 32,
        height: 18,
      );
      final firstTemp = await fakeExtract(cache, key, size: 200);
      final secondTemp = await fakeExtract(cache, key, size: 300);
      final paths = await Future.wait([
        cache.commit(key, firstTemp, width: 64, height: 36),
        cache.commit(key, secondTemp, width: 96, height: 54),
      ]);

      final hit = cache.lookup(key)!;
      expect(cache.entryCount, 1);
      expect(cache.totalBytes, await File(hit.path).length());
      expect(
        await cache.directory.list().where((entity) => entity is File).length,
        1,
      );
      expect(File(paths.first).existsSync(), isFalse);
      expect(hit.path, paths.last);
    },
  );

  test('clear preserves temporary outputs of active extractions', () async {
    final cache = newCache();
    await cache.init();
    final committedKey = await keyFor('done.mp4');
    await cache.commit(
      committedKey,
      await fakeExtract(cache, committedKey),
      width: 32,
      height: 18,
    );
    final activeKey = await keyFor('active.mp4');
    final activeTemp = await fakeExtract(cache, activeKey);
    await cache.clear();

    expect(cache.entryCount, 0);
    expect(cache.totalBytes, 0);
    expect(File(activeTemp).existsSync(), isTrue);
    final path = await cache.commit(
      activeKey,
      activeTemp,
      width: 32,
      height: 18,
    );
    expect(File(path).existsSync(), isTrue);
  });
}
