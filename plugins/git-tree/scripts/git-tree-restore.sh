#!/bin/bash
#
# Restore main repo after a git-tree-swap operation
#
# Usage: git-tree-restore.sh [--repo <path>] [--dry-run]
#
# This script:
#   1. Validates swap state exists
#   2. Updates worktree's .git file to point to restored main repo
#   3. Updates dependency symlinks to point to restored main repo
#   4. Removes symlink at original repo location
#   5. Moves {repo-name}-main back to original location
#   6. Runs bin/after-swap.sh hook if it exists
#

set -e
set -o pipefail

# Track state for cleanup (restore is inherently recovery, so minimal cleanup needed)
SYMLINK_REMOVED=""

cleanup() {
	echo "Error occurred during restore..."
	# If we removed the symlink but haven't moved the repo back, recreate symlink
	if [[ -n "$SYMLINK_REMOVED" && ! -e "$REPO_PATH" && -d "$MAIN_STASH_PATH" ]]; then
		echo "Recreating symlink to preserve access..."
		ln -s "$WORKTREE_NAME" "$REPO_PATH"
	fi
}
trap cleanup ERR

# Portable sed in-place edit (works on both macOS and Linux)
sed_inplace() {
	local file="$1"
	local pattern="$2"
	local tmp="${file}.tmp.$$"
	sed "$pattern" "$file" > "$tmp" && mv "$tmp" "$file"
}

# Parse command line arguments
REPO_PATH=""
DRY_RUN=false

while [[ $# -gt 0 ]]; do
	case $1 in
		--repo)
			REPO_PATH="$2"
			shift 2
			;;
		--dry-run)
			DRY_RUN=true
			shift
			;;
		-h|--help)
			echo "Usage: $0 [--repo <path>] [--dry-run]"
			echo ""
			echo "Restore main repo after a git-tree-swap operation."
			echo ""
			echo "Arguments:"
			echo "  --repo <path>  Optional. Path to repo symlink (defaults to current directory)"
			echo "  --dry-run      Optional. Show what would be done without making changes"
			exit 0
			;;
		*)
			echo "Error: Unknown argument $1"
			exit 1
			;;
	esac
done

# Default to current directory if not specified
if [[ -z "$REPO_PATH" ]]; then
	REPO_PATH=$(pwd)
fi

# Resolve to absolute path (but don't follow symlink yet)
PARENT_DIR=$(cd "$(dirname "$REPO_PATH")" && pwd)
REPO_NAME=$(basename "$REPO_PATH")
REPO_PATH="${PARENT_DIR}/${REPO_NAME}"

# Validate swap state: repo path should be a symlink
if [[ ! -L "$REPO_PATH" ]]; then
	echo "Error: $REPO_PATH is not a symlink"
	echo "No swap appears to be active"
	exit 1
fi

# Get the worktree that's currently symlinked
WORKTREE_NAME=$(readlink "$REPO_PATH")
WORKTREE_PATH="${PARENT_DIR}/${WORKTREE_NAME}"

# Validate worktree exists
if [[ ! -d "$WORKTREE_PATH" ]]; then
	echo "Error: Symlink target $WORKTREE_PATH does not exist"
	exit 1
fi

# Validate stashed main repo exists
MAIN_STASH_NAME="${REPO_NAME}-main"
MAIN_STASH_PATH="${PARENT_DIR}/${MAIN_STASH_NAME}"

if [[ ! -d "$MAIN_STASH_PATH" ]]; then
	echo "Error: Stashed main repo not found at $MAIN_STASH_PATH"
	exit 1
fi

# Validate stashed location is actually the main repo (has .git directory)
if [[ ! -d "$MAIN_STASH_PATH/.git" ]]; then
	echo "Error: $MAIN_STASH_PATH does not appear to be the main repository"
	exit 1
fi

# Dry run output
if [[ "$DRY_RUN" == true ]]; then
	echo "Dry run - would perform:"
	echo ""
	echo "1. Update worktree .git file:"
	echo "   Replace /${MAIN_STASH_NAME}/ with /${REPO_NAME}/"
	echo ""
	echo "2. Update dependency symlinks in worktree:"
	for item in vendor node_modules .env; do
		if [[ -L "$WORKTREE_PATH/$item" ]]; then
			echo "   - $item"
		fi
	done
	echo ""
	echo "3. Remove symlink: $REPO_NAME"
	echo ""
	echo "4. Move main repo back:"
	echo "   $MAIN_STASH_NAME → $REPO_NAME"
	echo ""
	if [[ -x "$WORKTREE_PATH/bin/after-swap.sh" ]]; then
		echo "5. Run after-swap hook in worktree"
	fi
	if [[ -x "$MAIN_STASH_PATH/bin/after-swap.sh" ]]; then
		echo "6. Run after-swap hook in main repo"
	fi
	exit 0
fi

echo "Restoring main repo from swap state..."
echo ""

# Step 1: Update worktree's .git file to point back to original location
echo "Updating worktree .git file..."
WORKTREE_GIT_FILE="$WORKTREE_PATH/.git"
if [[ -f "$WORKTREE_GIT_FILE" ]]; then
	sed_inplace "$WORKTREE_GIT_FILE" "s|/${MAIN_STASH_NAME}/|/${REPO_NAME}/|g"
fi

# Step 2: Update dependency symlinks in worktree
echo "Updating dependency symlinks..."
SYMLINKS_UPDATED=0

for item in vendor node_modules .env; do
	LINK_PATH="$WORKTREE_PATH/$item"
	if [[ -L "$LINK_PATH" ]]; then
		# Get current target
		CURRENT_TARGET=$(readlink "$LINK_PATH")
		# Replace stash name with original repo name
		NEW_TARGET="${CURRENT_TARGET//$MAIN_STASH_NAME/$REPO_NAME}"
		if [[ "$CURRENT_TARGET" != "$NEW_TARGET" ]]; then
			rm "$LINK_PATH"
			ln -s "$NEW_TARGET" "$LINK_PATH"
			echo "  Updated: $item → $NEW_TARGET"
			SYMLINKS_UPDATED=$((SYMLINKS_UPDATED + 1))
		fi
	fi
done

if [[ $SYMLINKS_UPDATED -eq 0 ]]; then
	echo "  No dependency symlinks to update"
fi

# Step 3: Remove symlink
echo "Removing symlink: $REPO_NAME"
rm "$REPO_PATH"
SYMLINK_REMOVED="true"

# Step 4: Move stashed main repo back to original location
echo "Restoring main repo: $MAIN_STASH_NAME → $REPO_NAME"
mv "$MAIN_STASH_PATH" "$REPO_PATH"

# Clear cleanup trap since we succeeded
SYMLINK_REMOVED=""
trap - ERR

# Step 5: Run after-swap hook in worktree if it exists
HOOK_PATH="$WORKTREE_PATH/bin/after-swap.sh"
if [[ -x "$HOOK_PATH" ]]; then
	echo ""
	echo "Running after-swap hook in worktree..."
	(cd "$WORKTREE_PATH" && ./bin/after-swap.sh)
fi

# Also run hook in main repo if it exists
MAIN_HOOK_PATH="$REPO_PATH/bin/after-swap.sh"
if [[ -x "$MAIN_HOOK_PATH" ]]; then
	echo ""
	echo "Running after-swap hook in main repo..."
	(cd "$REPO_PATH" && ./bin/after-swap.sh)
fi

echo ""
echo "Restore complete!"
echo ""
echo "Main repo restored to: $REPO_PATH"
echo "Worktree remains at:   $WORKTREE_PATH"
