# Agent Inbox Design

## Goal

Add `/maestro:agent-inbox` (Codex: `$maestro:agent-inbox`), a read-only morning briefing
that answers which agents are working, which are waiting on the user, and what finished
while the user was away. The result is a quick orientation to current agent work.

## Existing Functionality to Reuse

- **Graveyard, when installed:** `graveyard candidates --json` supplies a unified live
  cmux + Herdr inventory with session ID, agent kind, transport, busy/idle state,
  workspace title, tab title, cwd, and idle duration.
- **Herdr:** `herdr agent list/get/read` enriches Herdr rows with agent names and native
  lifecycle state.
- **cmux:** tree and sidebar state enrich rows whose Graveyard metadata is insufficient.
- **Session Tools:** the session list finds transcripts and `sessions-catch-up` supplies
  bounded, read-only transcript briefings.
- **Hotline:** its registry maps caller sessions to callee sessions and host handles.
- **Maestro:** owns the orchestration viewpoint and final `Next for you:` action.

## Workflow

### 1. Check reachability

Use `graveyard candidates --json` as the fast path when the command is installed. The
portable path probes cmux and Herdr directly with their existing skills. Either path may
run inside or outside the hosts. When only one transport is reachable, ask whether the
user wants that briefing or wants to resume where both are reachable. When neither
transport answers, offer a transcript-only briefing and wait for confirmation.

Use read-only discovery and inspection commands throughout, preserving pane focus, seen
state, notifications, and session input.

### 2. Inventory live agents

Start with Graveyard's unified candidate list when available; otherwise combine the Herdr
agent list with cmux tree/sidebar metadata. Enrich rows where another native read adds a
missing visible name or status. Read recent output only for a shortlisted unclear row.

Every item uses a locator the user can see:

- Herdr: `<agent name>` in `<tab name>`, `<workspace name>`.
- cmux: `<surface title>` in `<workspace title>`; add a window anchor only when needed.

UUIDs and pane IDs are internal lookup keys. If a visible name is unavailable, say the agent is
unnamed and include only the smallest ID needed to find it.

### 3. Collapse Hotline callees

Read Hotline's caller/callee registry. Nest each known callee beneath its caller. Show the
child when it explains a blocker or conflicts
with the caller's apparent state.

The one justified addition outside Maestro is a pared-down `hotline:call-status` skill. It
exposes the existing registry read-only and shares Hotline's registry reader with
Switchboard. Maestro consumes that owned interface.

### 4. Catch up only where needed

Use Session Tools for shortlisted workstreams whose native status and recent output leave
the task unclear. Give a cheaper/faster agent the bounded digest when the harness supports
choosing one. The main agent receives the resulting short summary.

Summarize up to five unclear workstreams, using the last eight turns and an 8,000-character
ceiling. These are fixed internal safeguards. List any remainder by visible location.

### 5. Brief the user

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

V1 covers live Claude and Codex sessions returned by Graveyard across cmux and Herdr,
enriched with native host status, Hotline relationships, and bounded Claude transcript
briefings from Session Tools.

## Acceptance Criteria

- Implementation is one Maestro skill and one small Hotline status skill.
- Graveyard supplies an optional unified fast path; existing cmux and Herdr skills supply
  the portable path.
- Host inventories are read-only and may be reached from outside their hosts.
- An unreachable host causes confirmation before partial coverage.
- Hotline callees appear beneath their caller.
- Normal output uses visible names rather than arbitrary IDs.
- The main agent receives bounded summaries rather than full transcripts.
- At most five unclear workstreams receive bounded semantic summaries.
- The briefing ends with one concrete `Next for you:` action.
