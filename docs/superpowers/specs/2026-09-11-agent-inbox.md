# Agent Inbox Design

## Goal

Add `/maestro:agent-inbox` (Codex: `$maestro:agent-inbox`), a read-only morning briefing
that answers which agents are working, which are waiting on JT, and what finished while JT
was away. It should orient JT quickly, not build a general session-management system.

## Existing Functionality to Reuse

- **Herdr:** `herdr agent list/get/read` supplies lifecycle and recent output.
- **cmux:** tree, sidebar state, and notifications supply visible locations and metadata.
- **Session Tools:** the session list finds transcripts and `sessions-catch-up` supplies
  bounded, read-only transcript briefings.
- **Hotline:** its registry maps caller sessions to callee sessions and host handles.
- **Maestro:** owns the orchestration viewpoint and final `Next for you:` action.

Handoff and Fable need no integration. Handoff is a transfer artifact, not live state;
Fable is an operating stance, not a data source.

## Workflow

### 1. Check reachability

Probe cmux and Herdr with read-only commands. The inbox may run inside or outside either
host when the CLI can reach it. If one is unreachable, ask whether JT wants a partial
briefing or wants to resume somewhere both are reachable. If both are unreachable, ask
before producing a transcript-only briefing.

No operation may focus a pane, mark an agent seen, clear a notification, resume a session,
or send input.

### 2. Inventory live agents

Read Herdr's agent list and cmux's tree/sidebar status. Prefer native lifecycle state. Do
not read every terminal screen; read recent output only when status cannot be explained.

Every item uses a locator JT can see:

- Herdr: `<agent name>` in `<tab name>`, `<workspace name>`.
- cmux: `<surface title>` in `<workspace title>`; add a window anchor only when needed.

UUIDs and pane IDs are internal lookup keys. If no visible name exists, say the agent is
unnamed and include only the smallest ID needed to find it.

### 3. Collapse Hotline callees

Read Hotline's caller/callee registry. A known callee appears beneath its caller, never as
a second top-level workstream. Show the child only when it explains a blocker or conflicts
with the caller's apparent state.

The one justified addition outside Maestro is a pared-down `hotline:call-status` skill. It
exposes the existing registry read-only and shares Hotline's registry reader with
Switchboard so Maestro does not learn the private schema.

### 4. Catch up only where needed

Use Session Tools only when native status and recent output do not explain a workstream.
Give a cheaper/faster agent the bounded digest when the harness supports choosing one. The
main agent never reads full transcripts.

Summarize no more than five unclear workstreams, using the last eight turns and an
8,000-character ceiling. These are internal safeguards, not user options. List any
remainder by visible location without semantic summary.

### 5. Brief JT

Use only sections with content:

```text
## Agent inbox

Waiting on you
- <visible agent locator> — <what it needs>

Working
- <visible agent locator> — <current task>

Finished while you were away
- <visible agent locator> — <outcome and verification caveat>

Coverage
- <only when cmux or Herdr was unavailable>

Next for you: <one concrete action and visible locator>.
```

## V1 Boundary

V1 covers agents cmux or Herdr can currently enumerate, plus Claude transcripts Session
Tools can correlate to them. It does not promise every historical session, headless
process, AgentMail thread, CI job, independent Codex/Pi transcript, or handoff. Consider
those later only after the daily workflow proves a real omission.

## Acceptance Criteria

- Implementation is one Maestro skill and one small Hotline status skill.
- Host inventories are read-only and may be reached from outside their hosts.
- An unreachable host causes confirmation before partial coverage.
- Hotline callees do not appear as duplicate top-level agents.
- Normal output uses visible names rather than arbitrary IDs.
- Full transcripts are never read by the main agent.
- At most five unclear workstreams receive bounded semantic summaries.
- The briefing ends with one concrete `Next for you:` action.
