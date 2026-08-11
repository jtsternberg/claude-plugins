# Claude Code and Codex compatibility

This is the maintained guide for installing and using this repository's
plugins in Claude Code and Codex. The harnesses deliberately publish different
catalogs, so install from the column that matches the client you are using.

**Last reviewed:** 2026-08-11

**Catalog probes:** Claude Code 2.1.226 and Codex CLI 0.147.0

The clean probes found 27 entries in the Claude Code marketplace and exactly
three entries in the Codex-native marketplace: `codex`, `pr-workflow`, and
`hotline`. Together those catalogs name 28 plugins. Recheck this guide after a
client upgrade or a catalog change.

## Install and invoke

### Claude Code

Add the marketplace, install an **Available** plugin from the matrix, and use
its skill's frontmatter `name`:

```bash
claude plugin marketplace add jtsternberg/claude-plugins
claude plugin install pr-workflow@jtsternberg
```

```text
/pr-workflow:qa-walkthrough-pr
```

The invocation form is `/<plugin>:<frontmatter-name>`; a skill directory name
is not necessarily its invocation name.

### Codex

Add the marketplace, then choose one of the three **Available** Codex-native
plugins in the matrix:

```bash
codex plugin marketplace add jtsternberg/claude-plugins
codex plugin add pr-workflow@jtsternberg
```

Open `/plugins` in Codex to browse configured marketplaces. Start a new Codex
session after installing or updating a plugin, then invoke a skill with
`$<plugin>:<frontmatter-name>`:

```text
$pr-workflow:qa-walkthrough-pr
```

For example, the `hotline-ringing` frontmatter name is invoked as
`$hotline:hotline-ringing`, not by its directory name alone.

### Update an installed plugin

Refresh the marketplace and plugin in Claude Code:

```bash
claude plugin marketplace update jtsternberg
claude plugin update pr-workflow@jtsternberg
```

Refresh the Git marketplace snapshot in Codex:

```bash
codex plugin marketplace upgrade jtsternberg
codex plugin list --available --json
```

Codex CLI 0.147.0 reconciled installed versioned caches during marketplace
upgrade in the repository's release probe. If the expected version is absent,
run `codex plugin add <plugin>@jtsternberg` again. Start a new session in either
harness before testing changed skills, hooks, or tools.

### One skill instead of a plugin

If you need a single self-contained skill rather than a whole plugin, follow
the [standalone skill guide](codex/standalone-skills.md). It covers the supported
`.agents/skills` locations, the installer, and the boundary for skills that
depend on plugin-root resources.

Plugin authors and maintainers should use the [release guide](release.md) for
versioning, catalog refresh, cache verification, and cross-harness checks; it
is deliberately not repeated here.

## Runtime boundaries

- Reusable workflows are shipped as `skills/<name>/SKILL.md`. Claude Code
  invokes them with `/`; Codex mentions them with `$`.
- Codex does not expose cached `commands/*.md` files as plugin commands. This
  repository has migrated its reusable command workflows to skills.
- Codex runs plugin hooks only after the user trusts them. Hook path resolution
  and skill-body shell path resolution are separate contracts.
- Skill-body commands must not assume Claude path variables exist in Codex.
  The repository's dual-harness authoring pattern keeps Claude's literal path
  token and gives Codex adjacent path-substitution instructions.

## Reading the matrix

- **Available** means the plugin appears in that harness's observed catalog and
  is maintained as a working surface for that harness. Packaging and repository
  checks support the classification; machine-specific prerequisites remain the
  user's responsibility.
- **Not offered** means it does not appear in that harness's observed catalog;
  it is not a claim that the underlying idea could never work there.
- **Redirect** means this repository's catalog entry is not the working plugin;
  it points users to a separately maintained distribution.
- **Manual setup** means no installable skill/plugin surface is supplied for
  that use case; follow the linked plugin documentation instead.

Availability is separate from prerequisites. An available plugin can still
require an operating system, a local executable, authentication, a project
state, or user configuration. Those constraints are noted in the last column.

## Plugin support matrix

