# Agent Inbox Design

## Problem

JT needs one quick, read-only briefing at the start of a day: which autonomous agent
workstreams are still active, which are waiting on JT, what finished overnight, and what
single action deserves attention first. The briefing must cover work hosted in Claude
sessions, Hotline calls, Herdr, and cmux without treating transport-created callees as
independent workstreams or rereading every transcript with an expensive model.

## Recommendation

Add `agent-inbox` to the `maestro` plugin. Maestro already owns the human-facing view of
delegated pipelines, while `session-tools`, Hotline, Herdr, and cmux remain the owners of
their own discovery and status semantics. The new skill is a federation layer: collect
compact provider records, correlate them, shortlist the records that need semantic
summary, delegate only those summaries to a cheaper model when the harness supports an
explicit model choice, and render one prioritized briefing.

Do not call the skill `morning-brief`: daily startup is the primary use case, but the same
operation is useful after lunch, after travel, or whenever JT asks “what is waiting on
me?”. The user-facing invocation should be `/maestro:agent-inbox` in Claude Code and
`$maestro:agent-inbox` in Codex.

## Existing Capability Audit

| System | Reuse | Gap |
|---|---|---|
| `session-tools` | Shared transcript parser, cached session index, tail-state inference, current bead resolution, bounded digest | `--list` is text-only and does not bulk-return compact tail state; Claude transcripts only |
| Hotline | Registry already maps caller session to callee session, target, mode, transport, host handle, and last contact | No small read-only “all calls as JSON” skill; Switchboard is HTML and too heavy for composition |
| Herdr | `agent list/get/read` expose authoritative lifecycle state plus agent, tab, and workspace names | The installed skill needs a narrow read-only outside-context inventory path |
| cmux | `tree --all --json`, sidebar state/status, notifications, stable UUIDs, surface and workspace titles | No normalized agent/session identity or lifecycle state; screen scraping is expensive and unreliable |
| Maestro | Correct owner for orchestration policy, “Next for you”, and zero-token waiting discipline | No durable global ledger or inbox command |
| handoff | Strong explicit transfer artifact for future work | No global handoff index; a handoff is not evidence that work is currently active |
| Fable mode | Supports delegating mechanical work to cheaper models while retaining judgment in the main model | A stance, not a status source; should influence execution but never appear as an inbox provider |

## Required Provider Interfaces

Every provider returns newline-delimited JSON records so collection remains shell-cheap
and one broken provider cannot invalidate the others.

```ts
type ProviderRecord = {
  provider: "session" | "hotline" | "herdr" | "cmux" | "handoff";
  provider_id: string;
  session_id?: string;
  parent_session_id?: string;
  cwd?: string;
  title?: string;
  host?: {
    kind: "herdr" | "cmux" | "headless";
    id?: string;
    agent_name?: string;
    surface_title?: string;
    tab_title?: string;
    workspace_title?: string;
    window_anchor?: string;
  };
  state: "working" | "waiting_on_user" | "done_unseen" | "idle" | "unknown" | "stale";
  state_source: "native" | "transcript" | "metadata" | "heuristic";
  updated_at?: string;
  summary_hint?: string;
  confidence: "high" | "medium" | "low";
};
```

Providers must distinguish `unknown` from `idle`, and every inferred result must carry a
lower confidence than native lifecycle state. Missing providers emit one diagnostic
record; they do not disappear silently. Verified read-only reachability is sufficient for
cmux and Herdr; the inbox session does not need to be hosted by that system.

## Provider-Reachability Preflight

The ideal launch point remains an agent session nested in both systems: a Herdr-managed
agent running inside a cmux surface. It is not required. Probe cmux with
`cmux tree --all --json --id-format both` and Herdr with `herdr agent list`. Native
context enriches locators but is not required when the provider answers its read-only
probe.

Before reading either host:

1. Both providers answer: continue with full coverage, inside or outside either host.
2. Exactly one answers: stop and ask whether JT wants a partial run or wants to resume
   where the missing provider is reachable. Do not collect beyond capability probes first.
3. Neither answers: stop and ask JT to resume where cmux and/or Herdr are reachable. A
   transcript-only run remains available after explicit confirmation.
4. `--provider cmux`, `--provider herdr`, or `--allow-partial` is prior consent for the
   named partial scope, so no second confirmation is needed.

The skill may explain how to resume, but it must not create, move, focus, resume, or prompt
an agent session on JT's behalf during preflight. Probes must not mark agents or tabs seen.

## Correlation Rules

1. A Hotline registry record makes `callee session_id` a child of
   `caller_session_id`. The child is not rendered as a top-level conversation.
2. Native host state wins for liveness; transcript tail state wins for conversational
   responsibility. For example, a Herdr agent may be `done_unseen` while its transcript
   says `waiting_on_user`.
