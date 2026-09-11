# Agent Inbox Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a small read-only Maestro skill that catches the user up on live cmux and Herdr agents without double-counting Hotline callees.

**Architecture:** Compose existing Herdr, cmux, Session Tools, and Hotline capabilities in prose. One small Hotline helper exposes caller/callee relationships; no generalized provider framework or Maestro status engine is introduced.

**Tech Stack:** Markdown skills, Bash, `jq`, existing plugin scripts

**Spec:** `docs/superpowers/specs/2026-09-11-agent-inbox.md`

## Global Constraints

- Read-only: never send input, resume, focus, close, mark seen, or clear notifications.
- Reachability is sufficient; the inbox need not run inside cmux or Herdr.
- Ask before continuing when either host is unreachable.
- Use visible names as locators; IDs are fallback-only.
- Summarize at most five unclear workstreams from bounded Session Tools digests.
- Do not add user-facing options in V1.

---

### Task 1: Expose Hotline Caller/Callee Status

**Files:**
- Create: `plugins/hotline/skills/call-status/SKILL.md`
- Create: `plugins/hotline/skills/call-status/agents/openai.yaml`
- Create: `plugins/hotline/skills/call-status/scripts/call-status.sh`
- Create: `plugins/hotline/scripts/call-registry.mjs`
- Modify: `plugins/hotline/skills/switchboard/scripts/server.js`
- Modify: `plugins/hotline/README.md`
- Test: `plugins/hotline/tests/call-status_test.sh`
- Test: `plugins/hotline/tests/switchboard_test.sh`

**Interfaces:**
- Consumes: Hotline's existing session registry.
- Produces: compact caller session, callee session, target, transport, host handle, mode, and last-contact records.

- [ ] **Step 1: Extract the registry reader**

Move Switchboard's registry parsing into `call-registry.mjs`. Preserve legacy-entry and
traced-call behavior so both consumers share one interpretation.

- [ ] **Step 2: Write failing status tests**

Cover one caller with multiple callees, legacy entries, malformed files, and an empty
registry. Assert exact caller/callee IDs and host handles; malformed entries must not hide
valid ones.

- [ ] **Step 3: Implement the read-only skill**

Run the shared reader and print compact records without starting Switchboard, opening a
browser, changing registry files, or interpreting transcript content. Mirror
`disable-model-invocation: true` in `agents/openai.yaml`.

- [ ] **Step 4: Verify**

```bash
bash plugins/hotline/tests/call-status_test.sh
bash plugins/hotline/tests/switchboard_test.sh
```

Invoke `validate-dual-harness-skill` for `plugins/hotline/skills/call-status`.

- [ ] **Step 5: Commit**

```bash
git add plugins/hotline/skills/call-status plugins/hotline/scripts/call-registry.mjs plugins/hotline/skills/switchboard/scripts/server.js plugins/hotline/README.md plugins/hotline/tests/call-status_test.sh plugins/hotline/tests/switchboard_test.sh
git commit -m "add read-only Hotline call status"
```

### Task 2: Add the Maestro Agent Inbox Skill

**Files:**
- Create: `plugins/maestro/skills/agent-inbox/SKILL.md`
- Create: `plugins/maestro/skills/agent-inbox/agents/openai.yaml`
- Modify: `plugins/maestro/README.md`
- Test: `plugins/maestro/tests/agent-inbox-skill_test.sh`

**Interfaces:**
- Consumes: Herdr agent status, cmux tree/sidebar/notifications, Hotline call status, and Session Tools catch-up digests.
- Produces: one human briefing with waiting, working, finished, optional coverage, and `Next for you:` sections.

- [ ] **Step 1: Write a failing skill-contract test**

Assert read-only behavior, reachability probes, confirmation before a partial run,
visible-name locators, Hotline child collapse, five-summary limit, digest bounds, and the
absence of user-facing configuration flags.

- [ ] **Step 2: Implement preflight and inventory**

Probe `cmux tree --all --json --id-format both` and `herdr agent list`. Ask before
continuing if either fails. Otherwise collect native state and visible hierarchy names.
Do not read terminal screens by default.

- [ ] **Step 3: Correlate Hotline calls**

Invoke `hotline:call-status`, match exact session IDs or recorded host handles, and nest
known callees beneath callers. Never merge on similar cwd or title; keep IDs out of prose.

- [ ] **Step 4: Summarize unclear workstreams**

Use Session Tools only when native status and recent output are insufficient. Limit each
digest to eight turns and 8,000 characters, delegate to a cheaper model when available,
and stop after five summaries.

- [ ] **Step 5: Render the briefing**

Omit empty sections. Use Herdr `<agent> in <tab>, <workspace>` and cmux `<surface title>
in <workspace>`. Add a window anchor only when necessary. End with one `Next for you:`.

- [ ] **Step 6: Verify**

```bash
bash plugins/maestro/tests/agent-inbox-skill_test.sh
```

Invoke `validate-dual-harness-skill` for `plugins/maestro/skills/agent-inbox`. Perform one
read-only run with both providers reachable and one that confirms before partial coverage.

- [ ] **Step 7: Commit**

```bash
git add plugins/maestro/skills/agent-inbox plugins/maestro/README.md plugins/maestro/tests/agent-inbox-skill_test.sh
git commit -m "add agent inbox briefing"
```

### Task 3: Version and Verify

**Files:**
- Modify: `plugins/hotline/.claude-plugin/plugin.json`
- Modify: `plugins/maestro/.claude-plugin/plugin.json`
- Modify: generated Codex catalog files

**Interfaces:**
- Consumes: the two completed skills.
- Produces: discoverable Claude and Codex skills.

- [ ] **Step 1: Run compounding preflight**

Confirm the shared Hotline reader prevents parser drift and docs describe only implemented
behavior.

- [ ] **Step 2: Bump once and regenerate catalogs**

Bump Hotline and Maestro once, then run `node scripts/gen-codex-catalog.mjs`.

- [ ] **Step 3: Run repository gates**

```bash
bash plugins/codex/tests/skill-paths_test.sh
node --test plugins/codex/tests/compatibility.test.mjs
bash tests/run-all.sh
```

Expected: zero failures and only the expected `codex: live-plugin` skip unless opted in.

- [ ] **Step 4: Commit and publish**

Stage only the two manifests and generated catalog files, commit with
`update agent inbox plugin catalogs`, then invoke `publish-release` and verify its merge,
push, and marketplace refresh results.