| Plugin | Claude Code | Codex | Requirements and scope |
| --- | --- | --- | --- |
| [agentmail](../plugins/agentmail) | Available | Not offered | Requires the `agentmail` CLI and an `AGENTMAIL_API_KEY`. |
| [beads-workflow](../plugins/beads-workflow) | Available | Not offered | Requires the `bd` CLI for Beads work. |
| [bible](../plugins/bible) | Available | Not offered | Requires the configured Bible API access. |
| [cmux-cli](../plugins/cmux-cli) | Available | Not offered | macOS only; requires cmux.app and its `cmux` executable. |
| [codex](../plugins/codex) | Not offered | Available | Codex-native model-stance and delegation skills. |
| [collab-tools](../plugins/collab-tools) | Available | Not offered | No extra platform requirement documented. |
| [export-presentation](../plugins/export-presentation) | Available | Not offered | Requires browser automation dependencies. |
| [fable](../plugins/fable) | Available | Not offered | Claude Code plugin; the Codex-native `codex` plugin carries its separate A/B skills. |
| [generating-blog-images](../plugins/generating-blog-images) | Available | Not offered | Produces prompts; use of an image provider is a separate choice. |
| [git-commits](../plugins/git-commits) | Available | Not offered | Requires a Git working tree. |
| [git-tree](../plugins/git-tree) | Available | Not offered | Requires Git and local worktree prerequisites. |
| [gws](../plugins/gws) | Available | Not offered | Requires the Google Workspace CLI and its authentication/setup. |
| [handoff](../plugins/handoff) | Available | Not offered | Uses local session/Beads context as described by the plugin. |
| [headline-refiner](../plugins/headline-refiner) | Available | Not offered | No extra platform requirement documented. |
| [hotline](../plugins/hotline) | Available | Available | Codex can place calls; the current launch transport starts Claude Code receivers. `cmux` is optional/preferred on macOS; calls need reachable local workspaces and a working Claude launcher. |
| [localwp-shell](../plugins/localwp-shell) | Available | Not offered | macOS only; requires LocalWP and its local shell tooling. |
| [mac-caffeinate](../plugins/mac-caffeinate) | Available | Not offered | macOS only; uses the system `caffeinate` utility. |
| [obsidian-cli](../plugins/obsidian-cli) | Available | Not offered | Requires Obsidian CLI v1.12+ and a local vault. |
| [paperclip](../plugins/paperclip) | Available | Not offered | Requires a locally running Paperclip instance and CLI. |
| [pr-workflow](../plugins/pr-workflow) | Available | Available | Individual workflows may require an open PR, Git, GitHub CLI authentication, or Beads. |
| [publish-insights](../plugins/publish-insights) | Redirect | Not offered | Install from the separately maintained `jtsternberg/claude-usage-data` marketplace; it also requires Git, authenticated `gh`, and a Claude Code insights report. |
| [research-tools](../plugins/research-tools) | Available | Not offered | Requires network access for source retrieval. A self-contained skill can instead be installed through the standalone guide. |
| [session-tools](../plugins/session-tools) | Available | Not offered | Operates on Claude Code session transcripts. |
| [skill-tools](../plugins/skill-tools) | Available | Not offered | Some workflows require their documented local toolchain. |
| [slack](../plugins/slack) | Available | Not offered | Requires Slack Web API credentials/configuration. |
| [slides-presentation](../plugins/slides-presentation) | Available | Not offered | Requires its documented browser/image-generation tooling as needed. |
| [thinking-tools](../plugins/thinking-tools) | Available | Not offered | No extra platform requirement documented. |
| [work-with-media](../plugins/work-with-media) | Available | Not offered | macOS support is required for MacWhisper; `yt-dlp` covers supported URL workflows. |
| [workspace-status](../plugins/workspace-status) | Manual setup | Not offered | Configure Claude Code's `statusLine` manually as documented; requires PHP (and Git for repository status). |

The matrix describes what each marketplace offers, not a promise that every
skill can complete every workflow on every machine. For prior probes and
version-specific implementation evidence, see the [Codex documentation
index](codex/README.md).
