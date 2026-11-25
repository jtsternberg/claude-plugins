# Dual-harness contract: template for a repository's AGENTS.md

Paste the section below into the repository's agent instructions and adapt the
paths and commands to its layout. Drop any rule for a surface the repository
does not ship (for example, the hooks line in a repository with no hooks).

```markdown
## Dual-Harness Skill Contract

Every new or edited skill must keep working under both Claude Code and Codex
unless its frontmatter and docs mark it harness-specific.

- Workflows are `skills/<name>/SKILL.md`, never `commands/*.md`. Codex does not
  expose commands.
- Routing terms go in `description`. Codex ignores `when_to_use`,
  `argument-hint` and `effort`, and does not honor `allowed-tools` or `!`
  dynamic context. Keep `allowed-tools` in sync with the commands Claude runs.
- `disable-model-invocation: true` is mirrored by
  `policy.allow_implicit_invocation: false` in the skill's `agents/openai.yaml`.
- Keep the literal argument token where Claude must interpolate, with Codex
  fallback prose beside it that does not repeat the token.
- Claude path tokens stay bare (`${CLAUDE_SKILL_DIR}`, `${CLAUDE_PLUGIN_ROOT}`):
  no `:-` defaults, no `../..` out of a skill dir, no plugin-cache paths. Put a
  Codex substitution note in adjacent prose and repeat the `SKILL_DIR=`
  assignment in every executable block, because Codex shells do not keep state.
- Hooks are a separate runtime contract. Do not infer hook behavior from skill
  shells.

Before committing a skill change, run `scripts/check-skill.sh <skill-dir>` (CI
runs it over every skill). Changes to paths, arguments, hooks or permissions
also need an installed-plugin probe in both harnesses.
```

Codex reads `AGENTS.md`. Claude Code reads it only when no `CLAUDE.md` exists at
or above that directory. If the repository has a `CLAUDE.md`, put the section
there and symlink `AGENTS.md` to it.
