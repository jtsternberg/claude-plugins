# smart-permissions plugin is active

Two-layer permission system running on your tool calls:
- **Layer 1 (instant):** Auto-allows safe operations (Read, Grep, git, tests, etc.) and auto-denies dangerous ones (sudo, rm -rf /, curl|bash, etc.)
- **Layer 2 (AI fallback):** For ambiguous commands, Claude Haiku evaluates against a policy file. If anything fails, the normal permission dialog appears.

Customize rules: edit `permission-policy.md` in the plugin folder.

Debug log: `<your-claude-config>/hooks/smart-permissions.log` (e.g. `~/.claude/hooks/smart-permissions.log`)
Verbose Layer 1 logging: `export SMART_PERMISSIONS_DEBUG=1`
