# API mapping: video_thumbnail family -> cached_video_thumbnail

Source packages covered:

- `video_thumbnail` (justsoft, <= 0.5.6; upstream inactive)
- `flutter_video_thumbnail_plus` (copy-fork of the above, same call shape)
- `get_thumbnail_video` (fork; same call shape, returns `XFile`)
- `fc_native_video_thumbnail` (fc, 3.x; different call shape)

Fork APIs drift; always confirm the consumer's resolved package source in
`.pub-cache` before mapping mechanically. Map by parameter *semantics*
below, not by class name.

## video_thumbnail / flutter_video_thumbnail_plus / get_thumbnail_video

```dart
VideoThumbnail.thumbnailData({video, headers, imageFormat, maxWidth,
    maxHeight, timeMs, quality})            // -> Uint8List? (XFile in forks)
VideoThumbnail.thumbnailFile({video, headers, thumbnailPath, imageFormat,
    maxWidth, maxHeight, timeMs, quality})  // -> String? / XFile
```

| Old parameter | New equivalent | Notes |
|---|---|---|
| `video: String` (URL or local path) | `VideoSource.network(Uri.parse(s), headers: h)` or `VideoSource.file(s)` | Decide per call site; file paths must be absolute. Bundle assets: `VideoSource.asset` (new capability - delete copy-to-temp workarounds) |
| `headers:` | `VideoSource.network(headers: ...)` | Now excluded from cache identity; `evict` on content change |
| `imageFormat: ImageFormat.JPEG` | `format: ThumbnailFormat.jpeg` | |
| `imageFormat: ImageFormat.PNG` | `format: ThumbnailFormat.png` | `quality` ignored for png |
| `imageFormat: ImageFormat.WEBP` | **No equivalent** | Deliberate exclusion. Convert to jpeg and update downstream extension/MIME expectations, or do not migrate that call site |
| `maxWidth:`/`maxHeight:` (0 default) | `maxWidth:`/`maxHeight:` in `ThumbnailSpec` | Same fit-box idea, but physical px, aspect always preserved, never upscaled. Old code often left 0 (full size) - set a real box in feeds |
| `timeMs: int` | `position: Duration(milliseconds: n)` | New default seeks nearest keyframe (`exact: false`); old behavior was exact-seek-everywhere (that was also its perf defect). `exact: true` restores frame accuracy where required |
| `quality: int` (old default 10!) | `quality:` 1..100 (default 80) | 0 now throws. Old defaults produced very low quality jpegs; expect visually better output |
| `thumbnailPath:` (dir or file path) | none | Engine owns output in its LRU cache; copy `thumb.filePath` out when the caller needs ownership |
| Return `Uint8List?` | `Thumbnail.filePath` (+ `readAsBytes` only if bytes truly needed) | `Image.memory` -> `Image.file`, or better: `VideoThumbnailImage` provider |
| Return `null` on failure | `ThumbnailException{code}` thrown | Never null; branch on `ThumbnailErrorCode` |

## fc_native_video_thumbnail

```dart
FcNativeVideoThumbnail().getVideoThumbnail({srcFile, destFile, width,
    height, keepAspectRatio, format, quality, srcFileUri}) // -> bool
```

| Old | New | Notes |
|---|---|---|
| `srcFile:` (local path only) | `VideoSource.file(path)` | Network/asset sources are new capabilities here |
| `srcFileUri:` (Android content URI) | **No equivalent in 0.2.x** | `content://` is documented as not yet supported - keep such call sites on the old package or resolve the URI to a file first |
| `destFile:` | none | Engine-owned cache file; copy out if needed |
| `width:`/`height:` (required) | spec `maxWidth`/`maxHeight` | fc treats them similarly as a bounding box with `keepAspectRatio: true`; aspect is now always preserved (no stretch mode) |
| `format: 'jpeg'/'png'` | `ThumbnailFormat.jpeg/png` | fc's Android ignored the format and always wrote JPEG; the new engine honors it on both platforms - PNG call sites will now actually produce PNG |
| `quality:` | `quality:` | |
| Returns `false` / swallows errors | typed `ThumbnailException` | Real failure information for the first time; do not translate back into booleans |
| macOS / Windows support | **Android + iOS only** | Platform-gate before migrating (see SKILL.md Step 0) |
| No frame position parameter | `position:` | fc always used its platform default; pick explicitly now |

## What migrated code gains (mention in the PR description)

Disk cache with LRU + atomic writes, cache hits without decoding, request
coalescing, priority scheduling with bounded native concurrency (default
2), cancellation (automatic via `VideoThumbnailImage`), per-request
timeouts, negative caching of failures, typed errors, metrics/event hook,
and hermetic test injection (`ThumbnailEngine.forTesting`).
