---
name: generating-blog-images
description: Generates AI image prompts for blog posts by analyzing content, identifying optimal placement points, and crafting detailed prompts. Use when the user asks for image prompts, illustrations, or visual suggestions for blog content, or mentions AI image generators like Midjourney, DALL-E, Imagen, or Nano Banana.
---

# Blog Post Image Prompt Generator

## Workflow Checklist

Copy and track progress:

```
Image Prompt Progress:
- [ ] Step 1: Analyze blog post (type, tone, themes)
- [ ] Step 2: Identify placement points
- [ ] Step 3: Determine visual style
- [ ] Step 4: Generate prompts
- [ ] Step 5: Validate prompts
- [ ] Step 6: Write output file
```

## Process

### Step 1: Analyze the Blog Post

Identify:
- **Content type**: Technical, personal essay, business, opinion, how-to
- **Key themes**: Concepts, metaphors, or ideas that could be visualized
- **Structure**: Sections and natural break points

### Step 2: Identify Placement Points

| Location | When to Use |
|----------|-------------|
| **Hero** | Almost always |
| **Section breaks** | Long posts with distinct sections |
| **Concept illustrations** | Abstract ideas needing visualization |
| **Emotional beats** | Key moments in narratives |

**Quantity** (flexible guidelines):
- Short posts: 1-2 images
- Medium posts: 2-4 images
- Long posts: 3-6 images

Not every section needs an image.

### Step 3: Determine Visual Style

| Content Type | Style Direction |
|--------------|-----------------|
| Technical | Diagrams, isometric, flat design |
| Personal essays | Editorial photography, painterly, atmospheric |
| Business | Professional, polished |
| Opinion | Conceptual, metaphorical, abstract |

### Step 4: Generate Prompts

Each prompt must include these five elements:
1. **Subject** - Main focus
2. **Style** - Illustration, photograph, diagram, etc.
3. **Mood** - Lighting, color palette, emotional tone
4. **Composition** - Framing, perspective, negative space
5. **Details** - Specific elements from the blog content

For concrete examples, see [references/prompt-examples.md](references/prompt-examples.md).

### Step 5: Validate Prompts

Before presenting, verify each prompt:
- [ ] References specific content/metaphors from the post
- [ ] Style is consistent across all prompts
- [ ] Aspect ratio specified (16:9 for headers, 1:1 or 4:3 for inline)
- [ ] Explicitly excludes common AI clichés (lightbulbs for ideas, handshakes for business, etc.)
- [ ] No text rendering requested (AI struggles with text)

Revise any prompt that fails these checks.

### Step 6: Write Output File

Write the prompts to a markdown file for collaborative editing.

**File naming**: Save alongside the blog post as `[blog-post-name]-image-prompts.md`

Example: If the blog post is `draft-the-performance-treadmill.md`, create `draft-the-performance-treadmill-image-prompts.md` in the same directory.

**File format**:

```markdown
# Image Prompts for "[Blog Post Title]"

**Content analysis**: [1-2 sentence summary]
**Recommended image count**: [N] images
**Visual style direction**: [Overall style]

---

## Image 1: [Title]
**Placement**: [Location in post]
**Purpose**: [What it accomplishes]
**Prompt**: [Full prompt text]
**Style notes**: [Aspect ratio, what to avoid]

---

## Image 2: [Title]
...
```

After writing the file, confirm the file path to the user so they can open it for review and editing.

## Flexibility Guide

- **High freedom**: Image count, exact placement, style interpretation
- **Medium freedom**: Output format structure (maintain organization, adapt sections)
- **Low freedom**: Five prompt elements (always include all five), validation checks
