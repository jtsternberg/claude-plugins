---
name: localwp-shell
description: "Wraps WP-CLI, PHP, MySQL, and Composer commands through LocalWP's sandboxed environment. Use when working inside a LocalWP site directory. Triggers on wp/php/mysql/composer commands in WordPress context, 'command not found' errors, wrong PHP version errors, opcache/xdebug loading failures, or MySQL socket errors."
---

# LocalWP Shell

> **Platform:** macOS only.

Run commands through LocalWP's sandboxed environment (PHP, MySQL, WP-CLI, Composer). Auto-detects the correct LocalWP site from the current working directory, including through symlinked `app/public` directories **and project directories whose contents symlink into a site tree** (e.g. `myproject/links/theme -> ~/Sites/wp-site/wp-content/themes/x` — the script follows the project's symlinks, finds the site, and runs commands from its WordPress root).

## Usage

All scripts live in this skill's directory, referenced at runtime via `${CLAUDE_SKILL_DIR}`. Run them with `bash`:

```bash
# WP-CLI (most common) — silent by default
bash ${CLAUDE_SKILL_DIR}/scripts/wplocal plugin list
bash ${CLAUDE_SKILL_DIR}/scripts/wplocal search-replace 'old.test' 'new.test'
bash ${CLAUDE_SKILL_DIR}/scripts/wplocal db export backup.sql

# PHP, Composer, MySQL — full env with version info
bash ${CLAUDE_SKILL_DIR}/scripts/localwpshell php -v
bash ${CLAUDE_SKILL_DIR}/scripts/localwpshell composer install
bash ${CLAUDE_SKILL_DIR}/scripts/localwpshell mysql -e "SHOW DATABASES;"

# Silent mode — only command output, no env info
bash ${CLAUDE_SKILL_DIR}/scripts/silentlocalwpshell php -r 'echo PHP_VERSION;'
```

### Commands

| Command | Purpose |
|---------|---------|
| `${CLAUDE_SKILL_DIR}/scripts/localwpshell [cmd]` | Load LocalWP env, show versions, optionally run a command |
| `${CLAUDE_SKILL_DIR}/scripts/silentlocalwpshell [cmd]` | Same as above but suppresses info output |
| `${CLAUDE_SKILL_DIR}/scripts/wplocal [wp-args]` | Shorthand for `silentlocalwpshell wp ...` |

## When to Use

**Always wrap commands through these scripts when the working directory is inside a LocalWP site.** The system PHP/MySQL on macOS is not the same as what LocalWP provisions.

### Recognizing a LocalWP Site

- The path contains `Local Sites/`
- The path is inside a symlinked LocalWP directory (handled automatically)
- The project has the typical LocalWP structure: `app/public/wp-content/`
- The project directory contains symlinks INTO a LocalWP site (handled automatically — searched up to 2 levels deep)

## Critical Warnings

**NEVER source a LocalWP ssh-entry script directly** (`source "~/Library/Application Support/Local/ssh-entry/XXX.sh"`). It launches an interactive shell that blocks the agent indefinitely. Always go through `localwpshell` / `silentlocalwpshell` / `wplocal`, which extract the environment without spawning a shell.

**WordPress Multisite: always pass `--url=`.** On a multisite install, WP-CLI without `--url` targets the network's primary site — pages, options, and plugin changes land on the WRONG site silently. Find the right URL first (`wp site list`), then include it in every command:

```bash
bash ${CLAUDE_SKILL_DIR}/scripts/wplocal site list
bash ${CLAUDE_SKILL_DIR}/scripts/wplocal post list --post_type=page --url=https://wp.wpengine/coaching
```

### Error Patterns That Mean "Use This Skill"

- `Error: Failed loading /opt/...opcache.so` or `xdebug.so` — wrong PHP binary
- `ERROR 2002 (HY000): Can't connect to local MySQL server through socket` — wrong MySQL
- `PHP Fatal error: Uncaught Error: Call to undefined function ...` — missing PHP extension
- `wp: command not found` — WP-CLI not on PATH
- PHP version mismatch (e.g. expecting 8.x, got system 7.x)
- Composer dependency conflicts due to wrong PHP version

### Recovery

```bash
# Instead of:        Use:
wp plugin list       bash ${CLAUDE_SKILL_DIR}/scripts/wplocal plugin list
php -v               bash ${CLAUDE_SKILL_DIR}/scripts/localwpshell php -v
composer install     bash ${CLAUDE_SKILL_DIR}/scripts/localwpshell composer install
```
