# How plugin-root paths resolve under Codex

Probed 2026-07-27 against **codex-cli 0.144.6** (`gpt-5.6-sol`). Reproducible; see Method.

> **Superseded Claude-side conclusion (2026-08-05):** Claude Code 2.1.221
> performs exact-token textual substitution in plugin Markdown; it does not
> export these variables or replace `${VAR:-fallback}`. The fallback pattern
> below is retained as historical Codex evidence and is not current guidance.

## Answer

**Codex provides no variable for a skill's own location — not `CLAUDE_SKILL_DIR`, and not `CLAUDE_PLUGIN_ROOT` either.** Of the three hypotheses, (b) is confirmed:

| Hypothesis | Verdict |
|---|---|
| (a) Codex textually interpolates `${CLAUDE_PLUGIN_ROOT}` in plugin markdown | **False.** The model read the literal token out of the file. |
| (b) Injected for hook commands only; codex-plugin-cc's skill usage is Claude-side | **Confirmed.** |
| (c) Injected into the shell env when the active skill came from a plugin | **False.** All three vars expanded empty. |

Raw result from run 1, with the skill body containing the literal `${CLAUDE_PLUGIN_ROOT}`:

```
ENV_ROOT=[] ENV_PLUGIN_ROOT=[] ENV_DATA=[]
bash: /skills/probe/scripts/hello.sh: No such file or directory     (exit 127)
```

## Consequence — this corrects the epic's premise

The epic assumed the `${CLAUDE_SKILL_DIR}` → `${CLAUDE_PLUGIN_ROOT}` migration AGENTS.md already mandates was *also* the Codex fix. **It is not.** `${CLAUDE_PLUGIN_ROOT}` fails under Codex in exactly the same way and for the same reason. Migrating the 28 `CLAUDE_SKILL_DIR` sites to it would satisfy AGENTS.md and still leave every one of them broken under Codex.

It also means the 4 files in `session-tools` that AGENTS.md holds up as the reference-correct pattern are themselves broken under Codex today — the repo's *best* plugin on this axis is as broken as its worst.

`${CLAUDE_PLUGIN_ROOT}` remains correct for **hooks**, where Codex does inject it (documented, and the binary carries `PLUGIN_ROOT`/`CLAUDE_PLUGIN_ROOT`/`PLUGIN_DATA`/`CLAUDE_PLUGIN_DATA` adjacently). Skill bodies are the divergent surface, not hooks.

## Why OpenAI's own skills look the way they do

This explains a pattern that read as sloppy: OpenAI's bundled skills (presentations, template-creator, google-slides) instruct the model to `Set: SKILL_DIR=<absolute path to this skill>` rather than using a variable. There is no variable to use. It is the documented-by-example workaround, not an oversight.

The mechanism that makes it work: **the agent does know its skill's absolute path.** Unprompted, Codex's first action was `sed -n '1,240p' <cache-path>/skills/probe/SKILL.md` — it resolved the full cache path with no help. The location is available to the model; it is just not available to the shell.

## The pattern that works in both harnesses

Verified in run 2 — the agent filled the `:-` default with its own resolved absolute path and the script ran:

```bash
SKILL_DIR="${CLAUDE_SKILL_DIR:-<absolute path of the directory containing this SKILL.md>}"
bash "$SKILL_DIR/scripts/hello.sh"
```

```
SCRIPT_RAN=yes SCRIPT_PATH=/.../probe-plugin/0.2.0/skills/probe/scripts/hello.sh
```

Under Claude Code the env var wins and nothing changes. Under Codex the fallback is filled from what the model already knows. One caveat worth stating plainly: the fallback is **model-resolved, not mechanically resolved** — it depends on the agent substituting correctly. It did so reliably here at `reasoning_effort=low`, but this is a softer guarantee than an env var, and any test for it has to assert on behavior rather than on text.

For a plugin root (not a skill dir), the same shape applies with `CLAUDE_PLUGIN_ROOT` as the primary and the plugin root as the fallback.

## Incidental findings

- **Local-source installs do get a real version.** `codex plugin add` from a local marketplace cached to `.../probe-plugin/0.1.0/`, not the `local` pseudo-version the docs describe. Bumping to `0.2.0` and re-adding produced a new versioned directory. This corrects an assumption in the release/versioning task.
- **A version bump is sufficient to re-cache.** `plugin remove` + `plugin add` after a bump picked up the new content; no `marketplace upgrade` was needed for a local source. Untested for git sources.
- Codex accepted the throwaway plugin's legacy `.claude-plugin/` layout and bare-string marketplace `source` without complaint — consistent with the 27-plugin result.

## Method

Throwaway marketplace + one plugin + one skill, installed into a scratch `CODEX_HOME` so the real config was untouched, with `auth.json` symlinked (never read). Parent `CLAUDE_*` vars scrubbed via `env -u` because a first pass inside Claude Code leaked `CLAUDE_PLUGIN_DATA` from the enclosing process and would have produced a false positive.

```bash
CODEX_HOME=$SCRATCH codex plugin marketplace add $SCRATCH/probe-mkt
CODEX_HOME=$SCRATCH codex plugin add probe-plugin@probe-mkt
env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PLUGIN_DATA -u CLAUDE_SKILL_DIR \
  CODEX_HOME=$SCRATCH codex exec --skip-git-repo-check \
  'Use the $probe skill now and follow its instructions exactly.'
```

This is undocumented surface. Re-run the probe when Codex updates.

## Re-verification needed

The probe ran on codex-cli **0.144.6**. This machine has since auto-updated to **0.145.0**, so these findings are unverified on the current build.
