# Hotline Dial Skill Review

## Summary

At 299 lines, the skill is within the 500-line guideline but dense. The main issues: arguments section doesn't use Claude Code's `$ARGUMENTS` substitution syntax (so args won't actually work), the description is written in second person, several sections over-explain things Claude already knows, and the async call flow forces a fragile sleep/poll loop that could be a single script.

## Issues

**I-1: Arguments won't work as documented (lines 10-22)**
The Arguments section shows `$1`, `$2+` but doesn't use Claude Code's actual argument substitution: `$ARGUMENTS`, `$ARGUMENTS[0]`, `$ARGUMENTS[1]`, etc. As written, Claude has no mechanism to receive these values — it would need to parse them from the raw user prompt anyway.

**I-2: Description in wrong point-of-view (line 3)**
Best practices say: "Always write in third person." Current: "Initiate cross-workspace communication..." (imperative). Should describe what the skill does and when to use it, in third person.

**I-3: Over-explained sections eating token budget**
- Lines 8: "You're the switchboard operator here" — decorative, not functional
- Lines 112-122: The mode table with "Think..." column adds ~50 tokens for examples Claude doesn't need
- Lines 126: "They don't care how the sausage gets made" — humor costs tokens in a skill
- Lines 238-253: "Reporting to the User" section explains how to format a response — Claude knows how to format responses

**I-4: Async call flow is a fragile multi-step dance (lines 169-212)**
The agent must: fire async script → parse call_dir → sleep 2 → read session_id.txt → report to user → poll done file in a while loop → parse response → cache session → clean up. This is 8 steps across 3+ tool calls. A single `headless-call-async.sh` that handles the polling internally and outputs two lines (session ID immediately, response when done) would reduce this to 1 tool call. The sleep/poll loop is particularly fragile — Claude may not implement it correctly.

**I-5: headless-call.sh still referenced for follow-ups (line 219)**
Follow-ups use the synchronous `headless-call.sh` while first contacts use `headless-call-async.sh`. Two different scripts for the same operation adds cognitive load. Should converge on one.

**I-6: Script path resolution requires a separate tool call (lines 26-35)**
`eval "$(bash ${CLAUDE_SKILL_DIR}/../../scripts/paths.sh)"` must run before anything else. This could be embedded via bash injection (`!`) directly into the skill text so the paths are pre-resolved when Claude reads the skill.

**I-7: Stale Identity Recovery uses synchronous headless-call.sh (line 106)**
This fires a headless call to run `/hotline-pickup` but uses the synchronous script, which blocks. For consistency and to avoid blocking on a slow workspace introspection, this should also be async — or at minimum, the skill should note this is a blocking call.

**I-8: "No freelancing" is vague (line 64)**
"Follow these steps in order. No freelancing — the protocol matters." The intent is good but "no freelancing" isn't actionable. The specific guardrails (don't pre-resolve, confirm mismatches) are more useful and already present.

## Recommendations

### HIGH Priority

**1. Fix arguments to use `$ARGUMENTS` substitution:**
```yaml
---
name: hotline-dial
description: "Initiates cross-workspace communication with another Claude Code instance. Supports quick calls (Q&A), work orders (delegation), and conference calls (collaboration). Use when the user wants to call, dial, message, or collaborate with another workspace."
---
```

Then in the body:
```markdown
## Arguments

- `$ARGUMENTS[0]` (optional): Workspace reference
- `$ARGUMENTS[1:]` (optional): Task/question for the remote workspace

If `$ARGUMENTS[0]` is provided, use it as `USER_REFERENCE`.
If arguments after the first are provided, use them as the prompt.
```

**2. Use bash injection for path resolution:**
```markdown
## Script Paths

!`bash ${CLAUDE_SKILL_DIR}/../../scripts/paths.sh`

The above sets HOTLINE_SCRIPTS, HOTLINE_DIAL_SCRIPTS, and HOTLINE_PICKUP_SCRIPTS.
```

This eliminates the need for a separate eval tool call — paths are injected when the skill loads.

**3. Rewrite description in third person with trigger words:**
```yaml
description: "Initiates cross-workspace communication with another Claude Code instance. Supports quick calls (Q&A), work orders (delegation), and conference calls (collaboration). Use when the user wants to call, dial, message, delegate to, or collaborate with another workspace or project."
```

### MEDIUM Priority

**4. Consolidate async call flow into fewer steps.**
The sleep/poll/parse dance should be a single script that the agent calls once. The script handles waiting internally and outputs structured results.

**5. Trim decorative text and over-explanation.** Remove "switchboard operator" metaphor, "sausage" joke, "Think..." column. Save ~80 tokens.

**6. Move the mode table, transport table, and error recovery into reference files.** The main SKILL.md should focus on the happy path. Progressive disclosure keeps the token budget lean.

### LOW Priority

**7. Add `--help` to headless-call-async.sh** (already has it — just verify it matches current behavior).

**8. Consider renaming to gerund form** per best practices: `hotline-dialing` instead of `hotline-dial`. Minor, and may not be worth the breaking change.

## Script Opportunities

- **`dial-call.sh`**: Single script that replaces the async fire → poll → parse → cache → cleanup dance. Takes workspace + prompt + mode, returns session ID line + response line. Agent makes one tool call instead of 3-4.
- **Bash injection for paths**: `!` syntax in SKILL.md eliminates the eval step entirely.
- **`detect-mode.sh`**: Given a prompt, outputs `quick_call`, `work_order`, or `conference_call` based on keyword analysis. Reduces agent reasoning overhead for mode selection.
