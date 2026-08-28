# Plugin Split — Scope Justification

Decision doc: which multi-skill plugins get split into single-skill plugins, and in what order. **Reviewed and decided 2026-08-20**: Option A (pr-workflow pilot only), with one amendment — `address-pr-comments` and `address-pr-comments-human` stay together in a single `address-pr-comments` child plugin (same job, human-vs-agent variants), so pr-workflow splits into **5 children + bundle**, not 6. Prior decisions:

- **Install UX**: split + dependency-only bundle plugin (official term per Claude docs). The bundle keeps the old plugin name (`pr-workflow`), so `claude plugin install pr-workflow@...` still installs everything. Per-child customization is a two-step (verified 2026-08-20 on Claude Code 2.1.237 with fixture plugins): a child cannot be disabled while the bundle is enabled — disable the bundle first (children stay installed/enabled), then disable unwanted children. Codex (0.148.0) ignores `dependencies` entirely; Codex users install children directly and the bundle is marked notAvailable in the Codex catalog.
- **Repo layout**: nested group dir — `plugins/pr-workflow/{bundle/, address-pr-comments/, ...}`. Requires updating ~6 in-repo tooling sites (test-runner globs, compatibility test, 2 scripts).
- **Naming**: child plugin name = skill name → invocation `/address-pr-comments:address-pr-comments` (precedent: `aiqrank:aiqrank`).

## Why split at all (recap)

