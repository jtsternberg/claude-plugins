# Native Cross-Session Messaging (fast path)

SKILL.md sent you here because the user's own words named a session that is *already
running* and the message is one that session can answer from where it sits. This file is
the mechanics of delivering it through Claude Code's native cross-session messaging
(`ListAgents` + `SendMessage`, Claude Code ≥ 2.1.224, macOS/Linux) — and the fallback
when the live sessions don't match.

**This path is Claude Code only.** Codex has no `ListAgents`/`SendMessage`. If you're
running under Codex, stop reading — use the normal dial flow in SKILL.md, which
launches a session and works from any harness.

When the target is a live session, native is dramatically simpler than hotline's
launch-and-scrape transport: no workspace resolution, no caller-identity resolution,
no cmux surface, no `read-screen` polling. You address the running session by name and
send it text.

## The gate lives in SKILL.md — re-check it before step 1

Native applies only when **all** of these hold. If any fails, go back to SKILL.md's
"The one command" and dial normally — without calling `ListAgents`.

1. **The user named a running session**, in their own words: "my other session", "the
   session working on X", "the terminal/tab that's …", a `ListAgents` name they've
   seen, a `/rename`d name, or a reply to a `<cross-session-message>` you received.
   A workspace/project/folder name ("dial monorepo", "call dotfiles") is a launch,
   even though `ListAgents` will usually list sessions in that folder — hotline's own
   callees live there, so those matches are expected noise, not evidence.
2. **The message is a lightweight ping or quick question** the session answers from
   what it already has in front of it — "migration's done, main is safe to rebase",
   "what branch are you on?". Anything it must fetch, read, or do (a URL, an issue, a
   file, "draft the about page") is a work order: launch it, so it gets a surface, a
   transcript, and a switchboard entry.
3. **You are not dialing by a raw session ID.** A session ID is hotline's
   fork-a-transcript path (`dial.sh --resume`), not a `ListAgents` name.
4. **Not a conference call.** "Pair with me" wants a launched, observable callee.

`ListAgents` is step 1 of *delivery*, not a way to decide whether native applies. The
user's phrasing decides; in doubt, launch.

## The algorithm

### 1. Discover live sessions

Call `ListAgents`. Each row leads with the agent's `name [ref]`; the **name is the
address**.

### 2. Match the target against the listed names

Compare the user's reference (their exact words for the target — "my other session",
"the frontend one", a project-ish name) to the agent names. Names default to
folder-derived slugs (e.g. `myapp-3f`) unless the user set one with `/rename`.

- **Exactly one confident live match** → go to step 3.
- **More than one plausible match** → **ask** with `AskUserQuestion`, candidates as
  options. Don't guess when the wrong pick messages the wrong session.
- **No live match** → the session the user meant isn't reachable here. Say so briefly
  and fall back to the normal launch flow — **SKILL.md's "The one command"**. Do not
  invent a name.

### 3. Send

```
SendMessage({
  to: "<exact name from the ListAgents row>",
  message: "<the message / question, plain text>",
  summary: "<5-10 word preview>"
})
```

Append the row's ` [ref]` to `to` **only** when the bare name is ambiguous — two rows
share it, or an error tells you to disambiguate. A ref you didn't just read from a
listing won't resolve.

### 4. Relay

- **One-way heads-up** (you handed the peer a fact/nudge): confirm delivery to the
  user — *"Messaged **frontend** — it'll pick that up at its next step."* Nothing to
  wait for.
- **A question**: the reply is asynchronous. The peer drains its queue at its next
  tool round and answers by sending you a message back, which arrives automatically
  wrapped as `<cross-session-message from="…">` — you don't poll an inbox. Tell the
  user you've messaged the session and will relay its answer when it comes in; when it
  arrives, relay it (`**frontend:** …`). To reply again, use that message's `from` as
  your `to`.

## What you give up vs. the normal transport

Native messages leave **no** hotline trace: nothing in the sessions registry, no
dial-history entry, no session-cache entry, and **the switchboard won't show them**
(native keeps no cross-session transcript — messages collapse to a one-line row in
each session's own history). That's an acceptable trade for a quick ping to a session
the user already has open and is watching. But if the user will want to *observe,
resume, or track* this exchange, prefer the normal transport (dial it as a work order)
so it lands in a surface and on the switchboard.

## Constraints & gotchas (native-side)

- **Plain text only.** No files, no structured data, no history. Native sends a
  summary, not context. If the user needs the peer to see files or prior conversation,
  native is the wrong tool — launch a call instead.
- **Same filesystem required** for same-machine delivery. Two sessions in different
  containers can't reach each other even on one host.
- **You can only open a conversation with a same-machine session.** Cross-machine and
  web sessions are reply-only: you may answer one that messaged you, but you cannot
  initiate. If the session the user means lives elsewhere, launch instead.
- **Message caps / loops.** A session holds at most ~100 undelivered messages, and
  repeated identical sends in a short window are dropped as loop protection. Don't
  retry-spam a send; if it didn't land, report that rather than looping.
- **No permission bypass — and no laundering.** A message can't approve permission
  prompts on the receiver's behalf; the receiver's own permission rules still apply.
  Never use `SendMessage` to ask a peer to do something that was blocked/denied in
  this session (or that you expect your own permissions would block) — routing blocked
  work through a peer bypasses the user's decision. Route blocked work back to the
  user.
- **Inbound may be gated.** The user can set `crossSessionInbound` to `hold`/`refuse`,
  or `isolatePeerMachines` to require approval before cross-machine delivery. If a send
  seems to go nowhere, the receiver may be holding/refusing — surface that possibility
  rather than assuming your send was malformed.
- **Feature can be off.** Requires Claude Code ≥ 2.1.224 on macOS/Linux and is disabled
  by `CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC` / `DISABLE_TELEMETRY` / `DO_NOT_TRACK`
  and on some managed platforms (Bedrock, Vertex, Foundry). If `ListAgents` errors or
  isn't available, fall back to SKILL.md's "The one command".
