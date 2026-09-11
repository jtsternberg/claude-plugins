#!/usr/bin/env bash
# =============================================================================
# Contract canary for maestro's `your-cue` skill.
#
# `your-cue` is prose a model executes against live hosts, so there is no
# behavior to unit-test — what breaks is a paragraph going missing. Each
# assertion below pins one acceptance criterion from
# docs/superpowers/specs/2026-09-11-your-cue.md to the text that carries it:
# delete the paragraph and the matching assertion fails.
#
# Two classes of assertion matter most. The negative ones (no mutating
# command appears as an instruction, the digest is never byte-cut) guard
# against a future edit reintroducing a footgun the fact-finding ruled out.
# The format ones (`Your cue:`, `Next for you:`) guard the rendering contract
# the human reads.
# =============================================================================
set -u

PASS=0
FAIL=0
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
SKILL="$ROOT/plugins/maestro/skills/your-cue/SKILL.md"
OPENAI="$ROOT/plugins/maestro/skills/your-cue/agents/openai.yaml"
README="$ROOT/plugins/maestro/README.md"

pass() { PASS=$((PASS + 1)); echo "ok - $1"; }
fail() { FAIL=$((FAIL + 1)); echo "not ok - $1"; }

# has <description> <pattern> [file]
has() {
  local msg="$1" pat="$2" file="${3:-$SKILL}"
  if [[ -f "$file" ]] && grep -qE -- "$pat" "$file"; then
    pass "$msg"
  else
    fail "$msg"
  fi
}

# lacks <description> <pattern> [file]
lacks() {
  local msg="$1" pat="$2" file="${3:-$SKILL}"
  if [[ -f "$file" ]] && ! grep -qE -- "$pat" "$file"; then
    pass "$msg"
  else
    fail "$msg"
  fi
}

# has_desc <description> <pattern> — matches inside the `description` scalar only.
# Codex ignores `when_to_use`, so a routing term that drifts from `description`
# into it (or into the body) must not keep a Codex assertion green.
frontmatter() { awk 'NR==1 && /^---$/{f=1;next} f && /^---$/{exit} f' "$SKILL"; }
# Folded to one line the way YAML folds it, so a phrase that straddles a wrap is
# still matched — grep is line-based, the matcher is not.
description() { frontmatter | awk '/^description: >/{f=1;next} f && /^[a-z]/{exit} f' | tr '\n' ' ' | tr -s ' '; }
has_desc() {
  local msg="$1" pat="$2"
  if description | grep -qE -- "$pat"; then
    pass "$msg"
  else
    fail "$msg"
  fi
}

# --- the skill exists where discovery expects it -----------------------------

if [[ -f "$SKILL" ]]; then
  pass "SKILL.md exists at plugins/maestro/skills/your-cue/SKILL.md"
else
  fail "SKILL.md exists at plugins/maestro/skills/your-cue/SKILL.md"
fi

has "frontmatter declares the bare name your-cue" '^name: your-cue$'
# Codex ignores `when_to_use`, so the routing terms have to live in the
# description itself — assert the terms, not the presence of the key.
has_desc "description routes Codex on the morning-briefing term" 'morning briefing'
has_desc "description routes Codex on the status-sweep term" 'status sweep'

