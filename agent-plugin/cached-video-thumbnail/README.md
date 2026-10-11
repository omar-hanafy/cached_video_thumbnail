# cached-video-thumbnail agent plugin

Package-specific AI coding-assistant support for the
[`cached_video_thumbnail`](https://pub.dev/packages/cached_video_thumbnail)
Flutter plugin. One canonical plugin tree, installable into both
**Claude Code** and **OpenAI Codex** from the package's GitHub repository.

This is tooling for coding agents. It is not a runtime feature of the Dart
package and is not shipped in the pub.dev archive.

## Installation

Claude Code (CLI shown; `/plugin` works interactively):

```sh
claude plugin marketplace add omar-hanafy/cached_video_thumbnail
claude plugin install cached-video-thumbnail@cached-video-thumbnail
```

OpenAI Codex (CLI; plugins also appear in `/plugins`):

```sh
codex plugin marketplace add omar-hanafy/cached_video_thumbnail
codex plugin add cached-video-thumbnail@cached-video-thumbnail
```

Start a new session after installing so the skills are discovered.

## Contents

| Component | Type | When it activates |
|---|---|---|
| `integrate-feed-thumbnails` | skill | Adding thumbnails to feeds/grids/lists; choosing specs, priorities, prefetch, engine config; reviewing an integration |
| `diagnose-thumbnail-issues` | skill | ThumbnailException errors, instant re-failures, cache misses, jank triage, platform quirks |
| `mock-thumbnail-engine` | skill | Writing hermetic tests for app code that uses the package |
| `migrate-from-video-thumbnail` | skill | Replacing video_thumbnail, flutter_video_thumbnail_plus, get_thumbnail_video, or fc_native_video_thumbnail |
| `migrate-v0-1-to-v0-2` | skill | Upgrading 0.1.x consumers to the new SDK minimums and cache schema |
| `thumbnail-integration-auditor` | agent (Claude Code only) | Read-only whole-codebase audit of an existing integration |

Skills follow the Agent Skills format (`skills/<name>/SKILL.md`) and are
shared verbatim by both clients; the manifests live in
`.claude-plugin/plugin.json` and `.codex-plugin/plugin.json`.

No hooks, no MCP servers, no scripts that execute on install, and no
network access: the plugin is instructions and reference files only. The
bundled agent is read-only by declared tool policy.

## Compatibility

Plugin version tracks the package version (validated in CI). Skill content
targets `cached_video_thumbnail` 0.2.x; when the package's public API
changes, skills are updated in the same release.

## Maintainers

Validation: `dart tool/validate_agent_plugin.dart` from the repo root
(runs in CI) plus `claude plugin validate . --strict`. Adding a skill:
create `skills/<kebab-name>/SKILL.md` with `name` + `description`
frontmatter; the validator enforces naming, frontmatter, link integrity,
and version sync. Every future breaking package release must add a
dedicated `migrate-vA-to-vB` skill before tagging (see repo AGENTS.md).
