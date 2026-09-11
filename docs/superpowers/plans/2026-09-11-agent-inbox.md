# Agent Inbox Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a token-bounded, read-only Maestro skill that briefs JT on ongoing agent work and items waiting on him without double-counting Hotline callees.

**Architecture:** Provider-owned skills emit compact JSONL status records; Maestro correlates and ranks those records, requests cheap semantic summaries only for a bounded ambiguous shortlist, and renders one human briefing. Session Tools and Hotline retain ownership of their schemas, while Herdr and cmux degrade explicitly when stable identity or access is unavailable.

**Tech Stack:** Markdown skills, Node.js 18+ ESM, Bash, `jq`, Claude Code/Codex dual-harness metadata

**Spec:** `docs/superpowers/specs/2026-09-11-agent-inbox.md`

## Global Constraints

- The workflow is read-only: never resume, prompt, focus, close, mark-seen, or clear notifications.
- cmux and Herdr may be inspected outside their host contexts when their read-only capability probes succeed.
- A default full run requires both providers to be reachable; partial coverage requires confirmation or an explicit partial-scope flag.
- Human output identifies Herdr agents by agent/tab/workspace names and cmux agents by surface/workspace titles, not arbitrary IDs.
- Default caps are eight top-level workstreams, three summary jobs, eight transcript turns, and 8,000 input characters per summarized workstream.
- Hotline callee sessions are children of their caller session and are not top-level duplicates.
- Provider failures and low-confidence correlations remain visible.
- Preserve Claude Code and Codex behavior under the Dual-Harness Skill Contract.
- Do not weaken Herdr’s `HERDR_ENV=1` safety boundary.

---

### Task 1: Bulk Session Status Provider

**Files:**
- Create: `plugins/session-tools/skills/sessions-status/SKILL.md`
- Create: `plugins/session-tools/skills/sessions-status/agents/openai.yaml`
- Modify: `plugins/session-tools/scripts/export-session.mjs`
- Modify: `plugins/session-tools/scripts/lib/format.mjs`
- Modify: `plugins/session-tools/README.md`
- Test: `plugins/session-tools/tests/transcript.test.mjs`

**Interfaces:**
- Consumes: existing `loadIndex()`, `readTranscript()`, `deriveSignals()`, and `deriveTailState()`.
- Produces: `node export-session.mjs --status --since <value> --max <n>` emitting one `ProviderRecord` JSON object per line.

- [ ] **Step 1: Add failing CLI tests for bounded JSONL status output**

Add fixtures and assertions proving that `--status` returns `provider`, `provider_id`,
`session_id`, `cwd`, `title`, normalized `state`, `state_source`, `updated_at`,
`summary_hint`, and `confidence`; filters records before the boundary; excludes sidechain
subagents; sorts waiting records before recent idle records; and obeys `--max`.

```js
assert.deepEqual(Object.keys(record).sort(), [
  'confidence', 'cwd', 'provider', 'provider_id', 'session_id',
  'state', 'state_source', 'summary_hint', 'title', 'updated_at'
]);
assert.equal(record.provider, 'session');
assert.equal(record.state, 'waiting_on_user');
```

- [ ] **Step 2: Run the focused test and verify failure**

Run: `node --test plugins/session-tools/tests/transcript.test.mjs`

Expected: FAIL because `--status` and the ProviderRecord formatter do not exist.

- [ ] **Step 3: Implement the compact status formatter and CLI flags**

Add `--status`, `--since`, and `--max` parsing. Reuse the cached index to prefilter by
mtime, parse only candidates, map transcript tail states as follows, and emit JSONL rather
than a JSON array so partial output survives one malformed session:

```js
const STATE_MAP = {
  'blocked-on-user': 'waiting_on_user',
  'unanswered-user': 'working',
  'interrupted': 'unknown',
  'idle-after-agent': 'idle',
};
```

Keep `summary_hint` to one line and 500 characters. `--status` must not resolve beads;
live bead lookup stays in the detailed digest path and is too expensive for discovery.

- [ ] **Step 4: Add the pared-down skill wrapper**

The skill must be model-free, accept `$ARGUMENTS`, invoke the plugin-root script with the
Dual-Harness path wording, and print JSONL unchanged. Set
`policy.allow_implicit_invocation: false` to mirror `disable-model-invocation: true`.

- [ ] **Step 5: Document and validate the provider**

Run:

```bash
node --test plugins/session-tools/tests/transcript.test.mjs
```

Then invoke `/skill-tools:validate-dual-harness-skill
plugins/session-tools/skills/sessions-status` in Claude Code or
`$skill-tools:validate-dual-harness-skill
plugins/session-tools/skills/sessions-status` in Codex.

Expected: all focused tests pass and the skill reports no contract failures.

