# Git Tree Troubleshooting

## Managing Worktrees

### List Active Worktrees

```bash
git worktree list
```

### Remove a Worktree

```bash
# Option 1: Use git command
git worktree remove gittree-feature-branch

# Option 2: Delete directory and prune
rm -rf gittree-feature-branch
git worktree prune
```

## Common Issues

### Dependencies Not Found

Check symlinks exist:
```bash
ls -la vendor node_modules .env
```

Recreate manually if needed:
```bash
ln -s ../main-repo/vendor vendor
ln -s ../main-repo/node_modules node_modules
ln -s ../main-repo/.env .env
```

### Different Dependencies Needed

Remove symlinks and install separately:
```bash
rm vendor node_modules
composer install
npm install
```

### Branch Already Checked Out

If you get "fatal: 'branch' is already checked out":
```bash
# List worktrees to find where it's checked out
git worktree list

# Remove the existing worktree first
git worktree remove <path-to-existing-worktree>
```

### Broken Symlinks

If symlinks point to non-existent targets:
```bash
# Check symlink targets
ls -la vendor node_modules .env

# Remove and recreate
rm vendor && ln -s ../main-repo/vendor vendor
```

### Pre-commit Hooks Failing

Hooks that invoke containers (Docker, Sail, etc.) may fail in worktrees due to different working directory context.

**Workarounds:**
- Run tests manually before committing
- Commit from the main repo instead
- Add worktree detection to hooks (check if `.git` is a file vs directory)

### Containerized Environments

Worktrees share the main repo's container context:
- **Database state is shared** across all worktrees
- **Containers must be started from main repo** (or have proper path mapping)
- **Asset builds** may need to run separately per worktree

### UI Testing with Web Servers

Web servers (LocalWP, nginx, Apache) serve from a configured document root, typically your main repo. Worktrees won't be served automatically.

**Current workaround:** Remove the worktree and checkout the branch normally in the main repo:
```bash
# Remove the worktree (deletes the worktree directory)
git worktree remove gittree-feature-branch

# Checkout the branch in the main repo where your web server serves from
cd /path/to/main-repo
git checkout feature-branch
```

This abandons the worktree approach for this branch, switching to a normal branch checkout so your web server can serve it.
