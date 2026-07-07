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
| `skills/localwp-shell/SKILL.md` | The skill definition Claude loads — trigger patterns, usage docs, error recovery |
| `skills/localwp-shell/scripts/localwpshell` | Core script: resolves the current directory to a LocalWP site (including through symlinks), loads its environment, and runs commands |
| `skills/localwp-shell/scripts/silentlocalwpshell` | Same thing, quiet mode — no version banners, just output |
| `skills/localwp-shell/scripts/wplocal` | Shorthand for `silentlocalwpshell wp ...` (the most common use case) |

## How It Works

1. Reads LocalWP's `sites.json` to match your current directory to a provisioned site
2. Falls back to symlink resolution if `app/public` is symlinked elsewhere
3. Loads that site's PHP, MySQL, and tool paths into the shell environment
4. Runs your command with the correct binaries

## Example Usage

```bash
# WP-CLI
bash plugins/localwp-shell/skills/localwp-shell/scripts/wplocal plugin list
bash plugins/localwp-shell/skills/localwp-shell/scripts/wplocal search-replace 'old.test' 'new.test'

# PHP / Composer / MySQL
bash plugins/localwp-shell/skills/localwp-shell/scripts/localwpshell php -v
bash plugins/localwp-shell/skills/localwp-shell/scripts/localwpshell composer install
bash plugins/localwp-shell/skills/localwp-shell/scripts/localwpshell mysql -e "SHOW DATABASES;"
```

## Install

```bash
amskills install localwp-shell
```

The skill triggers automatically when Claude detects you're working inside a LocalWP site directory.

## Troubleshooting

If commands still hit the system PHP after installing, make sure your working directory is inside the LocalWP site (or a symlink that resolves to one). Run `bash plugins/localwp-shell/skills/localwp-shell/scripts/localwpshell php -v` to verify the correct binary is being picked up.
