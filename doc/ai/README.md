# AI coding-assistant support

`cached_video_thumbnail` ships an installable agent plugin for
**Claude Code** and **OpenAI Codex**. It packages what an assistant needs
to work with this engine correctly - the knowledge is otherwise spread
across the engine source, native extractors, and design docs, and the
package is newer than most models' training data.

One canonical plugin tree serves both clients
(`agent-plugin/cached-video-thumbnail/`): skills follow the open Agent
Skills format (`skills/<name>/SKILL.md`), with a Claude manifest at
`.claude-plugin/plugin.json` and a Codex manifest at
`.codex-plugin/plugin.json`. Repo-root catalogs:
`.claude-plugin/marketplace.json` (Claude) and
`.agents/plugins/marketplace.json` (Codex).

## Supported clients

| Client | Support |
|---|---|
| Claude Code (CLI, desktop, IDE extensions) | Full plugin: 4 skills + 1 agent |
| Codex CLI | Full plugin: 4 skills (`/plugins`, `/skills`) |
| ChatGPT desktop app (Codex/Work mode) | Plugin skills |
| Codex IDE extension / mobile / Chat mode | Plugins not supported by these surfaces |
| Codex cloud | Not officially supported for plugins; repo-checked-in `AGENTS.md` still applies |

## Install / update / remove

Claude Code:

```sh
claude plugin marketplace add omar-hanafy/cached_video_thumbnail
claude plugin install cached-video-thumbnail@cached-video-thumbnail
claude plugin update cached-video-thumbnail@cached-video-thumbnail   # update
claude plugin uninstall cached-video-thumbnail@cached-video-thumbnail
claude plugin marketplace remove cached-video-thumbnail
```

OpenAI Codex:

```sh
codex plugin marketplace add omar-hanafy/cached_video_thumbnail
codex plugin add cached-video-thumbnail@cached-video-thumbnail
codex plugin marketplace upgrade    # refresh marketplace snapshot(s)
codex plugin remove cached-video-thumbnail@cached-video-thumbnail
codex plugin marketplace remove cached-video-thumbnail
```

Start a **new session** after install so components are discovered. Both
CLIs also offer interactive flows (`/plugin` in Claude Code, `/plugins` in
Codex).

## Capabilities

### Skills (both clients)

**`integrate-feed-thumbnails`** - wiring thumbnails into feeds, grids,
lists, chats: `VideoThumbnailImage` usage, physical-pixel `ThumbnailSpec`
sizing, priorities and prefetch, one-shot engine configuration, and an
audit checklist for existing integrations. Includes the full API quick
reference. Try: *"Add video covers to this grid; it targets low-end
Android."*

**`diagnose-thumbnail-issues`** - evidence-first triage of
`ThumbnailException` codes, metrics interpretation, negative-cache
semantics, and the documented platform quirks (Android 404-as-timeout,
HLS variance, cancellation asymmetry). Try: *"Why do failed thumbnails
keep failing instantly for a minute?"*

**`mock-thumbnail-engine`** - hermetic tests for app code that uses the
package: `ThumbnailEngine.forTesting`, engine injection into
`VideoThumbnailImage`, and a ready-to-adapt fake extractor that honors the
extractor contract. Try: *"Make these widget tests run without the native
plugin."*

**`migrate-from-video-thumbnail`** - guided conversion from
`video_thumbnail`, `flutter_video_thumbnail_plus`, `get_thumbnail_video`,
and `fc_native_video_thumbnail`: detection greps, API mapping tables,
semantic diffs (bytes vs files, nulls vs typed errors, WebP removal,
platform gates), ordered steps, validation, rollback. Try: *"Replace
video_thumbnail across lib/."*

The **`migrate-v0-1-to-v0-2`** skill covers the Flutter 3.47.7 / Dart 3.13.5
minimums, automatic cache regeneration, and bounded native work after
cancellation when upgrading an existing 0.1.x consumer.

### Agent (Claude Code only)

**`thumbnail-integration-auditor`** - an isolated, read-only subagent
(Read/Grep/Glob/Bash tools) that scans a consumer codebase against the
integration checklist and returns severity-ranked findings with file:line
references. Claude Code delegates to it for whole-codebase audits; Codex
users get the same checklist inline via the integrate skill.

### Deliberately not included

No hooks (nothing here needs lifecycle automation in consumer projects),
no MCP server (no structured tool beats reading the project directly), no
install-time scripts, no telemetry, no network access. Skills are plain
markdown; the only permissions involved are the read-only tools declared
by the auditor agent.

## Version compatibility

The plugin version equals the package version (enforced by
`tool/validate_agent_plugin.dart` in CI). Skill content targets
`cached_video_thumbnail` 0.2.x. Skills instruct the agent to verify the
installed package version and trust `.pub-cache` sources over skill text
if they ever disagree.

## Troubleshooting

- **Skills don't trigger**: confirm the plugin is installed and enabled
  (`claude plugin list` / `codex plugin list`), then start a new session.
  Explicit invocation: `/cached-video-thumbnail:<skill>` (Claude),
  `$<skill>` (Codex).
- **Marketplace add fails**: the source must be the public repo
  `omar-hanafy/cached_video_thumbnail` (or its full Git URL). Corporate
  proxies blocking GitHub will block installation.
- **Name collision**: each client allows one marketplace named
  `cached-video-thumbnail`; re-adding replaces the previous registration.
- **Codex IDE extension**: plugins are not available there; use Codex CLI
  or the ChatGPT desktop app.

## For maintainers

- Validate locally: `dart tool/validate_agent_plugin.dart` (also in CI)
  and `claude plugin validate . --strict` plus
  `claude plugin validate agent-plugin/cached-video-thumbnail --strict`.
- Smoke-test an install from the working copy:
  `claude plugin marketplace add /path/to/checkout` then
  `claude plugin install cached-video-thumbnail@cached-video-thumbnail`;
  Codex equivalent: `codex plugin marketplace add /path/to/checkout`.
- Adding a skill: `skills/<kebab-name>/SKILL.md` with `name` and
  `description` frontmatter (description = triggering conditions, third
  person); keep heavy material in `references/` next to the skill; run the
  validator.
- Release rule: bump the version in both plugin manifests together with
  `pubspec.yaml` (validator enforces), and every breaking package release
  must add a `migrate-vA-to-vB` skill before tagging (see `AGENTS.md`).
- The pub archive must never contain the plugin tree (`.pubignore` keeps
  `agent-plugin/` out; the validator checks this too).
