# Generating Blog Images Plugin

Generate AI image prompts for blog posts by analyzing content and identifying optimal placement.

## Installation

```bash
# Add the marketplace (if not already added)
/plugin marketplace add jtsternberg/claude-plugins

# Install the plugin
/plugin install generating-blog-images@jtsternberg
```

## Description

Analyzes blog post content to generate detailed AI image prompts with strategic placement recommendations. Works with any AI image generator (Midjourney, DALL-E, Imagen, Nano Banana, etc.).

## Usage

The skill triggers when you ask for:
- Image prompts for a blog post
- Illustrations for content
- Visual suggestions
- AI-generated images for articles
- Mentions of AI image generators

## How It Works

1. **Analyzes Content**: Identifies type, tone, themes, and structure
2. **Finds Placement Points**: Determines optimal image locations (hero, section breaks, concepts)
3. **Determines Style**: Matches visual style to content type
4. **Generates Prompts**: Creates detailed, specific prompts for each placement
5. **Validates**: Ensures prompts are clear and actionable
6. **Outputs**: Writes structured file with all prompts and metadata

## Output Format

```markdown
# Image Prompts for [Post Title]

## Hero Image
**Placement:** Top of post
**Prompt:** [Detailed prompt]
**Style:** [Visual style guidance]

## Section: [Section Name]
**Placement:** After introduction
**Prompt:** [Detailed prompt]
**Style:** [Visual style guidance]
```

## Visual Style Matching

| Content Type | Style Direction |
|--------------|-----------------|
| Technical | Clean, minimal, conceptual diagrams |
| Personal | Warm, relatable, lifestyle imagery |
| Business | Professional, modern, data-viz |
| Opinion | Bold, editorial, thought-provoking |

## Example Usage

```
User: "Generate image prompts for my blog post about async JavaScript"

Claude: Analyzes post, identifies 4 strategic placement points,
        generates technical-style prompts for each location
```

## Additional Documentation

- [SKILL.md](SKILL.md) - Complete workflow and guidelines
- [references/](references/) - Style guides and examples
