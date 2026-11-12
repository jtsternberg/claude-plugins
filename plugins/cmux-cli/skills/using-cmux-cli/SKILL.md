---
name: using-cmux-cli
description: "Drives cmux (macOS terminal multiplexer) via the `cmux` CLI — windows, workspaces, panes, tabs, sending keystrokes and reading terminal output, the cmux event stream for waiting on and verifying work, embedded browser, notifications, sidebar progress, layouts."
when_to_use: "Use when the user mentions cmux, workspaces, panes, surfaces, tabs, or splits; asks to send keystrokes to or read output from a terminal; wants to wait for a build or another agent's turn to finish, or to confirm a message actually landed; wants to drive cmux's embedded browser; wants to post a notification or sidebar progress into a workspace; or runs tmux-style commands (capture-pane, wait-for, swap-pane) where cmux is the multiplexer in play."
argument-hint: "[surface id/title, or describe what you want to do]"
allowed-tools:
  - "Bash(cmux *)"
  - "Bash(which cmux)"
  - "Bash(*/scripts/*)"
  - "Bash(jq *)"
---

# cmux CLI

Drive cmux specifically: windows, workspaces, panes, surfaces, terminal I/O, events,
notifications, sidebar progress, layouts, SSH, and the embedded browser. The CLI
connects to the running app over a Unix socket.

## Establish context and consult live help

Run `cmux --help` for the command index and `cmux <cmd> --help` before constructing a real invocation. Use `cmux guide`
(alias `cmux --skill`) for installed-build guidance and `cmux cloud guide` for
cloud machines and detached cloud agents. Prefer canonical `cmux workspace <verb>`
and `cmux surface <verb>` forms; there are no `window`, `pane`, or `tab` nouns.

Claude Code resolves the following context at load time. Under Codex, run these
commands explicitly; dynamic context and `allowed-tools` grants are Claude-only.

```!
cmux identify --json --id-format both 2>/dev/null || echo '{"error":"cmux identify failed — read command-reference.md Troubleshooting"}'
```

```!
cmux ping
```

Silent `ping` success means the app is reachable. On failure, read Troubleshooting
in the command reference below. Outside cmux, discover targets with
`cmux tree --all --json --id-format both` and pass explicit handles.

`identify.caller` is the agent's location; `focused` is where the user is looking
and can be different or null. Never substitute focused context for an unresolved
caller. Request `--id-format both` (or `uuids`) on `identify` and `tree`: default
refs omit UUID fields. Inherited `CMUX_*_ID` values are spawn-time snapshots;
confirm existing targets in the live tree. Fresh creations may precede tree
updates: use their validated creation-response UUIDs.

Run `cmux capabilities` before depending on gated features such as `events.v1`
or `terminal.render_grid.screen_anchor.v1`; use the documented ungated fallback
when the token is absent.

## Read the matching reference before acting

Codex: substitute the directory containing this `SKILL.md` for the skill-directory
prefix in the paths below. Read only the references needed for the task.

| Task / read trigger | Required reference |
|---|---|
| Resolve a named tab, read another surface, pass handles, close/move/swap or act on several targets | `${CLAUDE_SKILL_DIR}/references/targeting.md` |
| Open/start/SSH/run in a terminal, create browser surfaces, choose caller/focused placement, mark or focus an existing target | `${CLAUDE_SKILL_DIR}/references/opening-surfaces.md` |
| Send text/keys, interpret a REPL/input box, diagnose delivery, read styled grids | `${CLAUDE_SKILL_DIR}/references/terminal-io.md` |
| Wait, poll, readiness-loop design, confirm submission or agent completion | `${CLAUDE_SKILL_DIR}/references/events.md` |
| Embedded browser navigation, clicks, snapshots, screenshots, cookies, eval | `${CLAUDE_SKILL_DIR}/references/browser.md` |
| SSH workspace, relay, drag-drop, remote agents/browser, reconnect | `${CLAUDE_SKILL_DIR}/references/ssh.md` |
| Split orientation, divider ratio, nesting, save/reproduce layout | `${CLAUDE_SKILL_DIR}/references/layouts.md` |
| Ongoing sidebar progress loops | `${CLAUDE_SKILL_DIR}/references/progress-loops.md` |
| Command inventory, canonical forms, environment, sidebar/status, natural-language mappings, errors | `${CLAUDE_SKILL_DIR}/references/command-reference.md` |

