# `cmux events` — the event stream (wait and verify without polling)

`cmux events` streams newline-delimited JSON for everything happening inside
cmux: surfaces opening and closing, prompts being submitted, agent turns
starting and ending, notifications, sidebar writes. The buffer is **retained and
replayable**, so it answers questions about the past as well as the future.

Reach for it before any `read-screen` loop, any `pgrep` poll, and any
`ScheduleWakeup` heartbeat. One blocking call with `--timeout` replaces all
three, and unlike screen scraping it reports **facts about what cmux did**
rather than inferences from what a TUI happened to be drawing.

```
cmux events [--after <seq>] [--cursor-file <path>] [--name <event>]
            [--category <category>] [--reconnect] [--limit <n>]
            [--timeout <seconds>] [--snapshot] [--no-ack] [--no-heartbeat]
```

## The invocation contract

Verified on cmux 0.64.25:

| Behavior | Detail |
|---|---|
| Exit code | `0` when a matching frame arrived, `1` on `--timeout` expiry. |
| Timeout message | `Error: Timed out waiting for a matching event` on **stderr**. |
| Ack frame | Printed to **stdout** first (`"type":"ack"`) unless `--no-ack`. It has no `.name`, so it breaks a naive `jq` filter. |
| Heartbeats | Every 15s unless `--no-heartbeat`. |
| `--name` / `--category` | Filtered **server-side**, repeatable. |
| `--after <seq>` | Replays retained frames after that seq. `--after 0` replays everything retained. |
| `--cursor-file <path>` | Reads the start seq from the file, then writes the last seen seq back to it after each frame. |
| `--snapshot` | Prints the subscription ack and exits — use it to read `oldest_seq` / `latest_seq`. **Never combine with `--no-ack`**: the ack is the entire output, so the pair yields nothing and exits 0. |

**Scripted FRAME READS are always `--no-ack --no-heartbeat` with stderr kept out
of the pipe**, or `jq` chokes on the ack frame and on the timeout line.
**`--snapshot` is the exception**: it prints the ack and nothing else, so adding
`--no-ack` suppresses the only line it emits and returns empty output with exit
0 — a silent nothing, not an error.

```bash
cmux events --name surface.created --limit 1 --timeout 30 \
            --no-ack --no-heartbeat 2>/dev/null | jq -c .
```

## The catalog

**A replay window does not reach the newest frames, so never use one to ask "did
X just happen".** `--after <seq> --limit <n>` returns frames from that seq
forward and stops well short of `latest_seq`: three consecutive queries
(`--after 0`, `--after 17000`, `--after latest-1200`) all reported no trace of a
session that a 25-second LIVE watch then showed emitting on every turn. Windowed
absence is not even evidence of recent absence. To ask about the present, watch
the live stream or resume from `--cursor-file`; use `--after` only to read a
range you have already bounded.

Harvested live from replays on cmux 0.64.25. **The retained buffer is a rolling window**, so no single replay contains every name — `surface.input_sent` and `agent.hook.Notification` appear in one replay and are gone from the next taken minutes later. Treat a name's absence from a replay as "nothing did that recently", never as "this event does not exist". cmux may also add names; re-harvest with
`cmux events --after 0 --no-ack --no-heartbeat --limit 900 --timeout 10 2>/dev/null | jq -r '[.category,.name]|@tsv' | sort -u`.

| category | names |
|---|---|
| `agent` | `agent.hook.SessionStart`, `agent.hook.UserPromptSubmit`, `agent.hook.PreToolUse`, `agent.hook.PostToolUse`, `agent.hook.Stop`, `agent.hook.SubagentStop`, `agent.hook.SessionEnd`, `agent.hook.Notification`, `agent.notification.decision`, `agent.journal.unattributed` |
| `surface` | `surface.created`, `surface.selected`, `surface.focused`, `surface.closed`, `surface.moved`, `surface.input_sent`, `surface.key_sent` |
| `workspace` | `workspace.created`, `workspace.selected`, `workspace.closed`, `workspace.reordered`, `workspace.prompt.submitted` |
| `pane` | `pane.created`, `pane.focused` |
| `window` | `window.created`, `window.keyed`, `window.unkeyed` |
| `notification` | `notification.created`, `notification.read`, `notification.cleared`, `notification.clear_requested`, `notification.removed` |
| `feed` | `feed.item.received`, `feed.item.completed` |
| `sidebar` | `sidebar.metadata.updated` |

### Observed, shape not yet captured

<!-- tripwire: claude-plugins-6r0d — capture a real frame for each of these, then move them into the table above and delete this section. Do not guess a shape. -->

