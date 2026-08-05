# `allowed-tools` impact of the `.3` path migration

Scope: research and inventory only, 2026-07-27. No plugin files were changed.

## Q1 — documented Bash-pattern semantics

Claude Code treats `allowed-tools` as a temporary permission grant for the turn in which the skill is invoked; it pre-approves listed tools but does not remove unlisted tools from the model. [The skills documentation](https://code.claude.com/docs/en/slash-commands#pre-approve-tools-for-a-skill) documents that scope.

For `Bash(...)` specifiers, the official [permissions reference](https://code.claude.com/docs/en/permissions#bash) establishes these facts:

- A pattern without `*` matches the exact command. `*` is a glob that may appear anywhere and matches any sequence of characters, including spaces. This is not literal-prefix matching alone.
- A trailing `:*` is equivalent to a trailing space-plus-wildcard. Thus `Bash(ls:*)` and `Bash(ls *)` match the same commands; this shorthand is recognized only at the end of a pattern.
- Claude Code parses compound shell commands and requires every subcommand to match. It strips a fixed set of wrappers before matching. For allow rules, it strips only leading assignments of known-safe environment variables; it does **not** match past an arbitrary leading assignment. [See the wrapper rules.](https://code.claude.com/docs/en/permissions#wrappers)

The official documentation does **not** specify whether `${CLAUDE_SKILL_DIR}` or `${CLAUDE_PLUGIN_ROOT}` inside a `Bash(...)` pattern is expanded before matching the command input. It therefore does not establish whether this existing pattern:

```text
Bash(bash ${CLAUDE_SKILL_DIR}/scripts/fetch-docs.sh:*)
```

matches a command whose actual input is `bash /real/path/scripts/fetch-docs.sh ...`. No conclusion about that expansion behavior is made here.

## Q2 — path-bearing `allowed-tools` inventory

The following is the complete inventory of frontmatter `allowed-tools` entries that reference `CLAUDE_SKILL_DIR` or `CLAUDE_PLUGIN_ROOT`. It was extracted only from each SKILL.md frontmatter block. There are **six patterns across six plugins**; no `allowed-tools` entry references `CLAUDE_PLUGIN_ROOT`.

| Plugin | Path and line | Pattern text |
|---|---|---|
| `cmux-cli` | `plugins/cmux-cli/skills/using-cmux-cli/SKILL.md:9` | `Bash(${CLAUDE_SKILL_DIR}/scripts/*)` |
| `collab-tools` | `plugins/collab-tools/skills/diff-view/SKILL.md:5` | `Bash(${CLAUDE_SKILL_DIR}/scripts/*)` |
| `paperclip` | `plugins/paperclip/skills/paperclip/SKILL.md:5` | `Bash(${CLAUDE_SKILL_DIR}/scripts/*)` |
| `pr-workflow` | `plugins/pr-workflow/skills/qa-walkthrough-pr/SKILL.md:7` | `Bash(bash "${CLAUDE_SKILL_DIR}/scripts/*")` |
| `research-tools` | `plugins/research-tools/skills/fetch-docs/SKILL.md:13` | `Bash(bash ${CLAUDE_SKILL_DIR}/scripts/fetch-docs.sh *)` |
| `slack` | `plugins/slack/skills/read-slack/SKILL.md:14` | `Bash(bash ${CLAUDE_SKILL_DIR}/scripts/slack.sh *)` |

## Q3 — consequence for the `.3` command shape

The proposed shape is a `SKILL_DIR` fallback followed by a script invocation, for example:

```bash
SKILL_DIR="${CLAUDE_SKILL_DIR:-<absolute path>}"
bash "$SKILL_DIR/scripts/x.sh"
```

The current six patterns name a runtime-variable path. Under Codex, the fallback contains an install-specific absolute path, so a pattern with one fixed absolute prefix cannot match every installed copy. The closest path-generic forms for the stated command shape are:

| Existing pattern | Path-generic form for the stated `.3` shape | Permission-scope change |
|---|---|---|
| `Bash(${CLAUDE_SKILL_DIR}/scripts/*)` (three entries) | `Bash(bash */scripts/*)` | Matches `bash` running a script below any path segment named `scripts`, rather than only the current skill directory. |
| `Bash(bash "${CLAUDE_SKILL_DIR}/scripts/*")` | `Bash(bash */scripts/*)` | Same broader any-prefix scope; quoting does not supply an install-independent fixed path. |
| `Bash(bash ${CLAUDE_SKILL_DIR}/scripts/fetch-docs.sh *)` | `Bash(bash */scripts/fetch-docs.sh *)` | Allows that basename under any matching `*/scripts/` prefix. |
| `Bash(bash ${CLAUDE_SKILL_DIR}/scripts/slack.sh *)` | `Bash(bash */scripts/slack.sh *)` | Allows that basename under any matching `*/scripts/` prefix. |

`collab-tools` currently invokes its helper through `node`, not `bash`; if that call shape remains `node "$SKILL_DIR/scripts/gen-diff.js"`, its corresponding generic form would be `Bash(node */scripts/*)`, with the same any-prefix broadening. The exact match behavior of an inline `SKILL_DIR=...` assignment remains material: the official documentation says an allow rule does not match past an arbitrary assignment, and compound-command subcommands must each match. A real Claude Code permission-matcher probe is required to establish the complete rule set for that exact command text.

### Safety judgment

**Blocked pending that matcher probe.** The `.3` migration cannot safely proceed with the current six patterns: their compatibility with expanded runtime variables is undocumented, and replacing them with path-generic wildcards broadens the pre-approved `Bash` scope. Any implementation would need the applicable `allowed-tools` changes in the same change, followed by a real Claude Code permission test of the exact emitted commands.