The references retain full procedures, examples, and failure evidence. The rules
below apply even when a task doesn't need the full procedure.

## Target safely

- **Act by UUID**, never by saved positional refs (`surface:N`, `pane:N`, indexes).
  Snapshot target and container UUIDs together. Pin `--workspace` and, where
  required, `--window` even when passing a surface or pane UUID.
- **Reject empty, `null`, unresolved, and unintended self handles.** cmux can
  silently substitute the caller for an empty CLI target, or the focused surface
  for malformed RPC parameters. Check helper exit status before parsing JSON;
  refuse to send when identity is missing. Use snake_case RPC parameters and
  verify echoed `result.surface_id`; `ok:true` alone proves nothing.
- **For destructive or bulk operations**, confirm your own live surface/pane UUID,
  collect all target UUIDs in one tree snapshot, exclude yourself, then mutate.
  If your own location cannot be confirmed, resolve targets individually instead
  of running the bulk operation. Verify UUID absence/presence afterward; echoed
  positional refs may already have renumbered.
- A **bare surface identifier or tab title is a read request**: resolve, read,
  report title + workspace + screen summary. Ask only if it cannot be resolved.
  Use `find-surface.sh "<verbatim title>" --json`: title-first, content fallback.
  Use `-w` for workspace scope, `-c` for screen content, `-t` for title-only.

## Default principle: make new work visible to the user

For ambiguous "open/start/SSH/run in a new terminal" requests, open beside the
agent in the current window. Use the helper: one pane means split right;
multiple panes means add a tab in the adjacent pane. Use `--focused` only when
the user means next to the tab they are looking at. Mixed split geometry needs
`layout`; flat `tree` pane ordering cannot prove visual adjacency.

Read the opening-surfaces reference before creation. The guarded shell recipe is:

Codex: substitute the directory containing this `SKILL.md` in the assignment below.

```bash
SKILL_DIR="${CLAUDE_SKILL_DIR}"
OUT=$("$SKILL_DIR/scripts/open-side-surface.sh" \
  --wait-ready --title "dev server :3000" --json) || {
  echo "side surface refused — inspect stderr and any orphan before continuing" >&2
  exit 2
}
SID=$(jq -er '.surface_id | strings | select(length > 0 and . != "null")' <<<"$OUT") || exit 2
WS=$(jq -er '.workspace_id | strings | select(length > 0 and . != "null")' <<<"$OUT") || exit 2
cmux send --workspace "$WS" --surface "$SID" "npm run dev\n"
cmux read-screen --workspace "$WS" --surface "$SID" --scrollback --lines 20
cmux tree --workspace "$WS"    # verify placement and title before reporting
```

Create without stealing focus (`--focus false`). The first send attaches the PTY;
`--wait-ready` clears the shell line with raw Ctrl-U, probes execution, and waits
for typed + executed marker hits. Never attach with `focus-pane`. A readiness
failure is a refusal, not permission to send anyway. Helper exits: 1 cmux error,
2 context error, 3 readiness timeout, 4 unavailable/mismatched creation identity.
Inspect diagnostics for an orphan; never close an untrusted target. Caller/session
recovery and readiness/cleanup budgets are in the opening reference.

### Name it, then report it by name (required)

**Give it a meaningful human-visible title** for every new surface, pane, or
workspace: 2–5 words describing the activity, not `zsh`, `test`, or `workspace`.
Pass `--title "<purpose>"` to the helper; use `--name` for a new workspace.
Check `title_status` and the live tree, and repair a failed rename.

**Report the title plus its workspace — never a bare positional ref.**
"Opened surface:258" gives the user nothing searchable. Include a window anchor
when several windows exist. Fix generic/duplicate names on things you created;
for existing workspaces, give a concrete visible position instead of renaming
someone else's workspace.

Use separate workspaces/windows only when explicitly requested. Plain SSH in a
visible split is the default; `cmux ssh` is appropriate for requested workspace
integration (relay, remote agents/browser, drag-drop). Tell the user it opens
behind a workspace tab and how to reach the named surface.