`agent.hook.AskUserQuestion` and `surface.action` are real — the catalog guard saw
both on cmux 0.64.25 — and their payloads are **not** documented here, because the
rolling buffer had dropped them before either could be read. They are listed so the
catalog is honest about the event surface, not because anything is known about their
contents. Do not guess a shape for them; capture one the next time either appears:

```bash
cmux events --name agent.hook.AskUserQuestion --name surface.action \
            --after 0 --no-ack --no-heartbeat --limit 900 --timeout 10 2>/dev/null | jq
```

`agent.hook.AskUserQuestion` is presumably the hook pair for Claude Code's
question tool, and so presumably carries the same `phase` double-fire and
`session_id` / `cwd` fields as every other `agent.hook.*` — presumably, which is
exactly why it is in this section and not in the table above.

## Frame shape and how to target one surface

Every frame carries `seq`, `occurred_at`, `category`, `name`, `source`, and
**top-level** `surface_id` / `workspace_id` / `pane_id` / `window_id` — always
UUIDs, never refs. Filter on those, not on anything inside `payload`.

```json
{"name":"surface.created","seq":5,"category":"surface",
 "occurred_at":"2026-09-21T16:38:12.256Z",
 "surface_id":"F41D2405-…","pane_id":"31266DD3-…","workspace_id":"DDDF12C7-…",
 "payload":{"kind":"terminal","origin":"workspace_initial","focused":true,
            "surface_id":"F41D2405-…","pane_id":"31266DD3-…"}}
```

Three traps, all verified:

- **`agent.hook.*` fires twice per occurrence** — once with
  `payload.phase == "received"`, once with `"completed"`. Deduplicate with
  `select(.payload.phase == "completed")` or you will count every turn twice.
- **`surface_id` is `null` on a large share of `agent.hook.*` frames**, not an
  occasional few — in one 900-frame replay, on most `agent.hook.Stop`s. So a
  `select(.surface_id == $s)` filter drops the majority of them, and "fall back
  to matching null too" over-corrects: it makes *any* session's frame match, which
  answers "something happened" and never "my agent did". Discriminate on
  `payload.cwd` or `payload.session_id` instead — real frames carry both.
- **Sensitive text is redacted.** Frames list what was withheld in
  `payload.redacted_fields`, and hand you a length and a preview instead — which
  is exactly what the verification recipes below need.

## Recipe: did my message actually submit?

`workspace.prompt.submitted` fires when a prompt is submitted into an agent REPL
and carries a `message_preview` capped at 240 characters, plus a
`message_length` that is **the length of that preview, not of the message**:

```json
{"name":"workspace.prompt.submitted","seq":647,
 "payload":{"message":null,"message_length":43,
            "message_preview":"> I'd say yes, but as a second pass\nagreed.",
            "redacted_fields":["message"],"workspace_id":"4C7FA894-…"}}
```

<!-- tripwire: claude-plugins-8ur4 — cmux#13687; if that is fixed, this cap and the at-least-240 reading go away. -->

**`message_length` IS CAPPED AT 240 AND CANNOT VERIFY A LONGER PAYLOAD.** It
equals the preview's own length in every frame, and no frame reports more than
240. Measured on cmux 0.64.25 over a 900-frame replay: 21 submissions, all 21
with `message_length == (message_preview | length)`, 14 of them at exactly 240,
none above it, and those 14 were 6 distinct messages whose previews end
mid-token. A shorter value is exact; 240 means "240 or more".

An earlier reading of this field as character-exact came from checking it against
two plaintexts of 119 and 43 characters — both under the cap, so both agreed.

What that leaves:

- **Fragmentation is measurable** → several `workspace.prompt.submitted` frames
  for one send, and a count needs no length at all.
- **Silent byte loss is measurable only under 240 characters.** For anything
  longer, a whole payload and a truncated one both report 240, so use a nonce or
  a transcript read instead.

```bash
MSG="…"; LEN=${#MSG}
# NO --no-ack here: --snapshot prints only the ack, so the pair returns nothing.
SEQ=$(cmux events --snapshot --no-heartbeat 2>/dev/null | jq -r '.resume.latest_seq')

cmux send     --workspace "$WS" --surface "$SID" "$MSG"
sleep 0.2
cmux send-key --workspace "$WS" --surface "$SID" Enter

# Every submission since the send, for that workspace. `verdict` is deliberately
# three-valued: an equality test would call every payload over 240 chars short.
cmux events --after "$SEQ" --name workspace.prompt.submitted \
            --limit 5 --timeout 15 --no-ack --no-heartbeat 2>/dev/null \
  | jq -c --arg ws "$WS" --argjson len "$LEN" \
      'select(.workspace_id==$ws)
       | {seq, got:.payload.message_length, want:$len,
          verdict: (if .payload.message_length >= 240 then "capped-unknown"
                    elif .payload.message_length == $len then "exact"
                    else "short" end)}'
```

