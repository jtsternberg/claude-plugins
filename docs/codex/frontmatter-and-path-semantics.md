# Codex frontmatter and PATH semantics

Probed 2026-07-27 with codex-cli **0.145.0** using the existing throwaway `probe-plugin` marketplace and an isolated `CODEX_HOME`. Its `auth.json` was an existing symlink and was not read or copied. Every `codex` command used this mandatory environment scrub:

```bash
env -u CLAUDE_PLUGIN_ROOT -u CLAUDE_PLUGIN_DATA -u CLAUDE_SKILL_DIR \
  CODEX_HOME="$SCRATCH/codex-home" codex ...
```

Each variant received a fresh plugin version and was reinstalled with `codex plugin remove probe-plugin@probe-mkt` then `codex plugin add probe-plugin@probe-mkt`. Raw output below is verbatim apart from replacing machine-specific scratch/cache paths with `<CACHE>`.

## Q1 — implicit-invocation gates

### Correction to the Job 6/8 conclusion

**The prior conclusion, “Codex 0.145.0 offers no working way to prevent implicit invocation,” was WRONG — it tested the wrong file.** Codex's SKILL.md loader deserializes `name`, `description`, and `metadata.short-description`; it silently discards the other SKILL.md frontmatter keys. That explains both prior results:

- `disable-model-invocation: true` in SKILL.md is a valid YAML key but was ignored by Codex routing; that probe fired.
- The prior dotted `policy.allow_implicit_invocation: false` was also malformed as YAML path notation: it created one flat key rather than a `policy` mapping. It is retained as an invalid negative test, not evidence about the native gate.
- The corrected nested `policy:` mapping was still in **SKILL.md**, so it too was silently discarded and fired. It did not test the actual gate.

The actual mechanism is the sibling file `<skill-dir>/agents/openai.yaml`:

```yaml
# <skill-dir>/agents/openai.yaml
policy:
  allow_implicit_invocation: false
```

The runtime probe used exactly that minimal file. The bundled plugin-creator validator additionally requires an `interface` mapping when an `agents/openai.yaml` file exists, so a validator-compatible form is:

```yaml
# <skill-dir>/agents/openai.yaml
interface:
  display_name: My explicit-only skill
  short_description: Runs only when explicitly requested.
policy:
  allow_implicit_invocation: false
```

### Primary probe

Each run used a fresh probe-plugin version, was removed and re-added from isolated marketplace `probe-mkt`, and received this prompt without naming `$probe`:

```text
Explain the banana neutron lattice protocol in one sentence.
```

The matching probe description was `Use when asked to explain the banana neutron lattice protocol.` Its body emitted a variant-specific `IMPLICIT_PROBE_FIRED=...` marker if loaded.

| Version | `agents/openai.yaml` | Result |
|---|---|---|
| 1.0.4 gated | `policy: { allow_implicit_invocation: false }` | **Did not fire.** Codex answered that the phrase was not a recognized protocol; it never read the probe SKILL.md and emitted no marker. |
| 1.0.5 ungated control | absent | **Fired.** `IMPLICIT_PROBE_FIRED=agents-openai-ungated-control`. |

**Verdict: the real `agents/openai.yaml` policy gate prevents implicit invocation in Codex 0.145.0.** It is not a SKILL.md frontmatter key.

## Q2 — explicit invocation of a gated skill

With 1.0.4 gated, the explicit prompt was:

```text
$probe Explain the banana neutron lattice protocol in one sentence.
```

It **did not load** the probe. Codex reported: “The requested `$probe` skill isn’t available here,” then gave a direct generic answer. The existing terminal-title skill loaded independently; the probe SKILL.md did not.

