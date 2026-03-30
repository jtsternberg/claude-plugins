# Dirmap Fallback

If `dirmap` is not in PATH, use the bundled fallback scripts:

```bash
# List all projects
bash "$HOTLINE_SCRIPTS/dirmap-fallback.sh" list

# Get path for a project ID
bash "$HOTLINE_SCRIPTS/dirmap-fallback.sh" get <id>
```

(Requires `eval "$(bash ${CLAUDE_SKILL_DIR}/../../scripts/paths.sh)"` to have been run first.)

These read from `~/.dirmap.json`. To set up dirmap for the first time, create `~/.dirmap.json`:

```json
{
  "my-project": "/path/to/project",
  "another-project": "/path/to/other"
}
```

For the full `dirmap` tool with add/remove/search: https://github.com/jtsternberg/dotfiles