- [ ] **Step 6: Commit the provider**

```bash
git add plugins/session-tools/skills/sessions-status plugins/session-tools/scripts/export-session.mjs plugins/session-tools/scripts/lib/format.mjs plugins/session-tools/README.md plugins/session-tools/tests/transcript.test.mjs
git commit -m "add compact session status provider"
```

### Task 2: Hotline Correlation Provider

**Files:**
- Create: `plugins/hotline/skills/call-status/SKILL.md`
- Create: `plugins/hotline/skills/call-status/agents/openai.yaml`
- Create: `plugins/hotline/skills/call-status/scripts/call-status.sh`
- Modify: `plugins/hotline/README.md`
- Test: `plugins/hotline/tests/call-status_test.sh`

**Interfaces:**
- Consumes: `~/.agents-hotline/sessions/*.json` through Hotline-owned code.
- Produces: JSONL ProviderRecords with `parent_session_id` for every known callee and host metadata from `transport`, `surface_ref`, and `remote`.

- [ ] **Step 1: Write fixtures and a failing Bash suite**

Cover current registries, legacy entries without transport, malformed registry files,
multiple callees under one caller, `--since`, and no registry directory. Assert that
malformed files emit a diagnostic record and do not suppress valid records.

```bash
assert_eq "$(jq -r '.parent_session_id' <<<"$line")" "caller-123"
assert_eq "$(jq -r '.session_id' <<<"$line")" "callee-456"
assert_eq "$(jq -r '.host.kind' <<<"$line")" "cmux"
```

- [ ] **Step 2: Run the test and verify failure**

Run: `bash plugins/hotline/tests/call-status_test.sh`

Expected: FAIL because `call-status.sh` does not exist.

- [ ] **Step 3: Implement a read-only registry renderer**

The script accepts `--since <epoch>` and `--sessions-dir <path>` for tests. It must not
source `session-cache.sh`, because that script creates the sessions directory. Map each
connection to `provider:"hotline"`, use `last_contact` for `updated_at`, set state to
`unknown`, state_source to `metadata`, and preserve caller/callee identity exactly.

- [ ] **Step 4: Add and validate the skill wrapper**

The skill prints compact JSONL only, has no model work, and is non-implicit under both
harnesses. Document that it is the programmatic sibling of Switchboard, not a second
dashboard.

Run:

```bash
bash plugins/hotline/tests/call-status_test.sh
```

Then invoke `/skill-tools:validate-dual-harness-skill
plugins/hotline/skills/call-status` in Claude Code or
`$skill-tools:validate-dual-harness-skill plugins/hotline/skills/call-status`
in Codex.

Expected: all tests pass and the skill reports no contract failures.

- [ ] **Step 5: Commit the provider**

```bash
git add plugins/hotline/skills/call-status plugins/hotline/README.md plugins/hotline/tests/call-status_test.sh
git commit -m "add read-only Hotline call status provider"
```

### Task 3: Correlator and Ranker

**Files:**
- Create: `plugins/maestro/scripts/agent-inbox.mjs`
- Create: `plugins/maestro/tests/agent-inbox.test.mjs`

**Interfaces:**
- Consumes: ProviderRecord JSONL on stdin.
- Produces: one JSON document `{generated_at, boundary, groups, diagnostics, summary_candidates, next_for_you}`.

- [ ] **Step 1: Write failing correlation tests**

Create table-driven fixtures for: Hotline child collapse, native-state precedence,
transcript-responsibility precedence, exact-ID joins, refusal to merge by cwd/title alone,
provider diagnostics, stable ordering, default eight-record cap, and default three-summary
cap.

```js
assert.equal(result.groups.needs_you.length, 1);
assert.equal(result.groups.needs_you[0].children[0].session_id, 'callee-456');
assert.equal(result.groups.needs_you.some(x => x.session_id === 'callee-456'), false);
assert.equal(result.summary_candidates.length <= 3, true);
```

- [ ] **Step 2: Run the test and verify failure**

Run: `node --test plugins/maestro/tests/agent-inbox.test.mjs`

Expected: FAIL because the correlator does not exist.

- [ ] **Step 3: Implement normalization, correlation, and ranking**

Export pure functions for tests:

```ts
normalizeRecord(input: unknown): ProviderRecord | Diagnostic
correlate(records: ProviderRecord[]): Workstream[]
rank(workstreams: Workstream[], options: { max: number }): GroupedInbox
```

Reject invalid enum values as diagnostics. Join exact session IDs first, attach Hotline
children second, then decorate with host records only when session ID or explicit Hotline
host handle matches. Never join on cwd/title alone. Select summary candidates only when
`summary_hint` cannot explain a waiting, working, or unknown state.

- [ ] **Step 4: Run focused tests**

