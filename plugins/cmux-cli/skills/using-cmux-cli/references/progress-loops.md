# Driving sidebar progress for long-running work

`cmux set-progress` and `cmux set-status` are **one-shot writes**. The value you push sticks until you push another one. Call `set-progress 0.05` at the start of a long task and the pill sits at 5% forever — the user will ask "is this still working?" and they will be right to. cmux has no metric back-channel; the agent re-pushes values as work advances, and clears the sidebar when work ends.

## The two-loop pattern

1. **Updater** — periodically reads progress from somewhere (parses the running command's output, counts files in a dir, etc.) and re-pushes `set-progress` / `set-status`.
2. **Exit detector** — decides when the underlying process is done so the updater stops and the UI gets cleared. Use **`pgrep -f <cmd-pattern>`** rather than screen-pattern matching: `pgrep` returns non-zero the instant the process exits, with no false positives from interactive prompts (`Mine this now? [Y/n]` looks like a shell prompt to a regex). The idiom: `while pgrep -f "<cmd-pattern>" >/dev/null; do …; sleep N; done`.

In practice the two loops collapse into one — pgrep is the `while` condition; the body is the updater.

## Worked example

```bash
# Long-running command in surface:142, total known from its own output (e.g. "[N/TOTAL]")

# 1. Initial status pill + zero progress
cmux set-status mempalace_mine "starting" --icon hammer --color "#ff9500"
cmux set-progress 0.05 --label "MemPalace: starting"

# 2. Updater loop — polls the surface, parses [N/TOTAL], updates the bar
while pgrep -f "mempalace mine.*claude/projects" >/dev/null; do
  LATEST=$(cmux read-screen --surface surface:142 --lines 8 2>/dev/null | grep -oE "\[ *[0-9]+/[0-9]+\]" | tail -1)
  if [ -n "$LATEST" ]; then
    N=$(echo "$LATEST"     | grep -oE "[0-9]+/" | tr -d "/")
    TOTAL=$(echo "$LATEST" | grep -oE "/[0-9]+" | tr -d "/")
    if [ -n "$N" ] && [ -n "$TOTAL" ] && [ "$TOTAL" -gt 0 ]; then
      PCT=$(awk -v n="$N" -v t="$TOTAL" "BEGIN { printf \"%.3f\", n/t }")
      cmux set-progress "$PCT" --label "MemPalace: $N/$TOTAL"
      cmux set-status mempalace_mine "$N/$TOTAL" --icon hammer --color "#ff9500"
    fi
  fi
  sleep 5
done

# 3. After pgrep exits — clear the sidebar + notify the human
cmux clear-status mempalace_mine
cmux clear-progress
cmux notify --title "MemPalace mine done" --body "claude_history wing finished."
```

## Parsing source

The agent reads the running command's own output to derive progress — there is no metric back-channel. Common patterns to grep for: `[N/M]`, `N of M`, trailing percentages, or a file counter against a known directory. Match whatever the tool actually prints.

## Always clear what you set

Sidebar state persists. A stale "Running tests (3/42)" pill from a job that finished an hour ago pollutes the UI until something clears it. `set-progress`/`set-status` must be paired with `clear-progress`/`clear-status <key>` in the exit branch — treat them as open/close brackets.

## Cap with `notify`

When the updater loop exits, send one `cmux notify --title … --body …` so the user gets pinged even if they're looking at another workspace. Sidebar tells them *where* the work was; notify tells them *that it's done*.