Count the lines this prints: more than one is fragmentation regardless of any
length. `capped-unknown` on a long payload is the expected answer, not a
failure — verify those with a nonce.

No frame within the timeout means **nothing submitted** — the text is sitting in
the input box, and `send-key Enter` is the fix (never a re-`send`, which appends).
One frame is a clean submit; several are fragmentation. Treat a length of 240 as
"unknown, at least 240" and fall back to the nonce-and-verify discipline in
SKILL.md, which is what actually covers a long payload.

`agent.hook.UserPromptSubmit` corroborates per-surface with `session_id`,
`surface_id` and `cwd`, but **do not length-check against it** — its
`tool_input_length` is useless for length in BOTH directions: it counts claude's
wrapping on a short input (56 where `message_length` was 43) and it is bounded on a
long one. Measured over 26 frames on 0.64.25 it never exceeded 270, and an
**18,635-byte** payload delivered whole reported **253** — so it is not the
uncapped alternative to `message_length` it looks like. Count FRAMES with it (it is
the only submit event carrying `session_id` and `surface_id`, so it is the only one
that can say whose submit it was) and leave byte-verification to a nonce in the
callee's transcript.

## Recipe: did my `send` reach the surface I meant?

`surface.input_sent` fires on **every** `cmux send` — shell targets included, not
just agent REPLs — and it is the only event that reports **which surface cmux
actually resolved**:

```json
{"name":"surface.input_sent","seq":1195,"source":"socket.v2",
 "surface_id":"395ECEAE-…","workspace_id":"4C7FA894-…",
 "payload":{"method":"surface.send_text",
            "params":{"text":null,"text_length":25,"redacted_fields":["text"],
                      "workspace_id":"4C7FA894-…"},
            "result":{"queued":false,
                      "surface_id":"395ECEAE-…","surface_ref":"surface:20",
                      "workspace_id":"4C7FA894-…","window_id":"AD03B5BA-…"}}}
```

Two fields earn their keep:

- **`params.text_length`** — the exact byte count cmux delivered (25 for
  `"echo events-probe-marker\n"`). Compare against what you sent to catch
  truncation at the transport, one layer below the REPL.
- **`result.surface_id`** — the surface cmux resolved your handle to. Compare it
  against the surface you *intended*, because a handle that fails to resolve
  does not error; it falls back to the caller (see the trap below).

`result.queued` tells you whether the input was queued rather than delivered
straight through.

**`surface.key_sent` is the same frame for `cmux send-key`**, which matters because
submitting into a TUI/Ink REPL takes two calls — the text, then a separate Enter —
and each half now has its own event:

```json
{"name":"surface.key_sent","source":"socket.v2","surface_id":"A382E9F4-…",
 "payload":{"method":"surface.send_key",
            "params":{"key":"Enter","surface_id":"surface:49"},
            "result":{"queued":false,"surface_id":"A382E9F4-…",
                      "surface_ref":"surface:49","workspace_id":"8CFA1F37-…"}}}
```

Two details it adds over `surface.input_sent`:

- **`params.key` is not redacted** — the key name arrives verbatim, so you can tell
  an `Enter` from an `Escape` or a `C-c` after the fact.
- **`params.surface_id` is the handle you PASSED; `result.surface_id` is what cmux
  RESOLVED it to.** Here a positional `surface:49` went in and a UUID came back.
  Seeing both sides is the sharpest form of the target check below: a substituted
  target shows up as the two disagreeing.

So a full submit into a REPL leaves three frames — `surface.input_sent` for the text,
`surface.key_sent` for the Enter, then `workspace.prompt.submitted` when the REPL
actually accepts it. Missing the third with the first two present is precisely the
"delivered but never submitted" case.

### `surface.moved` is how a positional ref stops meaning what it meant

A surface moving between panes is what renumbers the `surface:N` / `pane:N` slots
every other snapshot was read against, so this frame is the observable behind
"refs renumber between the snapshot and the call". It carries the same two-sided
shape as the send frames — `params` is what the caller passed, `result` is what
cmux resolved:

```json
{"name":"surface.moved","seq":18364,"source":"socket.v2",
 "surface_id":"4089FEEB-…","pane_id":"7FDF0314-…","workspace_id":"F6D3065C-…",
 "payload":{"method":"surface.move",
            "params":{"index":0,"pane_id":"pane:26","surface_id":"surface:61",
                      "workspace_id":"workspace:12"},
            "result":{"pane_id":"7FDF0314-…","pane_ref":"pane:26",
                      "surface_id":"4089FEEB-…","surface_ref":"surface:61",
                      "window_id":"AD03B5BA-…","window_ref":"window:2",
                      "workspace_id":"F6D3065C-…","workspace_ref":"workspace:12"}}}
```