Run: `node --test plugins/maestro/tests/agent-inbox.test.mjs`

Expected: all tests pass.

- [ ] **Step 5: Commit the correlator**

```bash
git add plugins/maestro/scripts/agent-inbox.mjs plugins/maestro/tests/agent-inbox.test.mjs
git commit -m "add agent inbox correlation engine"
```

### Task 4: Maestro Agent Inbox Skill

**Files:**
- Create: `plugins/maestro/skills/agent-inbox/SKILL.md`
- Create: `plugins/maestro/skills/agent-inbox/agents/openai.yaml`
- Modify: `plugins/maestro/README.md`
- Test: `plugins/maestro/tests/agent-inbox-skill_test.sh`

**Interfaces:**
- Consumes: output from `session-tools:sessions-status`, `hotline:call-status`, documented Herdr `agent list`, and documented cmux `tree`, `sidebar-state`, and notification commands.
- Produces: the briefing format in the spec and optional `--json` output.

- [ ] **Step 1: Write a failing skill-contract test**

Assert exact defaults and safety language, dual-harness path tokens, the two-provider preflight,
Herdr’s read-only outside-context path, cmux reachability, partial-run confirmation, cmux UUID
usage, no screen reads by default, summary caps, `--no-summaries`, and the singular
`Next for you:` line.

- [ ] **Step 2: Run the contract test and verify failure**

Run: `bash plugins/maestro/tests/agent-inbox-skill_test.sh`

Expected: FAIL because the skill does not exist.

- [ ] **Step 3: Implement the provider-reachability preflight**

Probe cmux with `cmux tree --all --json --id-format both` and Herdr with `herdr agent list`.
Both probes must be documented as read-only and must not mark tabs or agents seen. Native
`CMUX_*` and `HERDR_*` context enriches locators but is not required. When only one or
neither provider answers, ask before collection beyond the probes whether to continue
partially or resume where both are reachable. Explicit partial flags bypass only that
confirmation. The skill must not move or launch the current conversation itself.

- [ ] **Step 4: Implement provider collection in the skill**

After preflight consent, the skill loads provider skills when installed, captures each
JSONL stream separately, and feeds their concatenation to `agent-inbox.mjs`. Through a
reachable Herdr server, use `herdr agent list` and map native states without calling
`agent get/read` unless a shortlisted record lacks a summary hint. Through a reachable
cmux socket, snapshot `tree --all --json --id-format both`, query sidebar state and notifications read-only, and
do not infer a session ID from a title. A partial run emits an explicit coverage banner.

- [ ] **Step 5: Implement bounded cheap summarization**

For each `summary_candidates` entry, request this exact output shape from a cheaper model
when the harness exposes explicit model selection:

```json
{"status":"one sentence","waiting_on_jt":"one sentence or null","next":"one sentence","confidence":"high|medium|low"}
```

Supply `sessions-catch-up` digest data with `--window 8 --max-chars 8000 --fast
--no-beads`. Batch candidates into one request when supported, cap concurrent requests at
three, and never ask for `--deep`. If model selection is unavailable, summarize no more
than three candidates inline and label unsummarized records with their locator.

- [ ] **Step 6: Render the briefing and JSON mode**

Omit empty groups, show confidence only when medium/low, indent Hotline child status under
the caller only when it explains a blocker or conflict, list unavailable providers last,
and end with one `Next for you:` action chosen from the highest-ranked concrete blocker.
Render Herdr locations as `<agent name> in <tab name>, <workspace name>` and cmux locations
as `<surface title> in <workspace title>` plus a window anchor only when needed. Never
render a UUID/pane ID as the primary locator.

- [ ] **Step 7: Validate the skill and focused suites**

Run:

```bash
bash plugins/maestro/tests/agent-inbox-skill_test.sh
node --test plugins/maestro/tests/agent-inbox.test.mjs
```

Then invoke `/skill-tools:validate-dual-harness-skill
plugins/maestro/skills/agent-inbox` in Claude Code or
`$skill-tools:validate-dual-harness-skill plugins/maestro/skills/agent-inbox`
in Codex.

Expected: all focused tests pass and the skill reports no contract failures.

- [ ] **Step 8: Commit the user-facing skill**

```bash
git add plugins/maestro/skills/agent-inbox plugins/maestro/README.md plugins/maestro/tests/agent-inbox-skill_test.sh
git commit -m "add token-bounded agent inbox briefing"
```

### Task 5: Catalog, Compatibility, and Full Verification

**Files:**
- Modify: `plugins/session-tools/.claude-plugin/plugin.json`
- Modify: `plugins/hotline/.claude-plugin/plugin.json`
- Modify: `plugins/maestro/.claude-plugin/plugin.json`
- Modify: `.agents/plugins/marketplace.json` (generated)
- Modify: any generated catalog files produced by `node scripts/gen-codex-catalog.mjs`

