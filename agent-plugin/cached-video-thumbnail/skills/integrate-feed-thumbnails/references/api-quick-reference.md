# cached_video_thumbnail 0.2.x - API quick reference

Everything below is the complete public API surface (single import:
`package:cached_video_thumbnail/cached_video_thumbnail.dart`). Facts here
were extracted from the package source; when in doubt, the installed
`.pub-cache` source wins.

## Sources

```dart
VideoSource.asset('assets/videos/intro.mp4', package: 'other_pkg'); // bundle
VideoSource.file('/absolute/path/video.mp4');   // must be absolute, non-empty
VideoSource.network(Uri.parse('https://cdn.io/v.mp4'),
    headers: {'Authorization': 'Bearer t'});    // http/https only
```

Constructors throw `ArgumentError` synchronously on invalid input (empty
asset key, relative file path, non-http(s) scheme).

Cache identity semantics:
- asset: key + package.
- file: path, PLUS mtime + size folded into the cache key at request time -
  editing a file self-invalidates its thumbnails; a missing file throws
  `ThumbnailException(fileNotFound)` at key-computation time.
- network: **URL only. Headers are deliberately NOT part of identity**
  (tokens rotate, content does not). If a URL's content truly changed, call
  `engine.evict(source)`.

## ThumbnailSpec

```dart
const ThumbnailSpec(
  maxWidth: 480,    // fit-within box, PHYSICAL px, 0 = unconstrained
  maxHeight: 480,   // aspect preserved; frames are NEVER upscaled
  position: Duration.zero, // clamped into the video duration natively
  exact: false,     // false = nearest keyframe (fast); true = exact frame (slow)
  format: ThumbnailFormat.jpeg, // or ThumbnailFormat.png
  quality: 80,      // 1..100, JPEG only; ignored (normalized to 100) for PNG
);
```

`validate()` throws `ArgumentError` for negative sizes/position or quality
outside 1..100; the engine calls it on every request. `copyWith`, `==`,
`hashCode`, `toString` provided.

## Engine

```dart
final engine = ThumbnailEngine.instance;               // shared singleton

await engine.configure(const ThumbnailEngineConfig(
  maxConcurrentExtractions: 2,   // 1..8
  defaultTimeout: Duration(seconds: 15),   // counted from native dispatch
  negativeCacheTtl: Duration(seconds: 60),
  maxCacheBytes: 256 << 20,      // cache sizing: BEFORE first request only,
  maxCacheEntries: 4000,         // later changes throw StateError
  defaultSpec: ThumbnailSpec(),
));

final request = engine.thumbnail(source,
    spec: spec, priority: ThumbnailPriority.visible, timeout: ...);
final Thumbnail t = await request.result;
request.cancel();                          // free pre-dispatch; detaches joiner
request.bumpPriority(ThumbnailPriority.visible);   // raise only, never lowers

final Thumbnail t2 = await engine.getThumbnail(source, spec: spec); // one-shot
engine.prefetch(source, spec: spec);      // fire-and-forget, lowest band,
                                          // errors only recorded in metrics
await engine.evict(source);     // all specs + content versions + neg. entries
await engine.clearCache();      // everything
engine.onEvent = (event) => log('$event');   // structured events, nullable
final m = engine.metrics;                    // snapshot, see below
```

`Thumbnail`: `filePath` (engine-owned cache file - never delete/move it;
copy out if you need ownership), `width`, `height`, `wasCached`.

Priorities: `visible > normal > prefetch`; newest-first (LIFO) within a
band. Identical (source, spec) requests coalesce into one extraction;
cancelling one joiner never affects the others.

## VideoThumbnailImage (ImageProvider)

```dart
Image(image: VideoThumbnailImage(source, spec: spec,
    priority: ThumbnailPriority.visible))   // priority is the default
```

- Identity/`==` = source + spec + engine (priority excluded) -> Flutter's
  `ImageCache` dedups identical tiles.
- Cancels the engine request when the last image-stream listener detaches.
- Decode failure of a cached file evicts the entry and rethrows; the next
  resolve regenerates it. Cancellation settles the dead stream with an
  inert transparent pixel instead of spamming FlutterError.
- Accepts `engine:` (named parameter) for injecting a test engine.

## Errors

Every failure is `ThumbnailException{code, message, cause}` with
`ThumbnailErrorCode` one of: `invalidSource, assetNotFound, fileNotFound,
network, unsupportedMedia, extractionFailed, encodingFailed, io, timeout,
cancelled`. Failures are never nulls or booleans.

## Metrics snapshot fields

`requests, cacheHits, coalescedJoins, extractions, cancellations, timeouts,
failures (Map<ThumbnailErrorCode, int>), queueDepth, activeJobs,
extractP50/extractP95, queueWaitP50/queueWaitP95` (percentiles over the last
256 samples, null until data exists).

## Cache behavior

Use `ThumbnailSpec` to size `VideoThumbnailImage` directly. A `ResizeImage`
wrapper bypasses its resolver and automatic cancellation tracking, though
native extraction remains bounded by the engine.

- Location: `<app cache dir>/thumbnail/v2/`; OS may purge it any time; the
  engine re-extracts on demand.
- Hits are answered from an in-memory index: no platform channel, no disk
  stat, no decode (dimensions are stored in the file name).
- Writes are atomic (`.part` temp + rename); orphans swept on init.
- LRU eviction to 90% of caps, async, off the request path.
- Negative cache: recent failures fast-fail for `negativeCacheTtl` (60s
  default); cancellations are never negative-cached; `evict`/`clearCache`
  clear entries; re-running `configure` rebuilds (clears) all failure memos.

## Platform envelope

Android minSdk 24, iOS 15+. No web/desktop backends in 0.2.x. Android
cannot abort in-flight native work (result is banked into the cache
instead); iOS cancels natively. Extraction of network sources downloads
just enough bytes to decode a frame (cheap for faststart MP4s).