When pointing the user at an existing target, read the marking procedure: preserve
its prior color, use the `cue_pointer` pill and flash, then restore/clear when acted
on or before marking another target. Keep existing titles. Move focus only when
asked; scoped `focus-panel` selects the actual tab, while `focus-pane` may not.

## Read, send, and verify

Read terminal-io before sending, and events before waiting or judging submission.

- **Decision reads use `--scrollback --lines N`**, with explicit target workspace
  and surface UUIDs. Bare `read-screen` follows the user's scroll. `Jump to bottom`
  means stale view: re-read the live tail, never resend on that evidence.
- Treat prompt text cautiously: autosuggestions look like user input in plain
  text. Queued messages also render in the input box; `Press up to edit queued
  messages` indicates queued delivery. A missing transcript user record can be a
  `queued_command` attachment, not a failed send.
- **Shell:** append `\n` to execute. Verify output/execution on the live tail.
  **TUI/Ink REPL:** paste text, allow ingestion to settle, then issue a separate
  `send-key Enter`. Verify submission, not just arrival in the box.
- Delivery can suffer **sporadic fragmentation and silent byte loss, not
  size-gated**. Snapshot the event cursor before sending; match the intended
  surface/session, submission count and length. `message_length` is full length
  on cmux 0.65.0+; earlier builds cap it at 240. Use a nonce/transcript fallback
  where needed; neither exit 0 nor a marker still inside the input box proves
  submission. Reconcile queued/busy state before retrying.
- `send-key C-c` works for shells but fails inside Claude's REPL. Raw Ctrl-C can
  interrupt an active tool or restore old prompt text. An empty box needs no clear;
  queue into a busy REPL without interrupting. Clear parked text only when provably
  idle, then re-read and require an empty box. Read the full procedure first.
- Structured reads use gated `terminal.replay` with `anchor:"screen"`, snake_case
  parameters and echoed-target verification. `scrolled_rows` is always zero;
  `terminal.viewport` is a **setter**, not a read probe.

#### Gotcha: a trailing `\n` does not submit into a TUI/Ink REPL

Bracketed paste treats the newline as a literal line break. A separate
`send-key Enter` submits it. Read the full mechanism and recovery in
`${CLAUDE_SKILL_DIR}/references/terminal-io.md` before sending into a REPL.

#### Gotcha: cmux rewrites a literal backslash-n in your payload

`send` rewrites literal `\n`/`\r`/`\t` sequences; there is no backslash escape.
Split the payload after the relevant backslashes as detailed in
`${CLAUDE_SKILL_DIR}/references/terminal-io.md`; doubling slashes does not help.

## Wait and report state

Prefer retained, replayable **`cmux events`** over read-screen/pgrep polls or
scheduled wake-ups. `workspace.prompt.submitted` answers submission;
`agent.hook.Stop`/`SubagentStop`/`SessionEnd` answer agent boundaries (check
`payload.phase == "completed"`); `surface.created` proves existence, not PTY
readiness. Read events.md for exact filters, scoping, replay and fallback rules.
Streaming scripts use `--no-ack --no-heartbeat` and keep timeout stderr out of
JSON; snapshot acknowledgments are different and must remain enabled.

Use `notify` for one-shot events; sidebar status/progress/log for ongoing state.
Use distinct status keys, update progress while work runs, and clear owned state
on completion before notifying. Check events before designing a progress poll.

Use `browser snapshot` for machine inspection and screenshots for human images.
Use `new-pane --type browser`, not terminal-only `new-split`. Use `layout` for
geometry, `diff --last-turn` to show changes since this surface's agent-turn
baseline, `markdown open` for a live document panel, `top`/`memory` first for cmux
resource diagnosis, and `vault search` for indexed session history. Full command
vocabulary is in command-reference.md and the installed help.

**The cmux sidebar todo checklist belongs to the user.** Reading is fine;
add/edit/check/remove/replace items only on an explicit request. Keep agent plans
in the agent's own task tracker.

After every mutation, inspect output and verify the resulting state: tree for
creation/title/action, live-tail output for shell execution, events for REPL
submission. Report verified human-visible names and any unresolved failure.
