# maestro plugin

New plugin `plugins/maestro/` — orchestration stance for a main agent overseeing
delegated multi-agent pipelines (implement → review → address). Distilled from a
real orchestration run (session 515bbb92, lindris epic); the authoring session was
interviewed to separate what an intelligent agent does anyway from the genuinely
non-obvious rules. Only the latter survive.

Two skills:

- `conduct` — the stance. Deliberately small: boss/doer split, fresh-session-per-phase
  (with the hotline session-cache-clear mechanic), work-order anatomy, waiting
  forensics, verify-before-relay, "Next for you:" contract. Tooling is bound by
  pointers (`/hotline:hotline-dial`, `/cmux-cli:using-cmux-cli`), not duplicated docs;
  recommends hotline/cmux when absent, falls back to subagents/headless sessions.
- `patient-waiting` — moved in from `~/.claude/skills/` so conduct's pointer resolves
  for every installer. Verbatim. Retire the user-level copy once maestro is installed.

Follow-up filed as a bd task: hotline `dial.sh` needs a `--fresh` flag — today,
forcing a fresh session per phase means hand-deleting the caller→target entry in
`~/.agents-hotline/sessions/<caller>.json`.