**Interfaces:**
- Consumes: all three completed provider/orchestrator changes.
- Produces: discoverable Claude and Codex skills with one version bump per changed plugin.

- [ ] **Step 1: Run the compounding preflight against the change-set**

Use the repo-private `compounding-preflight` skill and address every applicable ledger
headline. In particular, ensure docs describe the actual provider mechanism and no new
transcript parser was introduced.

- [ ] **Step 2: Bump each changed plugin once**

Apply one semver minor bump to Session Tools, Hotline, and Maestro because each gains a
new non-breaking skill. Do this only after behavior and docs have settled.

- [ ] **Step 3: Regenerate the Codex catalog**

Run: `node scripts/gen-codex-catalog.mjs`

Expected: generated inventory includes `session-tools:sessions-status`,
`hotline:call-status`, and `maestro:agent-inbox`; no hand edits are made to the generated
marketplace.

- [ ] **Step 4: Run focused and full quality gates**

Run:

```bash
node --test plugins/session-tools/tests/transcript.test.mjs
bash plugins/hotline/tests/call-status_test.sh
node --test plugins/maestro/tests/agent-inbox.test.mjs
bash plugins/maestro/tests/agent-inbox-skill_test.sh
bash tests/run-all.sh
```

Expected: every focused suite passes; the full summary reports zero failures and exactly
the one expected `codex: live-plugin` skip unless `CODEX_LIVE=1` is intentionally enabled.

- [ ] **Step 5: Perform two read-only live probes**

From outside Herdr but with its server reachable, run `/maestro:agent-inbox --no-summaries`
and verify both provider inventories appear without touching any surface. Repeat with one
provider genuinely unreachable and verify that the skill pauses after capability probes;
approve a partial run and verify the coverage banner. Finally run from a Herdr-managed
agent nested in cmux and verify richer native locators. Confirm every normal locator uses
visible names rather than IDs, and record actual output counts and low-confidence joins.

- [ ] **Step 6: Commit release metadata and generated files**

Before committing, run `git status`, `git diff`, `git diff --cached`, and `git log -5
--oneline`; stage only the three manifests and generated catalog files.

```bash
git add plugins/session-tools/.claude-plugin/plugin.json plugins/hotline/.claude-plugin/plugin.json plugins/maestro/.claude-plugin/plugin.json .agents/plugins/marketplace.json
git commit -m "update agent inbox plugin catalogs"
```

- [ ] **Step 7: Ship through the repository release workflow**

Manually invoke `publish-release`. Confirm the three plugin versions, dual-harness
validation, merge result, marketplace refresh, `bd dolt push`, `git push`, and final
`git status` rather than treating a local commit as shipped.

### Task 6: Follow-up Discovery for Complete Non-Hotline Coverage

**Files:**
- Create only if evidence supports it: `plugins/cmux-cli/skills/agent-status/SKILL.md`
- Create only if evidence supports it: `plugins/cmux-cli/skills/agent-status/scripts/agent-status.sh`
- Test only if created: `plugins/cmux-cli/tests/agent-status_test.sh`
- External follow-up: Herdr read-only outside-context inventory skill/capability

**Interfaces:**
- Consumes: stable session identity/lifecycle signals discovered from cmux and Herdr.
- Produces: ProviderRecords for independent non-Hotline agents, or a documented “not safely available” result.

- [ ] **Step 1: Spike cmux identity without screen scraping**

Inspect current `cmux capabilities`, `tree --all --json`, `sidebar-state`, notifications,
surface health, and Claude hook metadata. A usable signal must provide stable surface UUID,
agent kind, session ID, lifecycle state, and freshness without reading terminal prose. Do
not treat titles, tty paths, or process command lines alone as session identity.

- [ ] **Step 2: Decide whether `cmux-cli:agent-status` is justified**

Create the skill only if the spike finds a stable high/medium-confidence interface. If it
does not, close the spike with the explicit limitation and keep V1’s uncertainty section;
do not build heuristic screen parsing.

- [ ] **Step 3: Specify the Herdr upstream change**

Add a separate read-only global inventory skill or snapshot that can be consumed outside
`HERDR_ENV=1` when `herdr agent list` can reach the server. Require stable agent name,
tab/workspace names, pane ID, cwd, agent kind, session ID when known, lifecycle state, and
last transition time. Keep every control or mutation command behind `HERDR_ENV=1`. Until
that change lands, treat outside-context Herdr inventory as unavailable rather than
bypassing the installed skill contract.

- [ ] **Step 4: File linked beads for accepted follow-up work**

Create one linked issue per accepted provider change with
`--deps discovered-from:claude-plugins-b3la`; do not mix speculative adapter code into the
V1 release.
