# The cmux Control Socket, As Hotline Uses It

Every cmux-routed dial goes over cmux's unix control socket, through
`${CLAUDE_PLUGIN_ROOT}/scripts/cmux-rpc.py` — never `cmux rpc`, which is argv-only
and would publish whole work orders to any local `ps` (claude-plugins-86ka). This
file is the RPC contract: three methods, one addressing rule, and one method that
looks like a probe and is not.

Codex: substitute the installed Hotline plugin directory for the leading path
segment above.

For the CLI-level version of the scroll story — which `read-screen` forms are
scroll-immune, and the `Jump to bottom` tell — invoke the
`/cmux-cli:using-cmux-cli` skill. This file covers only what the dial flow itself
speaks over the socket.

## The three methods

| Method | Where | What it is for |
|---|---|---|
| `system.capabilities` | `dial.sh` transport preflight | one call, before anything is opened, to decide cmux vs headless |
| `terminal.paste` | `cmux-paste.sh` — every delivery, first contact and follow-up alike | the payload, JSON-escaped in-process, plus a `submit_key` that actually submits |
| `terminal.replay` | `cmux-reuse-surface.sh`, `close-superseded-surface.sh` | the **styled** render grid, when text alone cannot answer the question |

`terminal.replay` is not a nicer `read-screen`. It exists in the dial flow for one
judgement text cannot make: Claude Code draws its ghost prompt, its queued-messages
hint and `Message @agent…` from a placeholder prop, and `read-screen` renders a
placeholder and a human's half-typed words identically. In the grid, a placeholder
is dim. That is the whole reason the capability is in this path.

## Addressing: snake_case, and verify the echo

**Every param key is snake_case, and that is not a style choice.** cmux drops
unrecognised targeting keys and then resolves the call against the **focused**
surface, returning `ok:true` — so `{"workspaceId":…,"surfaceId":…}` reads a
bystander's terminal and reports success (claude-plugins-r465.9).

Because a silent retarget is invisible in `ok:true`, **check that
`result.surface_id` is the surface you asked for.** `cmux-rpc.py` does this for
you and exits **4** (`RETARGETED`) when the reply names a different surface; treat
that payload as somebody else's and never act on it. A hand-built `--params-file`
call is covered by the same check, but only because the helper compares against
the params it actually sent — a call made any other way owes the comparison
itself.

## `anchor`: reading a surface the user is scrolling

`terminal.replay` takes `anchor`. The default `"viewport"` **follows the user's
scroll**; `anchor:"screen"` pins the grid to the live primary screen and is
scroll-immune by contract — cmux's `MobileTerminalRenderGridAnchorRegistry.swift`
states that primary-screen scrolling never round-trips. Gated on the
`terminal.render_grid.screen_anchor.v1` capability, and confirmed live on 0.64.22.

`cmux-rpc.py` passes `--anchor` through rather than defaulting it, so a cmux
without that capability is never handed a param it does not know.

This matters more here than it looks. Every gate in the dial flow — is the input
box drawn, is that text a placeholder or a human's, did the paste land — reads a
surface the user can scroll at any moment. A viewport-anchored read hands a frozen
capture to a boot wait, and a frozen capture reads as "nothing has happened yet"
for the entire budget.

One trap to know: **`scrolled_rows` in the reply is not a scroll offset.** It is
forced to 0 whenever the reply is `full:true`, and every reply is, so it is
structurally always 0 (`MobileTerminalRenderGrid.swift:212`). Never gate on it.
If you genuinely need to detect scroll, use `history_rows` growth or row-content
deltas.

## `terminal.viewport` is a SETTER — never call it in a dial path

It looks like the probe you want when a read comes back an unexpected width. It is
not a probe at all. Registering a `client_id` with `viewport_rows` /
`viewport_columns` **caps the surface's grid** — a test surface went 84×289 → 37×99
and its history reflowed — and `{"clear": true}` releases the cap.

In a dial path the surface you would be "probing" is a live `claude` REPL, so the
call reflows the callee's input box, mid-delivery, in the user's own window. Read
the grid with `terminal.replay` instead; nothing in the dial flow has a reason to
set a viewport.

## Preflight, and what a failure means

`dial.sh` makes exactly one `system.capabilities` call before it opens anything,
and reads **`result.methods`** — `result.capabilities` is a different list (`*.v1`
feature tokens) and never contains `terminal.paste`, so checking it would degrade
every call on a cmux that supports the transport fine.

Failure here degrades to headless and nothing else, deliberately: every cmux path
carries the payload over this socket, so there is no paste-free cmux delivery left
to fall back to. The four causes get four distinct `.fallbacks` strings —
`python3-missing`, `terminal-paste-unavailable`, `cmux-socket-unreachable`,
`cmux-rpc-error` — because each needs a different action, and the RPC's own stderr
rides along. See `error-recovery.md` for the `fire` stage.