Claude Code has no per-skill disable for plugin skills: `skillOverrides` excludes them (filed upstream as [anthropics/claude-code#88302](https://github.com/anthropics/claude-code/issues/88302)), and permission deny rules block invocation but leave the description in context. Splitting is the only author-side move that gives users real granularity today. Codex already has per-skill disabling (`[[skills.config]]`), so this is for Claude users.

## What splitting costs — same price regardless of scope

- **Every existing invocation breaks**: `/pr-workflow:X` → `/X:X`. Docs, muscle memory, `.codex-plugin` `defaultPrompt` examples all need updating; users need a migration note.
- **Release overhead multiplies**: one version line becomes N+1 (children + bundle). `publish-release` runs per plugin.
- **Tooling migration** (one-time, shared across all splits): run-all.sh globs, `compatibility.test.mjs` (3 assumptions), `measure-skill-descriptions.sh`, `compare-skill-descriptions.mjs`, `install-standalone-skill.sh`, marketplace entries.

## Honest numbers: the token savings are small

Frontmatter (what lands in every session) per candidate, ~chars/4:

| Plugin | Skills | Total context cost | Notes |
|---|---|---|---|
| pr-workflow | 6 | ~461 tok — **but only ~304 live** | 3 skills already ship `disable-model-invocation: true` (address-pr-comments, -human, update-pr-description) and cost zero context now |
| beads-workflow | 3 | ~382 tok | triage-beads alone is ~297 |
| thinking-tools | 3 | ~323 tok | evenly spread |
| git-commits | 2 | ~147 tok | smallest |

A user who disables half of pr-workflow's live skills saves ~150 tokens/session. **The real value of splitting is not tokens** — it's (a) trigger-routing noise: unwanted descriptions compete at skill-selection time, (b) the duplicate-skill problem: users who have their own `update-pr-description` equivalent can drop ours entirely, (c) install-time choice as the plugin catalog grows. If those don't feel compelling per-plugin, the split isn't worth its cost for that plugin.

## Candidate-by-candidate

### pr-workflow — strong yes (DECIDED: split into 5 children + bundle)
Zero coupling: no skill references a sibling, no shared plugin-root scripts/references; each skill is self-contained (verified by grep). No internal-mirror mapping entries — nothing external breaks. Six skills spanning genuinely different jobs (reviewing history vs. QA walkthroughs vs. comment triage vs. PR watching) — the highest-probability plugin for "I want some of these, not all." Has `.codex-plugin`, so the split exercises the dual-harness path once, where mistakes are cheapest to find. **This is the pilot.**

Amendment from review: `address-pr-comments` + `address-pr-comments-human` are variants of one job and ship together as a single `address-pr-comments` child plugin with two skills. Final children: `address-pr-comments` (2 skills), `qa-walkthrough-pr`, `update-pr-description`, `walk-through-work-history`, `watch-pr-then-action`, plus the `pr-workflow` bundle.

### git-commits — weak case
Two skills (`commit-staged`, `commit-unstaged`) that are the same job with different staging behavior. A user who wants one almost certainly tolerates both; ~74 tok saved by dropping one. Splitting doubles its release surface for near-zero user value. **Recommend: don't split.** If duplication complaints arrive ("I have my own commit skill"), revisit.

### thinking-tools — moderate case
Three genuinely unrelated skills (chestertons-fence, interview-mode, pink-elephant) — thematic grouping only, so subset-demand is plausible. But: two skills have internal-mirror mappings whose paths break on move, adding mirror republish work to the split. Value is real but not urgent. **Recommend: split in the follow-up wave, not the pilot.**

### beads-workflow — moderate case
Three uncoupled skills, but they serve one audience (beads users) and one workflow arc (triage → tackle → fix-findings). A beads user plausibly wants all three; a non-beads user installs none. Subset-demand is the weakest of the three-skill plugins. **Recommend: hold. Split only if triage-beads's ~297-token description draws complaints from users who only want the other two.**

### Everything else — stays whole (not a judgment call)
agentmail, hotline, gws, collab-tools, cmux-cli, work-with-media, fable, codex, session-tools, skill-tools all have verified coupling: sibling cross-references, shared plugin-root scripts/references, or deliberate lockstep sets (the stance-skill trio). Splitting them breaks behavior, not just paths.

## Scope decision

**Option A chosen: pr-workflow pilot only.** Land the split + all shared tooling changes in one change-set. thinking-tools follows in a later wave once the pattern is proven; git-commits and beads-workflow stay whole unless demand appears.

(Options considered: B added thinking-tools now — deferred; C split all four — rejected, git-commits and beads-workflow fail their own cost/benefit.)

## Open items

- Migration path gets verified but not heavily documented — the only known installer is the author, so a one-line release note suffices.
- Bundle-update behavior: auto-update off by default for non-Anthropic marketplaces; users pick up new children via `claude plugin update pr-workflow` + `/reload-plugins`. Document this.
- The stale `measure-skill-descriptions.sh` 60-skill guard (claude-plugins-nwtk) gets fixed as part of the tooling pass.
- Follow-up (from review): author a repo-private meta-skill (`.claude/skills/split-plugin/`) that encodes this split playbook — both "split an existing multi-skill plugin" and "should a new plugin start split?" guidance — so future splits don't re-derive the process.

## Verification

Live install verification against the shipped plugins (2026-08-20, Claude Code 2.1.237, codex-cli 0.148.0), run in isolated `CLAUDE_CONFIG_DIR` / `CODEX_HOME` scratch dirs, confirms every earlier probe on this doc — this time on the real `pr-workflow` group, not fixtures.

- **Dependency auto-install: yes.** `claude plugin install pr-workflow@jtsternberg` pulled all 5 children in one call: `Successfully installed plugin: pr-workflow@jtsternberg (scope: user) (+ 5 dependencies: address-pr-comments, qa-walkthrough-pr, update-pr-description, walk-through-work-history, watch-pr-then-action)`. `claude plugin list` showed all 6 (bundle + 5 children) enabled; `claude plugin details` on each child confirmed skills resolve under the child's own namespace (address-pr-comments: 2 skills; the other four: 1 skill each).
- **Refusal message: confirmed verbatim.** Disabling a child directly while the bundle is enabled fails as documented: `Failed to disable plugin "update-pr-description@jtsternberg": update-pr-description is still required by pr-workflow. Disable that plugin first, or disable everything together: claude plugin disable pr-workflow@jtsternberg && claude plugin disable update-pr-description@jtsternberg`.
- **Per-child disable: works.** Following the suggested two-step — `claude plugin disable pr-workflow@jtsternberg` (children stayed enabled), then `claude plugin disable update-pr-description@jtsternberg` — left `update-pr-description` disabled while the other four children stayed enabled.
- **Codex: bundle notAvailable, children install directly (as designed).** `codex plugin add pr-workflow@jtsternberg` fails: `plugin \`pr-workflow\` is not available for install in marketplace \`jtsternberg\`` (native catalog `installPolicy: NOT_AVAILABLE`, as generated in Task 6). `codex plugin add walk-through-work-history@jtsternberg` installed and enabled cleanly, with skills under `skills/walk-through-work-history/`.