# Codex pools every installed skill's description into one ~8,000-char budget, so
# an implicitly-invocable description is capped at 270 chars; overflow trigger
# vocabulary belongs in `when_to_use`, which only Claude Code reads.
DESC=$(description | sed 's/^ //;s/ $//')
if [[ ${#DESC} -le 270 ]]; then
  pass "description stays inside the 270-char Codex budget (${#DESC})"
else
  fail "description stays inside the 270-char Codex budget (${#DESC})"
fi

# Zero-argument: no Claude argument metadata, no interpolation token, and the
# prose says so, so a future editor does not quietly add a parameter.
lacks "no argument-hint (zero-argument invocation)" '^argument-hint:'
lacks "no \$ARGUMENTS interpolation" '\$ARGUMENTS'
has "prose states the skill takes no arguments" '[Tt]akes no arguments'

# It is a workflow the model runs on request, not a gated command.
lacks "model invocation is not disabled" '^disable-model-invocation:'

# --- read-only contract ------------------------------------------------------

# Anchor to the section itself: a bare `[Rr]ead-only` also matches the
# description and the anti-pattern table, so it would survive Rule zero's
# deletion.
has "Rule zero heads the read-only contract" '^## Rule zero — read only'
has "Rule zero preserves pane focus and seen state" 'pane focus, seen state'
has "preserves focus, seen state, notifications, and input" 'focus.*notification|notification.*focus'

# Name the forbidden commands: a fresh agent will not know which cmux/herdr
# verbs mutate, and several read like probes.
has "names cmux focus-pane as forbidden" 'focus-pane'
has "names cmux clear-notifications as forbidden" 'clear-notifications'
has "names cmux clear-history as forbidden" 'clear-history'
has "names cmux send-key as forbidden" 'send-key'
has "names herdr prompt/send-keys as forbidden" 'herdr[^.]*(prompt|send-keys)|(prompt|send-keys)[^.]*herdr'
has "names herdr rename/start/attach as forbidden" '`rename`, `start`, `attach`'

# --- inventory: graveyard fast path and portable path ------------------------

has "graveyard fast path command" 'graveyard candidates --json'
has "inventory is reachable from outside either host" 'works from outside both hosts'
has "portable path uses herdr agent list" 'herdr agent list'
has "portable path uses cmux tree" 'cmux tree --all --json'
has "portable path reads cmux sidebar state" 'cmux sidebar-state'
has "reads recent output only for shortlisted unclear rows" 'cmux read-screen --surface'
has "resolves the herdr workspace title with an extra read" 'herdr workspace (get|list)'
has "notes herdr agent get/read key on the herdr name, not the session UUID" 'herdr `?name'

# --- confirmation before partial coverage ------------------------------------

has "probes each host directly instead of trusting graveyard's row set" '[Pp]robe each host yourself'
has "warns that graveyard hides an unreachable host" 'relabels every herdr row|not a reachability field'
has "stops and asks when only one transport is reachable" '[Ss]top and ask|ask (the user|first)'
has "confirmation covers the one-reachable-transport case" 'only one transport'
has "offers a transcript-only briefing when neither host answers" 'transcript-only'
has "renders a Coverage section when a host was unavailable" '^Coverage$'

# --- visible-name locators ---------------------------------------------------

has "herdr locator form" '<agent name>` in `<tab name>'
has "cmux locator form" '<surface title>` in `<workspace title>'
has "window anchor only when needed" 'window anchor'
has "session UUIDs and pane ids stay internal, not output" 'pane ids are internal lookup keys, not output'

# --- hotline nesting ---------------------------------------------------------

has "consumes the hotline call-status skill by its invocation form" '/hotline:hotline-call-status'
has "gives the Codex invocation form for call-status" '\$hotline:hotline-call-status'
# maestro declares no dependency on hotline, so the registry step has to be
# optional rather than an instruction to invoke a skill that is not there.
has "skips the hotline step when the plugin is not installed" 'skip this step \*\*when the hotline plugin'
has "nests callees beneath their caller" 'nested beneath its caller'
has "matches on callee_session_id" 'callee_session_id'
has "matches on host_handle" 'host_handle'
has "ignores registry rows absent from the live inventory" '[Ff]ilter to the live inventory'
# A `--remote` callee runs on another box, so its session id and host handle
# belong to that box's inventory, not this one. Without the carve-out the row
# falls through the stale filter and a live workstream is briefed as absent.
has "reads the registry's remote field" '`remote`'
has "keeps a remote callee instead of dropping it as stale" 'remote callee on <host>, not inventoried here'
has "cues a remote callee as not inventoried" 'Your cue: nothing — remote host not inventoried'
has "names the remote host under Coverage" 'Coverage. line naming that host'

# --- bounded catch-up --------------------------------------------------------

has "uses the sessions-catch-up skill for unclear workstreams" 'session-tools:sessions-catch-up'
has "bounds the digest to eight turns with the real flag" '\-\-window 8'
# `8,?000` alone also matches the `--max-chars 8000` invocations above, so pin
# the bullet that carries the ceiling.
has "bounds the digest to 8,000 characters" '^- \*\*8,000 characters\*\*'
has "enforces the character ceiling with the real flag" '\-\-max-chars[= ]8000'
# `--max-chars` sheds cheapest-first and keeps `Recent turns`. Piping the
# finished digest through a byte-counting truncation instead cuts the tail — the
# newest turns, the ones that say where the agent stopped.
lacks "never byte-cuts the digest output" 'head -c'
has "states that sessions-catch-up is model-invocable" 'is model-invocable'
has "dispatches one cheap subagent per shortlisted row" 'one cheap subagent per shortlisted row'
# Rule zero promises the run changes nothing, and sessions-catch-up's own steps
# would break that: Step 4 writes the nudge ledger and Step 3 offers `--deep`.
has "work order skips the nudge bump so the briefing stays read-only" 'nudge\.mjs bump'
has "work order skips the --deep offer" 'skip its `--deep` offer'
# sessions-catch-up is model-invocable (34f84cb), so your-cue routes to it
# itself. A hedge about being unable to route degrades the briefing to a manual
# step the human has to run.
lacks "no hedge about being unable to route to sessions-catch-up" 'explicitly.invoked only|cue the human to run it'
has "delegates the summary to a cheaper model under Claude Code" 'model: "(haiku|sonnet)"'
has "tells Codex to invoke it inline when it has no subagent" '\-\-max-chars[= ]8000`? inline'
has "the main agent never reads the full transcript itself" 'never see the transcript'
has "stops after five summaries" '\*\*Stop after five summaries\.\*\*'
has "lists the remainder by visible locator" 'the remainder'

# --- rendering contract ------------------------------------------------------

has "renders the Waiting on you section" 'Waiting on you'
has "renders the Working section" '^Working$'
has "renders the Finished while you were away section" 'Finished while you were away'
has "every workstream ends with Your cue:" 'Your cue:'
has "explicit nothing cue keeps its reason" 'Your cue: nothing — '
has "one cue per workstream is stated as a rule" '[Ee]very workstream'
has "final line is Next for you:" 'Next for you:'
has "Next for you: nothing when everything is settled" 'Next for you: nothing'

# The rendering block is the human-facing contract, and the spec's `## Your cue`
# fence is its canonical form. Compare them literally rather than grepping for
# fragments, so a reworded section header cannot pass.
SPEC="$ROOT/docs/superpowers/specs/2026-09-11-your-cue.md"
extract_fence() { awk '/^```text$/{f=1;next} /^```$/{if(f)exit} f{print}' "$1"; }
if [[ -f "$SPEC" ]] && diff -q <(extract_fence "$SPEC") <(extract_fence "$SKILL") >/dev/null 2>&1; then
  pass "rendering block matches the spec's canonical \`## Your cue\` fence verbatim"
else
  fail "rendering block matches the spec's canonical \`## Your cue\` fence verbatim"
fi

# --- burial cues -------------------------------------------------------------

has "native host status outranks graveyard busy" '[Nn]ative status outranks'
has "burial cue requires graveyard buryable" 'buryable'
has "plot cue requires every targetable session" 'targetable'
has "offers bury this session" 'bury this session'
has "offers bury this plot" 'bury this plot'
has "burial stays text; execution needs a later explicit request" 'leaves execution to'
has "an unverified transcript downgrades to review, never to burial" '[Uu]nverified is not failed'
# The verb itself, not just the paragraph: the five-summary cap means most
# finished rows never had their transcript read, so this is the common branch.
has "the unverified branch names the review and close verb" 'Your cue: review and close'
has "defines one workstream for cue purposes" 'One workstream is one session'
has "a session that dialed nobody is still a workstream" 'workstream of one'

# --- dual-harness surface ----------------------------------------------------

if [[ -f "$OPENAI" ]]; then
  pass "agents/openai.yaml exists"
else
  fail "agents/openai.yaml exists"
fi
has "openai.yaml declares interface metadata" '^interface:' "$OPENAI"
lacks "openai.yaml has no policy block (implicit invocation stays allowed)" '^policy:' "$OPENAI"

# --- README ------------------------------------------------------------------

has "README documents the your-cue skill" '^### `your-cue`$' "$README"
has "README lists your-cue in the skill list" '\[`your-cue`\]\(skills/your-cue/SKILL.md\)' "$README"
has "README gives the your-cue triggers line" '\*\*Triggers\*\* when the user wants to know what their agents' "$README"

echo "${PASS} passed, ${FAIL} failed"
[[ $FAIL -eq 0 ]]
