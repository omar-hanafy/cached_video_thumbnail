import 'package:flutter_test/flutter_test.dart';
import 'package:cached_video_thumbnail/cached_video_thumbnail.dart';

void main() {
  group('VideoSource', () {
    test('asset factory creates AssetVideoSource with key and package', () {
      final source = VideoSource.asset(
        'assets/videos/intro.mp4',
        package: 'my_pkg',
      );
      expect(source, isA<AssetVideoSource>());
      final asset = source as AssetVideoSource;
      expect(asset.assetKey, 'assets/videos/intro.mp4');
      expect(asset.package, 'my_pkg');
    });

    test('file factory creates FileVideoSource', () {
      final source = VideoSource.file('/tmp/video.mp4');
      expect(source, isA<FileVideoSource>());
      expect((source as FileVideoSource).path, '/tmp/video.mp4');
    });

    test('network factory creates NetworkVideoSource with headers', () {
      final url = Uri.parse('https://cdn.example.com/v.mp4');
      final source = VideoSource.network(
        url,
        headers: {'Authorization': 'Bearer x'},
      );
      expect(source, isA<NetworkVideoSource>());
      final net = source as NetworkVideoSource;
      expect(net.url, url);
      expect(net.headers, {'Authorization': 'Bearer x'});
    });

    test('asset equality covers key and package', () {
      expect(VideoSource.asset('a.mp4'), equals(VideoSource.asset('a.mp4')));
      expect(
        VideoSource.asset('a.mp4', package: 'p'),
        isNot(equals(VideoSource.asset('a.mp4'))),
      );
      expect(
        VideoSource.asset('a.mp4'),
        isNot(equals(VideoSource.asset('b.mp4'))),
      );
    });

    test('file equality covers path', () {
      expect(VideoSource.file('/a.mp4'), equals(VideoSource.file('/a.mp4')));
      expect(
        VideoSource.file('/a.mp4'),
        isNot(equals(VideoSource.file('/b.mp4'))),
      );
    });

    test('network equality is over the url and ignores headers', () {
      final url = Uri.parse('https://cdn.example.com/v.mp4');
      expect(
        VideoSource.network(url, headers: {'a': '1'}),
        equals(VideoSource.network(url, headers: {'b': '2'})),
      );
      expect(
        VideoSource.network(url),
        isNot(
          equals(
            VideoSource.network(Uri.parse('https://cdn.example.com/w.mp4')),
          ),
        ),
      );
    });

    test('network rejects non-http schemes', () {
      expect(
        () => VideoSource.network(Uri.parse('ftp://x/v.mp4')),
        throwsArgumentError,
      );
      expect(
        () => VideoSource.network(Uri.parse('file:///v.mp4')),
        throwsArgumentError,
      );
    });

    test('file rejects relative and empty paths', () {
      expect(() => VideoSource.file('relative/v.mp4'), throwsArgumentError);
      expect(() => VideoSource.file(''), throwsArgumentError);
    });

    test('asset rejects empty key', () {
      expect(() => VideoSource.asset(''), throwsArgumentError);
    });

    test('describe is human readable', () {
      expect(
        VideoSource.asset('a.mp4', package: 'p').describe(),
        'asset:p/a.mp4',
      );
      expect(VideoSource.asset('a.mp4').describe(), 'asset:a.mp4');
      expect(VideoSource.file('/x/v.mp4').describe(), 'file:/x/v.mp4');
      expect(
        VideoSource.network(Uri.parse('https://c.io/v.mp4')).describe(),
        'url:https://c.io/v.mp4',
      );
    });
  });

  group('ThumbnailSpec', () {
    test('defaults match the spec', () {
      const spec = ThumbnailSpec();
      expect(spec.maxWidth, 0);
      expect(spec.maxHeight, 0);
      expect(spec.position, Duration.zero);
      expect(spec.exact, isFalse);
      expect(spec.format, ThumbnailFormat.jpeg);
      expect(spec.quality, 80);
    });

    test('equality and hashCode cover all fields', () {
      const a = ThumbnailSpec(maxWidth: 320, maxHeight: 320, quality: 70);
      const b = ThumbnailSpec(maxWidth: 320, maxHeight: 320, quality: 70);
      expect(a, equals(b));
      expect(a.hashCode, b.hashCode);
      expect(
        a,
        isNot(
          equals(
            const ThumbnailSpec(maxWidth: 321, maxHeight: 320, quality: 70),
          ),
        ),
      );
      expect(a, isNot(equals(a.copyWith(exact: true))));
      expect(a, isNot(equals(a.copyWith(format: ThumbnailFormat.png))));
      expect(
        a,
        isNot(equals(a.copyWith(position: const Duration(seconds: 1)))),
      );
    });

    test('copyWith replaces only the given fields', () {
      const a = ThumbnailSpec(maxWidth: 100);
      final b = a.copyWith(quality: 50);
      expect(b.maxWidth, 100);
      expect(b.quality, 50);
      expect(b.format, ThumbnailFormat.jpeg);
    });

    test('validation rejects bad values', () {
      expect(() => ThumbnailSpec(maxWidth: -1).validate(), throwsArgumentError);
      expect(
        () => ThumbnailSpec(maxHeight: -5).validate(),
        throwsArgumentError,
      );
      expect(() => ThumbnailSpec(quality: 0).validate(), throwsArgumentError);
      expect(() => ThumbnailSpec(quality: 101).validate(), throwsArgumentError);
      expect(
        () =>
            ThumbnailSpec(position: const Duration(milliseconds: -1))
                .validate(),
        throwsArgumentError,
      );
      expect(() => const ThumbnailSpec().validate(), returnsNormally);
    });
  });

  group('ThumbnailFormat', () {
    test('exposes extension, mime type and wire name', () {
      expect(ThumbnailFormat.jpeg.fileExtension, 'jpg');
      expect(ThumbnailFormat.jpeg.mimeType, 'image/jpeg');
      expect(ThumbnailFormat.jpeg.wireName, 'jpeg');
      expect(ThumbnailFormat.png.fileExtension, 'png');
      expect(ThumbnailFormat.png.mimeType, 'image/png');
      expect(ThumbnailFormat.png.wireName, 'png');
    });
  });

  group('Thumbnail', () {
    test('holds result fields', () {
      const t = Thumbnail(
        filePath: '/c/x.jpg',
        width: 320,
        height: 180,
        wasCached: true,
      );
      expect(t.filePath, '/c/x.jpg');
      expect(t.width, 320);
      expect(t.height, 180);
      expect(t.wasCached, isTrue);
      expect(t.toString(), contains('320x180'));
    });
  });

  group('ThumbnailPriority', () {
    test('orders prefetch < normal < visible', () {
      expect(
        ThumbnailPriority.prefetch.index < ThumbnailPriority.normal.index,
        isTrue,
      );
      expect(
        ThumbnailPriority.normal.index < ThumbnailPriority.visible.index,
        isTrue,
      );
    });
  });

  group('ThumbnailException', () {
    test('toString includes code and message', () {
      const e = ThumbnailException(ThumbnailErrorCode.network, 'boom');
      expect(e.toString(), contains('network'));
      expect(e.toString(), contains('boom'));
    });

    test('carries an optional cause', () {
      final cause = Exception('inner');
      final e = ThumbnailException(
        ThumbnailErrorCode.io,
        'outer',
        cause: cause,
      );
      expect(e.cause, same(cause));
      expect(e.toString(), contains('inner'));
    });
  });
}
