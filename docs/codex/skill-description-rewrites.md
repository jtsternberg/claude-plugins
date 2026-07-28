# Skill-description rewrites for the Codex budget

Draft for review — nothing under `plugins/` is edited by this doc's phase. Proposed texts live
in [`proposed-descriptions.json`](proposed-descriptions.json); every number below was emitted by
[`scripts/compare-skill-descriptions.mjs`](../../scripts/compare-skill-descriptions.mjs), which
re-parses the live SKILL.md frontmatter and the proposals on each run:

```bash
node scripts/compare-skill-descriptions.mjs                 # the tables below (exits 1 on any 1,536-cap violation)
node scripts/compare-skill-descriptions.mjs --dump-current  # current state as JSON
```

**Status: Phase 1 (the 24 explicit-only description rewrites) has landed** — explicit-only
descriptions now total 2,005 chars in the live tree. The "before" figures in the tables below
are therefore post-Phase-1; the original all-50 baseline was 15,902 chars (198.77% of the
Codex budget), measured before any landing.

## The verified Codex / Claude Code asymmetry (this changed the plan)

Tested empirically on Codex 0.145.0: `when_to_use`, `argument-hint`, and `effort` frontmatter
have **no effect** on Codex implicit matching and are accepted without warning. Claude Code,
by contrast, **does** read `when_to_use`: it is appended to `description` as additional
invocation context, sharing a **1,536-char per-skill cap** with it.

So the two matchers see different text:

| field | Codex (8,000-char global pool) | Claude Code (1,536/skill cap) |
|---|---|---|
| `description` | matched | matched |
| `when_to_use` | ignored | matched |

The original draft of this plan cut trigger vocabulary from `description` and stopped there —
which would have *deleted* it from Claude Code's matcher too, a silent recall loss. The
corrected plan **relocates** it: `description` carries the short, Codex-safe trigger core;
`when_to_use` carries the overflow vocabulary that Claude Code alone matches on. Each entry in
`proposed-descriptions.json` is now either a string (description only) or
`{ "description", "when_to_use" }`.

An earlier "bad ideas" bullet here claimed the `when_to_use` escape hatch "mostly moves
phrases out of both matchers." That was wrong on the Claude Code half, and the empirical
Codex test settled the other half. Withdrawn.

## The target, and why

