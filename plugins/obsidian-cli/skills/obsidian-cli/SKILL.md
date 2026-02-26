---
name: obsidian-cli
description: |
  Interacts with Obsidian vaults from the terminal using the official Obsidian CLI (v1.12+).
  Manages notes, tasks, properties, daily notes, bases, tags, search, vault health,
  file operations, and Obsidian automation. Triggers on "obsidian", "vault", "daily note",
  "obsidian task", "obsidian search", "obsidian property", "note in obsidian", "obsidian base",
  or any request involving Obsidian vault interaction from the command line.
---

# Obsidian CLI

Control Obsidian from the terminal. The CLI communicates with the running Obsidian app, enabling file operations, task management, property editing, search, vault analysis, and more — all without reading full file contents into context.

## Prerequisites

- Obsidian 1.12+ with CLI support
- CLI enabled in **Settings > General > Command line interface**
- Obsidian app must be running (first CLI command launches it if needed)
- PATH configured (macOS: `/Applications/Obsidian.app/Contents/MacOS` in PATH)

## Key Concepts

The CLI uses `key=value` parameters and bare-word boolean flags (no `--` prefix). Append `--copy` to any command to copy output to clipboard.

```bash
obsidian vault=Notes daily                    # vault= must be first param
obsidian read file=Recipe                     # target by wikilink name
obsidian read path="Templates/Recipe.md"      # target by exact path
obsidian read                                 # no file param = active file
```

## Common Workflows

### Daily Notes as Inbox

```bash
obsidian daily                                          # Open today's daily note
obsidian daily:read                                     # Read daily note contents
obsidian daily:append content="- [ ] Buy groceries" silent  # Add task silently
obsidian daily:prepend content="## Morning Ideas" silent    # Prepend after frontmatter
```

Example `daily:read` output:
```
---
date: 2026-02-12
---
## Tasks
- [ ] Buy groceries
- [x] Review PR
```

### Task Management (No File Reading Required)

```bash
obsidian tasks daily                    # List tasks from daily note
obsidian tasks daily todo               # Incomplete daily tasks only
obsidian tasks daily done               # Completed daily tasks
obsidian tasks all                      # All tasks in vault
obsidian tasks file=Projects todo       # Incomplete tasks in specific file
obsidian tasks verbose                  # Tasks grouped by file with line numbers

# Toggle/update tasks by reference
obsidian task daily line=3 toggle       # Toggle daily note task
obsidian task ref="Recipe.md:8" done    # Mark specific task done
obsidian task ref="Recipe.md:8" todo    # Mark as incomplete
obsidian task file=Plan line=5 status=- # Set custom status [-]
```

Example `tasks daily todo` output:
```
- [ ] Buy groceries (line 5)
- [ ] Review PR (line 8)
- [ ] Call dentist (line 12)
```

### Properties (No File Reading Required)

Set, read, and remove frontmatter properties without loading file contents:

```bash
obsidian property:set name=status value=done file=ProjectX
obsidian property:set name=priority value=high path="Projects/Sprint.md"
obsidian property:read name=status file=ProjectX
obsidian property:remove name=draft file=Article
obsidian properties file=Recipe                         # List all properties
obsidian properties all counts sort=count               # Vault-wide property stats
```

### File Operations (Preserves Backlinks)

Always prefer CLI file operations over `mv`/`cp` — the CLI updates all backlinks automatically:

```bash
obsidian create name="New Note" content="# Hello" silent
obsidian create name="From Template" template=Meeting silent
obsidian move file=OldName to="Archive/OldName.md"      # Rename/move, updates backlinks
obsidian delete file=Scratch                             # Moves to trash
obsidian append file=Log content="Entry added"           # Append to specific file
obsidian open file=Plan newtab                           # Open in new tab
```

### Search and Discovery

```bash
obsidian search query="meeting notes" matches            # Search with context
obsidian search query="TODO" path=Projects limit=10      # Scoped search
obsidian tags all counts sort=count                      # All tags with counts
obsidian tag name=quick verbose                          # Files with specific tag
```

### Bases (Structured Data Queries)

```bash
obsidian bases                                           # List all .base files
obsidian base:query file=Bookmarks format=json           # Query base as JSON
obsidian base:query file=Bookmarks view=Unread format=md # Query specific view
obsidian base:create name="New Item" content="..." silent
```

### Vault Health Analysis

```bash
obsidian orphans                        # Files with no incoming links
obsidian deadends                       # Files with no outgoing links
obsidian unresolved verbose             # Unresolved links with source files
obsidian backlinks file=Note counts     # Backlinks to a specific file
obsidian links file=Note                # Outgoing links from a file
```

### File History and Versioning

```bash
obsidian diff file=Recipe               # List all versions
obsidian diff file=Recipe from=1        # Compare latest version to current
obsidian diff file=Recipe from=2 to=1   # Compare two versions
obsidian history:read file=Recipe version=3  # Read specific version
obsidian history:restore file=Recipe version=5  # Restore a version
```

### Developer / Advanced

```bash
obsidian eval code="app.vault.getFiles().length"  # Run JS in Obsidian context
obsidian dev:screenshot path=screenshot.png        # Take screenshot
obsidian dev:console level=error                   # Show JS errors
obsidian plugin:reload id=my-plugin                # Reload plugin
```

## Important Guidelines

1. **Prefer CLI over file I/O.** Property edits, task toggles, file moves, and appends via CLI are more context-efficient than reading and editing files directly. This saves tokens and preserves vault integrity.

2. **Use `silent` flag** when making changes that do not need to open the file in Obsidian (e.g., batch task updates, property changes from scripts).

3. **Never use `mv`/`cp`/`rm` on vault files.** Always use `obsidian move`, `obsidian create`, `obsidian delete` to preserve backlinks and let Obsidian handle link updates.

4. **Use `obsidian help <command>`** to discover parameters for any command not covered here. Run `obsidian help` for the full command list.

5. **Batch operations** may be slow when run sequentially. For bulk property changes or task updates, consider using `obsidian eval` with JavaScript for better performance.

6. **Vault targeting:** When the terminal's cwd is inside a vault, that vault is used automatically. Otherwise, use `vault=<name>` as the first parameter.

## Batch Operations Workflow

For multi-step vault changes (reorganizing files, bulk property updates, etc.):

```
Progress:
- [ ] Step 1: Search/list to identify target files
- [ ] Step 2: Preview scope (e.g., obsidian search query="..." total)
- [ ] Step 3: Apply changes with silent flag
- [ ] Step 4: Verify results (re-run search or list)
```

## Troubleshooting

- **"Obsidian is not running"**: Start Obsidian.app first, or run any CLI command to launch it automatically.
- **"No vault found"**: Either `cd` into a vault directory or pass `vault=<name>` as the first parameter. Use `obsidian vaults verbose` to list known vaults with paths.
- **"File not found"**: The `file=` param uses wikilink resolution (case-insensitive, partial match). Try `obsidian search query="partial name"` to find the correct name, or use `path=` for exact paths.
- **Command not recognized**: Run `obsidian help` to verify CLI is installed. Check PATH includes `/Applications/Obsidian.app/Contents/MacOS`.

## Full Command Reference

For the complete list of 80+ commands with all parameters and flags, read `references/command-reference.md` (has a table of contents at the top for quick navigation).
