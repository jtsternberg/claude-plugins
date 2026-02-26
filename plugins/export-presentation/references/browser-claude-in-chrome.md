# Claude in Chrome MCP

Browser automation commands for exporting slides via the Claude in Chrome MCP server.

## Setup

Verify the MCP tools are available by checking for `mcp__claude-in-chrome__navigate` in the tool list.

## Viewport

Resize the browser window to 1920x1080:

```
mcp__claude-in-chrome__resize_window({ width: 1920, height: 1080 })
```

## Commands

### Open the presentation

Create a new tab and navigate to the URL:

```
mcp__claude-in-chrome__tabs_create_mcp({ url: "<url>" })
```

Or navigate in the current tab:

```
mcp__claude-in-chrome__navigate({ url: "<url>" })
```

Wait 2 seconds after navigation for fonts and JavaScript to load.

### Screenshot a slide

Use the `computer` tool to take a screenshot:

```
mcp__claude-in-chrome__computer({ action: "screenshot" })
```

Save the returned screenshot data to a file. The screenshot captures the current viewport.

Alternatively, use `read_page` with screenshot mode if available.

### Advance to next slide

Send an ArrowRight keypress:

```
mcp__claude-in-chrome__computer({ action: "key", text: "ArrowRight" })
```

Wait 0.5 seconds after the keypress for the CSS transition to complete.

## Full Export Flow

1. Get current tabs context: `mcp__claude-in-chrome__tabs_context_mcp()`
2. Create a new tab with the presentation URL
3. Resize window to 1920x1080
4. Wait 2 seconds for page load
5. For each slide:
   - Take a screenshot and save to `screenshots/slide-NN.png`
   - Press ArrowRight to advance
   - Wait 0.5 seconds
6. Take the final slide screenshot (no ArrowRight after last slide)

## Notes

- Claude in Chrome uses the user's actual browser — the presentation renders with all installed fonts and extensions
- Screenshots are taken at the browser's current DPI (may be 2x on Retina displays)
- Avoid triggering JavaScript alerts or dialogs during export — they block the extension
- The tab remains open after export; close it manually if desired
