# Slides Presentation Plugin

Create self-contained HTML slide presentations from talk prompts, outlines, or content descriptions.

## Installation

```bash
# Add the marketplace (if not already added)
/plugin marketplace add jtsternberg/claude-plugins

# Install the plugin
/plugin install slides-presentation@jtsternberg
```

## Requirements

**Core (no external dependencies):** The skill generates pure HTML/CSS/JS presentations that work in any browser. No build tools, frameworks, or API keys needed for basic use.

**Optional — AI-generated illustrations:**

| Requirement | What it's for | How to get it |
|-------------|---------------|---------------|
| `compound-engineering:gemini-imagegen` skill | Generates realistic images for slides (people, objects, scenes) | Install the [compound-engineering](https://github.com/kiwicopple/compound-engineering) plugin |
| `GEMINI_API_KEY` environment variable | Authenticates with Google's Gemini API | Get a key from [Google AI Studio](https://aistudio.google.com/apikey) |

The skill prefers `gemini-imagegen` but will use any image generation skill available in your environment. Without any image generation skill, you can still build full presentations using SVG/CSS for diagrams and visuals.

## Description

Builds browser-based slide decks as single HTML files — no dependencies, no build step. Supports dark/light themes, SVG diagrams, terminal mocks, two-column layouts, and AI-generated illustrations via Gemini.

## Usage

The skill triggers when you:
- "Create a presentation about X"
- "Make slides for my talk"
- "Build a slide deck"
- Ask for talk slides or presentation help

## How It Works

1. **Gather Requirements** — Topic, slide count, visual style, existing materials
2. **Plan the Deck** — Outline each slide with title, bullets, and visual elements
3. **Build** — Copy the HTML template, customize theme and content
4. **Illustrate** — Generate images via Gemini for complex visuals; use SVG/CSS for diagrams
5. **Validate** — Run `scripts/validate-presentation.sh` to catch issues, then visual review

## Features

- Fluid layout with `rem` units — scales with browser zoom
- Keyboard navigation (arrows, space, number keys, Home/End, F for fullscreen)
- Touch/swipe support
- Progress bar and slide counter
- Customizable CSS theme variables
- Terminal mocks, code blocks, flow diagrams, before/after comparisons

## Utility Scripts

- **`scripts/validate-presentation.sh <file>`** — Checks for unreplaced placeholders, slide numbering gaps, counter mismatches, and broken image paths
- **`scripts/new-presentation.sh <title> [output-dir]`** — Scaffolds a new presentation from the template

## Example

```
User: "Create a 10-slide presentation about building CLI tools in Rust"

Claude: Reads talk prompt, plans slide structure, builds HTML deck
        with terminal mocks and flow diagrams, validates output
```

## Additional Documentation

- [SKILL.md](SKILL.md) - Complete workflow and guidelines
- [references/slide-template.html](references/slide-template.html) - Base HTML template
- [references/LAYOUT-GUIDE.md](references/LAYOUT-GUIDE.md) - Sizing and visual component reference