The surface's `pane_id` and `workspace_id` are what change, so a handle cached as
`surface:61` may now sit in a different pane and workspace — which matters because
`cmux` scopes pane and surface calls *inside* a workspace context. Re-resolve a
cached ref against a fresh tree after one of these, and prefer the UUID, which a
move does not change.

### Trap: an empty or unresolved handle silently targets *you*

`cmux send --surface "" …` does not fail. The empty value falls through to
`$CMUX_SURFACE_ID`, so the payload is delivered to **the caller's own surface**.
When the caller is an agent running inside a Claude Code REPL, that means the
text lands in the **user's input box**.

This is not hypothetical — it happened while writing this reference. A helper
script exited non-zero with empty stdout, `SID=$(jq -r '.surface_id' <<<"$OUT")`
produced an empty string, and the next `cmux send --surface "$SID"` typed the
probe command into the user's prompt. `send` exited 0. The only evidence was a
`surface.input_sent` frame whose `result.surface_id` was the caller's.

So: **validate the handle before sending, and confirm the target afterward.**

```bash
[[ -n "$SID" && "$SID" != "null" ]] || { echo "no surface handle — refusing to send" >&2; exit 2; }
[[ "$SID" != "$MY_SURFACE_ID" ]]    || { echo "handle resolved to my own surface" >&2; exit 2; }

SEQ=$(cmux events --snapshot 2>/dev/null | jq -r '.resume.latest_seq')
cmux send --workspace "$WS" --surface "$SID" "$MSG"
cmux events --after "$SEQ" --name surface.input_sent --limit 3 --timeout 5 \
            --no-ack --no-heartbeat 2>/dev/null \
  | jq -e --arg s "$SID" 'select(.payload.result.surface_id==$s)' >/dev/null \
  || echo "WARNING: send did not land on $SID" >&2
```

`jq -r` printing `null` for a missing key is the other half of this trap — quote
the guard against the literal string `null`, not just against empty.

## Recipe: wait for another agent to finish its turn

One blocking call, zero wake-ups, no model tokens burned while waiting:

```bash
cmux events --category agent --name agent.hook.Stop \
            --timeout 600 --no-ack --no-heartbeat 2>/dev/null \
  | jq -c --arg s "$SURF_ID" \
      'select(.payload.phase=="completed" and .surface_id==$s)' \
  | head -1
```

`agent.hook.SubagentStop` is the same signal for a subagent; `agent.hook.SessionEnd`
fires when the session itself exits. Note `--limit` counts **frames**, not
matches, so when a `jq` filter does the narrowing, bound the wait with
`--timeout` and terminate on the first match with `head -1` rather than
trusting `--limit 1`.

`agent.hook.SessionStart` is the counterpart for "has the agent come up yet?" —
its payload carries `session_id`, `surface_id` and `cwd`, which is also how you
map a live claude session id onto the cmux surface showing it.

**`payload.session_id` is not a bare uuid.** It is a composite feed id,
`cmux-feed-v1:<base64 agent name>:<base64 session uuid>` — e.g.
`cmux-feed-v1:Y2xhdWRl:ZDFkNzIyYjkt…` for claude session
`d1d722b9-d8c1-42ef-987e-468ce2662c73`. So an equality test against a uuid never
matches, and passing the raw value on hands your caller something no transcript
path or registry can use. A uuid is 36 bytes, so its base64 is padding-free and
a `contains()` test is exact; decode the last `:` segment to recover it.

**`surface_id` is null on a large share of real `agent.hook.*` frames** — in the
same replay, on many `agent.hook.Stop`s. A surface filter with a null fallback
therefore matches *any* session's turn end, which answers "something finished"
but never "the agent I care about finished". Discriminate on `payload.cwd` or
`payload.session_id`, both of which real frames do carry.

## Recipe: wait for a surface to exist

```bash
cmux events --name surface.created --timeout 30 --no-ack --no-heartbeat 2>/dev/null \
  | jq -c --arg p "$PANE_ID" 'select(.pane_id==$p)' | head -1
```

This tells you the surface **exists**. It does not tell you its PTY is attached —
a `cmux send` is still what attaches the PTY, so the readiness probe in SKILL.md
(and `open-side-surface.sh --wait-ready`) is still required before a read.

## Recipe: a durable cursor across calls

`--cursor-file` makes a watcher resumable without tracking seq yourself: it seeds
the start from the file and writes the last seen seq back after each frame.

```bash
cmux events --cursor-file ~/.cache/cmux/events.seq --reconnect \
            --category notification --no-ack --no-heartbeat
```

With `--reconnect` it reconnects forever and resumes from the last received seq,
which survives a cmux restart. Check `resume.gap` in the ack frame — `true` means
retention dropped frames between your cursor and the live stream, so the replay
is incomplete.
