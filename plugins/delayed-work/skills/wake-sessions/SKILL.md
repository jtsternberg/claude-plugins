---
name: wake-sessions
description: "Schedule a wake-up of other existing Claude Code or Codex sessions after a session or quota limit resets. Discover their exact cmux surfaces, Herdr agents or other supported live addresses, plan delivery now, then use delayed-work:until to wake this caller and nudge the same targets at the requested time. Use for 'wake these sessions at 3pm', 'resume those rate-limited agents after reset', or 'schedule a continuation prompt to these sessions'."
argument-hint: "<when> <sessions, surfaces or agents> [continuation]"
---

# Wake other sessions

Schedule this caller to nudge one or more **existing** Claude Code or Codex sessions.
The caller and each target may use either harness. `until` wakes the caller; the
caller then delivers the nudge. A context-window limit needs a handoff, not a timed
quota reset. For a wake of this session itself, use `delayed-work:until` directly.

Read the invocation from `$ARGUMENTS`.
Codex: if the invocation token is not populated, use the text following the skill name.

## Plan before scheduling

1. Resolve the requested time to a date, time and timezone. Identify each intended
   existing session from the user's identifiers and context. Inspect available
   read-only evidence: the cmux tree and screen, Herdr agents and state, session
   transcripts or available session tools as appropriate. Use the relevant cmux,
   Herdr or session skill and its current command help. Do not send a probe message.
2. Record each target's harness, exact stable address (cmux surface UUID, Herdr
   agent identity, or exact session/thread ID for a supported session tool), its
   session ID when independently established, and the evidence connecting the two.
   A title, cwd, positional cmux ref, or recency alone does not establish identity.
   If the user specified a surface UUID, preserve that exact surface. Resolve names
   or refs to stable addresses now; if the target remains ambiguous, ask rather than
   guess. Do not claim that a surface UUID identifies a particular conversation
   without evidence: a REPL can have been resumed or replaced inside the surface.
3. Assess a provisional delivery route for each target and its limitations. Prefer a
   live address that matches what the user named and preserves the existing session.
   A named Herdr agent can receive `herdr agent prompt`; check its identity and state.
   For an exact cmux surface, use the cmux skill's safe targeting and submission
   guidance; the `send-at` delivery helper is best effort and its screen observation
   is not transcript confirmation. A native session message is a candidate only if
   the current harness exposes it and it addresses the exact target: Claude native
   messaging is documented as draining at the recipient's next tool round, not as
   proven to wake an idle or rate-limited session. Do not present it as a verified
   wake-up without a relevant observed receipt. Hotline's ordinary dial may launch,
   fork, or fall back to a new surface: do not use that path unless it can be shown
   to deliver to the exact live target without those side effects. A successful
   transport call alone is not proof the recipient ran a turn.
4. Unless the user supplies different text, use this continuation message for each
   target: `This is an automated message to request you to resume where you left off
   when the session limit was hit. Reply with ack.` Ask for an acknowledgment; do not
   assume one will arrive or that it proves the subsequent work is complete.
5. If a target cannot be addressed confidently, tell the user what is missing and
   ask for the identifier or an explicit choice. For multiple targets, proceed with
   the independently resolved ones and report the rest. Never invent a reset time.

Before arming, tell the user the timezone-qualified time and, for each target, the
identity, provisional route and continuation message. Name any unverified wake
behavior and the reliability limits below. This is a plan, not a claim of delivery.

## Arm this caller

Invoke `delayed-work:until` in **this** session. Give it one self-contained wake
instruction per requested time, covering all targets due then, so simultaneous
timers do not race each other. The instruction must include the exact addresses,
known session IDs, planned routes, evidence and continuation text, and tell the
caller to return to this skill's fire-time steps. Keep sensitive payloads out of
process arguments and follow `until`'s own payload storage and cancellation rules.

The caller needs usable quota and a live callback mechanism at fire time. In
particular, another session on the same exhausted account may also be rate-limited;
do not promise it can run. A sleeping machine delays the attempt; neither timer
wakes the machine. Claude's background task depends on the caller session; Codex's
timer depends on the live queue receiver. `--caffeinate` is opt-in through `until`.
Report the actual task ID or job directory, as applicable, and the exact wake time
after `until` confirms it is armed. No task ID or timer process alone proves delivery.

## At fire time

1. Reinspect each exact address and identity and select an available route consistent
   with the user's target. If the original route disappeared, an alternative may
   address the same proven live session only when it does not contradict an explicit
   surface target. Never send to a lookalike, create a new session, fork, or resume a
   closed session automatically. Respect busy sessions, permission prompts and dirty
   inputs; do not replace or submit the user's existing text.
2. Send the continuation once to each eligible target. Use the transport's
   documented safe submission and receiving-side verification. Distinguish attempted,
   submitted, observed in the target transcript, and acknowledged or resumed. A screen
   check, queue acceptance, or successful API call alone is not an acknowledgment.
   Wait a bounded interval for the requested `ack`, using an event-driven or
   zero-token wait when available; report an absent acknowledgment as pending, not
   as proof of failure. Acknowledgment does not mean the resumed work is done.
   If delivery is ambiguous, report it and do not retry blindly: the first message may
   already be queued or submitted.
3. Report an outcome for every target. If an original target is gone, offer separate,
   clearly labeled choices for each **known** session, for example: `A) resume
   session 123` and `B) resume session 456`. Explain that selection authorizes a
   separate resume and ask which, if any, to resume. Do not offer a fabricated ID;
   if the ID was not established, report that it is unknown and ask for it. Wait for
   an explicit selection before resuming, and check that the same session is not
   already live before launching it. Continue reporting the results of other targets.

Never claim that a target was woken merely because the timer fired or a message was
accepted. If the caller does not run at fire time, it cannot deliver or report; the
user must inspect the timer or nudge the caller.
