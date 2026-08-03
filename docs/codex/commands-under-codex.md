# `commands/` under Codex

**Verdict:** Codex 0.145.0 installs a plugin's `commands/*.md` files into its
cache but does not register, list, or execute them. The directory is a
Claude-Code-only command surface, not a Codex plugin component.

## Q1 — Scratch result

I added this deliberately distinctive legacy command to a scratch marketplace
plugin, bumped it from `1.0.9` to `1.0.10`, removed and re-added the plugin,
then opened a fresh Codex TUI:

```text
commands/probe-cmd.md

---
description: Emit the distinctive legacy-command marker.
---

Reply with exactly `LEGACY_COMMAND_PROBE_FIRED=yes`.
```

Raw observations (paths scrubbed):

```text
$ codex plugin list
probe-plugin@probe-mkt  installed  enabled  1.0.10

$ find <SCRATCH>/codex-home/plugins/cache/probe-mkt/probe-plugin/1.0.10 \
    -path '*/commands/*' -type f -print
<SCRATCH>/codex-home/plugins/cache/probe-mkt/probe-plugin/1.0.10/commands/probe-cmd.md
```

The plugin list contained no command entry. Typing `/` opened the normal Codex
command menu; filtering it with `/probe` produced no match. The cache copy is
therefore packaging behavior, not command discovery.

## Q2 — Codex custom prompts are not an alternative

The old Codex custom-prompt convention was one Markdown file per command in
`$CODEX_HOME/prompts` (normally `~/.codex/prompts`): the filename without
`.md` supplied the name and it was invoked as `/prompts:<name>`. Optional YAML
frontmatter supplied `description` and `argument_hint`; the remaining Markdown
was the prompt body. A historical worked example was:

```markdown
<!-- ~/.codex/prompts/review.md -->
---
description: Review the current working-tree change.
argument_hint: "[focus]"
---

Review the current working-tree change. Focus on: $ARGUMENTS
```

It was invoked as `/prompts:review error handling`.

This is **legacy syntax, not a current export target**. Custom prompts were
removed in Codex 0.117.0; the scratch runtime is Codex 0.145.0. The old
documentation route, [`docs/slash_commands.md`][slash-commands-source], now
only redirects readers to the general command reference. An upstream report
records both the old exact path/invocation and its disappearance at 0.117.0;
an OpenAI maintainer's resolution says to convert prompts to skills
([#15941][custom-prompts-removed]).

Codex's plugin surfaces do not provide a prompt-export component. The scratch
experiment establishes that simply shipping a Claude `commands/` directory does
not bridge that gap: it is copied but unavailable. So a plugin cannot ship a
working Codex custom prompt in the current runtime.

## Q3 — Repository command inventory

The remaining five command files are unavailable to Codex as commands:

| Plugin | Command file | Claude command intent | Codex result |
| --- | --- | --- | --- |
| `beads-workflow` | `commands/tackle-epic.md` | Work a Beads epic and create a PR | Not surfaced or invokable. |
| `beads-workflow` | `commands/fix-findings-beads-tasks.md` | Fix findings as tracked, separately committed tasks | Not surfaced or invokable. |
| `pr-workflow` | `commands/update-pr-description.md` | Refresh a PR description | Not surfaced or invokable. |
| `pr-workflow` | `commands/address-pr-comments.md` | Address PR comments and post the result | Not surfaced or invokable. |
| `pr-workflow` | `commands/address-pr-comments-human.md` | Address PR comments with an approval gate | Not surfaced or invokable. |

`beads-workflow` contains only its two command files and README (plus its
manifest), so it is **effectively empty in Codex**. `git-commits` was migrated
to the `commit-staged` and `commit-unstaged` skills after this command audit.
`pr-workflow` is not empty: its two skills, `qa-walkthrough-pr` and
`watch-pr-then-action`, remain a separate potentially usable Codex surface,
but none of its three command workflows do.

## Options — no decision

1. **Promote selected commands to skills.** Cost: redesign `$ARGUMENTS`,
   Claude-specific command assumptions, and permission/frontmatter behavior;
   bump and test the plugins. Buys a current, installable Codex workflow and
   keeps Claude compatibility.
2. **Ship a prompts export.** Cost: it is manual and only useful to users
   deliberately running pre-0.117 Codex; it is not a current plugin feature.
   Buys migration help for an obsolete runtime, not a Codex 0.145.0 command.
3. **Declare these command-only plugins Claude-only.** Cost: document the
   compatibility boundary and accept no Codex workflow for them. Buys an honest
   install experience and avoids a misleading, apparently successful empty
   Codex install.

[slash-commands-source]: https://raw.githubusercontent.com/openai/codex/main/docs/slash_commands.md
[custom-prompts-removed]: https://github.com/openai/codex/issues/15941
