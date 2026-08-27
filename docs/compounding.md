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
  the third shape a live run produced. A per-delivery nonce matched anywhere in the
  *transcript* beats a whitelist — on a *screen* it is weaker, see the next entry.
  (claude-plugins-gxar, -xick)
- **On a rendered screen, a marker proves arrival; only its position proves
  submission.** The nonce or a `[Pasted text` placeholder on the live input-box line
  is a payload still WAITING for its Enter, and confirming delivery on it left work
  orders parked while the caller waited out a 30-minute budget. Scope screen-side
  acceptances to the text outside the input box, deriving the box from the one helper
  that owns it (`input_box_content`) — the sole exception being a marker the TUI draws
  as a PLACEHOLDER, which proves the input value is empty and so cannot be a parked
  payload. (claude-plugins-fkgv, -y4rl, -ff6g)
- **Order confirmation tiers so the negative reading is tested first.** When two
  tiers can read the same signal and reach opposite verdicts, whichever runs first
  wins — so a tier concluding "delivered" placed ahead of one concluding "arrived but
  never submitted" makes the second unreachable and its recovery dead code. Put the
  refusing/negative classifier first and let confirmation run only where it declines.
  (claude-plugins-fkgv, -y4rl)
- **Live smokes use real-sized payloads.** A smoke with a toy payload proves the
  toy: 300-byte test payloads sailed under Claude Code's 800-char/3-line paste
  collapse while every real work order crossed it, shipping a silent
  protocol-drop. Size smoke inputs like production inputs — or above.
  (claude-plugins-pmgb)
- **When two states are byte-identical in text, find a styled source before inventing
  a heuristic.** A plain-text terminal read erases the attribute distinguishing a
  placeholder from typed input, and shape-matching the placeholder covered one of its
  three strings; cmux's `terminal.replay` grid carries `faint`/`inverse` per span and
  answers it outright. Ask what the renderer knows that the text dropped — and gate
  the reader on the capability, failing closed to the text behavior.
  (claude-plugins-ff6g)
- **When one observation supports two opposite verdicts, open a window or write a
  resumable marker — never convert it to a terminal verdict on sight.** An
  intervening human prompt in a callee's session is either a reassignment or a
  redirect of the same order, and a waiter's expired budget is a fact about the
  waiter, not the call; verdict-on-sight reports failure on calls that then
  complete unheard. Wait (bounded) for the evidence only the other side can
  produce — e.g. the callee's next nonce-stamped STATUS — and let that decide.
  (claude-plugins-mrpi, -tyaj)
