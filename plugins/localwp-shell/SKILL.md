---
name: localwp-shell
description: Wraps WP-CLI, PHP, MySQL, and Composer commands through LocalWP's sandboxed environment. Use when working inside a LocalWP site directory. Triggers on wp/php/mysql/composer commands in WordPress context, 'command not found' errors, wrong PHP version errors, opcache/xdebug loading failures, or MySQL socket errors.
---

# LocalWP Shell

> **Platform:** macOS only.

Run commands through LocalWP's sandboxed environment (PHP, MySQL, WP-CLI, Composer). Auto-detects the correct LocalWP site from the current working directory, including through symlinked `app/public` directories.

## Usage

All scripts are in this skill's `scripts/` directory. Run them with `bash`:

```bash
# WP-CLI (most common) — silent by default
bash scripts/wplocal plugin list
bash scripts/wplocal search-replace 'old.test' 'new.test'
bash scripts/wplocal db export backup.sql

# PHP, Composer, MySQL — full env with version info
bash scripts/localwpshell php -v
bash scripts/localwpshell composer install
bash scripts/localwpshell mysql -e "SHOW DATABASES;"

# Silent mode — only command output, no env info
bash scripts/silentlocalwpshell php -r 'echo PHP_VERSION;'
```

### Commands

| Command | Purpose |
|---------|---------|
| `scripts/localwpshell [cmd]` | Load LocalWP env, show versions, optionally run a command |
| `scripts/silentlocalwpshell [cmd]` | Same as above but suppresses info output |
| `scripts/wplocal [wp-args]` | Shorthand for `silentlocalwpshell wp ...` |

## When to Use

**Always wrap commands through these scripts when the working directory is inside a LocalWP site.** The system PHP/MySQL on macOS is not the same as what LocalWP provisions.

### Recognizing a LocalWP Site

- The path contains `Local Sites/`
- The path is inside a symlinked LocalWP directory (handled automatically)
- The project has the typical LocalWP structure: `app/public/wp-content/`

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
wp plugin list       bash scripts/wplocal plugin list
php -v               bash scripts/localwpshell php -v
composer install     bash scripts/localwpshell composer install
```
