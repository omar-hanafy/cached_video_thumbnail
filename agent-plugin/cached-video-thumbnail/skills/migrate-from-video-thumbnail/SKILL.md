---
name: migrate-from-video-thumbnail
description: Use when replacing the video_thumbnail, flutter_video_thumbnail_plus, get_thumbnail_video, or fc_native_video_thumbnail package with cached_video_thumbnail, or when code still calls VideoThumbnail.thumbnailData, VideoThumbnail.thumbnailFile, or FcNativeVideoThumbnail and should move to the cached engine.
---

# Migrate to cached_video_thumbnail

Converts one-shot `video -> image` calls from the video_thumbnail family
into engine requests. This is an API *and semantics* migration: results
become cache-owned files instead of caller-owned bytes/paths, failures
become typed exceptions instead of nulls/booleans, and every call becomes
cached, scheduled, and cancellable. Mapping tables:
[api-mapping.md](references/api-mapping.md).

## Step 0 - inspect before touching anything

1. Identify the source package and its call sites:
   ```
   grep -rn "video_thumbnail\|get_thumbnail_video\|fc_native_video_thumbnail" pubspec.yaml lib/ test/
   grep -rn "thumbnailData\|thumbnailFile\|getVideoThumbnail\|ImageFormat\." lib/ test/
   ```
2. Verify the old package's actual API in the consumer's resolved version
   (`.pub-cache`) - forks differ in return types (`String?` vs `XFile`).
3. **Platform gate**: cached_video_thumbnail supports Android (minSdk 24)
   and iOS (15+) only. fc_native_video_thumbnail also runs on macOS and
   Windows; flutter_video_thumbnail_plus has a web path. If the app builds
   those targets, keep the old package behind a platform branch for them or
   stop and surface the gap - do not silently drop platforms.
4. **WebP gate**: `ImageFormat.WEBP` has no equivalent (by design; only
   jpeg/png). Find WebP consumers downstream (file extensions, MIME types,
   upload endpoints) before converting them to jpeg.
5. Note where old code passed a `thumbnailPath`/`destFile` it later reads,
   moves, uploads, or deletes - file ownership changes below.

## Step 1 - dependencies

In `pubspec.yaml`: add `cached_video_thumbnail: ^0.2.0` (needs Dart SDK
^3.13.5, Flutter >= 3.47.7). Keep the old dependency until Step 4 verifies, so
the migration is revertible file-by-file; remove it as the final commit.

## Step 2 - convert call sites

Core translation (full parameter tables in the reference file):

```dart
// OLD (video_thumbnail / get_thumbnail_video)
final bytes = await VideoThumbnail.thumbnailData(
  video: url, imageFormat: ImageFormat.JPEG,
  maxWidth: 128, quality: 25, timeMs: 2000);

// NEW - widget display: skip bytes entirely, use the provider
Image(image: VideoThumbnailImage(
  VideoSource.network(Uri.parse(url)),
  spec: const ThumbnailSpec(maxWidth: 128, quality: 25,
      position: Duration(milliseconds: 2000)),
))

// NEW - when a file/bytes value is genuinely needed
final thumb = await ThumbnailEngine.instance.getThumbnail(
  VideoSource.network(Uri.parse(url)),
  spec: const ThumbnailSpec(maxWidth: 128, quality: 25,
      position: Duration(milliseconds: 2000)),
);
// thumb.filePath is ENGINE-OWNED cache; copy out if the caller needs
// ownership, readAsBytes only if bytes are truly required.
```

Decision per call site:
- Rendered in a widget -> `VideoThumbnailImage` (adds ImageCache dedup and
  scroll cancellation for free). Prefer this whenever possible.
- Needs a path/bytes (upload, share, save) -> `getThumbnail` + copy out of
  `thumb.filePath`.
- The old `video:` parameter was a String for BOTH urls and local paths:
  route to `VideoSource.network(Uri.parse(s))` vs `VideoSource.file(s)`
  explicitly (file paths must be absolute). Asset support is new
  (`VideoSource.asset`) - old code that copied assets to temp files first
  can drop that workaround entirely.

## Step 3 - semantic diffs reviewers must sign off on

- **Null/bool -> exceptions**: `== null` / `if (!ok)` checks become
  `try/catch on ThumbnailException` (plus `ArgumentError` for structurally
  invalid input, thrown synchronously).
- **Frame choice changes**: old packages seek exactly (slow); the new
  default `exact: false` snaps to the nearest keyframe. Feeds should keep
  the fast default even though pixels may differ from before; use
  `exact: true` only where the precise frame matters.
- **Quality clamps**: 1..100 now; literal `quality: 0` (seen with old PNG
  calls) throws `ArgumentError` - drop it, quality is ignored for PNG.
- **Sizing**: old `maxWidth`/`maxHeight` 0-defaults decoded full frames;
  new spec is a fit-within box in physical px that never upscales. Feeds
  should now SET a box (see the `integrate-feed-thumbnails` skill).
- **Caching changes retry behavior**: repeat calls become cache hits
  (`wasCached: true`); failures fast-fail for `negativeCacheTtl` (60s) -
  user-initiated retries should `await engine.evict(source)` first.
- **Do not delete/move `thumb.filePath`**: LRU owns it. Old cleanup code
  that deleted `thumbnailPath` outputs must be removed or pointed at
  copies.
- Headers are supported (`VideoSource.network(headers: ...)`) but excluded
  from cache identity; `evict` when content changes.

## Step 4 - validate

1. `dart analyze` clean; `dart format` changed files.
2. Run the app's existing tests. Tests that mocked the old package's
   method channel must move to the injectable fake engine - invoke the
   `mock-thumbnail-engine` skill.
3. On-device smoke test: one asset, one file, one network thumbnail, plus
   one deliberate failure (bad URL) proving the error path renders.
4. Remove the old dependency; `dart pub get`; re-run analyze + tests.

## Failure handling / rollback

- Already-migrated call sites are recognizable by `ThumbnailEngine` /
  `VideoThumbnailImage` usage - skip them idempotently.
- If a call site cannot be migrated (WebP contract, desktop platform),
  leave it on the old package, isolate it behind an adapter, and report it
  in the summary rather than forcing a broken conversion.
- Rollback = revert the migration commits; keeping the old dependency
  until final verification makes this a pure git operation.

## Example scenario

"Replace get_thumbnail_video in our chat app; thumbnails for received
videos are saved next to the media file." -> `getThumbnail` + explicit
copy to the media dir (ownership), `VideoThumbnailImage` for the bubbles,
try/catch replacing XFile-null checks, retry buttons call `evict` first,
WebP check (chat used jpeg - safe), old package removed after tests pass.
