# Git-Tree Skill Review

Review against Anthropic's Agent Skills best practices.

---

## Critical Issues

### 1. Description missing explicit trigger terms

**Current:**
```yaml
description: Checkout a branch to a new git worktree with symlinks to dependencies. Use when users want to work on multiple branches simultaneously...
```

**Issue:** The description is lengthy (298 chars) but lacks explicit trigger terms that users would actually type. Per best practices, descriptions should include specific terms users would mention.

**Recommendation:** Add common trigger phrases: "git worktree", "parallel branch", "switch between branches without stashing", "work on two branches at once".

### 2. SKILL.md references scripts with relative paths that assume skill directory is cwd

**Current:**
```bash
./scripts/git-tree.sh <branch-name>
```

**Issue:** Claude Code loads skills from `~/.claude/skills/` or `.claude/skills/`. When Claude runs this command, the cwd is the user's project, not the skill directory. The script won't be found.

**Recommendation:** Either:
- Use absolute paths with `$SKILL_DIR` variable pattern
- Move scripts to user's PATH
- Have Claude read and execute the script content directly
- Update instructions to specify the full path to the skill's scripts directory

### 3. No verification that script output is parsed/used

**Issue:** The workflow says "Execute the Script" then "Confirm" but doesn't show Claude how to parse the script's output or handle errors programmatically.

**Recommendation:** Add expected output format and how Claude should interpret success/failure.

### 4. Supplementary docs (TROUBLESHOOTING.md, WEBSERVER-WORKTREES.md) not referenced with clear triggers

**Issue:** Best practices state references should be one level deep from SKILL.md with clear guidance on when Claude should read them. Current reference is minimal:

```markdown
See [TROUBLESHOOTING.md](TROUBLESHOOTING.md) for worktree management and common issues.
```

**Recommendation:** Add specific triggers:
```markdown
## Troubleshooting

**Error messages or failures?** → See [TROUBLESHOOTING.md](TROUBLESHOOTING.md)
**Need to serve worktree via web server?** → See [WEBSERVER-WORKTREES.md](WEBSERVER-WORKTREES.md)
```

---

## Content Issues

### 7. SKILL.md is verbose in places

**Example:**
```markdown
### Step 1: Determine Arguments

If a branch name is provided:
- Use it as the target branch

If no branch name is provided:
- Ask the user which branch to checkout as a worktree
```

**Issue:** This is obvious behavior that Claude already knows. Per best practices: "Only add context Claude doesn't already have."

**Recommendation:** Remove this section entirely. Trust Claude to prompt for missing required arguments.

### 8. ASCII art diagram is token-expensive

**Current:** ~200 tokens for the directory structure visualization.

**Recommendation:** Keep it—it adds genuine value for understanding—but trim whitespace:
```
repository/
├── main-repo/           # Original (real deps)
└── gittree-branch/      # Worktree (symlinked deps)
```

### 9. "When NOT to Use" section could be more actionable

**Current:** Lists scenarios but doesn't tell Claude what to do instead.

**Recommendation:** Add alternatives:
```markdown
### When NOT to Use
- **Different dependency versions needed** → Install deps directly: `rm vendor && composer install`
- **Temporary one-file changes** → Use `git stash`
- **Branch already checked out** → Remove existing worktree first
```

---

## Script Issues

### 10. Scripts use `set -e` but don't handle cleanup on failure

**Issue:** If the script fails mid-way (e.g., after creating worktree but before symlinks), it leaves partial state.

**Recommendation:** Add trap for cleanup:
```bash
trap 'echo "Error on line $LINENO"; cleanup' ERR
```

### 11. sed -i portability issue

**git-tree-swap.sh:135:**
```bash
sed -i.bak "s|/${REPO_NAME}/|/${MAIN_STASH_NAME}/|g" "$WORKTREE_GIT_FILE"
```

**Issue:** `sed -i` behavior differs between macOS BSD sed and GNU sed. The `.bak` suffix helps but the pattern may still differ.

**Recommendation:** Use a more portable approach or document macOS requirement.

### 12. Scripts lack --dry-run option

**Issue:** Users can't preview what will happen before execution. This is especially important for `swap` and `restore` which move directories.

**Recommendation:** Add `--dry-run` flag that shows planned actions without executing.

---

## Missing Features

### 13. No cleanup/list workflow

**Issue:** Users can accumulate many worktrees. No skill support for cleaning them up.

**Recommendation:** Add to SKILL.md:
```markdown
## Cleanup

List all worktrees:
```bash
git worktree list
```

Remove a worktree:
```bash
git worktree remove gittree-branch-name
```

### 14. No integration with swap/restore scripts in main SKILL.md

**Issue:** The `git-tree-swap.sh` and `git-tree-restore.sh` scripts exist but SKILL.md only references `git-tree.sh`. The swap/restore functionality is documented only in WEBSERVER-WORKTREES.md.

**Recommendation:** Add a "Web Server Integration" section to SKILL.md that references these scripts or explicitly directs to WEBSERVER-WORKTREES.md.

---

## Minor Issues

### 16. No examples section with input/output pairs

**Issue:** Best practices recommend input/output examples for Skills where output quality depends on seeing examples.

**Recommendation:** Add:
```markdown
## Examples

**User:** "I want to work on feature-auth while keeping my current work"
**Claude:** Creates worktree at ../gittree-feature-auth/

**User:** "Set up a worktree for PR review of branch fix-login"
**Claude:** Creates worktree at ../gittree-fix-login/
```

---

## Summary

| Priority | Count | Issues |
|----------|-------|--------|
| Critical | 3 | Script paths, description triggers, output parsing |
| Structural | 3 | Unrelated settings, missing references |
| Content | 4 | Verbosity, missing alternatives |
| Scripts | 3 | Error handling, portability, dry-run |
| Missing | 2 | Cleanup workflow, swap integration |
| Minor | 2 | Naming, examples |

**Top 3 actions:**
1. Fix script path resolution (skill scripts won't work as currently written)
3. Add explicit triggers to supplementary doc references
