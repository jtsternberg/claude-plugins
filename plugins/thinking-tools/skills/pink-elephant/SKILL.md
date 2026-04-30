---
name: pink-elephant
description: Use when the user calls out a "pink elephant" — i.e. flags that an instruction, prompt, or guideline is counterproductively telling an agent NOT to do something. Triggers on phrases like "pink elephant", "don't think about a pink elephant", or critiques about negative instructions, prohibition framing, or rules phrased as "do not X" / "never X" / "avoid X" that draw attention to the very behavior they're trying to prevent. Helps rewrite negative prohibitions into positive directives.
---

# Pink Elephant

> "Don't think about a pink elephant."
> — Now you're thinking about a pink elephant.

## The Principle

Telling an LLM **not** to do something is unreliable. The forbidden behavior is named in the prompt, which (a) raises its salience as a continuation, and (b) runs into well-documented weaknesses in how language models handle negation. Telling the model what *to* do is more direct and more reliable.

This is industry-standard prompting guidance:

- **OpenAI**: *"Instead of just saying what not to do, say what to do instead."*
- **Anthropic**: *"Tell Claude what to do instead of what not to do."* And: *"Positive examples tend to be more effective than negative examples or instructions."*

See `references.md` for citations and the supporting research.

## When This Skill Activates

- The user says "pink elephant", "don't think about a pink elephant", or similar
- The user critiques a prompt/skill/CLAUDE.md/system instruction for being too focused on what *not* to do
- A document is full of "DO NOT" / "NEVER" / "AVOID" / "DON'T" — especially when stacked or repeated
- The user asks why an agent keeps doing the thing it was just told not to do
- Reviewing prompts, skills, agent instructions, hooks, or guardrails for effectiveness

## Two Failure Modes to Watch For

Negative instructions fail in **two opposite ways**. The fix is the same — rewrite affirmatively — but recognizing which one is happening helps explain the symptom.

### 1. Fixation (the classic pink elephant)
The model produces the forbidden behavior anyway because the prohibition put it in context. Examples: a "no preamble" instruction yields a preamble; "don't apologize" yields apologies; "never use emojis" yields emojis. Negation research (Kassner & Schütze 2020; Truong et al. 2023) confirms LLMs are often "insensitive to the presence of negation."

### 2. Over-literal suppression (especially with newer/more compliant models)
The model follows the prohibition *too* faithfully and suppresses useful behavior alongside the forbidden behavior. Anthropic explicitly warns about this with Claude Opus 4.x: an instruction like "don't nitpick" or "only report high-severity issues" can be obeyed so literally that the model withholds findings the user would have wanted. The prohibition didn't fail — it succeeded too well, on the wrong scope.

Both failure modes have the same fix: state the affirmative goal, with scope. "Don't nitpick" → "Report findings that materially affect correctness, security, or maintainability."

## The Reframe Protocol

### Step 1: Identify the Prohibition
State the negative instruction plainly. "Don't write long preambles." "Never use emojis."

### Step 2: Ask What Behavior You Actually Want
For every "don't X", there's a positive counterpart describing the target behavior:

| Pink elephant (negative) | Reframe (positive) |
|---|---|
| "Don't write long preambles." | "Lead with the answer or action." |
| "Never use emojis." | "Use plain text." |
| "Don't be sycophantic." | "Match the user's tone; respond matter-of-factly." |
| "Avoid hedging." | "State conclusions directly." |
| "Don't make up APIs." | "Verify symbols exist in the codebase before referencing them." |
| "Don't nitpick." | "Report findings that materially affect correctness, security, or maintainability." |

### Step 3: Keep Prohibitions Where They're Load-Bearing — But Pair Them With An Affirmative Fallback
Some negatives are genuinely necessary — usually around safety, security, or hard constraints with no positive substitute:

- "Never commit secrets to git."
- "Never run `rm -rf` on user data."
- "Don't push to main without review."

The Microsoft Azure OpenAI safety-system-message pattern is the right one here: *pair every necessary prohibition with what to do instead when the prohibition fires*. "Never share customer PII → if asked, redirect the user to <link>." The prohibition holds the line; the affirmative tells the model what success looks like when it does.

### Step 4: Don't Stack Prohibitions
A wall of "DO NOT" / "NEVER" / "AVOID" is itself a giant pink elephant. Even if each rule is individually load-bearing, the cumulative effect floods the prompt with forbidden behaviors. Consolidate, prioritize, convert as many as possible to positive directives.

## Quick Diagnostic
1. Does this tell the agent what TO do, or only what NOT to do?
2. If I removed this line, would the agent still know what behavior is expected?
3. Am I describing the failure mode, or the success mode?
4. If a prohibition must stay, does it specify what to do instead when it fires?

If the instruction only describes the failure mode, it's a pink elephant. Rewrite it.
