#!/bin/bash
#
# Swap a git worktree into the main repo location for web server testing
#
# Usage: git-tree-swap.sh <branch-name> [--repo <path>] [--dry-run]
#
# This script:
#   1. Moves main repo to {repo-name}-main
#   2. Creates symlink from worktree to original repo location
#   3. Updates worktree's .git file to point to moved main repo
#   4. Updates dependency symlinks to point to moved main repo
#   5. Runs bin/after-swap.sh hook if it exists
#
# To restore: use git-tree-restore.sh
#

set -e
set -o pipefail

# Track state for cleanup
MAIN_MOVED=""
SYMLINK_CREATED=""

cleanup() {
	echo "Error occurred, attempting to restore state..."
	# Remove symlink if created
	if [[ -n "$SYMLINK_CREATED" && -L "$SYMLINK_CREATED" ]]; then
		rm -f "$SYMLINK_CREATED"
	fi
	# Move main repo back if moved
	if [[ -n "$MAIN_MOVED" && -d "$MAIN_MOVED" && ! -e "$REPO_PATH" ]]; then
		mv "$MAIN_MOVED" "$REPO_PATH"
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
BRANCH=""
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
			echo "Usage: $0 <branch-name> [--repo <path>] [--dry-run]"
			echo ""
			echo "Swap a git worktree into the main repo location for web server testing."
			echo ""
			echo "Arguments:"
			echo "  branch-name    Required. The branch/worktree to swap in"
			echo "  --repo <path>  Optional. Path to main repository (defaults to current directory)"
			echo "  --dry-run      Optional. Show what would be done without making changes"
			exit 0
			;;
		*)
			if [[ -z "$BRANCH" ]]; then
				BRANCH="$1"
			else
				echo "Error: Unknown argument $1"
				exit 1
			fi
			shift
			;;
	esac
done

# Validate required arguments
if [[ -z "$BRANCH" ]]; then
	echo "Error: Branch name is required"
	echo "Usage: $0 <branch-name> [--repo <path>] [--dry-run]"
	exit 1
fi

# Default to current directory if not specified
if [[ -z "$REPO_PATH" ]]; then
	REPO_PATH=$(pwd)
fi

# Get absolute path
REPO_PATH=$(cd "$REPO_PATH" && pwd)

# Check if already in swapped state (repo path is a symlink)
if [[ -L "$REPO_PATH" ]]; then
	echo "Error: $REPO_PATH is already a symlink (swap already active?)"
	echo "Run git-tree-restore.sh first to restore the main repo"
	exit 1
fi

# Ensure we're in a git repo and it's the main clone (not a worktree)
if ! git -C "$REPO_PATH" rev-parse --git-dir > /dev/null 2>&1; then
	echo "Error: $REPO_PATH is not a git repository"
	exit 1
fi

# Check if this is the main repo (has .git directory) vs worktree (has .git file)
if [[ ! -d "$REPO_PATH/.git" ]]; then
	echo "Error: $REPO_PATH appears to be a worktree, not the main repository"
	echo "Run this script from the main repository location"
	exit 1
fi

# Get the repository name and parent directory
REPO_NAME=$(basename "$REPO_PATH")
PARENT_DIR=$(dirname "$REPO_PATH")

# Determine worktree path
WORKTREE_NAME="gittree-${BRANCH}"
WORKTREE_PATH="${PARENT_DIR}/${WORKTREE_NAME}"

# Validate worktree exists
if [[ ! -d "$WORKTREE_PATH" ]]; then
	echo "Error: Worktree not found at $WORKTREE_PATH"
	echo "Create it first with: git-tree.sh $BRANCH"
	exit 1
fi

# Validate it's actually a worktree (has .git file, not directory)
if [[ ! -f "$WORKTREE_PATH/.git" ]]; then
	echo "Error: $WORKTREE_PATH does not appear to be a git worktree"
	exit 1
fi

# Define paths for swap
MAIN_STASH_NAME="${REPO_NAME}-main"
MAIN_STASH_PATH="${PARENT_DIR}/${MAIN_STASH_NAME}"

# Check stash location doesn't already exist
if [[ -e "$MAIN_STASH_PATH" ]]; then
	echo "Error: $MAIN_STASH_PATH already exists"
	echo "A previous swap may not have been restored properly"
	exit 1
fi

# Dry run output
if [[ "$DRY_RUN" == true ]]; then
	echo "Dry run - would perform:"
	echo ""
	echo "1. Move main repo:"
	echo "   $REPO_NAME → $MAIN_STASH_NAME"
	echo ""
	echo "2. Create symlink:"
	echo "   $REPO_NAME → $WORKTREE_NAME"
	echo ""
	echo "3. Update worktree .git file:"
	echo "   Replace /${REPO_NAME}/ with /${MAIN_STASH_NAME}/"
	echo ""
	echo "4. Update dependency symlinks in worktree:"
	for item in vendor node_modules .env; do
		if [[ -L "$WORKTREE_PATH/$item" ]]; then
			echo "   - $item"
		fi
	done
	echo ""
	if [[ -x "$WORKTREE_PATH/bin/after-swap.sh" ]]; then
		echo "5. Run after-swap hook: $WORKTREE_PATH/bin/after-swap.sh"
	fi
	echo ""
	echo "To restore: git-tree-restore.sh --repo $REPO_PATH"
	exit 0
fi

echo "Swapping worktree '$BRANCH' into main repo location..."
echo ""

# Step 1: Move main repo to stash location
echo "Moving main repo: $REPO_NAME → $MAIN_STASH_NAME"
mv "$REPO_PATH" "$MAIN_STASH_PATH"
MAIN_MOVED="$MAIN_STASH_PATH"

# Step 2: Create symlink from worktree to original repo location
echo "Creating symlink: $REPO_NAME → $WORKTREE_NAME"
ln -s "$WORKTREE_NAME" "$REPO_PATH"
SYMLINK_CREATED="$REPO_PATH"

# Step 3: Update worktree's .git file to point to moved main repo
echo "Updating worktree .git file..."
WORKTREE_GIT_FILE="$WORKTREE_PATH/.git"
if [[ -f "$WORKTREE_GIT_FILE" ]]; then
	sed_inplace "$WORKTREE_GIT_FILE" "s|/${REPO_NAME}/|/${MAIN_STASH_NAME}/|g"
fi

# Step 4: Update dependency symlinks in worktree
echo "Updating dependency symlinks..."
SYMLINKS_UPDATED=0

for item in vendor node_modules .env; do
	LINK_PATH="$WORKTREE_PATH/$item"
	if [[ -L "$LINK_PATH" ]]; then
		# Get current target
		CURRENT_TARGET=$(readlink "$LINK_PATH")
		# Replace old repo name with stash name
		NEW_TARGET="${CURRENT_TARGET//$REPO_NAME/$MAIN_STASH_NAME}"
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

# Clear cleanup trap since we succeeded
MAIN_MOVED=""
SYMLINK_CREATED=""
trap - ERR

# Step 5: Run after-swap hook if it exists
HOOK_PATH="$WORKTREE_PATH/bin/after-swap.sh"
if [[ -x "$HOOK_PATH" ]]; then
	echo ""
	echo "Running after-swap hook..."
	(cd "$WORKTREE_PATH" && ./bin/after-swap.sh)
fi

echo ""
echo "Swap complete!"
echo ""
echo "Web server now serves: $WORKTREE_PATH (via $REPO_PATH symlink)"
echo "Main repo stashed at:  $MAIN_STASH_PATH"
echo ""
echo "To restore: git-tree-restore.sh --repo $REPO_PATH"
