# agent-browser CLI

Browser automation commands for exporting slides via the [agent-browser](https://github.com/anthropics/agent-browser) CLI.

## Setup

Verify installation:

```bash
which agent-browser
```

## Viewport

Set the viewport to 1920x1080 before capturing:

```bash
agent-browser resize 1920 1080
```

If `resize` is not available, the default viewport is typically sufficient for full-screen presentations. Screenshots with `--full` capture the entire rendered page.

## Commands

### Open the presentation

```bash
agent-browser open <url>
```

Wait 2 seconds after opening for fonts and JavaScript to load.

### Screenshot a slide

```bash
agent-browser screenshot --full screenshots/slide-01.png
```

The `--full` flag captures the full viewport. Screenshots are saved as PNG.

### Advance to next slide

```bash
agent-browser press ArrowRight
```

Wait 0.5 seconds after pressing for the CSS transition to complete before taking the next screenshot.

## Full Export Loop

```bash
# Create output directory
mkdir -p screenshots

# Screenshot first slide (already visible after open)
agent-browser screenshot --full screenshots/slide-01.png

# Advance and screenshot remaining slides
for i in $(seq 2 $SLIDE_COUNT); do
  agent-browser press ArrowRight
  sleep 0.5
  agent-browser screenshot --full screenshots/slide-$(printf '%02d' $i).png
done
```

## Notes

- `agent-browser` runs headless — no visible browser window
- Each command is a separate CLI invocation (stateful session)
- The `sleep 0.5` accounts for the slide deck's `transition: opacity 0.5s ease`
