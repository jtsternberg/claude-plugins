---
name: chestertons-fence
description: This skill should be used when about to remove, refactor, or significantly change existing code, configuration, processes, or systems whose purpose is not fully understood. Triggers on concerns about unintended side-effects, confusion about why something exists, requests to delete or simplify "unnecessary" code, or when someone says "Chesterton's Fence." Prevents the classic mistake of tearing down a fence before understanding why it was built.
---

# Chesterton's Fence

> "If you don't see the use of it, I certainly won't let you clear it away. Go away and think."
> — G.K. Chesterton, *The Thing* (1929)

## The Principle

Not understanding why something exists is the worst possible reason to remove it. The inability to see a purpose signals missing context, not absence of purpose. Every fence was erected by someone who saw a reason for it. Before tearing it down, reconstruct that reason.

## When This Skill Activates

- About to delete code, configuration, or infrastructure whose purpose is unclear
- Refactoring something that "doesn't make sense" or "looks like cruft"
- Removing a dependency, feature flag, or workaround without understanding its origin
- Simplifying a process that seems unnecessarily complex
- A gut feeling that something is "legacy" or "dead code"
- Explicitly invoked via "Chesterton's Fence"

## The Investigation Protocol

Before removing, changing, or simplifying anything whose purpose is not fully understood, complete this investigation. Do not skip steps.

### Step 1: Identify the Fence

State clearly what is being considered for removal or change, and why it seems unnecessary. Name the assumption: "I believe this exists because..." or "I don't know why this exists."

### Step 2: Reconstruct the History

Investigate why the fence was built. Use every available source:

- **Git blame / git log** — Who wrote it? What was the commit message? What PR was it part of? What issue did it reference?
- **Surrounding code** — Are there comments, related tests, or error handling that hint at the purpose?
- **Related issues / PRs** — Search for referenced ticket numbers, keywords, or the function/file name in issue trackers
- **Grep for usage** — Is it called from unexpected places? Is it referenced in configs, cron jobs, or external systems?
- **Tests** — Do any tests exercise this code path? What do they assert? What would break?

### Step 2b: Ask the Fence-Builder (Optional)

If the investigation leaves gaps — unclear commit messages, missing context, ambiguous purpose — ask the user directly. They may have institutional knowledge, historical context, or a relationship with the original author that code archaeology cannot surface. Example questions:

- "This function runs weekly but I can't find what triggers it. Do you know what it's for?"
- "The git history shows this was added in a rush during an incident. Do you remember what happened?"
- "This config value looks arbitrary. Is there a reason it's set to 30 rather than the default?"
- "I found three places this is referenced but none of them seem active. Has this system been decommissioned?"

Skip this step when the investigation in Step 2 produced a clear, confident answer. Use it when the picture is incomplete — half a story is more dangerous than no story at all.

### Step 3: Assess the Risk

With the history reconstructed (or honestly acknowledging gaps), answer:

1. **What problem did this originally solve?** (If still unknown after investigation, that is a strong signal to leave it alone or escalate.)
2. **Does that problem still exist?** Conditions may have changed — but verify, don't assume.
3. **What breaks if this is removed?** Consider edge cases, infrequent triggers (quarterly jobs, rare user paths, specific client configurations), and downstream dependencies.
4. **Is there an equivalent safeguard elsewhere?** Sometimes the fence was made redundant by later changes. Confirm this concretely.

### Step 4: Decide and Document

Only after completing steps 1-3, choose one of:

- **Keep it** — The fence still serves its purpose. Add a comment explaining why, so the next person doesn't repeat this investigation.
- **Replace it** — The need is real but the implementation is outdated. Build the replacement *before* removing the original. Ensure tests cover the same scenarios.
- **Remove it** — The original reason no longer applies, and this has been verified. Document the removal in the commit message: what the fence was, why it existed, and why it's now safe to remove.
- **Escalate** — The investigation is inconclusive. Flag it to someone with more context rather than guessing.

## Key Heuristics

- **"I don't know why this exists" = "I am not yet qualified to remove it."** Ignorance of purpose is not evidence of purposelessness.
- **The weirder it looks, the more important the investigation.** Bizarre code often guards against bizarre edge cases.
- **Infrequent execution != unnecessary.** That function running once a quarter might be the only thing keeping quarterly reports alive.
- **Absence of tests is not permission.** It may mean the original author didn't have time, not that the behavior is unimportant.
- **"Nobody remembers" is a reason for caution, not confidence.** If institutional memory has been lost, the fence's purpose is *more* likely to surprise you, not less.

## Anti-Patterns to Catch

| What it sounds like | What's really happening |
|---|---|
| "This is dead code, I'll just delete it" | Possibly alive in a path not yet explored |
| "This seems overly complex, let me simplify" | Complexity may encode hard-won edge case handling |
| "Nobody uses this anymore" | Verify with data, not assumption |
| "The tests pass without it" | Tests may not cover the scenario it protects |
| "I'll clean this up while I'm in here" | Scope creep into territory not yet understood |
