# Chrome DevTools MCP

Browser automation commands for exporting slides via the Chrome DevTools Protocol (CDP) MCP server.

## Setup

Verify the MCP tools are available by checking for Chrome DevTools MCP tools in the tool list. Tool names vary by implementation but typically include navigation, input, and screenshot capabilities.

Chrome must be running with remote debugging enabled:

```bash
# macOS
/Applications/Google\ Chrome.app/Contents/MacOS/Google\ Chrome --remote-debugging-port=9222
```

## Commands

The exact MCP tool names depend on the Chrome DevTools MCP server implementation. The CDP operations needed are:

### Set viewport

CDP command: `Emulation.setDeviceMetricsOverride`

```json
{
  "width": 1920,
  "height": 1080,
  "deviceScaleFactor": 1,
  "mobile": false
}
```

Setting `deviceScaleFactor: 1` prevents Retina 2x scaling, keeping screenshot dimensions at exactly 1920x1080.

### Navigate to the presentation

CDP command: `Page.navigate`

```json
{
  "url": "<presentation-url>"
}
```

Wait for `Page.loadEventFired`, then wait an additional 2 seconds for fonts and JavaScript.

### Screenshot a slide

CDP command: `Page.captureScreenshot`

```json
{
  "format": "png",
  "clip": {
    "x": 0,
    "y": 0,
    "width": 1920,
    "height": 1080,
    "scale": 1
  }
}
```

The response contains base64-encoded PNG data. Decode and save to `screenshots/slide-NN.png`.

### Advance to next slide

CDP command: `Input.dispatchKeyEvent`

```json
{
  "type": "keyDown",
  "key": "ArrowRight",
  "code": "ArrowRight",
  "windowsVirtualKeyCode": 39
}
```

Follow with a matching `keyUp` event. Wait 0.5 seconds for the CSS transition.

## Full Export Flow

1. Connect to Chrome's debugging port
2. Set viewport to 1920x1080 with scale factor 1
3. Navigate to the presentation URL
4. Wait 2 seconds for full page load
5. For each slide:
   - Capture screenshot (PNG, clipped to viewport)
   - Decode base64 and save to file
   - Dispatch ArrowRight key event to advance
   - Wait 0.5 seconds for transition
6. Capture final slide (no advance after last)

## Notes

- CDP gives the most control over screenshot parameters (format, clip, scale)
- Setting `deviceScaleFactor: 1` explicitly avoids 2x Retina screenshots
- Chrome must already be running with `--remote-debugging-port` — the MCP server connects to it
- Some CDP MCP implementations bundle navigation + screenshot into higher-level tools; check your server's tool list
