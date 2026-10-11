---
name: integrate-feed-thumbnails
description: Use when adding video thumbnails to a Flutter feed, grid, list, chat, or gallery with the cached_video_thumbnail package, when choosing ThumbnailSpec sizes, priorities, prefetch, or engine configuration, or when reviewing an existing integration for scroll jank and performance problems.
---

# Integrate cached_video_thumbnail into a feed

The engine's contract: thumbnail generation must never be the reason the UI
janks. Integration is about wiring the three layers so that contract holds:
`VideoThumbnailImage` in cells, one `configure()` at startup, `prefetch`
ahead of the viewport. API details: [api-quick-reference.md](references/api-quick-reference.md).

## Inspect the consumer project first

Before writing code, establish (do not assume):

1. `cached_video_thumbnail` version in `pubspec.lock`; this skill matches 0.2.x.
2. Target platforms. The package supports **Android (minSdk 24) and iOS (15+)
   only**. If the app also targets web/desktop, thumbnails need a platform
   branch; do not silently break those builds.
3. Cell geometry: logical size of each thumbnail widget and how it is laid out
   (ListView/GridView/slivers), plus target device DPR range.
4. Whether the app already calls `ThumbnailEngine.instance.configure` -
   cache sizing throws `StateError` if configured after the first request,
   so there must be exactly one early configure call.

## Core recipe

```dart
// 1. Once, in main(), BEFORE runApp / any thumbnail request:
await ThumbnailEngine.instance.configure(const ThumbnailEngineConfig(
  maxConcurrentExtractions: 2,   // 1 for very low-end fleets, max 8
));

// 2. In each cell: plain Image + the provider. Nothing else.
Image(
  image: VideoThumbnailImage(
    source,                       // VideoSource.network/file/asset
    spec: spec,                   // shared const spec, physical px
  ),
  fit: BoxFit.cover,
  errorBuilder: (_, _, _) => const ColoredBox(color: Color(0xFF202226)),
)

// 3. Ahead of the viewport (scroll listener or item builder lookahead):
ThumbnailEngine.instance.prefetch(source, spec: spec);
```

`VideoThumbnailImage` already gives you: `visible` priority, automatic
cancellation when the cell's last listener detaches mid-fling, Flutter
`ImageCache` deduplication (identity = source + spec), and eviction +
regeneration of externally corrupted cache files. Do not rebuild any of that
manually with `FutureBuilder` + `getThumbnail`.

## Spec sizing - the decision that matters most

`maxWidth`/`maxHeight` are a fit-within box in **physical pixels** (aspect
preserved, never upscaled, 0 = unconstrained on that axis):

```dart
final dpr = MediaQuery.devicePixelRatioOf(context);
final box = (cellLogicalSize * dpr).round().clamp(1, 1080);
final spec = ThumbnailSpec(maxWidth: box, maxHeight: box);
```

- An unconstrained spec (`ThumbnailSpec()`) decodes and stores full video
  frames - the single most common integration mistake.
- Use ONE shared spec per tile shape. Every distinct spec is a distinct
  cache entry and a distinct extraction; per-cell spec variation destroys
  both caches.
- A square box sized to the cell's larger physical dimension handles mixed
  landscape/portrait sources with `BoxFit.cover`.
- Cap the box (~1080px) so 3x-DPR tablets do not decode near-full-size
  frames for grid tiles.

## Decision points

| Decision | Default | Deviate when |
|---|---|---|
| `exact` | `false` (nearest keyframe) | Only for single hero/detail images; exact seeks may decode every frame since the last keyframe |
| `format` | `jpeg`, `quality: 80` | `png` only when artifacts are unacceptable (screenshots of text); quality is ignored for png |
| `position` | `Duration.zero` | ~1s dodges black opening frames for free (keyframe snap makes it cheap) |
| Priority | provider default `visible` | `prefetch` band for warmup; `normal` for off-screen UI like share sheets |
| API | `VideoThumbnailImage` | `engine.thumbnail()` handle when you need `cancel`/`bumpPriority` yourself; `getThumbnail()` for one-shot non-widget use |
| Concurrency | 2 | 1 for very low-end fleets; raising above 2-3 usually adds contention, verify with the bench page before changing |

## Verify

1. `dart analyze` and `dart format` on changed files.
2. Run the app; scroll fast; then inspect
   `ThumbnailEngine.instance.metrics`: warm-scroll `cacheHits/requests`
   should approach 1; `queueWaitP95` should stay low while extractions are
   bounded by the concurrency cap.
3. For systematic numbers, the package's example app ships a bench page
   (cold vs warm percentiles, scroll test) - useful when tuning concurrency.
4. Hermetic tests for new code: invoke the `mock-thumbnail-engine` skill.

## Common mistakes (audit checklist)

When reviewing an existing integration, flag these:

- No spec box, or logical-pixel box without DPR multiplication.
- `exact: true` inside any scrolling list.
- `FutureBuilder`/`initState` + `getThumbnail` inside cells: no cancellation,
  no ImageCache dedup; replace with `VideoThumbnailImage`.
- `configure()` called per widget/build, late (StateError on cache sizing),
  or from multiple places.
- Prefetching the entire data set at once (the band is bounded, but the
  queue churns) instead of a viewport-ahead window; or prefetching with a
  different spec than the cells render (warms the wrong entries).
- Deleting or moving files returned in `Thumbnail.filePath` - the engine
  owns them; copy out if ownership is needed.
- `clearCache()`/`evict()` on scroll paths or app start "to free space" -
  LRU already caps the cache (256 MiB / 4000 entries by default).
- Treating one `ThumbnailException` as fatal for the feed: failures are
  per-tile, classified, and negative-cached; render a quiet error box.

In Claude Code, delegate whole-codebase audits to the
`thumbnail-integration-auditor` agent from this plugin; otherwise apply the
checklist directly to every file that references the package.

## Failure handling

- Errors surface as `ThumbnailException` with a `ThumbnailErrorCode`; for
  causes, platform quirks (Android 404-as-timeout, HLS variance), and
  negative-cache behavior, invoke the `diagnose-thumbnail-issues` skill.
- If an API in this skill does not match the installed package version,
  trust the installed source (`.pub-cache`) and say so - do not guess.

## Example scenario

"Our explore tab (3-column grid, 120dp square tiles, low-end Android) shows
video covers; scrolling stutters." -> shared spec
`ThumbnailSpec(maxWidth: (120 * dpr).round(), maxHeight: (120 * dpr).round())`,
`VideoThumbnailImage` in tiles, configure concurrency 1-2 at startup,
prefetch next ~2 rows from the grid's scroll listener, verify with metrics
before/after: cacheHits climbing, no queueWait blowup.
