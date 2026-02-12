# Git Commits Plugin

Create git commits with AI-generated commit messages.

## Installation

```bash
# Add the marketplace (if not already added)
/plugin marketplace add jtsternberg/claude-plugins

# Install the plugin
/plugin install git-commits@jtsternberg
```

## Description

Provides commands for creating commits from staged or unstaged files with automatically generated conventional commit messages.

## Commands

### `/commit-staged`

Create a commit from currently staged files.

```
/commit-staged [optional commit message]
```

If you provide a commit message, it will be used. Otherwise, Claude analyzes the staged changes and generates an appropriate conventional commit message.

**Example:**
```
/commit-staged
```

### `/commit-unstaged`

Stage all unstaged files and create a commit.

```
/commit-unstaged [optional commit message]
```

Automatically stages all modified files, then creates a commit with either your provided message or an AI-generated one.

**Example:**
```
/commit-unstaged fix: resolve navigation bug
```

## How It Works

1. Reviews the changes (staged or unstaged)
2. Generates a conventional commit message following best practices
3. Creates the commit with proper formatting

## Message Format

Generated messages follow the [Conventional Commits](https://www.conventionalcommits.org/) format:

```
<type>: <description>

[optional body]
```

Common types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `style`
