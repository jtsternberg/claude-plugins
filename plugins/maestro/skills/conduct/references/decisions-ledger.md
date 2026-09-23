# The decisions ledger

A long orchestration asks the human a lot of binary questions. Each one is clear
in the message that asks it and meaningless a few hours later, because every
later reference is to the *answer tokens* — "fold" / "defer", "now" / "after
81", "3" / "keep 2" — and those carry no subject. The ledger is where the
subject lives, so `Next for you:` stays actionable without scrollback.

## Path

```
/tmp/maestro/decisions-<session-id>.md
```

One file per orchestrating session. `<session-id>` is this session's id (the
`caller-id` skill in the `hotline` plugin prints it); its first segment is
enough, and that is what the human can retype. No session id available →
`/tmp/maestro/decisions-<YYYY-MM-DD>-<short-slug>.md`.

`/tmp` on purpose: guessable, `code -r`-able, survives the session, and the
human can find it by `ls /tmp/maestro/` without asking. The harness scratchpad
is not a substitute — its path is unguessable, which defeats the point. `/tmp`
is world-readable and cleared on reboot, so the ledger is working context, not
storage: nothing secret, nothing you'd mind losing once the work lands.

## Shape

```markdown
# Decisions in play — <what this session is doing>

Plain-language context for every question the orchestrator has asked <human>.
One section per decision. Resolved ones move to the bottom with the answer.

## Open

### decide-<slug> — <the question as a question>

**What happened:** the facts that produced the question, in words. Spell out
what an id refers to ("PR #92 fixes a bug where …"), never just the number.

**Why it matters:** the cost of getting it wrong, or of deciding later.

**Options:**
- "<exact token to type>" (<alias>) — what it does, what it costs, how long it takes.
- "<exact token to type>" (<alias>) — same.

**Recommendation:** one option, one sentence of why.

**What happens next either way:** what you do with the answer, so the human
knows what they're starting.

## Decided

- <YYYY-MM-DD> — <subject>: **<answer>**. (<one clause of why, if it wasn't the
  recommendation or if the reasoning binds future work>)
```

Write it for a sharp reader who has never seen this repo: no jargon, no bare
issue numbers, no internal shorthand. If a sentence only parses for someone who
watched the session, rewrite it.

## Rules

- **Write the section before the message that asks the question.** Never after,
  and never "when it comes up again" — the gap between asking and writing is
  exactly where the context is lost. It also means the asking message can link
  a section that already exists.
- **`decide-<slug>` names the subject**, not a counter: `decide-92-campaigns`,
  `decide-exit-code`. The anchor is a search token, never part of the path:
  `code /tmp/maestro/decisions-abc.md#decide-90` treats the whole string as a
  filename and offers to **create a new file**. So the path and the anchor are
  written as two things with a separator between them, the path stays a clean
  token the human can click or paste, and the anchor has to be greppable.
  Keep `## Open` above `## Decided` so opening the file lands on live
  questions.
- **Options are the literal strings you'll accept as an answer**, each with
  the same one-letter alias the asking message uses. The human should be able
  to reply with one token, or one letter, and nothing else. A decision that
  bundles numbered recommendations also accepts `N: <change>`, overriding
  item N alone.
- **Resolve in the same turn you act on the answer:** move the section to
  `Decided` with the date and what was chosen. A ledger whose `Open` list is
  stale is worse than none, because it re-asks settled questions.
- **One file, appended all session.** Don't start a second ledger for a second
  decision, and don't rewrite history in `Decided`.

## `Next for you:` lines

Three parts, always: the answer tokens with their one-letter aliases, a plain
clause naming the subject, and the ledger path followed by the anchor as a
separate token.

Bad — tokens with no subject, and a path fused to its anchor, which opens
nothing:

```
Next for you: still owe "fold campaigns into 92" or "defer campaigns"
(/tmp/maestro/decisions-c54f524f.md#decide-92-campaigns)
```

Good:

```
Next for you: answer "fold campaigns into 92" (F) or "defer campaigns" (D) — whether
PR #92 also fixes the wrong exit code in the five campaigns commands
(/tmp/maestro/decisions-c54f524f.md - #decide-92-campaigns)
```

Numbered recommendations bundled into one decision, with per-item override:

```
Next for you: type `ok` (k) to take all 8 recommendations and file the 11 sub-issues
for frontend#2653, or `N: <change>` to override item N
(/tmp/maestro/decisions-c54f524f.md - #decide-2653-split)
```

Nothing owed now, but the next step is already known — its token still carries
its alias:

```
Next for you: nothing. After I confirm the edits, the next step is your `file` (F) on #2653.
```

The clause stays short enough (≈15 words) that a human who was present never
needs the link, and concrete enough that a human who wasn't can decide from the
file alone.

## Handoffs

A handoff **points at the ledger path**; it does not restate it. Open decisions
belong in the handoff's next steps as one line each — tokens, clause, link —
and the `Decided` list is the decision history a fresh agent needs, already
written. Copying sections into the handoff forks them, and the copy is the one
that goes stale.
