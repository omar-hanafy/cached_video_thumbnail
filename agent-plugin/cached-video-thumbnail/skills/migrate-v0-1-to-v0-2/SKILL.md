---
name: migrate-v0-1-to-v0-2
description: Upgrade a cached_video_thumbnail consumer from 0.1.x to 0.2.x, including the Flutter and Dart minimums, cache regeneration, and cancellation behavior.
---

# Upgrade cached_video_thumbnail 0.1 to 0.2

Read the consumer's pubspec, selected Flutter SDK, CI configuration, and
installed package source before editing. Version 0.2.0 requires Flutter
3.47.7 or newer and Dart 3.13.5 or newer within Dart 3. If the consumer must
support older SDKs, retain 0.1.x and explain that compatibility boundary.

Flutter 3.47 supports iOS 15 and newer. Raise the consumer's iOS deployment
target to 15 in its Xcode targets and Podfile (when present). Android remains
at API 24 or newer. Consumers that need iOS 13 or 14 must retain 0.1.x and
an older supported Flutter toolchain.

Update the consumer's SDK constraints and CI/toolchain selection together,
then change its dependency to `cached_video_thumbnail: ^0.2.0` and resolve
dependencies. Do not override Flutter's pinned transitive dependencies.

The public Dart thumbnail API is unchanged. No call-site rename is needed.
Check these behavioral changes when assessing the integration:

- Disk-cache schema v2 hashes Unicode source identities correctly. Old
  thumbnails are invalidated automatically and regenerate on demand;
  expect a cold disk cache after upgrading. Never migrate old cache keys.
- Cancellation and timeout still finish the caller's request promptly.
  Native work that cannot stop immediately continues to occupy its
  scheduler slot until it finishes, preserving the configured concurrency
  bound. Do not assume cancellation means a decoder is already idle.

Run the consumer's analyzer and tests, then exercise thumbnail generation,
cache reuse, and rapid scrolling/cancellation on its supported Android and
iOS targets. Distinguish source checks from actual platform execution.

For integration patterns use
[integrate-feed-thumbnails](../integrate-feed-thumbnails/SKILL.md); for
classified failures use
[diagnose-thumbnail-issues](../diagnose-thumbnail-issues/SKILL.md).
