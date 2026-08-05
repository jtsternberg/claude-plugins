# Codex compatibility guide

This is the maintained, user-facing summary of how this plugin repository
behaves under Codex. Runtime behavior changes with Codex releases, so treat
these results as versioned compatibility information, not a permanent API
guarantee.

**Last reviewed:** 2026-08-05

**Tested on:** codex-cli 0.146.0 for the hook and skill-shell probe; related
plugin-surface probes were run on codex-cli 0.145.0.

**Reverify after upgrade:** yes—especially after any Codex plugin, hook, or
skill-loader change.

## Current compatibility

| Surface | Current finding | Tested on |
| --- | --- | --- |
| Legacy `.claude-plugin` manifests and marketplace | Supported for the repository's marketplace and plugins. | 0.145.0 |
| `skills/<name>/SKILL.md` | Skills are the usable Codex workflow surface. | 0.145.0–0.146.0 |
| `commands/*.md` | Files may be cached, but Codex does not list or invoke them as plugin commands. | 0.145.0 |
| Explicit plugin skill invocation | Use `$<plugin-name>:<skill-name>`; the bare skill name remains the prose identifier. | 0.146.1 |
| Plugin hook commands | Supported after the user trusts the plugin; `${CLAUDE_PLUGIN_ROOT}` resolves inside the hook process. | 0.145.0–0.146.0 |
| Skill-body shell commands | Do not rely on `${CLAUDE_SKILL_DIR}` or `${CLAUDE_PLUGIN_ROOT}` being set. A SessionStart hook export does not persist into a later skill-body shell. | 0.146.0 |
| Installed plugin `bin/` on `PATH` | Not provided as a general skill-script path solution. | 0.145.0 |
| Skill descriptions | The current source tree has 60 descriptions totaling 7,700 characters (96.25% of the approximate 8,000-character Codex pool). | 2026-08-05 source-tree measurement |

## Authoring guidance

- Ship Codex workflows as skills, not slash commands.
- Keep hook paths anchored to `${CLAUDE_PLUGIN_ROOT}`; that variable is a hook
  contract, not a skill-body contract.
- For a skill that runs a bundled script, keep Claude's exact substitution
  token in executable text and tell Codex, in adjacent prose, to replace it
  with the absolute directory containing the current `SKILL.md`:

  Codex: this path resolves under Claude Code; substitute the directory containing
  this `SKILL.md` in the executable text below.

  ```bash
  SKILL_DIR="${CLAUDE_SKILL_DIR}"
  bash "$SKILL_DIR/scripts/example.sh"
  ```

  Claude Code substitutes only the exact token; it does not export the variable
  or substitute a compound `${VAR:-fallback}` expression. Codex substitutes
  nothing, so the adjacent instruction preserves its model-resolved path.
- Keep the highest-signal invocation terms in `description:`. Do not assume
  that supplemental frontmatter fields participate in Codex implicit matching.

## Detailed evidence

The dated evidence archive contains the underlying probes and limitations:

- [plugin and command compatibility](compat-matrix.md)
- [commands under Codex](commands-under-codex.md)
- [skill path and environment evidence](path-resolution-evidence.md)
- [plugin-root semantics](plugin-root-semantics.md)
- [hook behavior](hooks-under-codex.md)
- [frontmatter and PATH semantics](frontmatter-and-path-semantics.md)
- [skill-description budget](skill-description-budget.md)

Those documents are research records. Recheck their stated version before
using an observation to make a new compatibility claim.
