# File backend

The handoff is a `HANDOFF*.md` markdown file in the current working directory.

## 1. Choose the filename

Map the work name (see SKILL.md) to a filename:

- Work name `fix-auth` → `HANDOFF-fix-auth.md`.
- No work name → plain `HANDOFF.md`.
- If a handoff file for this work already exists (any `HANDOFF*.md` whose name matches the work), **reuse its name** rather than creating a second one.

## 2. Update vs create

Check whether the file already exists. If it does, read it in full first to understand prior context, then update it in place — carry forward still-true content, replace what's stale.

## 3. Pickup banner

Generate the harness-specific pickup command for the absolute file path:

```bash
# Codex: this path resolves under Claude Code; substitute the directory containing the handoff SKILL.md.
SKILL_DIR="${CLAUDE_SKILL_DIR}"
bash "$SKILL_DIR/scripts/generate-command.sh" "<absolute path to this file>"
```

The file starts with this banner at the very top, before the Goal — it's the next agent's cold-start path. Reproduce the generated command exactly:

```
> **Resuming this work?** Run `<generated command>` (or paste: `Read <absolute path to this file> and continue where we left off`).
```

Then the contract sections from SKILL.md, in order.

## 4. Keep it out of git

Handoff files are session artifacts, not repo files. After writing, exclude them locally (idempotent — safe to run every time; `.gitignore` is a committed file, `.git/info/exclude` is not):

```bash
git rev-parse --git-dir >/dev/null 2>&1 && {
  ex="$(git rev-parse --git-dir)/info/exclude"
  mkdir -p "$(dirname "$ex")"
  grep -qxF 'HANDOFF*.md' "$ex" 2>/dev/null || echo 'HANDOFF*.md' >> "$ex"
}
```

## 5. Resume fallback line

For the "To resume" block:

```
Fallback: paste into a new session: Read <absolute path to file> and continue where we left off
```
