# Git Commits Plugin

Create git commits with AI-generated commit messages.

## Installation

```bash
# Add the marketplace (if not already added)
claude plugin marketplace add jtsternberg/claude-plugins

# Install the plugin
claude plugin install git-commits@jtsternberg
```

`git-commits` is not offered in the Codex-native plugin catalog. From this repository checkout, install one or both self-contained skills instead:

```bash
bash scripts/install-standalone-skill.sh git-commits:commit-staged
bash scripts/install-standalone-skill.sh git-commits:commit-unstaged
```

See the [standalone Codex skill guide](../../docs/codex/standalone-skills.md) for install scopes, copy mode, updates, and uninstalling.

## Description

Provides skills for creating commits from staged or unstaged files with automatically generated conventional commit messages. Claude Code invokes the plugin skills as `/git-commits:commit-staged` and `/git-commits:commit-unstaged`; standalone Codex installs use `$commit-staged` and `$commit-unstaged`.

## Skills

### `commit-staged`

Create a commit from currently staged files.

If you provide a commit message in your request, it will be used. Otherwise, the skill analyzes the staged changes and generates an appropriate conventional commit message.

**Example:**
```
Invoke the `commit-staged` skill.
```

### `commit-unstaged`

Review, stage, and commit the intended unstaged changes.

The skill reviews and stages each intended file explicitly, then creates a commit with either your provided message or an AI-generated one.

**Example:**
```
Invoke the `commit-unstaged` skill with the message `fix: resolve navigation bug`.
```

## How It Works

1. Reviews the changes (staged or unstaged)
2. Stages intended files explicitly for the unstaged workflow
3. Generates a conventional commit message following best practices
4. Creates the commit with proper formatting

## Message Format

Generated messages follow the [Conventional Commits](https://www.conventionalcommits.org/) format:

```
<type>: <description>

[optional body]
```

Common types: `feat`, `fix`, `docs`, `chore`, `refactor`, `test`, `style`
