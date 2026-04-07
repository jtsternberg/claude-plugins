# LocalWP Shell

A Claude Code skill that routes WP-CLI, PHP, MySQL, and Composer commands through [LocalWP](https://localwp.com/)'s sandboxed environment — so Claude stops tripping over your system PHP and wondering why `wp` doesn't exist.

**Platform:** macOS only.

## The Problem

LocalWP provisions its own PHP, MySQL, WP-CLI, and Composer per site. But when Claude Code runs shell commands, it hits the system binaries (or nothing at all), leading to:

- `wp: command not found`
- Wrong PHP version (system 8.1 vs LocalWP's 8.2)
- `Can't connect to local MySQL server through socket`
- `Failed loading opcache.so` / `xdebug.so`
- Composer dependency conflicts from version mismatches

This skill teaches Claude to automatically detect LocalWP sites and wrap commands through the correct environment.

## What's Included

| File | Purpose |
|------|---------|
| `SKILL.md` | The skill definition Claude loads — trigger patterns, usage docs, error recovery |
| `scripts/localwpshell` | Core script: resolves the current directory to a LocalWP site (including through symlinks), loads its environment, and runs commands |
| `scripts/silentlocalwpshell` | Same thing, quiet mode — no version banners, just output |
| `scripts/wplocal` | Shorthand for `silentlocalwpshell wp ...` (the most common use case) |

## How It Works

1. Reads LocalWP's `sites.json` to match your current directory to a provisioned site
2. Falls back to symlink resolution if `app/public` is symlinked elsewhere
3. Loads that site's PHP, MySQL, and tool paths into the shell environment
4. Runs your command with the correct binaries

## Example Usage

```bash
# WP-CLI
bash scripts/wplocal plugin list
bash scripts/wplocal search-replace 'old.test' 'new.test'

# PHP / Composer / MySQL
bash scripts/localwpshell php -v
bash scripts/localwpshell composer install
bash scripts/localwpshell mysql -e "SHOW DATABASES;"
```

## Install

```bash
amskills install localwp-shell
```

The skill triggers automatically when Claude detects you're working inside a LocalWP site directory.
