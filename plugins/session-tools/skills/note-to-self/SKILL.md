---
name: note-to-self
description: "Leave a breadcrumb in this conversation about why you're pausing and where the work stands, so returning later — to any one of many parallel sessions — starts with orientation instead of archaeology. Records the user's own words verbatim alongside an agent-written state snapshot."
when_to_use: |
  Use when the user invokes /note-to-self, or says "note to self", "leave myself a
  note", "breadcrumb this", "remind me where I left off", "I'm pausing here",
  "parking this until X".
  Not a handoff: the audience is the user returning to THIS conversation, not a
  fresh agent inheriting the work. For that, use the `handoff` skill.
disable-model-invocation: true
allowed-tools: "Bash(git *) Bash(date *) Read Grep"
argument-hint: "<what you want to remember>"
---

# Note To Self

The user runs many Claude Code conversations in parallel and cannot tell them apart on
return. A note-to-self is the fix: their own sentence about *why* they stopped, paired with
your snapshot of *where* the work actually stands.

Both halves matter. Their sentence carries intent you can't reconstruct ("waiting on final
PR review"). Yours carries state they won't remember (branch, what landed, what's next).
Keep them separate — never paraphrase their words into yours.

## Writing the note

`$ARGUMENTS` is the user's note, verbatim. Do not rewrite, expand, or tidy it. Codex: that
token is not interpolated for you — use whatever text the user passed alongside the skill
invocation, and treat an empty invocation as the no-arguments case below.

First look at where things stand — enough for one or two concrete sentences, not a report.
`git status --short`, `git log --oneline -3`, and whatever you were mid-way through. Two
values must come from commands rather than from memory, because the return trip measures
against them: the timestamp from `date "+%Y-%m-%d %H:%M"` and the commit from
`git rev-parse --short HEAD`. Then print exactly this, and nothing after it:

```
⏸  Paused — <YYYY-MM-DD HH:MM>
   <the user's words, unchanged>
   ↳ <branch> @ <short-sha>: <what landed>. Next: <the single next action>.
```

A good state line pins the commit, says what's done, and gives one next action — *"On
`note-to-self-skill` @ 9265612: SKILL.md written, plugin version bumped. Next: add the
README section and commit."* A bad one restates the note or narrates the session.

The sha is what makes the state checkable later: `git log <sha>..HEAD --oneline` is the exact
list of what moved, and it stays true across a rebase or force-push that a branch name alone
would hide.

**No arguments** means the user is pausing without telling you why. Write the same block
minus their line — the state snapshot is now the entire note, so make it carry more: what
this conversation is *about*, not just where it stopped. Don't prompt them for a note; if
they had one they'd have typed it.

The block is the whole deliverable. Don't summarize what you just wrote, don't ask what's
next, and don't start new work — they told you they're pausing.

## When the user returns after a ⏸

**The trigger is positional, not verbal.** If your last message was a `⏸ Paused` block, then
the next user prompt to arrive — whatever it says — *is* the return. Its arrival is the proof
the pause just ended. It won't announce itself; there is no "I'm back," and it will read like
an ordinary instruction or a continuation of what you were doing. That's precisely why these
checks fire on position rather than on anything in the prompt's text: by the time a prompt
looks like it needs them, you've already answered it wrong.

The block is the last thing on the user's screen, so don't narrate it back — they just read
it. It's *you* who needs grounding: you have no clock, and an unchecked transcript reads as
though it ended moments ago. Run `date`, compare it to the block's timestamp, and answer the
prompt in the tense of the real gap.

Then, before acting on that prompt, check whether the note's claimed state still holds —
`git log <sha>..HEAD --oneline`, the branch, the PR or blocker it named. Surface only what's
different. If nothing moved, say nothing extra and just continue.
