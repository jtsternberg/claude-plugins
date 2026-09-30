---
name: dont-lead-the-witness
description: "Use when the user says 'don't lead the witness', or whenever you want someone's genuine, unprompted response: testing an agent or skill, asking a reviewer for a verdict, questioning the user, probing a real-world scenario. Ask the way the real situation would, with no hint of the answer you expect."
when_to_use: |
  Also when a prompt, question, or test is about to state what it's looking for, or ask the
  subject to report the very thing being measured.
---

# Don't Lead the Witness

> A leading question gets back the answer it carried in.

When you want to learn what someone would do or think on their own (an agent, a reviewer, the
user, a tester), anything in your question that hints at the expected answer contaminates the
result. The response now measures your hint, not them.

## The Stance

- **Recreate the real situation.** Ask exactly what the real-world asker would ask, in their
  words and register. No framing that this is a test, no explanation of why you're asking.
- **Hide the target.** Don't name what you're watching for, the result you expect, or the
  answer you'd prefer. "Confirm this is safe" gets a different answer than "what could go
  wrong here?"
- **Observe, don't ask for self-report.** Judge from what the witness actually did (output,
  logs, transcript, state), never from its account of what it did.
- **Disclose unavoidable hints.** If the setup forces you to reveal something, reveal the
  minimum and say what leaked when you report the result.

Before sending, reread your message as the witness: can you guess what the asker wants to hear?
If yes, rewrite it.
