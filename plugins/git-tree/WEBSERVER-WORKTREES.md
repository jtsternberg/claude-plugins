# Web Server Integration with Git Worktrees

Research findings on testing UI from git worktrees with web servers.

## Problem Statement

Web servers serve from a configured document root (e.g., `/path/to/project`). When using git worktrees, each worktree is in a separate directory (e.g., `../gittree-feature-branch/`), but the web server doesn't know about them.

**Goal:** Switch between worktrees for browser testing without reconfiguring the web server each time.

**Constraint:** Solution should be a portable drop-in that works without requiring users to reconfigure their web server.

## Recommended Solution: Hybrid Symlink Swap

This approach temporarily moves the main repo aside and symlinks the worktree into its place. The web server continues serving from the same path, but now gets the worktree content.

### How It Works

1. Move main repo to a temporary location (`project` → `project-main`)
2. Create symlink from worktree to original location (`gittree-feature` → `project`)
3. Update worktree's `.git` file to point to moved main repo
4. Update dependency symlinks (vendor, node_modules) to point to moved main repo
5. Run optional hook for environment-specific setup

### Directory Structure

**Before swap:**
```
parent/
├── project/                    # Main clone (web server serves this)
│   ├── .git/                   # Real git directory
│   ├── vendor/
│   ├── node_modules/
│   └── [code]
└── gittree-feature-branch/     # Worktree
    ├── .git                    # File: gitdir: ../project/.git/worktrees/feature-branch
    ├── vendor -> ../project/vendor
    ├── node_modules -> ../project/node_modules
    └── [code]
```

**After swap:**
```
parent/
├── project -> gittree-feature-branch   # Symlink (web server follows it)
├── project-main/                        # Main clone moved here
│   ├── .git/
│   ├── vendor/
│   ├── node_modules/
│   └── [code]
└── gittree-feature-branch/             # Worktree (unchanged location)
    ├── .git                            # Updated: gitdir: ../project-main/.git/worktrees/...
    ├── vendor -> ../project-main/vendor
    ├── node_modules -> ../project-main/node_modules
    └── [code]
```

### Why This Works

- **Worktree stays in place** → main repo's gitdir pointer unchanged
- **Only update**: worktree's `.git` file + dependency symlinks
- **Web server follows symlink** → serves worktree content
- **Git operations still work** in worktree after `.git` file update
- **No web server config changes required**

### Commands

```bash
# Swap to a worktree for testing
/git-tree swap <branch-name>

# Restore main repo to original location
/git-tree restore
```

### Hook Support

After swap/restore, the script checks for and runs:
- `bin/after-swap.sh` - for cache clearing, asset rebuilding, etc.

Example hook for Laravel:
```bash
#!/bin/bash
php artisan cache:clear
php artisan view:clear
php artisan config:clear
```

### Limitations

- Brief "downtime" during swap (acceptable for local testing)
- Web server must follow symlinks (most local dev servers do by default)
- Only one worktree can be "active" at a time

---

## Alternative: Traditional Symlink Swap

If you can modify your web server config once, this simpler approach works well.

### How It Works

1. Point web server document root at a symlink (e.g., `project/current`)
2. The symlink points to whichever worktree you want to test
3. Swap the symlink to switch between worktrees instantly

### Directory Structure

```
project/
├── main/                         # Main worktree
├── gittree-feature-branch/       # Feature worktree
└── current -> main/              # Symlink (document root)
```

### Atomic Symlink Swap

```bash
ln -s gittree-feature-branch current_tmp && mv -Tf current_tmp current
```

### Web Server Configuration

**Nginx** - Add `$realpath_root` to resolve symlinks properly:

```nginx
server {
    root /var/www/project/current;

    location ~ \.php$ {
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        fastcgi_param DOCUMENT_ROOT $realpath_root;
    }
}
```

**Apache** - Enable symlink following:

```apache
<VirtualHost *:80>
    DocumentRoot /var/www/project/current
    Options FollowSymLinks
</VirtualHost>
```

### When to Use This

- You control web server config
- You want atomic switching (no downtime)
- You're setting up a permanent workflow

---

## Other Approaches Considered

### Multiple Vhosts

Create a vhost per worktree with different hostnames.

**Rejected:** Requires DNS/hosts changes, server reload, doesn't scale.

### Reverse Proxy Path Routing

Route `/worktrees/feature-branch/` to different backends.

**Rejected:** Changes URLs, breaks application routing.

### Docker Volume Mapping

Tools like DevTree, Grove, Sprout provide worktree + Docker integration.

**Use case:** When already using Docker for local development.

---

## References

- [Etsy's Atomic Deploys](https://www.etsy.com/codeascraft/atomic-deploys-at-etsy/)
- [mod_realdoc (Apache)](https://github.com/etsy/mod_realdoc)
- [Nginx symlink caching fix](https://dev.to/ibrarturi/how-to-fix-nginx-symlink-caching-issue-3loe)
- [Git Worktree Documentation](https://git-scm.com/docs/git-worktree)
