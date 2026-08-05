# Reading a digest

Shared by `sessions-catch-up` and `sessions-fork`. Both run the same command and read
the same output; they differ only in what they do with it.

```bash
# Codex: replace the fallback with the directory containing this plugin.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT:-<absolute path to this session-tools plugin directory>}"
node "$PLUGIN_ROOT/scripts/export-session.mjs" "<target>" --format digest --fast
```

The digest is already 200–800x smaller than the transcript. **Read it directly from the
command result — do not pipe it through a subagent.** That adds a round-trip to the one
thing that has to be fast.

## Resolution and ambiguity

Resolution order: exact session id → id prefix → slug/title, disambiguated by proximity
to the current cwd. Ambiguity is **reported, never guessed**. On a non-zero exit:

- a candidate list → show it and ask which one
- `No session matches` → run `--list` and offer the nearest few by name

## Tail state is the most important line

`## ⏳ Tail state` is the first thing to read and the first thing to report. The four
states mean different things and must not be blurred together:

| State | Meaning |
|---|---|
| `BLOCKED ON YOU` | It asked a question, or hit `AskUserQuestion`/`ExitPlanMode`, and stopped. Someone owes it an answer. |
| `YOUR MESSAGE MAY BE UNANSWERED` | The user's message was the last record. It may never have been picked up at all. |
| `INTERRUPTED MID-TURN` | Stopped during a tool call. Work may be half-applied — check the repo, don't trust the narrative. |
| `Not blocked` | The agent spoke last and nothing is explicitly pending. |

## Other signals, and what to trust

- **Beads are re-resolved live** via `bd show`, so the digest reports each issue's
  *current* status, not what it was when the session ran. Trust the digest over the
  transcript here — a bead the session left open may since have closed.
- **Todo state** is the last `TodoWrite` in the transcript. `~/.claude/todos/` is empty
  in 2.1.x, so this is the only source.
- **Files touched** comes from `Edit`/`Write` tool calls. A file changed by `sed`, by a
  subagent, or by a shell redirect will **not** appear. Treat the list as a floor, and
  check `git status` / `git log` when it matters.
- **A compaction summary** means detail before that point exists *only* as that summary.
  Say so rather than implying full fidelity.
- **`thinking` blocks are empty on disk** (signature only). Reasoning is unrecoverable
  by any method — never imply you know why something was decided if only the decision
  was recorded.

## Do not fabricate

A thin transcript gets a thin answer. "The transcript doesn't show why" is a correct
and useful sentence. Inventing a rationale is worse than admitting the gap.

## Going deeper

The digest header names the transcript path. `Grep` it directly, or re-run with
`--format md` (full readable transcript), `--window 40`, or `--compaction-full`.

`claude --resume <id> --fork-session` is a last resort only: it replays the entire
transcript into a fresh context and costs a full prefill.
