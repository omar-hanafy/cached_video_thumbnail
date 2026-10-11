import 'package:flutter_test/flutter_test.dart';
import 'package:cached_video_thumbnail/src/cache/negative_cache.dart';
import 'package:cached_video_thumbnail/cached_video_thumbnail.dart';

void main() {
  const err = ThumbnailException(ThumbnailErrorCode.network, '404');

  test('records and returns a failure within the ttl', () {
    var now = DateTime(2026, 1, 1);
    final cache = NegativeCache(
      ttl: const Duration(seconds: 60),
      now: () => now,
    );
    cache.record('k1', err);
    expect(cache.lookup('k1'), same(err));

    now = now.add(const Duration(seconds: 59));
    expect(cache.lookup('k1'), same(err));
  });

  test('expires entries after the ttl and prunes them on lookup', () {
    var now = DateTime(2026, 1, 1);
    final cache = NegativeCache(
      ttl: const Duration(seconds: 60),
      now: () => now,
    );
    cache.record('k1', err);
    now = now.add(const Duration(seconds: 61));
    expect(cache.lookup('k1'), isNull);
    expect(cache.length, 0);
  });

  test('expires at the ttl boundary, including zero ttl', () {
    var now = DateTime(2026, 1, 1);
    final cache = NegativeCache(
      ttl: const Duration(seconds: 60),
      now: () => now,
    );
    cache.record('key', err);
    now = now.add(const Duration(seconds: 60));
    expect(cache.lookup('key'), isNull);

    final disabled = NegativeCache(ttl: Duration.zero, now: () => now);
    disabled.record('key', err);
    expect(disabled.lookup('key'), isNull);
  });

  test('unknown keys return null', () {
    final cache = NegativeCache(ttl: const Duration(seconds: 60));
    expect(cache.lookup('nope'), isNull);
  });

  test('re-recording overwrites the previous error and restarts the ttl', () {
    var now = DateTime(2026, 1, 1);
    final cache = NegativeCache(
      ttl: const Duration(seconds: 60),
      now: () => now,
    );
    cache.record('k1', err);
    now = now.add(const Duration(seconds: 50));
    const err2 = ThumbnailException(ThumbnailErrorCode.timeout, 'slow');
    cache.record('k1', err2);
    now = now.add(const Duration(seconds: 50));
    expect(cache.lookup('k1'), same(err2));
  });

  test('remove and clear drop entries', () {
    final cache = NegativeCache(ttl: const Duration(seconds: 60));
    cache.record('k1', err);
    cache.record('k2', err);
    cache.remove('k1');
    expect(cache.lookup('k1'), isNull);
    expect(cache.lookup('k2'), same(err));
    cache.clear();
    expect(cache.length, 0);
  });

  test('removeByPrefix drops only matching keys', () {
    final cache = NegativeCache(ttl: const Duration(seconds: 60));
    cache.record('aaaa-1111.jpg', err);
    cache.record('aaaa-2222.jpg', err);
    cache.record('bbbb-3333.jpg', err);
    cache.removeByPrefix('aaaa');
    expect(cache.lookup('aaaa-1111.jpg'), isNull);
    expect(cache.lookup('aaaa-2222.jpg'), isNull);
    expect(cache.lookup('bbbb-3333.jpg'), same(err));
  });

  test('never stores cancelled errors', () {
    final cache = NegativeCache(ttl: const Duration(seconds: 60));
    const cancelled = ThumbnailException(
      ThumbnailErrorCode.cancelled,
      'user scrolled away',
    );
    cache.record('k1', cancelled);
    expect(cache.lookup('k1'), isNull);
  });
}
