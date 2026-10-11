# Error codes, causes, and platform behavior

## Per-code causes and fixes

### invalidSource
Structurally invalid input. Note that the common cases throw
`ArgumentError` synchronously at `VideoSource` construction (empty asset
key, relative/empty file path, non-http(s) scheme), so `invalidSource`
exceptions are rare in practice. Fix the input; nothing to retry.

### assetNotFound
Asset key not resolvable in the bundle. Check: exact key spelling including
`assets/` prefix, the asset declared under `flutter: assets:` in pubspec,
`package:` parameter set when the asset lives in another package, hot
restart after pubspec edits.

### fileNotFound
Thrown at cache-key computation (the file is stat'ed to fold mtime+size
into the key), so it fires even before any native work. Check the path
exists at request time; files in temp dirs may have been cleaned.

### network
Connectivity, DNS, TLS, or an HTTP failure that the platform media stack
actually surfaced. Transient ones are negative-cached (60s default);
retry-with-evict for user-initiated retries.

### unsupportedMedia
No decodable video track, unsupported codec/container, or a non-video URL
(e.g. an HTML page). Both platforms map "cannot open" data-source failures
for local/asset sources here too. If the file plays in the platform's video
player but fails here, report upstream with the file.

### extractionFailed
Decoder failed for another reason - and the fallback for platform errors
whose code is not a known `ThumbnailErrorCode` name (the raw code is
preserved in the message as `platform error <code>: <detail>`). A message
like that indicates a channel/plumbing problem, not a media problem:
check that the app actually bundles the plugin's native side (full restart
after adding the dependency, not hot reload; add-to-app setups must
register plugins).

### encodingFailed
Frame decoded but jpeg/png encode failed (rare; low memory or an exotic
bitmap config). Retry once; if persistent with PNG, try JPEG.

### io
Local write/rename failure in the cache dir: disk full or the OS removed
the directory mid-write. The engine recreates dirs on init; persistent io
errors usually mean disk pressure.

### timeout
The per-request deadline (default 15s, override per request or via config)
elapsed, counted from native dispatch (queue wait does not consume it).
On timeout the engine also requests native cancellation (effective on iOS;
Android lets the work finish and banks the frame, so a later retry often
hits the cache). Remote sources on slow networks and badly-muxed files
(moov atom at the end - the whole file downloads before a frame decodes)
are the usual causes. Remedies: faststart-encode server assets, longer
per-request `timeout:` for known-slow sources, shorter for feed tiles.

### cancelled
The caller (or `VideoThumbnailImage` on last-listener detach) cancelled.
Never negative-cached, never counted as a failure per-flight (counted per
caller in `metrics.cancellations`). Seeing many is normal during flings.

## Platform behavior differences

| Behavior | Android | iOS |
|---|---|---|
| Native engine | `MediaMetadataRetriever` | `AVAssetImageGenerator` (async API on iOS 16+, continuation fallback below) |
| Keyframe seek | `OPTION_CLOSEST_SYNC` (`OPTION_CLOSEST` when exact) | tolerances infinite (zero when exact) |
| Downscale | decode-time via `getScaledFrameAtTime` (API 27+; decode-then-scale on 24-26) | `maximumSize` fit box |
| In-flight cancel | NOT supported; request detaches, finished frame banked into cache | Per-request `cancelAllCGImageGeneration` |
| HTTP status on failure | Often swallowed by internal retries -> deadline -> `timeout` | Usually surfaced -> `network` |
| Asset access | APK file descriptor; one-time copy fallback for compressed assets (`<cache>/thumbnail_assets/`) | Bundle path lookup |
| Network headers | Passed to `setDataSource` | De-facto `AVURLAssetHTTPHeaderFieldsKey` option |
| HLS `.m3u8` | Device-dependent: frame, clean failure, or timeout | Device-dependent, generally better than Android |
| Rotation | Display-matrix metadata applied; fit box computed display-oriented | `appliesPreferredTrackTransform = true` |

Both platforms: encode straight to the destination file (no byte arrays
over the platform channel), position clamped into `[0, duration]`, minSdk
24 / iOS 15.

## Cache layers (who cached what)

1. **Flutter `ImageCache`** (in-memory, decoded): keyed by
   `VideoThumbnailImage` identity (source + spec + engine). A "stale"
   image after `evict` may be this layer - also call
   `PaintingBinding.instance.imageCache` eviction or use a new source.
2. **Engine in-memory index over the disk cache**: keyed by canonical
   (source, spec) key; hits cost no channel/disk/decode.
3. **Disk files** `<app cache>/thumbnail/v2/`: atomic writes, LRU to 90%
   of `maxCacheBytes`/`maxCacheEntries`, OS-purgeable.
4. **Negative cache** (in-memory): failure memos for `negativeCacheTtl`.

`evict(source)` clears 2-4 for every spec/content version of one source;
`clearCache()` clears 2-4 entirely; neither touches layer 1.

## Event hook

`engine.onEvent` receives structured `ThumbnailEvent`s
(`requested, cacheHit, coalesced, extracted, failed, timedOut, cancelled`,
with key, optional elapsed and error code). Wire it to the app logger
during diagnosis; listener exceptions are swallowed by design.
