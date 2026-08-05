# Dirmap Fallback

If `dirmap` is not in PATH, use the bundled fallback scripts:

```bash
# Codex: replace ${CLAUDE_PLUGIN_ROOT} below with the Hotline plugin directory.
PLUGIN_ROOT="${CLAUDE_PLUGIN_ROOT}"
eval "$(bash "$PLUGIN_ROOT/scripts/paths.sh")"
# List all projects
bash "$HOTLINE_SCRIPTS/dirmap-fallback.sh" list

# Get path for a project ID
bash "$HOTLINE_SCRIPTS/dirmap-fallback.sh" get <id>
```

These read from `~/.dirmap.json`. To set up dirmap for the first time, create `~/.dirmap.json`:

```json
{
  "my-project": "/path/to/project",
  "another-project": "/path/to/other"
}
```

For the full `dirmap` tool with add/remove/search: https://github.com/jtsternberg/dotfiles
