## 0.2.0

- **Breaking:** requires Flutter 3.47.7 and Dart 3.13.5 or newer (Dart 3).
  iOS 15 is now the minimum, matching Flutter's supported platforms.
  The public thumbnail API is unchanged; upgrade the app's SDK and CI
  toolchain before updating the dependency.
- Fix Unicode source identities that could share a disk-cache key. Cache
  schema v2 invalidates existing thumbnails and regenerates them on demand.
- Keep native extraction within the configured concurrency limit after
  cancellation or timeout, and preserve priority changes while requests
  initialize or join queued work.
- Fix automatic image cancellation when widgets leave the tree, and allow
  failed image streams to retry without clearing Flutter's entire image cache.
- Serialize disk-cache changes, clean failed extraction output, preserve
  active writes during cache clearing, and allow cache initialization to retry
  after an I/O failure. Reject negative timeouts and expire failures at the
  configured TTL boundary.
- Fix Swift Package Manager integration on iOS and include the plugin's
  privacy manifest in SwiftPM builds. Preserve cancellation while iOS loads
  video metadata.
- Update Android build support to AGP 9.3.1, Gradle 9.7.0, and Kotlin
  2.4.21, and refresh supported Dart dependencies and generated channels.
  Require a Dart-compatible minimum for the transitive `platform` package.
- Fix error handling and disposal in the example benchmark and playground.
- Add a `migrate-v0-1-to-v0-2` agent skill covering the SDK requirements,
  cache regeneration, and cancellation behavior.

## 0.1.1

No changes to the Dart/native runtime; this release adds repo-distributed
AI coding-assistant support and maintainer tooling.

- Installable agent plugin for Claude Code and OpenAI Codex, hosted in
  this repository (`agent-plugin/cached-video-thumbnail`, one shared
  skills tree, dual manifests, repo-root marketplace catalogs for both
  clients). Install commands are in the README.
- Four package-specific skills: `integrate-feed-thumbnails` (feed wiring,
  physical-pixel specs, priorities, prefetch, audit checklist),
  `diagnose-thumbnail-issues` (error codes, negative cache, platform
  quirks, metrics triage), `mock-thumbnail-engine` (hermetic tests with an
  injectable fake extractor), and `migrate-from-video-thumbnail`
  (video_thumbnail / flutter_video_thumbnail_plus / get_thumbnail_video /
  fc_native_video_thumbnail conversions), plus a read-only
  `thumbnail-integration-auditor` agent for Claude Code.
- Repository guidance for coding agents (`AGENTS.md`, imported by
  `CLAUDE.md`) covering validation gates, generated-file rules, the
  error-code contract, and the release process.
- CI now validates the plugin tree and version sync
  (`tool/validate_agent_plugin.dart`); the plugin tree is excluded from
  the pub archive (`.pubignore`), which is why the package itself is
  unchanged.

## 0.1.0

Initial release: a disk-cached, scheduled, cancellable video thumbnail
engine for Android and iOS, designed for infinite feeds on low-end devices.

- Thumbnails from Flutter bundle assets, local files, and http(s) URLs
  (with optional request headers), requested with `getThumbnail` (a plain
  `Future`) or `thumbnail` (a cancellable request handle).
- `ThumbnailSpec` controls the output: fit-within sizing that preserves
  aspect ratio and never upscales, frame position (clamped into the video's
  duration), nearest-keyframe or exact-frame seeking, JPEG or PNG encoding,
  and JPEG quality.
- Persistent disk cache with deterministic keys, atomic writes, and LRU
  eviction capped by total bytes and entry count; hits are served from an
  in-memory index with no decoding and no platform-channel round trip. A
  file's cache identity includes its size and modification time, so editing
  a local video invalidates its thumbnails automatically.
- Request scheduling built for scroll performance: `visible`, `normal`, and
  `prefetch` priority bands, newest-first dispatch within a band, a bounded
  number of concurrent native extractions, coalescing of identical
  requests, per-request cancellation, priority bumping, and per-request
  timeouts.
- Negative caching: recent failures are remembered for a configurable TTL
  and fail fast instead of re-hammering a broken source during scroll.
- `VideoThumbnailImage`, an `ImageProvider` for any `Image` widget: its
  identity covers source and spec so Flutter's `ImageCache` deduplicates
  identical tiles, generation is cancelled when the last listener detaches,
  and externally purged or corrupted cache files are evicted and
  regenerated on the next resolve.
- Cache management: `prefetch` for warming, `evict` for a single source,
  and `clearCache` for everything.
- Every failure is a `ThumbnailException` carrying a classified
  `ThumbnailErrorCode` (asset/file not found, network, unsupported media,
  timeout, cancelled, ...); failures are never silently swallowed into
  nulls or booleans.
- Observability: a `metrics` snapshot (requests, cache hits, coalesced
  joins, extractions, failures, queue depth, and extraction and queue-wait
  percentiles) plus an `onEvent` hook for structured engine events.
- Engine tuning through `ThumbnailEngineConfig`: extraction concurrency,
  default timeout, negative-cache TTL, cache size caps, and the default
  spec.
- Hermetic test support: `ThumbnailEngine.forTesting` with an injectable
  `ThumbnailExtractor` and cache directory, so app tests run without native
  code.
