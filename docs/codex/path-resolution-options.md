# Path resolution under Codex — option space and recommendation

Status: **historical decision record.** Written 2026-07-27 against the evidence in [plugin-root-semantics.md](plugin-root-semantics.md), [compat-matrix.md](compat-matrix.md), and [frontmatter-and-path-semantics.md](frontmatter-and-path-semantics.md). The option rankings below reflect the probe state at that date; later results are summarized in the [maintained compatibility guide](../compatibility.md).

**Superseded runtime conclusion (2026-08-05):** Claude Code 2.1.221 replaces
only the exact `${CLAUDE_SKILL_DIR}` and `${CLAUDE_PLUGIN_ROOT}` tokens in plugin
Markdown. It does not export those variables or replace `${VAR:-fallback}`.
The fallback examples below are retained as decision history, not current
authoring guidance.

The SessionStart-hook option was subsequently tested on codex-cli 0.146.0 and
did not persist `CLAUDE_SKILL_DIR` into a later skill-body shell. Treat that
option as rejected in its simple export form; the detailed hook record is in
[hooks-under-codex.md](hooks-under-codex.md). Reverify after a Codex upgrade
before reopening any option based on undocumented environment behavior.

## The problem

A skill must invoke scripts bundled alongside it, but the same skill lives at a different absolute path per install (repo checkout, `~/.claude/plugins/cache/<mkt>/<plugin>/<version>/`, `~/.codex/plugins/cache/<mkt>/<plugin>/<version>/`), so the path cannot be hardcoded — that is exactly the bug that made `git-tree` non-functional. Claude Code solves this by exporting `CLAUDE_SKILL_DIR` / `CLAUDE_PLUGIN_ROOT` into the shell, so `bash "${CLAUDE_SKILL_DIR}/scripts/x.sh"` is mechanically correct. Codex sets **neither** variable in skill-body shell commands (verified on 0.144.6; 0.145.0 unverified on this exact point), so the same command degrades to `bash "/scripts/x.sh"` and exits 127. Every path-bearing instruction in every skill is affected — the repo's best-practice plugins equally with its worst.

## Ground truth about the blast radius

Fresh source scan (2026-07-27, this doc):

