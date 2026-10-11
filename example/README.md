# cached_video_thumbnail_example

Manual-verification app and test host for the `cached_video_thumbnail` engine.

## Tabs

- **Gallery**: one tile per generation path, all rendered through
  `VideoThumbnailImage`:
  - bundle assets (landscape + rotated portrait)
  - local files (fixtures copied to disk, `VideoSource.file`)
  - direct network links (Big Buck Bunny MP4 / M4V / MOV from
    download.blender.org)
  - an HLS stream (`.m3u8`, platform-dependent)
  - every `ThumbnailSpec` knob: position, exact, PNG, quality, fit box,
    unconstrained, past-the-end clamping
  - deliberate failures (404, non-video URL, missing asset) to show
    classified, bounded error handling
  - action chips for prefetch, cache clearing, and live engine metrics
- **Playground**: the direct `ThumbnailEngine` API with interactive
  controls; shows the raw `Thumbnail` result (dimensions, file size,
  `wasCached`, latency, path) and drives `prefetch`, `evict`, `clearCache`.
- **Bench**: cold vs warm runs with configurable request count, size, and
  concurrency; prints a metrics report.

## Tests

```sh
# Host-side tests (no device needed)
flutter test

# Hermetic on-device suite (loopback HTTP server, no internet needed)
flutter test integration_test/thumbnail_test.dart -d <device-id>

# Real-internet smoke tests (device must be online; hits blender.org + Mux)
flutter test integration_test/remote_media_test.dart -d <device-id>
```

iOS CI runs the hermetic Dart suite and native cancellation tests through
Flutter's XCTest integration runner. To use the same path on a booted simulator,
run from this directory after `flutter pub get`:

```sh
IOS_DEVICE=<simulator-uuid> RUNNER_TEMP="$(mktemp -d)" \
  bash ../.github/scripts/run-ios-integration.sh
```

The script selects the integration entrypoint, enables its native result channel,
and verifies 19 Dart tests and five Swift tests passed without skips. Its
`THUMBNAIL_INTEGRATION_TEST` compiler define enables the Objective-C bridge only
for this run; ordinary native-only Xcode tests do not wait for Dart results.
Use a fresh result directory for each invocation. When adding or removing tests,
update the expected counts in `../.github/scripts/verify-ios-test-results.py`.
