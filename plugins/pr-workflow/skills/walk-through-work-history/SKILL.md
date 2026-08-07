---
name: walk-through-work-history
description: Research and explain how work progressed as an interactive, one-page-at-a-time walkthrough. Use when the user asks for the history, evolution, review progression, revisions, decisions, false starts, or outcome of a GitHub pull request (the primary use case), issue, branch, project, incident, document, ticket, or other chronological work record—especially when they ask for a paginated, ADHD-friendly, story-like, or "turn the page" explanation.
---

# Walk Through Work History

Turn a dense work history into a causal narrative delivered one short page per user turn. Research the complete history before narrating the first page.

## Workflow

1. Resolve the artifact and evidence sources.
   - Prefer primary evidence: commits, reviews, inline threads, comments, tickets, logs, and final state.
   - For a GitHub pull request, read the harness-appropriate reference before continuing:
     - Claude: `${CLAUDE_SKILL_DIR}/references/github-pr.md`
     - Codex: resolve `references/github-pr.md` relative to the directory containing this `SKILL.md`.
   - Use current external data when the source can change or the user supplies a live URL.

2. Reconstruct the full progression privately.
   - Build an event ledger with timestamp, actor, action, rationale, consequence, and evidence link.
   - Connect review findings to the commits or decisions that answered them.
   - Record reversals, stale approvals, dismissed reviews, wrong diagnoses, and later corrections.
   - Identify which account represents the user when the available context makes that reliable; refer to their actions as "you."
   - Distinguish what participants believed at the time from what later evidence established.

3. Divide the history into causal chapters.
   - Group events by meaningful phase, not arbitrary date ranges.
   - Give each chapter one dominant question or transition, such as initial build, first review, live validation, scope expansion, redesign, re-test, or final merge.
   - Keep minor commits inside the chapter they support. Do not turn every commit into a page.
   - Know the likely ending before writing page 1, but do not reveal the full outline unless asked.

4. Deliver exactly one page.
   - Use `## Page N: Specific phase title`.
   - Default to roughly 150–350 words unless the user asks for another size.
   - Explain what changed, why it changed, and what that caused next.
   - Use short paragraphs and a few bullets only where they improve scanning.
   - Link a small number of especially useful primary events; do not turn the page into a citation list.
   - End every non-final page with exactly: `Ready to **turn the page**?`
   - Stop. Do not include the next page in the same response.

5. Continue on brief signals such as "yes," "next," or "turn the page."
   - Preserve the established page numbering and narrative thread.
   - Do not repeat prior pages.
   - Apply tone or detail feedback immediately to all later pages.
   - Fetch more evidence only when the remaining chapter needs it or the user asks a follow-up.

6. Close with a final page.
   - Explain the final outcome and the last consequential decisions.
   - Add a compact progression summary when it improves recall.
   - State clearly that the walkthrough has ended; do not ask the user to turn another page.

## Tone and pacing

- Treat "ADHD-friendly" as controlled information flow: one causal thread, short sections, concrete transitions, and limited detail per page.
- Use plain adult language. Do not equate accessibility with childish wording, cartoon metaphors, or exaggerated simplification.
- Explain unfamiliar terms briefly at the point of use.
- Prefer a narrative over a raw timeline, but never manufacture drama or motives.
- Keep the honest mess: failed approaches, mistaken diagnoses, reopened questions, and changes after approval often explain the work better than the final diff does.
- Calibrate technical detail to the user. Preserve exact names, commit IDs, errors, or contract shapes when they carry the story.

## Evidence discipline

- Inspect the complete available history before page 1. Early narration based on a partial timeline produces misleading chapters.
- Treat the current description or summary as the final record unless edit history proves what it said earlier.
- Do not infer that a currently dismissed or resolved review was never blocking; describe its state at each point in time.
- Do not treat an approval as permanent when substantial commits landed afterward.
- Separate feature commits, review fixes, merge commits, documentation changes, and cleanup commits.
- If evidence is missing or an attribution is uncertain, say so rather than smoothing the gap into certainty.

## Non-GitHub histories

Apply the same method to tickets, incident logs, documents, chat threads, or project notes:

1. Normalize the sources into the event ledger.
2. Find decision points and causal transitions.
3. Build the full chapter map.
4. Deliver one page per turn using the same pacing and evidence rules.
