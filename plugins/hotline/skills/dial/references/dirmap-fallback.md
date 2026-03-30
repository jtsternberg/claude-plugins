# Dirmap Fallback

If `dirmap` is not in PATH, use the bundled fallback scripts:

```bash
# List all projects
bash "PLUGIN_DIR/scripts/dirmap-fallback.sh" list

# Get path for a project ID
bash "PLUGIN_DIR/scripts/dirmap-fallback.sh" get <id>
```

These read from `~/.dirmap.json`. To set up dirmap for the first time, create `~/.dirmap.json`:

```json
{
  "my-project": "/path/to/project",
  "another-project": "/path/to/other"
}
```

For the full `dirmap` tool with add/remove/search: https://github.com/jtsternberg/dotfiles