Unchanged from the first draft. **Per-skill ceilings, not a repo-total quota:** explicit-only
`description` ≤ 120 chars; implicitly-invocable `description` ≤ 200 default, ≤ 270 only with
written justification; `description` + `when_to_use` ≤ 1,536 per skill (hard cap, enforced by
the comparator's exit code). The full-repo Codex figure lands at **6,557 chars (81.96%)**; a
deliberately heavy 10-plugin install (gws, slack, work-with-media, session-tools, handoff,
pr-workflow, skill-tools, research-tools, collab-tools, thinking-tools) totals **4,040 chars
(50.50%)** — and relocation doesn't change either figure, because `when_to_use` costs Codex
nothing.

The repo total is the wrong unit because nobody installs all 27 plugins; what composes across
subsets is per-skill cost. And pushing the repo under ~4,000 by thinning descriptions further
would delete the distinctive nouns that make implicit invocation work — if the
install-everything case must also be safe, the right lever is the domain-bundle
recommendation in [`skill-description-budget.md`](skill-description-budget.md), not thinner
descriptions.

## What the rewrites do

Two different jobs, two different rules:

- **Explicit-only (24 skills, `disable-model-invocation: true`).** Landed. These can never be
  implicitly invoked; the description is a picker label. One sentence that disambiguates from
  siblings. 6,648 → **2,005** (avg 84). No relocation needed — trigger phrases cut from these
  were matching nothing in either harness.
- **Implicitly invocable (26 skills).** The description keeps every distinctive noun/verb a
  user would actually type (proper nouns, URL shapes, file extensions, error strings,
  companion-skill routing): 9,254 → **4,552** (avg 175). Trigger vocabulary that still carries
  matching signal but didn't earn `description` chars moves to `when_to_use` — merged into the
  11 implicit skills that already had one (never clobbered), added fresh to 9 more, and
  deliberately **not** relocated where the cut text was noise (see "Dropped entirely" below).

One description grew: `collab-tools/promote-draft` (+14), adding the "not for arbitrary file
moves" guard. Its existing `when_to_use` already carries that guard for Claude Code — the
duplication is deliberate, because Codex cannot see `when_to_use` and needs the misfire guard
in the only field it reads.

## Two-budget before/after (all numbers from `compare-skill-descriptions.mjs`)

### Explicit-only (disable-model-invocation: true) (24 skills)

| plugin/skill | desc before | desc after | delta | wtu before | wtu after | CC combined after (cap 1536) |
|---|---:|---:|---:|---:|---:|---:|
| session-tools/sessions-fork | 115 | 115 | 0 | 467 | 467 | 582 |
| gws/md-to-google-doc | 111 | 111 | 0 | 0 | 0 | 111 |
| pr-workflow/watch-pr-then-action | 111 | 111 | 0 | 0 | 0 | 111 |
| session-tools/sessions-catch-up | 110 | 110 | 0 | 580 | 580 | 690 |
| gws/google-doc-to-md | 106 | 106 | 0 | 0 | 0 | 106 |
| session-tools/sessions-weekly-recap | 104 | 104 | 0 | 0 | 0 | 104 |
| skill-tools/create-skill | 103 | 103 | 0 | 0 | 0 | 103 |
| slides-presentation/create-slides-presentation | 102 | 102 | 0 | 0 | 0 | 102 |
| pr-workflow/qa-walkthrough-pr | 98 | 98 | 0 | 195 | 195 | 293 |
| hotline/ringing | 97 | 97 | 0 | 0 | 0 | 97 |
| mac-caffeinate/caffeinate-computer | 88 | 88 | 0 | 0 | 0 | 88 |
| git-tree/create-git-tree | 81 | 81 | 0 | 0 | 0 | 81 |
| hotline/pickup | 73 | 73 | 0 | 0 | 0 | 73 |
| skill-tools/create-subagent | 73 | 73 | 0 | 0 | 0 | 73 |
| paperclip/paperclip | 69 | 69 | 0 | 0 | 0 | 69 |
| skill-tools/create-slash-command | 67 | 67 | 0 | 0 | 0 | 67 |
| skill-tools/review-skill | 67 | 67 | 0 | 0 | 0 | 67 |
| headline-refiner/headline-refiner | 64 | 64 | 0 | 0 | 0 | 64 |
| skill-tools/review-slash-command | 64 | 64 | 0 | 0 | 0 | 64 |
| generating-blog-images/blog-image-prompts | 63 | 63 | 0 | 0 | 0 | 63 |
| hotline/add-contact | 63 | 63 | 0 | 0 | 0 | 63 |
| bible/bible-nlt-lookup | 62 | 62 | 0 | 0 | 0 | 62 |
| export-presentation/export-presentation | 58 | 58 | 0 | 0 | 0 | 58 |
| hotline/whoami | 56 | 56 | 0 | 0 | 0 | 56 |
| **subtotal** | **2005** | **2005** | **0** | **1242** | **1242** | — |

Three explicit-only skills (sessions-fork, sessions-catch-up, qa-walkthrough-pr) carry a
pre-existing `when_to_use`. It is matched by nothing (they can't be implicitly invoked in
either harness), so it's proposed unchanged here to keep this change surgical — deleting it
is a separate cleanup decision (1,242 chars of per-skill-cap dead weight, no budget impact).

### Implicitly invocable (26 skills)

| plugin/skill | desc before | desc after | delta | wtu before | wtu after | CC combined after (cap 1536) |
|---|---:|---:|---:|---:|---:|---:|
| slack/read-slack | 638 | 268 | -370 | 585 | 585 | 853 |
| work-with-media/macwhisper-cli | 606 | 254 | -352 | 360 | 444 | 698 |
| gws/youtube | 577 | 168 | -409 | 338 | 421 | 589 |
| thinking-tools/pink-elephant | 488 | 222 | -266 | 0 | 147 | 369 |
| fable/fable-mode | 466 | 259 | -207 | 0 | 114 | 373 |
| thinking-tools/chestertons-fence | 448 | 211 | -237 | 0 | 143 | 354 |
| gws/calendar | 439 | 157 | -282 | 243 | 423 | 580 |
| obsidian-cli/obsidian-cli | 430 | 161 | -269 | 0 | 0 | 161 |
| work-with-media/yt-dlp | 417 | 263 | -154 | 535 | 535 | 798 |
| gws/gmail-draft-from-markdown | 374 | 127 | -247 | 0 | 170 | 297 |
| cmux-cli/auto-rename | 370 | 196 | -174 | 0 | 159 | 355 |
| gws/gmail-read | 348 | 122 | -226 | 0 | 94 | 216 |
| hotline/switchboard | 348 | 142 | -206 | 0 | 127 | 269 |
| handoff/pickup-handoff | 346 | 152 | -194 | 0 | 90 | 242 |
| handoff/handoff | 336 | 169 | -167 | 0 | 87 | 256 |
| research-tools/fetch-docs | 331 | 186 | -145 | 470 | 470 | 656 |
| localwp-shell/localwp-shell | 314 | 191 | -123 | 0 | 0 | 191 |
| collab-tools/diff-view | 247 | 176 | -71 | 440 | 440 | 616 |
| hotline/wiretap | 247 | 119 | -128 | 0 | 0 | 119 |
| hotline/dial | 242 | 136 | -106 | 0 | 0 | 136 |
| fable/fable-delegate | 240 | 177 | -63 | 0 | 0 | 177 |
| collab-tools/temp-draft | 239 | 149 | -90 | 271 | 271 | 420 |
| hotline/caller-id | 238 | 75 | -163 | 0 | 0 | 75 |
| cmux-cli/using-cmux-cli | 213 | 185 | -28 | 327 | 327 | 512 |
| gws/account | 168 | 129 | -39 | 445 | 445 | 574 |
| collab-tools/promote-draft | 144 | 158 | 14 | 429 | 429 | 587 |
| **subtotal** | **9254** | **4552** | **-4702** | **4443** | **5921** | — |

### Totals

```
## Codex budget (description only, 8000-char global pool)
Before: 11259 chars (140.74%)        [post-Phase-1; original all-50 baseline was 15902 = 198.77%]
After:  6557 chars (81.96%)
  explicit-only: 2005 -> 2005
  implicit:      9254 -> 4552

## Claude Code budget (description + when_to_use, 1536-char cap per skill)
Combined before: 16944 chars; after: 13720 chars (delta -3224)
Largest per-skill combined after: slack/read-slack at 853 (55.53% of the 1536 cap)
Skills over the 1536 cap: 0

Proposals carrying a when_to_use: 23
```

The 1,536-cap concern is verified, not assumed: the comparator checks every skill and exits
non-zero on a violation. Worst case after relocation is 853/1,536.

## The relocation, skill by skill

**New `when_to_use` (9 skills)** — cut vocabulary that still carries Claude Code matching
signal: `cmux-cli/auto-rename`, `fable/fable-mode`, `gws/gmail-draft-from-markdown`,
`gws/gmail-read`, `handoff/handoff`, `handoff/pickup-handoff`, `hotline/switchboard`,
`thinking-tools/chestertons-fence`, `thinking-tools/pink-elephant`. Notables: the two
thinking-tools skills get their paraphrase triggers back ("concerns about unintended
side-effects", "critiques of prohibition framing") — those matter most for concept skills
matched by paraphrase; `fable-mode` regains the "Sonnet agents must load the guardrails
reference first" line, which was the one behavioral instruction I cut that the description
was the sole carrier of.

**Merged into an existing `when_to_use` (3 skills)** — existing text kept verbatim, authored
addition appended: `gws/calendar` (+ the raw-CLI routing rule and three cut phrasings),
`gws/youtube` (+ 'clean up my youtube playlists', 'merge playlists', 'youtube cleanup'),
`work-with-media/macwhisper-cli` (+ the model names whisper-cpp / WhisperKit / Parakeet /
Apple speech, which a user might say verbatim).

**Existing `when_to_use` kept unchanged (8 skills):** `read-slack`, `yt-dlp`, `fetch-docs`,
`diff-view`, `promote-draft`, `temp-draft`, `using-cmux-cli`, `gws/account` — everything cut
from their descriptions was already present there.

**Dropped entirely, on purpose (6 skills get no `when_to_use`):**

- `hotline/caller-id`, `hotline/wiretap`, `hotline/dial` — the cut text was near-synonym
  pile-ups of phrases the short description still contains ("'find my transcript'" next to
  "'where is my transcript'"); relocating it moves dead weight into the per-skill cap.
- `obsidian-cli` — every cut phrase ("obsidian task", "note in obsidian", …) is a
  recombination of tokens the description already lists (Obsidian, vault, daily notes, tasks,
  properties, tags, bases, search).
- `localwp-shell`, `fable-delegate` — the cuts were grammar and restatement; no vocabulary was
  lost.

Also dropped from everywhere: internal mechanics that match nothing ("returns structured
results (id, subject, from, date, snippet)", "(v1.12+)", "subs-first is usually cheaper",
"streaming, one-off model overrides, persist-to-history"), and "This skill should be used
when…" scaffolding. One judgment call: `using-cmux-cli` loses "sidebar progress" and
"surfaces" from its description; "surfaces" survives in its existing `when_to_use`, "sidebar
progress" is gone — I judged it too niche to earn chars in either field.

## Must stay long(ish) — the six descriptions over 200 chars

Unchanged from the first draft and not revisited: `read-slack` (268), `yt-dlp` (263),
`fable-mode` (259), `macwhisper-cli` (254), `pink-elephant` (222), `chestertons-fence` (211).
These keep their trigger core in `description` because Codex users need them to fire too —
relocation helps Claude Code only. Rationale per skill: read-slack's `slack.com/archives` URL
shape and three modes; the yt-dlp/macwhisper mutual routing contract; fable-mode's abstract
firing conditions; the thinking-tools pair's paraphrase-taught concepts.

## The authoring rule for AGENTS.md

> ### Skill description budget
>
> Skill `description:` frontmatter is shared trigger real estate: Codex pools every installed
> skill's description into one ~8,000-char budget and silently truncates the overflow, and
> truncated descriptions stop matching. Claude Code additionally matches on `when_to_use:`
> (appended to the description, 1,536-char combined cap per skill); Codex ignores
> `when_to_use` entirely (verified on 0.145.0). Check with
> `node scripts/compare-skill-descriptions.mjs`.
>
> - **`disable-model-invocation: true` skills: `description` ≤ 120 chars, no `when_to_use`.**
>   The description is a picker label, never a trigger — one sentence saying what it does and
>   what makes it different from its siblings. Trigger-phrase lists match nothing.
> - **Implicitly-invocable skills: `description` ≤ 200 chars** (≤ 270 with a justifying
>   comment in the PR). Spend description chars only on tokens a user would actually type:
>   proper nouns, URL/file patterns, error strings, companion-skill routing. Three example
>   phrasings beat ten.
> - **Overflow trigger vocabulary goes in `when_to_use`**, within the 1,536 combined cap. It
>   is Claude-Code-only: anything that must also trigger Codex belongs in `description`.
>   Don't warehouse noise there — near-synonyms of description phrases and internal mechanics
>   get cut, not relocated.

## Bad ideas, stated plainly

- **Targeting 8,000 (or "just under") is a bad idea** — it budgets as if this repo is the only
  thing installed. It never is; Codex ships bundled skills.
- **Forcing the repo under ~4,000 by editing descriptions is also a bad idea.** The remaining
  mass is implicit trigger surface; cutting it degrades Codex triggering to protect an
  install-everything scenario the marketplace-bundle recommendation handles better.
- **Relocation is not free for Codex.** `when_to_use` restores Claude Code recall, but Codex
  still only sees the short descriptions — the "watch for missed triggers" caveat now applies
  to Codex sessions specifically, and skill-creator's description-eval tooling could still A/B
  the biggest cuts (read-slack, calendar, obsidian-cli) there.
- **Do not land Phase 2 without version-bumping the touched plugins.** 26 skills across 12
  plugins change (code-verified: cmux-cli, collab-tools, fable, gws, handoff, hotline,
  localwp-shell, obsidian-cli, research-tools, slack, thinking-tools, work-with-media);
  several were already bumped in Phase 1 and land-ordering determines whether they need
  another bump.
- **Withdrawn from the first draft:** the claim that `when_to_use` moves phrases out of both
  matchers. Claude Code documents it as invocation context, and Codex 0.145.0 verifiably
  ignores it — the asymmetry is exactly the tool this plan needed.
