---
description: Update PR description based on code changes since last edit
argument-hint: [date/commit-hash | --force]
allowed-tools: Bash, Read, Write, Glob
---

Update the current PR description to reflect any code changes made since the last PR description edit.

This command will:
1. Get the current PR description and save it as the "current" version
2. Analyze git commits since the specified date/commit to identify new changes
3. Generate an updated PR description that incorporates these changes
4. Use your git diff tool to show the difference between current and proposed descriptions
5. If approved, update the PR with the new description

Arguments provided: $ARGUMENTS

**Arguments:**
- **Date/Commit Hash**: Specify either a date (e.g., "2025-01-15", "2025-01-15T10:30:00") or commit hash (e.g., "abc123f") to find commits since that point
- **--force**: Regenerate entire PR description from scratch, analyzing all commits in the branch

**Process:**

1. **Get current PR info and save current description**:
   ```bash
   gh pr view --json body --jq '.body' > /tmp/current-pr-description.md
   ```

2. **Parse arguments and find commits**:
   - If `--force` is provided: analyze all commits in the current branch
   - If a date is provided (contains `-` or `:`): use `git log --since="date" --oneline`
   - If a commit hash is provided: use `git log commit-hash..HEAD --oneline`
   - Determine argument type by checking format:
     - Date formats: `YYYY-MM-DD`, `YYYY-MM-DDTHH:MM:SS`, etc.
     - Commit hash: 7+ character alphanumeric string

3. **Generate updated PR description**:
   - Follow the same process as `/create-pr` command
   - Reference the detailed PR description generation process from @docs/ai/PR-Description-Generation.md
   - Incorporate information about new commits and changes

4. **Create diff and review**:
   - Save proposed description to `/tmp/proposed-pr-description.md`
   - ALWAYS US `git difftool --no-index /tmp/current-pr-description.md /tmp/proposed-pr-description.md` to show visual comparison
      - Note: The difftool command _may_ show an error status but should still open the visual diff tool successfully

   - Wait for user approval before applying changes

5. **Consider updating PR title** Consider whether the title needs to be updated to reflect the changes. Default to keeping the original title.

6. **Update the PR:**
   Example commands to suggest:
   ```bash
   gh pr edit --title "UPDATED_TITLE_HERE" --body-file /tmp/proposed-pr-description.md
   ```
   (only include UPDATED_TITLE_HERE if it is different from the original title)

7. **Apply changes if approved**:
   - Use the above commands to update the PR description and title.

**Usage Examples:**
- `/update-pr-description 2025-01-15` - Update based on commits since January 15, 2025
- `/update-pr-description 1764afe` - Update based on commits since commit hash 1764afe
- `/update-pr-description --force` - Regenerate entire PR description from scratch
- `/update-pr-description "2025-01-15T10:30:00"` - Update based on commits since specific date/time