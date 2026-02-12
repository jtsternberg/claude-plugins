# Obsidian CLI Command Reference

Complete reference for all Obsidian CLI commands. Source: [Obsidian Help](https://help.obsidian.md/cli)

## Contents

- [General](#general) - help, version, reload, restart
- [Bases](#bases) - bases, base:views, base:create, base:query
- [Bookmarks](#bookmarks) - bookmarks, bookmark
- [Command Palette](#command-palette) - commands, command, hotkeys, hotkey
- [Daily Notes](#daily-notes) - daily, daily:read, daily:append, daily:prepend
- [File History](#file-history) - diff, history, history:list, history:read, history:restore, history:open
- [Files and Folders](#files-and-folders) - file, files, folder, folders, open, create, read, append, prepend, move, delete
- [Links](#links) - backlinks, links, unresolved, orphans, deadends
- [Outline](#outline) - outline
- [Plugins](#plugins) - plugins, plugin, plugin:enable, plugin:disable, plugin:install, plugin:uninstall, plugin:reload
- [Properties](#properties) - aliases, properties, property:set, property:remove, property:read
- [Publish](#publish) - publish:site, publish:list, publish:status, publish:add, publish:remove, publish:open
- [Random Notes](#random-notes) - random, random:read
- [Search](#search) - search, search:open
- [Sync](#sync) - sync, sync:status, sync:history, sync:read, sync:restore, sync:open, sync:deleted
- [Tags](#tags) - tags, tag
- [Tasks](#tasks) - tasks, task
- [Templates](#templates) - templates, template:read, template:insert
- [Themes and Snippets](#themes-and-snippets) - themes, theme, theme:set, theme:install, theme:uninstall, snippets, snippet:enable, snippet:disable
- [Unique Notes](#unique-notes) - unique
- [Vault](#vault) - vault, vaults, vault:open
- [Web Viewer](#web-viewer) - web
- [Word Count](#word-count) - wordcount
- [Workspace](#workspace) - workspace, workspaces, workspace:save, workspace:load, workspace:delete, tabs, tab:open, recents
- [Developer Commands](#developer-commands) - devtools, dev:debug, dev:cdp, dev:errors, dev:screenshot, dev:console, dev:css, dev:dom, dev:mobile, eval

---

## General

### `help`
Show list of all available commands.

### `version`
Show Obsidian version.

### `reload`
Reload the app window.

### `restart`
Restart the app.

---

## Bases

### `bases`
List all `.base` files in the vault.

### `base:views`
List views in the current base file.

### `base:create`
Create a new item in the current base view.

```
name=<name>        # file name
content=<text>     # initial content
silent             # create without opening
newtab             # open in new tab
```

### `base:query`
Query a base and return results.

```
file=<name>                    # base file name
path=<path>                    # base file path
view=<name>                    # view name to query
format=json|csv|tsv|md|paths   # output format (default: json)
```

---

## Bookmarks

### `bookmarks`
List bookmarks.

```
total              # return bookmark count
verbose            # include bookmark types
```

### `bookmark`
Add a bookmark.

```
file=<path>        # file to bookmark
subpath=<subpath>  # subpath (heading or block) within file
folder=<path>      # folder to bookmark
search=<query>     # search query to bookmark
url=<url>          # URL to bookmark
title=<title>      # bookmark title
```

---

## Command Palette

### `commands`
List available command IDs.

```
filter=<prefix>    # filter by ID prefix
```

### `command`
Execute an Obsidian command.

```
id=<command-id>    # (required) command ID to execute
```

### `hotkeys`
List hotkeys.

```
total              # return hotkey count
all                # include commands without hotkeys
verbose            # show if hotkey is custom
```

### `hotkey`
Get hotkey for a command.

```
id=<command-id>    # (required) command ID
verbose            # show if custom or default
```

---

## Daily Notes

### `daily`
Open daily note.

```
paneType=tab|split|window    # pane type to open in
silent             # return path without opening
```

### `daily:read`
Read daily note contents.

### `daily:append`
Append content to daily note.

```
content=<text>     # (required) content to append
paneType=tab|split|window    # pane type to open in
inline             # append without newline
silent             # do not open file
```

### `daily:prepend`
Prepend content to daily note (after frontmatter).

```
content=<text>     # (required) content to prepend
paneType=tab|split|window    # pane type to open in
inline             # prepend without newline
silent             # do not open file
```

---

## File History

### `diff`
List or compare versions from File Recovery and Sync.

```
file=<name>          # file name
path=<path>          # file path
from=<n>             # version number to diff from
to=<n>               # version number to diff to
filter=local|sync    # filter by version source
```

### `history`
List versions from File Recovery only.

```
file=<name>        # file name
path=<path>        # file path
```

### `history:list`
List all files with local history.

### `history:read`
Read a local history version.

```
file=<name>        # file name
path=<path>        # file path
version=<n>        # version number (default: 1)
```

### `history:restore`
Restore a local history version.

```
file=<name>        # file name
path=<path>        # file path
version=<n>        # (required) version number
```

### `history:open`
Open file recovery.

```
file=<name>        # file name
path=<path>        # file path
```

---

## Files and Folders

### `file`
Show file info (default: active file).

```
file=<name>        # file name
path=<path>        # file path
```

### `files`
List files in the vault.

```
folder=<path>      # filter by folder
ext=<extension>    # filter by extension
total              # return file count
```

### `folder`
Show folder info.

```
path=<path>              # (required) folder path
info=files|folders|size  # return specific info only
```

### `folders`
List folders in the vault.

```
folder=<path>      # filter by parent folder
total              # return folder count
```

### `open`
Open a file.

```
file=<name>        # file name
path=<path>        # file path
newtab             # open in new tab
```

### `create`
Create or overwrite a file.

```
name=<name>        # file name
path=<path>        # file path
content=<text>     # initial content
template=<name>    # template to use
overwrite          # overwrite if file exists
silent             # create without opening
newtab             # open in new tab
```

### `read`
Read file contents (default: active file).

```
file=<name>        # file name
path=<path>        # file path
```

### `append`
Append content to a file (default: active file).

```
file=<name>        # file name
path=<path>        # file path
content=<text>     # (required) content to append
inline             # append without newline
```

### `prepend`
Prepend content after frontmatter (default: active file).

```
file=<name>        # file name
path=<path>        # file path
content=<text>     # (required) content to prepend
inline             # prepend without newline
```

### `move`
Move or rename a file (default: active file). Updates all backlinks.

```
file=<name>        # file name
path=<path>        # file path
to=<path>          # (required) destination folder or path
```

### `delete`
Delete a file (default: active file, trash by default).

```
file=<name>        # file name
path=<path>        # file path
permanent          # skip trash, delete permanently
```

---

## Links

### `backlinks`
List backlinks to a file (default: active file).

```
file=<name>        # target file name
path=<path>        # target file path
counts             # include link counts
total              # return backlink count
```

### `links`
List outgoing links from a file (default: active file).

```
file=<name>        # file name
path=<path>        # file path
total              # return link count
```

### `unresolved`
List unresolved links in vault.

```
total              # return unresolved link count
counts             # include link counts
verbose            # include source files
```

### `orphans`
List files with no incoming links.

```
total              # return orphan count
all                # include non-markdown files
```

### `deadends`
List files with no outgoing links.

```
total              # return dead-end count
all                # include non-markdown files
```

---

## Outline

### `outline`
Show headings for the current file.

```
file=<name>        # file name
path=<path>        # file path
format=tree|md     # output format (default: tree)
total              # return heading count
```

---

## Plugins

### `plugins`
List installed plugins.

```
filter=core|community  # filter by plugin type
versions               # include version numbers
```

### `plugins:enabled`
List enabled plugins.

```
filter=core|community  # filter by plugin type
versions               # include version numbers
```

### `plugins:restrict`
Toggle or check restricted mode.

```
on                 # enable restricted mode
off                # disable restricted mode
```

### `plugin`
Get plugin info.

```
id=<plugin-id>     # (required) plugin ID
```

### `plugin:enable`
Enable a plugin.

```
id=<id>                # (required) plugin ID
filter=core|community  # plugin type
```

### `plugin:disable`
Disable a plugin.

```
id=<id>                # (required) plugin ID
filter=core|community  # plugin type
```

### `plugin:install`
Install a community plugin.

```
id=<id>            # (required) plugin ID
enable             # enable after install
```

### `plugin:uninstall`
Uninstall a community plugin.

```
id=<id>            # (required) plugin ID
```

### `plugin:reload`
Reload a plugin (for developers).

```
id=<id>            # (required) plugin ID
```

---

## Properties

### `aliases`
List aliases (default: active file).

```
file=<name>        # file name
path=<path>        # file path
all                # list all aliases in vault
total              # return alias count
verbose            # include file paths
```

### `properties`
List properties (default: active file).

```
file=<name>        # show properties for file
path=<path>        # show properties for path
name=<name>        # get specific property count
sort=count         # sort by count (default: name)
format=yaml|tsv    # output format (default: yaml)
all                # list all properties in vault
total              # return property count
counts             # include occurrence counts
```

### `property:set`
Set a property on a file (default: active file).

```
name=<name>                                    # (required) property name
value=<value>                                  # (required) property value
type=text|list|number|checkbox|date|datetime   # property type
file=<name>                                    # file name
path=<path>                                    # file path
```

### `property:remove`
Remove a property from a file (default: active file).

```
name=<name>        # (required) property name
file=<name>        # file name
path=<path>        # file path
```

### `property:read`
Read a property value from a file (default: active file).

```
name=<name>        # (required) property name
file=<name>        # file name
path=<path>        # file path
```

---

## Publish

### `publish:site`
Show publish site info (slug, URL).

### `publish:list`
List published files.

```
total              # return published file count
```

### `publish:status`
List publish changes.

```
total              # return change count
new                # show new files only
changed            # show changed files only
deleted            # show deleted files only
```

### `publish:add`
Publish a file or all changed files (default: active file).

```
file=<name>        # file name
path=<path>        # file path
changed            # publish all changed files
```

### `publish:remove`
Unpublish a file (default: active file).

```
file=<name>        # file name
path=<path>        # file path
```

### `publish:open`
Open file on published site (default: active file).

```
file=<name>        # file name
path=<path>        # file path
```

---

## Random Notes

### `random`
Open a random note.

```
folder=<path>      # limit to folder
newtab             # open in new tab
silent             # return path without opening
```

### `random:read`
Read a random note (includes path).

```
folder=<path>      # limit to folder
```

---

## Search

### `search`
Search vault for text.

```
query=<text>       # (required) search query
path=<folder>      # limit to folder
limit=<n>          # max results
format=text|json   # output format (default: text)
total              # return match count
matches            # show match context
case               # case sensitive
```

### `search:open`
Open search view.

```
query=<text>       # initial search query
```

---

## Sync

### `sync`
Pause or resume sync.

```
on                 # resume sync
off                # pause sync
```

### `sync:status`
Show sync status and usage.

### `sync:history`
List sync version history for a file (default: active file).

```
file=<name>        # file name
path=<path>        # file path
total              # return version count
```

### `sync:read`
Read a sync version (default: active file).

```
file=<name>        # file name
path=<path>        # file path
version=<n>        # (required) version number
```

### `sync:restore`
Restore a sync version (default: active file).

```
file=<name>        # file name
path=<path>        # file path
version=<n>        # (required) version number
```

### `sync:open`
Open sync history (default: active file).

```
file=<name>        # file name
path=<path>        # file path
```

### `sync:deleted`
List deleted files in sync.

```
total              # return deleted file count
```

---

## Tags

### `tags`
List tags (default: active file).

```
file=<name>        # file name
path=<path>        # file path
sort=count         # sort by count (default: name)
all                # list all tags in vault
total              # return tag count
counts             # include tag counts
```

### `tag`
Get tag info.

```
name=<tag>         # (required) tag name
total              # return occurrence count
verbose            # include file list and count
```

---

## Tasks

### `tasks`
List tasks (default: active file).

```
file=<name>        # filter by file name
path=<path>        # filter by file path
status="<char>"    # filter by status character
all                # list all tasks in vault
daily              # show tasks from daily note
total              # return task count
done               # show completed tasks
todo               # show incomplete tasks
verbose            # group by file with line numbers
```

### `task`
Show or update a task.

```
ref=<path:line>    # task reference (path:line)
file=<name>        # file name
path=<path>        # file path
line=<n>           # line number
status="<char>"    # set status character
toggle             # toggle task status
daily              # daily note
done               # mark as done
todo               # mark as todo
```

---

## Templates

### `templates`
List templates.

```
total              # return template count
```

### `template:read`
Read template content.

```
name=<template>    # (required) template name
title=<title>      # title for variable resolution
resolve            # resolve template variables
```

### `template:insert`
Insert template into active file.

```
name=<template>    # (required) template name
```

---

## Themes and Snippets

### `themes`
List installed themes.

```
versions           # include version numbers
```

### `theme`
Show active theme or get info.

```
name=<name>        # theme name for details
```

### `theme:set`
Set active theme.

```
name=<name>        # (required) theme name (empty for default)
```

### `theme:install`
Install a community theme.

```
name=<name>        # (required) theme name
enable             # activate after install
```

### `theme:uninstall`
Uninstall a theme.

```
name=<name>        # (required) theme name
```

### `snippets`
List installed CSS snippets.

### `snippets:enabled`
List enabled CSS snippets.

### `snippet:enable`
Enable a CSS snippet.

```
name=<name>        # (required) snippet name
```

### `snippet:disable`
Disable a CSS snippet.

```
name=<name>        # (required) snippet name
```

---

## Unique Notes

### `unique`
Create unique note.

```
name=<text>        # note name
content=<text>     # initial content
paneType=tab|split|window    # pane type to open in
silent             # create without opening
```

---

## Vault

### `vault`
Show vault info.

```
info=name|path|files|folders|size  # return specific info only
```

### `vaults`
List known vaults (desktop only).

```
total              # return vault count
verbose            # include vault paths
```

### `vault:open`
Switch to a different vault (TUI only).

```
name=<name>        # (required) vault name
```

---

## Web Viewer

### `web`
Open URL in web viewer.

```
url=<url>          # (required) URL to open
newtab             # open in new tab
```

---

## Word Count

### `wordcount`
Count words and characters (default: active file).

```
file=<name>        # file name
path=<path>        # file path
words              # return word count only
characters         # return character count only
```

---

## Workspace

### `workspace`
Show workspace tree.

```
ids                # include workspace item IDs
```

### `workspaces`
List saved workspaces.

```
total              # return workspace count
```

### `workspace:save`
Save current layout as workspace.

```
name=<name>        # workspace name
```

### `workspace:load`
Load a saved workspace.

```
name=<name>        # (required) workspace name
```

### `workspace:delete`
Delete a saved workspace.

```
name=<name>        # (required) workspace name
```

### `tabs`
List open tabs.

```
ids                # include tab IDs
```

### `tab:open`
Open a new tab.

```
group=<id>         # tab group ID
file=<path>        # file to open
view=<type>        # view type to open
```

### `recents`
List recently opened files.

```
total              # return recent file count
```

---

## Developer Commands

### `devtools`
Toggle Electron dev tools.

### `dev:debug`
Attach/detach Chrome DevTools Protocol debugger.

```
on                 # attach debugger
off                # detach debugger
```

### `dev:cdp`
Run a Chrome DevTools Protocol command.

```
method=<CDP.method>  # (required) CDP method to call
params=<json>        # method parameters as JSON
```

### `dev:errors`
Show captured JavaScript errors.

```
clear              # clear the error buffer
```

### `dev:screenshot`
Take a screenshot (returns base64 PNG).

```
path=<filename>    # output file path
```

### `dev:console`
Show captured console messages.

```
limit=<n>                        # max messages to show (default 50)
level=log|warn|error|info|debug  # filter by log level
clear                            # clear the console buffer
```

### `dev:css`
Inspect CSS with source locations.

```
selector=<css>     # (required) CSS selector
prop=<name>        # filter by property name
```

### `dev:dom`
Query DOM elements.

```
selector=<css>     # (required) CSS selector
attr=<name>        # get attribute value
css=<prop>         # get CSS property value
total              # return element count
text               # return text content
inner              # return innerHTML instead of outerHTML
all                # return all matches instead of first
```

### `dev:mobile`
Toggle mobile emulation.

```
on                 # enable mobile emulation
off                # disable mobile emulation
```

### `eval`
Execute JavaScript and return result.

```
code=<javascript>  # (required) JavaScript code to execute
```
