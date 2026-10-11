# cached_video_thumbnail - agent guide

Flutter plugin (Android/iOS) that generates video thumbnails through a cached,
scheduled, cancellable pipeline. The design rationale and rejected alternatives
live in `doc/superpowers/specs/2026-07-06-thumbnail-engine-design.md`; read it
before changing engine semantics.

## Validation gates (run all before declaring work done)

```sh
dart pub get
dart format --output=none --set-exit-if-changed .
flutter analyze
flutter test
dart tool/validate_agent_plugin.dart   # agent-plugin tree + version sync
dart pub publish --dry-run
```

CI additionally requires a full pana score (160/160). Never "fix" a gate by
disabling tests, weakening lints, or excluding source files.

## Generated files - never edit by hand

`lib/src/pigeon/messages.g.dart`, `android/.../Messages.g.kt`, and
`ios/.../messages.g.swift` are generated from `pigeons/messages.dart`.
To change the channel: edit `pigeons/messages.dart`, run
`dart run pigeon --input pigeons/messages.dart`, then `dart format .`,
then update BOTH native implementations (`Extractor.kt`, `Extractor.swift`).

## Error-code contract

`ThumbnailErrorCode` enum names are the wire protocol: natives throw
`FlutterError`/`PigeonError` whose `code` must be one of those names, and
`mapPlatformError` maps by name. Adding or renaming a code requires, together:
the Dart enum, the doc comment in `pigeons/messages.dart`, both native
extractors (same classification on both platforms), the README error table,
and `test/pigeon_mapping_test.dart`.

## Engine invariants (PRs must not violate)

- Encoded image bytes never cross the platform channel; natives encode
  directly into the engine-chosen `destPath`.
- Disk-cache hits stay off the platform channel and never decode.
- Native concurrency is bounded by the Dart scheduler only; natives are
  stateless executors.
- Failures are always a classified `ThumbnailException`; never null/bool.
- Changing cache-key semantics requires bumping `cacheSchemaVersion`
  (`lib/src/cache/cache_key.dart`) to invalidate wholesale.

## Release process

- Branches: `main` = stable versions only; `dev` = `-dev.N` prereleases only
  (CI enforces this on every protected-lane PR and push).
- Flow: branch `release/X.Y.Z` -> bump `pubspec.yaml` + `CHANGELOG.md` -> PR
  -> merge. A package-version change on main/dev auto-tags
  `cached_video_thumbnail-vX.Y.Z` and publishes to pub.dev via trusted
  publishing (`.github/workflows/`). Never re-tag or reuse a version.
- Version sync: `pubspec.yaml`, both plugin manifests under
  `agent-plugin/cached-video-thumbnail/` (`.claude-plugin/plugin.json`,
  `.codex-plugin/plugin.json`) must carry the same version. The validator
  enforces this.

## Agent plugin (installable AI support)

`agent-plugin/cached-video-thumbnail/` is a dual-target plugin (Claude Code +
OpenAI Codex) with ONE canonical `skills/` tree; repo-root catalogs are
`.claude-plugin/marketplace.json` and `.agents/plugins/marketplace.json`.
It is repo-distributed and excluded from the pub archive via `.pubignore`.
Docs: `doc/ai/README.md`.

- Skill facts must match the current public API; when you change public API
  or documented behavior, update the affected skill in the same PR.
- Every future breaking release MUST ship a dedicated migration skill named
  `migrate-vA-to-vB` in the plugin before the release is tagged.

## Device / integration tests

CI runs the hermetic suite on Android and iOS simulators, plus the iOS native
cancellation tests. Run real-network checks explicitly on available devices:

```sh
cd example
flutter test integration_test/thumbnail_test.dart -d <device-id>   # hermetic
flutter test integration_test/remote_media_test.dart -d <device-id> # online
```
