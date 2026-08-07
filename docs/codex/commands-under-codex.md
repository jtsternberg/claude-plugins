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

## Q3 — Repository command inventory at audit time

The five command files present when this audit was written were unavailable to Codex as commands:

| Plugin | Command file | Claude command intent | Codex result |
| --- | --- | --- | --- |
| `beads-workflow` | `commands/tackle-epic.md` | Work a Beads epic and create a PR | Not surfaced or invokable. |
| `beads-workflow` | `commands/fix-findings-beads-tasks.md` | Fix findings as tracked, separately committed tasks | Not surfaced or invokable. |
| `pr-workflow` | `commands/update-pr-description.md` | Refresh a PR description | Not surfaced or invokable. |
| `pr-workflow` | `commands/address-pr-comments.md` | Address PR comments and post the result | Not surfaced or invokable. |
| `pr-workflow` | `commands/address-pr-comments-human.md` | Address PR comments with an approval gate | Not surfaced or invokable. |

At audit time, `beads-workflow` was **effectively empty in Codex**.
`git-commits` was migrated to the `commit-staged` and `commit-unstaged` skills
after the initial audit. The five files above were subsequently promoted to
same-named explicit-only skills, with Claude's invocation gate in `SKILL.md`
and Codex's gate in each skill's `agents/openai.yaml`.

## Resolution

Promote all five workflows to skills. Preserve the command names as canonical
skill names and preserve the automatic versus human-reviewed PR-comment modes
as separate skills because their side-effect contracts differ. Do not ship a
legacy prompts export. Layout tests now fail if command Markdown returns or if
either harness's explicit-only invocation gate is lost.

[slash-commands-source]: https://raw.githubusercontent.com/openai/codex/main/docs/slash_commands.md
[custom-prompts-removed]: https://github.com/openai/codex/issues/15941