- **29 SKILL.md files, ~152 textual occurrences** of `CLAUDE_SKILL_DIR`/`CLAUDE_PLUGIN_ROOT` (the task brief's "31 files / 148+" is the same population counted with non-SKILL files; five more `.md` files — two READMEs and three `references/` docs — also mention the variables).
- The occurrences are not one class. They split into four, and **no single mechanism fixes all four**:
  1. **Fenced bash commands** (the large majority) — e.g. `bash ${CLAUDE_SKILL_DIR}/scripts/upload.sh …`. Shell-mechanical fixes apply here.
  2. **Prose/table mentions** — command-reference tables, "scripts live at…" sentences. The model transcribes from these too; they need the same shape as (1) or they become the stale copy that misleads.
  3. **Read-tool pointers** — "**Read `${CLAUDE_PLUGIN_ROOT}/references/reading-a-digest.md`**". No shell runs; `$( … )` tricks cannot help. Only a model-resolved form (or routing the read through `cat` in bash) works here.
  4. **`allowed-tools` frontmatter** (5 files) — Claude-Code-only permission patterns. Codex discards them entirely, so they never *break* under Codex — but any option that changes the literal command shape in the body can stop matching these patterns **in Claude Code**, regressing auto-permissions there. This interaction is unverified (flagged as evidence item #5 below).
- **Not every affected plugin needs a Codex fix.** `hotline` (13 sites), `session-tools` (11), `handoff` (1), and arguably `fable` (4) operate on Claude Code sessions, transcripts, and models — they are Claude-Code-inherent, and option H (document as Claude-Code-only) is the *correct* answer for them, not a cop-out. The plugins where Codex support genuinely pays: `gws` (70 sites), `localwp-shell` (16), `research-tools` (9), `slack` (7), `cmux-cli` (6), `collab-tools` (5), `pr-workflow` (5), `skill-tools` (3). A scoped rollout is ~120 sites, and per-plugin sequencing is available regardless of mechanism.

## A framing correction: two axes, not one list

Options A–D as briefed conflate two independent choices:

- **Resolution mechanism** — who turns "this skill's directory" into an absolute path: the model (recall/transcription), a shell glob, an env var, a hook-written registry file, a PATH-installed shim, or an MCP manifest.
- **Placement** — how many times per file the resolution happens: every call site, once per file (needs shell-state persistence, probe #1), once per plugin, or once per machine.

"A vs B" is purely a placement question layered on the *same* mechanism (model-resolved). The real decision is the mechanism; placement then follows from probe #1. The table below keeps the briefed letters but evaluates them on both axes.

## Options

### A. Model-resolved placeholder at every call site (current plan)

`SKILL_DIR="${CLAUDE_SKILL_DIR:-<absolute path of this skill's directory>}"` — the env var wins under Claude Code; under Codex the model fills the blank from the path it read the file from. Verified working in both harnesses; already shipped in `git-tree` (`plugins/git-tree/skills/create-git-tree/SKILL.md:16`).

- **Mechanical?** No — model substitution. Mitigating fact from the probe: Codex *reads* the SKILL.md via its own shell (`sed -n … <cache-path>/SKILL.md`), so the correct path is usually **in the visible transcript**, making this closer to transcription than recall. That's why it was reliable at low reasoning effort. But it's a soft guarantee that depends on Codex continuing to surface the read path.
- **Failure modes.** Unfilled placeholder → path contains literal `<…>` → 127, **loud**. The dangerous mode is *plausible-but-wrong* fill — e.g. a stale version directory still present in the cache → runs an old script **silently**. Small per-site error rate × ~120–150 sites = a plugin that works most of the time, the worst kind of broken.
- **Edit volume.** Every executable site plus every prose/table mention (~150), largely codemod-able but each needs eyeballing for the placeholder wording.
- **Maintenance.** Every new skill must remember the incantation; a lint/test can enforce the *text* but cannot test the *substitution*.
- **Covers all four site classes** — the only option that natively handles Read-pointers (class 3).
- **Evidence that moves it.** Probe #3 (a `skills.list`-style tool returning paths) upgrades the substitution from "path seen in transcript" to "path fetched on demand" — materially de-risks it. Probe #2 (a `CODEX_*` var) largely obsoletes it.

### B. Resolve once per file, reuse below

Same mechanism as A; one `SKILL_DIR=…` preamble at the top, bare `"$SKILL_DIR/scripts/…"` everywhere below. Contingent on probe #1 (shell state persisting across a skill's tool calls, and/or Codex joining fenced blocks into one invocation).

- Cuts model-substitution events from ~150 to ~29 — directly attacks A's error-accumulation problem.
- **New failure mode:** if state does *not* persist (or persists in Claude Code but not Codex), later calls see empty `$SKILL_DIR` → `bash /scripts/x` → 127, **loud** but confusing, and it would pass any single-command test. If probe #1 comes back "no persistence", B is dead as a placement and everything collapses back to per-site.
- Even with persistence, each fenced example block a model copies in isolation must be self-sufficient — real sessions don't replay the file top-to-bottom. Safest form repeats the one-liner at the top of each *fenced block*, which lands between A and B in volume (~50–60 preambles).
- `allowed-tools` interaction (evidence #5): commands become `bash "$SKILL_DIR/…"`, which the existing `Bash(bash ${CLAUDE_SKILL_DIR}/scripts/… *)` patterns likely no longer match → permission-prompt regression in Claude Code unless patterns are updated in the same pass.

### C. Deterministic glob resolver, env var first

Mechanical fallback inline, generated per-file by a codemod (plugin and skill names are static per file):

```bash
SKILL_DIR="${CLAUDE_SKILL_DIR:-$(ls -d "$HOME"/.codex/plugins/cache/*/gws/*/skills/md-to-google-doc \
                                       "$HOME"/.claude/plugins/cache/*/gws/*/skills/md-to-google-doc 2>/dev/null | sort -V | tail -1)}"
```

Contingent on probe #4. Escapes D's chicken-and-egg because the resolver is *inline text*, not a file that itself needs locating.

- **Mechanical?** Yes at execution time — but note the honest caveat: the model still has to *transcribe the snippet verbatim* from the SKILL.md into its command. Verbatim transcription of exact text is the model's strong suit (far stronger than recalling a hashed cache path), so this is meaningfully more reliable than A, but it is not "the shell did everything".
- **Version ordering.** `sort -V | tail -1` picks the highest cached version. The probe showed a version bump creates a *new* directory; whether the old one is pruned is **unknown**. If stale versions linger, highest-version is probably still the installed one (installs move forward), but "probably" is doing work — probe #4 should check `ls` of a cache after several upgrade cycles. Wrong pick = silently running an old script, the same bad mode as A's stale fill.
- **Repo checkout coverage: none.** The glob can't know an arbitrary checkout path. Acceptable if dev-mode use always goes through Claude Code (env var set) or a local `plugin add` (cached); worth stating as an explicit assumption.
- **Failure mode.** Glob matches nothing → empty var → `bash /scripts/x` → 127, **loud**.
- **Edit volume.** Same sites as A/B, but the codemod writes identical deterministic text — no per-site judgment, review is mechanical. Doesn't cover Read-pointers (class 3) — those keep an A-style form or get routed through `cat`.
- **Maintenance.** Two harness cache layouts are hardcoded; a Codex (or Claude) cache-layout change breaks every site at once — loudly, and fixable by one more codemod run. A repo test can assert the snippet resolves against a fixture cache tree — **this option is testable in CI; A is not.**

### D. Shared resolver file at the plugin root

Chicken-and-egg is **not escapable on its own terms**: the resolver script's path needs the very resolution it provides. Every escape route turns D into another option — locate the resolver by glob (that's C, minus the indirection), put it on PATH (that's F), or have the model fill its path (that's A with extra steps). **D is not a distinct option; recommend striking it** and instead getting D's real benefit — one implementation to maintain — by having the C codemod own the snippet text.

### E. Ship capability as an MCP server via the plugin's `.mcp.json`

The harness launches MCP servers from the manifest and resolves paths itself; the skill body then calls tools, not scripts. Architecturally the Codex-native answer for *tool-shaped* plugins.

- **Mechanical?** Fully — best-in-class once running.
- **Unknown that gates it:** does Codex actually consume a *plugin's* `.mcp.json` and launch it with a resolved cwd? Not covered by any probe run so far. Codex has its own `config.toml` `mcp_servers` — if plugin manifests aren't honored, E degrades to per-user config, i.e. option F with more moving parts. **Needs its own probe before it can be ranked above speculative.**
- **Cost.** A rewrite, not a path fix: each bash script becomes a server tool (Node runtime, schema, error surfaces), plus every SKILL.md rewritten from "run this command" to "call this tool". Only plausible for `gws` (7 skills, 70 sites, coherent tool surface) — and even there it's weeks, not hours. Also changes the permission model and adds a resident process per plugin.
- **Failure mode.** Loud (tool absent). **Maintenance** higher-forever: server code + protocol drift vs. flat bash.
- Right long-term shape for `gws`; wrong instrument for a 5-site plugin like `collab-tools`.

### F. User-run installer putting a resolver/shim on PATH

One-time `install.sh` drops a `plugin-run` shim into `~/.local/bin`; SKILL.md says `plugin-run gws scripts/upload.sh …`; the shim globs the caches at runtime (C's logic, installed once per machine).

- **Mechanical after setup; one implementation** (D's benefit, chicken-and-egg solved by the human).
- **Fatal flaw for a shared marketplace:** breaks "install plugin and it works". Every machine, every user, every fresh box needs the manual step; forgotten step → 127 (loud, at least). The Codex probe confirmed user PATH *is* inherited, so it works — it just reintroduces exactly the class of out-of-band setup the git-tree bug came from (a hardcoded `~/.claude/skills/…` path that assumed a prior manual arrangement).
- Reasonable as a **personal-fleet escape hatch** if C's glob is killed by probe #4; unreasonable as the published answer.

### G. Codex-specific variant of affected skills

Two copies of each affected SKILL.md, diverging per harness.

- Satisfies both harnesses on day one, mechanically… by doubling the surface. This repo has already lost time **twice** to duplicated logic in the transcript parser and had to build a CI drift guard (`tests/parser-drift.test.mjs`) to stop the bleeding. That was *one* shared library; this would be ~15 skill documents.
- Also unclear it's even expressible: Codex installs from the same marketplace source, so "the Codex variant" needs a publish-time fork or in-file conditional prose — the in-file conditional *is* option A/C wearing a trench coat.
- Only worth revisiting if the two harnesses' divergence grows beyond paths (e.g. the frontmatter/`agents/openai.yaml` split becomes deep), at which point a publish-time overlay is the shape — a build step, not hand-maintained twins.

### H. Do nothing; document as Claude-Code-only

Zero cost, zero risk, honest. Wrong as a blanket answer while `gws`/`localwp-shell`/`research-tools`/`slack` have real Codex value — but **correct per-plugin** for the Claude-inherent set (`hotline`, `session-tools`, `handoff`, likely `fable`). Recommend adopting H *explicitly and selectively* no matter what wins overall: a one-line "Codex: not supported (reads Claude Code session state)" in those plugins' docs converts silent breakage into stated scope.

### I. (New) Hook-registered root file

Codex **does** inject `CLAUDE_PLUGIN_ROOT` into *hook* commands (confirmed in plugin-root-semantics.md, hypothesis b). So a plugin can ship a SessionStart hook that writes its own resolved root somewhere stable — `mkdir -p ~/.plugin-roots && echo "$CLAUDE_PLUGIN_ROOT" > ~/.plugin-roots/gws` — and skill bodies read it mechanically:

```bash
SKILL_DIR="${CLAUDE_SKILL_DIR:-$(cat ~/.plugin-roots/gws 2>/dev/null)/skills/md-to-google-doc}"
```

- **Mechanical, and immune to C's version-ambiguity** — it records the exact root the harness itself resolved, no glob heuristics.
- **Unverified load-bearing assumption:** that Codex runs plugin SessionStart hooks at all (the probe confirmed injection semantics for hook commands, not that a plugin-shipped `hooks.json` fires in Codex). Needs a probe before this can be ranked as real.
- **Cross-harness clobber:** if a Claude Code session writes last, the file holds a `~/.claude/...` root when Codex reads it. Harmless in Claude Code (env var wins there) but wrong in Codex after a Claude session. Fix requires per-harness files and harness detection in the hook — complexity climbing toward "just use the glob".
- Also: a hook per affected plugin (~8), firing every session whether or not the skill is used. Keep on the bench as the fallback if probe #4 kills the glob *and* the hook probe passes.

### J. (New, contingent) Native `CODEX_*` env fallback chain

If probe #2 finds any Codex-set var exposing the skill/plugin path, the fix collapses to a pure env chain — `"${CLAUDE_SKILL_DIR:-${CODEX_SKILL_DIR:?not running under a supported harness}}"` — fully mechanical in both harnesses, loud (`:?` aborts with a message) when neither is set, codemod-able, zero heuristics. **This dominates every other option if it exists.** Listed so the probe result has a named landing spot.

## Options table

| | Mechanism | Mechanical? | Harnesses | Edit volume | Failure mode | Maintenance | Confirmed / killed by |
|---|---|---|---|---|---|---|---|
| **A** placeholder per site | model transcription | no | both (verified) | ~150 sites, semi-manual | loud if unfilled; **silent if plausibly-wrong fill** | incantation discipline; untestable substitution | #3 strengthens; #2 obsoletes |
| **B** resolve once per file | model transcription | no | both, if state persists | ~29–60 preambles | loud 127 if state doesn't persist; else as A with fewer rolls | as A + persistence assumption | **#1 decides**; killed by "no persistence" |
| **C** env-first glob | shell glob | yes (transcribed verbatim) | both | ~150 sites, pure codemod, CI-testable | loud 127 on no-match; **silent if stale version wins sort** | 2 hardcoded cache layouts; breaks loudly+globally on layout change | **#4 decides**; #2 obsoletes |
| **D** shared resolver file | — | — | — | — | — | — | not a distinct option — collapses into C, F, or A |
| **E** MCP server | manifest | yes | Claude yes; **Codex unknown** | rewrite (gws-scale: weeks) | loud | highest, forever | needs its own probe (plugin `.mcp.json` in Codex) |
| **F** PATH installer | installed shim | yes, after manual step | both | ~150 + installer + per-machine step | loud 127 if not installed | shim + install docs; violates install-and-go | none pending; viable but self-disqualifying for marketplace |
| **G** Codex fork of skills | duplication | yes | both | ×2 surface | **silent drift** (proven twice in this repo) | worst | nothing pending would redeem it |
| **H** document as CC-only | none | — | Claude only | ~1 line/plugin | none (stated scope) | none | correct for Claude-inherent plugins regardless |
| **I** hook-registered root | hook + file read | yes | both, if Codex runs plugin hooks | ~150 + 8 hooks | loud 127 if file absent; **wrong-harness clobber** | hook per plugin, harness detection | needs new probe (plugin hooks fire in Codex?) |
| **J** `CODEX_*` env chain | env var | yes | both | ~150, pure codemod | loud (`:?` aborts with message) | none | **#2 decides — dominates all if true** |

## Ranked recommendation

Two of the four pending probes are decision-grade; the honest recommendation is a decision *tree*, not a fixed list. Reasoning exposed per step.

**0. Regardless of winner: adopt H selectively now.** Mark `hotline`, `session-tools`, `handoff`, `fable` as Claude-Code-only. They read Claude Code session state; no path fix makes them meaningful under Codex. This shrinks the problem to ~8 plugins / ~120 sites before any mechanism is chosen. (Independent of all probes.)

**1. If probe #2 finds a usable `CODEX_*` path var → J wins outright.** Pure env chain, mechanical in both harnesses, loud on failure, one codemod. Nothing else comes close. *This ranking position is entirely evidence-dependent; the probe result is binary.*

**2. Else, if probe #4 confirms the glob resolves deterministically (including the multi-version-cache question) → C, placed per fenced block (per-file if probe #1 allows).** Reasoning: C is the only remaining option that is mechanical at execution time, requires no install step, fails loud when it fails, and — uniquely — is **testable in CI** against a fixture cache tree. Its silent-failure mode (stale version wins `sort -V`) is exactly what probe #4 must rule in or out; if the probe shows old versions linger *and* can out-sort the installed one, add "prefer the newest `mtime`" or kill C. Pair with an A-style form for the Read-pointer sites C can't reach, and update the 5 `allowed-tools` patterns in the same pass (evidence item #5).

**3. Else (glob killed), A — per-file/per-block if probe #1 allows (i.e. B placement), per-site otherwise — with three mitigations.** Reasoning: A is the only option already *verified working in both harnesses*; when the mechanical routes fail, verified-soft beats speculative-hard. Mitigations that address the "works most of the time" objection: (a) placeholder wording that tells the model to take the path **from the transcript line where it read this file**, not from memory — grounding, not recall; (b) if probe #3 lands, wording points at the tool instead; (c) a smoke script per plugin (`scripts/selftest.sh` printing a marker) so "did resolution work" is a one-command check a user can run when a skill misbehaves. Accept that substitution itself is untestable in CI; pin the *text* with a lint.

**4. I stays benched** pending its own probe (does a plugin-shipped hook fire in Codex?). If C dies on version-ambiguity and the hook probe passes, I leapfrogs A — it's mechanical and records ground truth — provided the cross-harness clobber gets a per-harness file.

**5. E is a separate, later decision for `gws` only** — it's a product-architecture question ("should gws be an MCP server?") that happens to also fix paths, not a path fix. Don't let it block the ~50 sites in other plugins either way. Prerequisite: probe whether Codex honors plugin `.mcp.json` at all.

**6. F, G ranked out** (see "what I'd need to believe").

### What I'd need to believe, per low-ranked option

- **D:** that a resolver file can be invoked without first resolving a path — I couldn't construct a version of this that isn't secretly C, F, or A. Show me the invocation line and I'll re-rank.
- **E (as the general fix):** that rewriting ~8 plugins' bash surfaces into MCP servers costs less than a codemod over ~120 text sites, *and* that Codex launches plugin-manifest MCP servers. I believe neither today; the second is at least checkable.
- **F:** that "run this installer once per machine" is acceptable for a public marketplace plugin — i.e. that install-and-go isn't a requirement. For the personal fleet it plausibly *is* acceptable, which is why F survives as an escape hatch, not a recommendation.
- **G:** that the drift cost is lower this time than the two documented times it burned this repo — with ~15 forked documents instead of one shared parser. I'd need a publish-time build step that makes the fork mechanical (overlay-style), at which point it stops being G and becomes "C/A applied at publish time".
- **H (as the blanket answer):** that Codex usage of `gws`/`localwp-shell`/`research-tools`/`slack` doesn't matter. The epic exists because it does.

## Hybrids worth considering

- **C + A residue (the likely real-world shape):** mechanical glob for every fenced bash site; A-style model-resolved wording only for Read-pointers and any site a shell can't serve. One comment convention marks the A-residue sites so they're greppable.
- **Layered fallback in one line:** `"${CLAUDE_SKILL_DIR:-$(glob…)}"` with a trailing SKILL.md note: "if this prints `No such file`, substitute the absolute path of this skill's directory (visible where you read this file) and retry." Mechanical first, model as documented last resort — degradation is explicit rather than emergent. Cost: the snippet gets long; keep it two lines max or transcription fidelity drops.
- **J + C:** even if a `CODEX_*` var exists, keep the glob as the third link for future harnesses (`${CLAUDE_SKILL_DIR:-${CODEX_X:-$(glob)}}`) — only if it stays on one line.

## Evidence ledger

Pending (being gathered in parallel — mapped to decisions):

1. **Shell-state persistence across a skill's tool calls** → decides B's placement (per-file vs per-block vs per-site) for whichever mechanism wins. Includes whether Codex joins fenced blocks into one invocation.
2. **Any `CODEX_*` var exposing skill/plugin path** → binary switch for J; obsoletes A/C if true.
3. **Tool-obtainable skill path** (`skills.list`-style) → upgrades A from transcription to grounded lookup; matters only in branch 3.
4. **Deterministic glob over known cache layouts** → binary switch for C. Must answer the sub-question: do superseded version directories persist in the cache, and can one out-sort the installed version?

New evidence this doc requests (not covered by the four in flight):

5. **`allowed-tools` matching semantics in Claude Code** when the body's literal command shape changes (`bash "$SKILL_DIR/…"` vs `bash ${CLAUDE_SKILL_DIR}/…`) — every option except H changes the shape; a permission-prompt regression in Claude Code would be a self-inflicted wound. Check before the codemod, in Claude Code, no Codex involved.
6. **Does Codex fire a plugin-shipped `hooks.json` (SessionStart)?** → gates I.
7. **Does Codex consume a plugin's `.mcp.json`?** → gates E.

Standing caveat: the underlying "Codex sets neither var" finding is from 0.144.6 with the machine now on 0.145.0 (see plugin-root-semantics.md). If a re-probe on 0.145.0+ finds the vars now set, this entire document reduces to "do nothing beyond H's documentation pass" — the happiest possible outcome, and worth the five-minute check before any codemod runs.
