# Compounding Gotchas

The ledger of expensively-learned rules for this repo. Each unit of work should make
the next one easier: when a review round, correction, or cleanup teaches something
durable, it lands here — and from here it graduates into a mechanical guard.

**Read triggers (all mechanical):** the beads `compounding-ledger` memory
(injected by `bd prime`'s session hooks) points every session here; the
`compounding-preflight` skill scans a change-set against the rule headlines at
review/PR time; the `publish-release` runbook runs that scan at ship time.

**Write gate** (apply at write time — do not rely on authors re-reading this):
- The rule must be **repeatable**, not a one-time incident. One data point is an
  example; two is an entry.
- **Provenance is mandatory.** Every entry cites where it was learned (beads id,
  PR, or commit). No reference, no entry.
- Format is fixed: one **bold imperative headline** (greppable — this is what
  preflight matches), then at most three sentences: the failure it prevents and how
  to catch it. Nuance beyond that goes in the referenced record, not here.
- Write it as if it had always been true — no history, no narration, no past tense.
- **Graduate and prune.** When an entry becomes a test/canary/drift-check, replace
  its catch text with a pointer to the guard. At each release, sweep for entries the
  change-set made obsolete and delete them. This file must not only grow.

## Docs & skills

- **A doc must never describe a mechanism the code no longer has.** The hotline
  README taught a replaced transport 140 lines below the paragraph describing the
  real one. When a mechanism changes, grep the plugin's `*.md` and script
  headers/`--help` text for the old mechanism's nouns before closing the change-set.
  (claude-plugins-zrq1)
- **Script headers and `--help` output are documentation.** A header describing a
  dead mode misleads whoever runs the script, at README severity. Same grep as
  above — it's why the sweep includes `scripts/`. (claude-plugins-zrq1, b53cf1e)
- **Write rules as if they had always been true.** "No longer", "used to",
  "previously" force readers to learn the history before the rule. Grep changed
  docs for those phrases before committing. (claude-plugins-zrq1)
- **Pair every prohibition with its recovery action.** "Do NOT re-dial" without
  "read pending_paste.md, surface stage deliver" leaves the reader with nothing to
  do. (claude-plugins-zrq1)
- **An error hint must point at the doc section that handles that error.** Two
  deliver-stage hints pointed at the boot section, which never mentioned the
  surviving payload copy. When adding a hint, open the section it names and confirm
  it covers this failure. (claude-plugins-xick, round 2 #10)

## Verification

- **Exit codes and RPC acks are not delivery proof.** A transport can report
  success past failed chunks; confirm from the receiving side (transcript,
  on-screen state). (claude-plugins-jtti, -gxar)
- **Every delivery-path change gets a live end-to-end smoke.** Stubs are necessary,
  not sufficient — live runs caught symlinked-cwd transcript encoding and stray
  CLI stdout corrupting captured JSON, both invisible to every stub.
  (claude-plugins-xick)
- **Verifiers enumerate every terminal shape, or match a nonce instead.** Counting
  only user turns reads a landed-but-queued paste as lost; a shape whitelist missed
  the third shape a live run produced. A per-delivery nonce matched anywhere beats
  a whitelist. (claude-plugins-gxar, -xick)
- **Live smokes use real-sized payloads.** A smoke with a toy payload proves the
  toy: 300-byte test payloads sailed under Claude Code's 800-char/3-line paste
  collapse while every real work order crossed it, shipping a silent
  protocol-drop. Size smoke inputs like production inputs — or above.
  (claude-plugins-pmgb)
- **Accept/reject guards get one fixture per direction.** A recency check tested
  only against stale markers silently asserts the false-negative bug — the old
  single-screen fixtures asserted the bug they existed to prevent.
  (claude-plugins-xick, round 2 #1)

## Code shape

- **Extract the helper the moment a second caller appears.** The repo contract for
  this is CLAUDE.md § "Sharing Code or Docs Between Sibling Skills" and § "The
  parser drift guard" — this entry adds only the evidence that it keeps happening:
  after both sections existed, nonce injection still grew three copies and a bug fix
  had to land in two of them. (claude-plugins-xick, 279f98e)
- **Payloads ride files or stdin, never argv or env.** argv is `ps`-visible to
  every local user for the process lifetime. Guard: the hotline suites assert a
  sentinel never appears in recorded argv — copy that pattern for new launchers.
  (claude-plugins-86ka)
- **Each constant has one source; docs point at it rather than restating it.** A
  box-wait "default 60" documented in two files was hardcoded 20 at both call
  sites. Where a doc must state a fact, a string canary asserts agreement — see
  `newline-submit-docs_test.sh`. (claude-plugins-xick, round 2 #6)
- **Record state before the step that can fail.** An undelivered conference left a
  live REPL no cache knew about, so the next dial opened a second one. If a record's
  inputs exist before the risky step, write the record first.
  (claude-plugins-xick, round 2 #4)

## Process

- **A suite that can skip must be satisfiable, and skip counts get read.** Owned by
  CLAUDE.md § Testing (the gws incident) — kept here as a headline only so the
  preflight scans for it; the rule text lives there, not here.
- **Flags become beads tasks at the moment of noticing.** "Worth fixing later" said
  in prose evaporates; `bd create` with `discovered-from` survives the session.
  (memory: feedback_flag_becomes_beads_task)

## Known false positives — do not flag these

- **"Legacy fingerprint" language in hotline caller-id/wiretap/README is current,
  not archaeology.** The pre-2.1.132 fallback still ships and replay is its live
  observable. (claude-plugins-zrq1)
- **The U+00A0 box-detection requirement is load-bearing, not magic.** A bare `❯`
  match once pasted a work order into a shell, which executed it. It couples to one
  rendering detail on purpose — failure direction is refuse, not misfire.
  (claude-plugins-xick, round 1 #1)
- **The `cmux send` forensics in error-recovery.md stay.** The facts (typed-text
  chunking, `\n\r\t` rewriting, non-size-gated loss) are current and guard the
  "never hand-deliver with cmux send" rule; a doc canary pins them.
  (claude-plugins-zrq1, 9e0a09a)
