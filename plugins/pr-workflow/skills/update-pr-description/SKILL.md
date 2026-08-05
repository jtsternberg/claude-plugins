---
name: update-pr-description
description: Update a PR description from branch changes, optionally since a date or commit
argument-hint: "[date/commit-hash | --force]"
disable-model-invocation: true
allowed-tools: Bash, Read, Write, Glob
---

Update the current PR description to reflect branch changes, using an optional date or commit as the starting point and the PR base branch by default.

This skill will:
1. Get the current PR description and save it as the "current" version
2. Analyze git commits since the specified date/commit to identify new changes
3. Generate an updated PR description that incorporates these changes
4. Use your git diff tool to show the difference between current and proposed descriptions
5. If approved, update the PR with the new description

Arguments provided: $ARGUMENTS

Codex: if `$ARGUMENTS` above is not substituted, use the invocation text after the skill name. If none is available, infer an optional date, commit hash, or `--force` flag from the current request.

**Arguments:**
- **Date/Commit Hash**: Specify either a date (e.g., "2025-01-15", "2025-01-15T10:30:00") or commit hash (e.g., "abc123f") to find commits since that point
- **--force**: Regenerate entire PR description from scratch, analyzing all commits in the branch

**Project Conventions (optional):**
If the `CODE_CONVENTIONS` environment variable is set and points to a readable file, skim it for context about project patterns that should be reflected in the PR description (e.g., architecture decisions, naming conventions).

**Process:**

1. **Create a unique temporary directory, then get current PR info and save the description**:
   ```bash
   tmp_dir="$(mktemp -d)"
   gh pr view --json body --jq '.body' > "$tmp_dir/current-pr-description.md"
   ```

2. **Parse arguments and find commits**:
   - If `--force` is provided: analyze all commits in the current branch
   - If a date is provided (contains `-` or `:`): use `git log --since="date" --oneline`
   - If a commit hash is provided: use `git log commit-hash..HEAD --oneline`
   - If no argument is provided: get the PR's base branch with `gh pr view --json baseRefName --jq '.baseRefName'`, fetch/verify the corresponding `origin/<base>` ref, and analyze `origin/<base>...HEAD`
   - Determine argument type by checking format:
     - Date formats: `YYYY-MM-DD`, `YYYY-MM-DDTHH:MM:SS`, etc.
     - Commit hash: 7+ character alphanumeric string

3. **Generate updated PR description**:
   - Follow the project's established PR-description process and repository instructions
   - Incorporate information about new commits and changes

4. **Create diff and review**:
   - Save the proposed description to `$tmp_dir/proposed-pr-description.md`
   - Always show a textual comparison with `git diff --no-index -- "$tmp_dir/current-pr-description.md" "$tmp_dir/proposed-pr-description.md"`; exit status 1 means the files differ and is expected
   - Optionally use the user's configured visual difftool when requested and available

   - Wait for user approval before applying changes

5. **Consider updating PR title** Consider whether the title needs to be updated to reflect the changes. Default to keeping the original title.

6. **Update the PR:**
   Example commands to suggest:
   ```bash
   gh pr edit --title "UPDATED_TITLE_HERE" --body-file "$tmp_dir/proposed-pr-description.md"
   ```
   (only include UPDATED_TITLE_HERE if it is different from the original title)

7. **Apply changes if approved**:
   - Use the above commands to update the PR description and title.
   - After approval and a successful update, or after cancellation, remove only the unique temporary directory created in Step 1.

**Usage Examples:**
- Invoke `update-pr-description` with `2025-01-15` to update from commits since January 15, 2025.
- Invoke `update-pr-description` with `1764afe` to update from that commit.
- Invoke `update-pr-description` with `--force` to regenerate the entire description.
- Invoke `update-pr-description` with `2025-01-15T10:30:00` to update from a specific time.