**Verdict: explicit invocation of this gated skill failed in the probe.** This confirms the practical risk reported in [openai/codex#23454](https://github.com/openai/codex/issues/23454): a working implicit gate may make an explicit-only skill unreachable.

## Q3 — model-visible listing and description budget

This is directly observable at the model-visible listing level:

- With 1.0.4 gated, a session asked to inspect its provided skills reported neither `probe` nor the distinctive `banana neutron lattice` description as available.
- With 1.0.5 ungated, the identical request reported `probe-plugin:probe` and its distinctive description as available.
- The interactive `/skills` menu showed the same `probe-plugin`/`probe-mkt` plugin shell in both gated and ungated installs. It does not expose individual skill descriptions or a gate state.
- `skills.list` was not available to this Codex session. Neither tested startup emitted the 2% description-truncation warning.

**Verdict: the gate removes the skill name and description from the model-visible skills listing.** The probe does **not** directly expose a token counter or the rendered context budget, so it cannot prove a numeric budget reduction or independently prove that all 24 gated descriptions cost exactly zero. It does establish the visible-list exclusion; no stronger budget claim is made here.

## Q4 — plugin-creator validation of `disable-model-invocation`

The installed validator is `<HOME>/.codex/skills/.system/plugin-creator/scripts/validate_plugin.py`. Its `validate_skill_manifest()` rejects either `disable-model-invocation` or `disable_model_invocation` unless the value is `null` or `false`; a true value produces the error `frontmatter field disable-model-invocation must be false`.

The validator could not execute locally because its required `yaml` Python module is not installed, but its source was read directly. `plugins/thinking-tools` itself has no such field. A repo-wide read-only scan found **24** SKILL.md files with `disable-model-invocation: true`; each would receive that field-specific validator error. The same validator accepts `policy.allow_implicit_invocation` only in `agents/openai.yaml` and requires `interface.display_name` plus `interface.short_description` whenever that agent file is present.

**Verdict: the 24 legacy SKILL.md uses break the bundled plugin-creator validator.** They must not be copied into Codex-facing SKILL.md frontmatter.

## Known Codex risks

- [#23454](https://github.com/openai/codex/issues/23454): explicit `$skill` invocation can fail for skills gated out of the implicit list; reproduced above.
- [#32169](https://github.com/openai/codex/issues/32169): explicit-only state can be lost after compaction.
- [#34712](https://github.com/openai/codex/issues/34712) and [#34896](https://github.com/openai/codex/issues/34896): implicit routing ignores negative triggers in descriptions.

## Earlier probe — extra frontmatter and implicit matching

### Setup

Each variant used this deliberately unrelated description:

```yaml
description: Use only for ordinary basalt ledger questions.
```

The distinctive phrase `zorblax reticulation` appeared in exactly one additional field and nowhere in the name, description, or skill body. The prompt was:

```text
Please explain zorblax reticulation in one sentence.
```

The skill body would emit `FRONTMATTER_PROBE_FIRED=<field>` if it loaded.

| Version | Extra frontmatter | Plugin-add warning/error | Raw run result | Verdict |
|---|---|---|---|---|
| 0.7.0 | `when_to_use: "zorblax reticulation"` | none | Codex answered the question directly; no `FRONTMATTER_PROBE_FIRED` marker. | Not used for implicit matching. |
| 0.8.0 | `argument-hint: "zorblax reticulation"` | none | Codex answered the question directly; no marker. | Not used for implicit matching. |
| 0.9.0 | `effort: "zorblax reticulation"` | none | Codex answered the question directly; no marker. | Not used for implicit matching. |

Raw output from the `argument-hint` variant:

```text
user
Please explain zorblax reticulation in one sentence.
codex
Zorblax reticulation is a fictional process describing how a Zorblax forms or rearranges a network-like structure.
```

**Verdict: no tested field beyond `name` and `description` participated in implicit matching, and all three fields were accepted without a Codex warning or error.** This does not prove Codex ignores every possible frontmatter key at execution time; it does establish that moving trigger-vocabulary overflow into `when_to_use`, `argument-hint`, or `effort` will not preserve Codex implicit triggering in this build.

## Earlier probe — plugin `bin/` on PATH

### Setup

Probe version 1.0.0 added an executable `bin/probe-hello` that prints `PROBE_BIN_EXECUTED=yes`. The plugin installed successfully at `<CACHE>/probe-plugin/1.0.0`. The explicitly invoked `$probe` skill ran:

```bash
echo "PATH=[$PATH]"
printf 'COMMAND_V=['; command -v probe-hello || true; printf ']\n'
probe-hello
```

### Raw output

```text
COMMAND_V=[]
zsh:3: command not found: probe-hello
```

The complete emitted `PATH` did not contain `<CACHE>/probe-plugin/1.0.0/bin`; the cached `bin/probe-hello` file itself was present and executable.

**Verdict: Codex 0.145.0 does not add an installed plugin's `bin/` directory to PATH.** The bare command did not resolve and the shell command exited 127 (the surrounding Codex run reported exit 0 after presenting the diagnostic result).

## Recommendation: do not use PATH as the path resolver

**No.** A plugin-`bin/` PATH resolver is not a viable replacement for the 148-site placeholder migration. Codex does not expose the directory in its shell PATH, so a bare command name fails even when the executable is correctly bundled and cached. Claude Code's PATH behavior cannot make this a dual-harness solution; path-bearing skill instructions still need the model-resolved absolute fallback described in [plugin-root-semantics.md](plugin-root-semantics.md).