3. Exact session IDs are the only high-confidence cross-provider join. Host UUID/name plus
   cwd is medium confidence. Title or cwd alone is never enough to silently merge records.
4. User-facing locators use human names, never arbitrary IDs: Herdr agent name + tab name
   + workspace name; cmux surface/tab title + workspace title, plus a visible window
   anchor when multiple windows make it necessary. Raw IDs remain internal join keys and
   appear only in `--json` or a low-confidence diagnostic.
5. A caller summary may include one compact child line such as “reviewer finished; answer
   not yet relayed” or “callee is blocked on approval”.
6. Independent Herdr/cmux agents remain top-level records. Hotline children are
   de-emphasized, not discarded: expand them only when they contain the blocker or their
   state conflicts with the caller.
7. Repeated runs are read-only and stateless in V1. “Done overnight” means activity after
   a user-supplied/default time boundary, not an unread flag invented by this skill.

## Token Budget

The collector and correlator use no model. They shortlist at most eight top-level
workstreams using this order: waiting on JT, working, done since the boundary, unknown,
then most recent. Clear metadata-only records are rendered without semantic summary.

Only shortlisted records whose compact hint is insufficient receive an LLM summary. Feed
each summarizer the existing bounded digest, capped at 8,000 characters and the last 8
turns. Batch records into one cheaper-agent request when possible; otherwise run at most
three cheap summaries concurrently. The main model receives provider records plus those
short summaries, never raw transcripts. `--deep` is explicitly out of scope for the
aggregate command; JT can invoke `sessions-catch-up --deep` on one selected session.

If the harness cannot select a cheaper model, summarize at most three ambiguous records
inline and leave the rest as metadata with a locator. Never launch a premium-model poll or
background recap loop.

## Invocation and Output

Defaults:

- Boundary: local 6:00 PM on the previous calendar day.
- Scope: full cmux + Herdr coverage; partial host coverage requires confirmation.
- Maximum: eight top-level workstreams.
- Read-only: no resume, prompt, focus, close, mark-seen, or notification clearing.

Optional flags: `--since <duration|timestamp>`, `--provider <name>`, `--allow-partial`,
`--max <1..20>`, `--no-summaries`, and `--json`.

Human output:

```text
## Agent inbox — Thu Sep 11, 8:10 AM

Needs you (2)
- [project / task] What it needs. Last meaningful state. Where to find it.

Working (3)
- [project / task] Current phase and latest verified activity.

Finished since yesterday (1)
- [project / task] Outcome and any verification caveat.

Uncertain / unavailable
- Herdr server was unreachable; Hotline-linked Herdr calls are still included from metadata.

Next for you: answer <the highest-priority concrete question> in <locator>.
```

Empty sections are omitted. The final action is singular. Provider failures are visible
but do not dominate the briefing.

## V1 Boundary

V1 supports Claude transcript workstreams, Hotline correlation, native Herdr state when
the Herdr server is reachable, and cmux metadata/status/notifications when the cmux socket
is reachable. Running inside both gives the best locators, but is not required. It does not claim complete
coverage of independent Codex, Pi, or other cmux-hosted agents until cmux or those agents
expose a stable session identity and lifecycle record.

Two pared-down provider additions are justified:

1. `session-tools:sessions-status` — a model-free bulk scanner returning compact JSONL;
   it reuses the shared parser and is independently useful for scripts.
2. `hotline:call-status` — a read-only compact registry view returning caller/callee
   relationships and transport handles; it reuses Hotline schema knowledge instead of
   making Maestro parse private registry files.

For cmux, add `cmux-cli:agent-status` only after a discovery spike proves a stable signal
for agent identity. Until then, `agent-inbox` directly composes documented cmux topology,
sidebar status, and notifications and labels unmatched surfaces as uncertain. Herdr needs
a separate, explicitly read-only inventory path that permits an outside caller when the
CLI can reach the server; control and mutation remain behind `HERDR_ENV=1`.

## Acceptance Criteria

- A typical run returns a first useful briefing without reading full transcripts.
- Hotline callees never appear as duplicate top-level workstreams when the caller mapping
  is present.
- “Waiting on JT” is traceable to native blocked state or transcript tail evidence.
- An unreachable cmux or Herdr provider pauses after capability probes unless partial
  coverage was explicitly requested; provider absence and low-confidence joins are explicit.
- Every rendered workstream has a plain-language locator; arbitrary IDs are hidden from
  normal prose.
- No operation writes to, resumes, focuses, or marks activity seen in an agent session.
- The default run has a hard cap of eight workstreams, three summary jobs, 8,000 input
  characters per summarized workstream, and one final prioritization pass.
- Tests cover correlation, precedence, caps, partial provider failure, and unsupported
  Herdr/cmux coverage.
