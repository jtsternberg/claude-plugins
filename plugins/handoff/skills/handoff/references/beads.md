# Beads backend

The handoff is a bd issue titled `pending-handoff: <work-name>` whose description holds the full handoff content. The `pending-handoff: ` title prefix is the marker that distinguishes handoffs from regular work items — keep it exact.

The marker is deliberately an unusual string. A plain `Handoff: ` prefix collides with ordinary issues *about* handoffs (`fix(handoff): …`, `handoff-plugin: …`), and since `bd --title-contains` matches case-insensitively and anywhere in the title, those collisions are hard to filter out after the fact. `pending-handoff` doesn't occur in normal prose, so the lookup stays unambiguous.

## 1. Reuse before create

Never create a duplicate handoff for the same work. Look for an existing open one first:

```bash
bd list --status open,in_progress --title-contains "pending-handoff:" --json
```

If an issue's title matches this work (`pending-handoff: <work-name>`), update that issue. Otherwise create a new one.

## 2. Create

Description = the full handoff content per SKILL.md's contract (pickup banner not needed — the issue ID is the pointer). Pass it via stdin so multiline markdown survives intact:

```bash
bd create "pending-handoff: <work-name>" -t task --stdin --json <<'EOF'
## Goal
...

## Current Progress
...
(remaining contract sections)
EOF
```

Note the issue ID from the JSON output.

## 3. Update

Read the existing description first (`bd show <id> --json`) to understand prior context, then replace it wholesale — carry forward still-true content, replace what's stale:

```bash
bd update <id> --body-file - --json <<'EOF'
<full replacement handoff content>
EOF
```

## 4. Resume fallback line

For the "To resume" block, state the issue ID explicitly:

```
Fallback: run `bd show <issue-id>` and continue where we left off
```