- **Accept/reject guards get one fixture per direction.** A recency check tested
  only against stale markers silently asserts the false-negative bug, and a
  parked-payload retry fixtured only where screen confirmation already failed let the
  screen confirm the parked payload for another two days. Every fixture in a suite
  sharing one precondition (a baseline that already carries the marker, say) is the
  tell that a direction is missing. (claude-plugins-xick round 2 #1, -y4rl)
- **cmux resolves a missing or unparseable target to the FOCUSED surface, so hard-fail
  on an empty handle and echo-verify every RPC target.** Three separate incidents in
  one day: `cmux send --surface ""` typed into a bystander's live REPL twice, and a
  `terminal.replay` with camelCase param keys returned `ok:true` carrying the focused
  surface's grid. Refuse the call yourself before cmux can substitute a target
  (`cmux_handle_ok` in `plugins/hotline/scripts/repl-state.sh`), send snake_case
  params only, and compare `result.surface_id` against what you asked for — a wrong
  answer arrives as a successful one. (claude-plugins-r465.7, -r465.9)
- **Read a cmux screen with `--scrollback --lines N`, never bare.** Bare
  `read-screen` returns what the pane is CURRENTLY SHOWING, so a user scrolled up
  hands back a frozen capture — and "the screen did not change" then reads as "the
  REPL is idle", which is how a destructive cleanup closes a surface mid-turn. The
  `--scrollback` form is viewport-independent; `terminal.replay` needs
  `anchor:"screen"` for the same reason, and its `scrolled_rows` is structurally
  always 0, so it can never detect scroll for you. (claude-plugins-r465.5, -r465.6,
  -r465.1)
- **Never attach a PTY by focusing it.** `cmux send` attaches a surface's PTY lazily
  on first send, so `cmux focus-pane` and `--focus true` buy ~0.1s and cost the user's
  input line: three of their keystrokes arriving ahead of a launch command made a
  callee's shell run `rkebash /tmp/…` and burned the caller's whole 60s boot budget.
  Create everything `--focus false`, probe with a send, and clear the shared input
  line with a raw Ctrl-U (`$'\025'`) before any command you need to arrive intact.
  (claude-plugins-r465.4, -r465.7, -r465.2, -r465.3)
- **A readiness wait must poll the thing its own first action makes possible.** A loop
  that waited for `read-screen` to return anything could never succeed under
  `--focus false`, because nothing had sent yet and there was no tty to read — it
  burned its full budget and proceeded blind on every call. When flipping a flag
  changes what attaches a resource, re-derive the wait's signal instead of keeping it.
  (claude-plugins-r465.4, -r465.2)
- **A sweep that reports zero matches is only clean once it is proved able to
  match.** On macOS `/tmp` is a symlink, so `find /tmp -maxdepth 1` descends nothing
  and answers "clean" over 291 real files — as does an unquoted `$FILES` list in a
  `for` loop under zsh, which is one word, not a list. Give every scan a positive
  control it must hit before reading a zero as a result; for a symlinked directory
  that control is the trailing slash, `find /tmp/`. (claude-plugins-qq9f)

## Code shape

- **Extract the helper the moment a second caller appears.** The repo contract for
  this is CLAUDE.md § "Sharing Code or Docs Between Sibling Skills" and § "The
  parser drift guard" — this entry adds only the evidence that it keeps happening:
  after both sections existed, nonce injection still grew three copies and a bug fix
  had to land in two of them. (claude-plugins-xick, 279f98e)
- **A wrapped CLI's chatter stays out of every captured JSON.** `gws` prints
  "Using keyring backend" to stderr and hotline hit the same class from stdout, so
  a `2>&1` capture yields a file that looks fine and fails every parse downstream.
  Keep the streams separate and slice from the first `{` before parsing; save the
  raw response to a file rather than piping straight into `jq`, so a bad response
  is still readable. (claude-plugins-xick, 0affe5f)
- **Argv is a size limit, not just a leak surface — and the binding limit is
  per-argument.** `ARG_MAX` is the famous number (1,048,576 on macOS) but Linux caps
  a *single* argument at `MAX_ARG_STRLEN` = 32 pages = 131,072 however large
  `ARG_MAX` is, so a payload that passes locally at 445KB dies on the ubuntu runner;
  either way the kernel says only "argument list too long". Route any request body
  that scales with user input through a file upload, choose the threshold from the
  smaller limit, and gate on measured size rather than on the flag you think implies
  bigness. (0affe5f, claude-plugins-dekq)
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
- **Every Drive v3 file call carries `supportsAllDrives=true`; `files.export` and
  the Docs API do not.** The gws rung of the gws skills omitted it on
  `files.create/get/update`, so shared-drive folders and docs 404'd as "File not
  found" while the ADC rung — which already had the flag — worked; the same gap, one
  rung apart. When adding a Drive v3 file call to these skills put the flag in its
  `--params`, but leave it off `files.export` and `documents.get/batchUpdate`, which
  resolve shared-drive docs without it (verified live). (claude-plugins-wxh2, ddbb035)
- **A timer that must reach a `cmuxOnly` socket wakes an in-pane agent turn, never
  an external process.** cmux's default `cmuxOnly` mode refuses any process without
  cmux ancestry, so a `launchd`/`cron`/`at` job or a cloud routine fires but cannot
  drive cmux — the launchctl-into-cmux attempt died exactly here. Schedule the
  delivery from the agent's own in-session wait (Claude: a backgrounded until-clock
  loop that re-invokes the same session; Codex: a blocking `functions.wait` exec
  cell) so the send runs from a descendant of cmux. (claude-plugins-o4us)

## Testing

- **Read a file's mode with GNU `stat -c` before BSD `stat -f`.** On Linux
  `stat -f` is `--file-system` and prints verbose output instead of failing, so a
  BSD-first `stat -f … || stat -c …` never reaches the fallback and permission
  assertions read empty on the ubuntu runner. Grep tests for any `stat -f` placed
  before its `stat -c` fallback. (289ef4a)
- **An injectable delay keeps its shipped default under test, and patience is
  asserted on the exit path rather than the stopwatch.** Collapsing a poller's sleep
  for speed makes every wall-clock assertion vacuous and hides a `0` default that
  would spin-loop in production. Give the env var one case that runs with it unset,
  and prove "waited the whole budget" from the timeout branch's own message, which
  the early-give-up branch cannot produce. (claude-plugins-fhn3)
- **A count guard is derived from the tree, or it is a mask.** A hardcoded
  expected-count check the tree has outgrown fails before every check behind it: the
  50-skill guard in `compare-skill-descriptions.mjs` hid a 21-skill-stale proposals
  file, and the 60-skill guard in `measure-skill-descriptions.sh` suppressed the
  report it was protecting. Derive the count, or drop the guard and let the report
  state the number. (claude-plugins-nwtk, -lvj0)
- **A suite is not green until it is green on Linux.** The ubuntu runner is the
  only Linux check, and a macOS-green suite hid a red CI for the entire
  terminal.paste rework — portability bugs (BSD-only `stat`, `getppid` reparenting
  under command substitution) surface only there. Read the CI conclusion for a
  change, not just local output. (289ef4a, ad10bbf)
- **A fixture has to model the state the bug destroys, not a milder version of it.** A
  "user has scrolled up" screen that still rendered the input box left every
  box-shaped gate working, so no test could have caught the reads that followed the
  scroll; a stub that drew the box ABOVE the transcript instead of below it hid the
  same thing. Write the fixture from what the real surface looks like in that state,
  then check that at least one existing assertion changes verdict because of it.
  (claude-plugins-r465.8)
- **A stub screen may only draw frames the real program can render.** An impossible
  frame makes a whole class of bugs untestable: hotline's cmux stub echoed pasted
  bytes BELOW the input box, which claude never draws, so it hid every
  bottom-of-screen gate bug and broke 31 cases the moment a correct fix landed. Prove
  a fixture change is neutral by running the suite at the prior commit with only the
  fixture overlaid, in both orderings (180/180). (claude-plugins-r465, 8c04c1d)

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
