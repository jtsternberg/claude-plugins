---
name: sessions-recap-self
description: "Recap where THIS session is right now — the arc, the decisions, and what's still open — summarized from the conversation already in context. For a long session whose thread has slipped."
when_to_use: |
  Use when the user wants to get re-oriented on the CURRENT session — the one
  they are in right now — not a different one:
  "catch me up on where we are", "remind me what we're doing",
  "recap this session", "where were we", "I left this running overnight,
  where are we", "I stepped away, what's the state so far",
  "summarize where we've gotten".
  For a DIFFERENT session named by id or slug, use `sessions-catch-up`.
  To PRIME this session with another one's context, use `sessions-fork`.
disable-model-invocation: true
---

# Sessions Recap (self)

Summarize where **this** conversation stands, straight from the context you already hold.
No transcript to read and nothing to run — whatever is in context is exactly what the user
wants summarized. Use it when the session has run long enough that the thread has slipped
out of the user's head (an overnight run, or one they walked away from) and they want their
bearings back without scrolling.

The deliverable is **orientation, not a replay.** Answer three things, in prose:

```
## Where we are
<2–3 short paragraphs: what we set out to do, the main decisions and why,
what's been done, and the state right now.>

**Loose ends**
- <open questions between us, unfinished todos, a thing you said you'd circle
  back to, anything still undecided>

**Where we'd pick up**
- <the one next action>
```

Lead with the arc. Don't narrate the conversation tool-call by tool-call, and don't pad —
if the session is short, a couple of sentences is the honest answer. Don't invent a reason
for a decision that wasn't actually discussed; say it's still open instead.
