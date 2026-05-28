#!/usr/bin/env bash
# Manage the weekly sessions-weekly-recap launchd job on macOS.
# Writes a plist that fires `claude -p "/sessions-weekly-recap --weekly ..."` on a schedule.
#
# Usage:
#   install_cron.sh install --output-dir "<path>" [--day mon] [--time 09:00]
#   install_cron.sh uninstall
#   install_cron.sh status
#   install_cron.sh logs
#   install_cron.sh run-now

set -euo pipefail

LABEL="com.jtsternberg.sessions-weekly-recap"
PLIST="$HOME/Library/LaunchAgents/${LABEL}.plist"
RUNNER="$HOME/Library/LaunchAgents/${LABEL}.runner.sh"
LOG_DIR="$HOME/.claude/logs"
OUT_LOG="$LOG_DIR/sessions-weekly-recap.out.log"
ERR_LOG="$LOG_DIR/sessions-weekly-recap.err.log"
LOOKBACK_WEEKS="${SESSIONS_RECAP_LOOKBACK_WEEKS:-4}"

die() { echo "Error: $*" >&2; exit 1; }

# Map day name → launchd Weekday integer (Sun=0, Mon=1, ..., Sat=6)
day_to_int() {
  case "$(echo "$1" | tr '[:upper:]' '[:lower:]')" in
    sun|sunday) echo 0 ;;
    mon|monday) echo 1 ;;
    tue|tuesday) echo 2 ;;
    wed|wednesday) echo 3 ;;
    thu|thursday) echo 4 ;;
    fri|friday) echo 5 ;;
    sat|saturday) echo 6 ;;
    *) die "Unknown day: $1 (use mon/tue/wed/thu/fri/sat/sun)" ;;
  esac
}

# XML-escape a string for safe embedding in the plist.
xml_escape() {
  python3 -c 'import html,sys;print(html.escape(sys.argv[1], quote=True))' "$1"
}

find_claude() {
  local path
  path="$(command -v claude || true)"
  [ -n "$path" ] || die "claude binary not found in PATH"
  echo "$path"
}

cmd_install() {
  local output_dir="" day="mon" time="09:00"
  while [ $# -gt 0 ]; do
    case "$1" in
      --output-dir) output_dir="$2"; shift 2 ;;
      --day)        day="$2";        shift 2 ;;
      --time)       time="$2";       shift 2 ;;
      *) die "Unknown flag: $1" ;;
    esac
  done

  [ -n "$output_dir" ] || die "--output-dir is required"
  [[ "$time" =~ ^[0-9]{1,2}:[0-9]{2}$ ]] || die "--time must be HH:MM (got: $time)"

  # Expand leading ~ to $HOME so mkdir and the launchd plist get a real absolute
  # path. Without this, quoted paths like "~/notes" stay literal and the
  # scheduled job writes to a bogus directory.
  output_dir="${output_dir/#\~/$HOME}"

  local weekday hour minute claude_bin
  weekday="$(day_to_int "$day")"
  hour="${time%:*}"; hour="${hour#0}"; [ -z "$hour" ] && hour=0
  minute="${time#*:}"; minute="${minute#0}"; [ -z "$minute" ] && minute=0
  claude_bin="$(find_claude)"

  mkdir -p "$LOG_DIR" "$HOME/Library/LaunchAgents" "$output_dir"

  # Write a runner script that catches up any missing weekly recaps from the
  # last $LOOKBACK_WEEKS completed weeks. Skips weeks whose file already exists.
  # Filename convention matches the skill output: Week-M.D.YY.md (no zero-pad).
  cat > "$RUNNER" <<RUNNER
#!/usr/bin/env bash
set -uo pipefail
OUTPUT_DIR="$output_dir"
CLAUDE_BIN="$claude_bin"
LOOKBACK_WEEKS=${LOOKBACK_WEEKS}

dow=\$(date +%u)              # 1=Mon..7=Sun
days_back=\$((dow - 1))       # days since most recent Monday

ran_any=0
for i in \$(seq 1 "\$LOOKBACK_WEEKS"); do
  offset=\$((days_back + i * 7))
  mon=\$(date -v-\${offset}d +%Y-%m-%d)
  sun=\$(date -j -v+6d -f %Y-%m-%d "\$mon" +%Y-%m-%d)
  m=\$(date -j -f %Y-%m-%d "\$mon" +%-m)
  d=\$(date -j -f %Y-%m-%d "\$mon" +%-d)
  yy=\$(date -j -f %Y-%m-%d "\$mon" +%y)
  fname="Week-\${m}.\${d}.\${yy}.md"
  fpath="\$OUTPUT_DIR/\$fname"
  if [ -f "\$fpath" ]; then
    echo "[\$(date '+%F %T')] skip \$fname (exists)"
    continue
  fi
  echo "[\$(date '+%F %T')] run  \$fname (\$mon → \$sun)"
  cd "\$HOME"
  "\$CLAUDE_BIN" -p "/sessions-weekly-recap --weekly --since \$mon --until \$sun --output-dir \"\$OUTPUT_DIR\"" --dangerously-skip-permissions || \\
    echo "[\$(date '+%F %T')] claude exited non-zero for \$fname"
  ran_any=1
done

if [ "\$ran_any" = "0" ]; then
  echo "[\$(date '+%F %T')] no missing weeks in last \$LOOKBACK_WEEKS"
fi
RUNNER
  chmod +x "$RUNNER"

  local runner_escaped
  runner_escaped="$(xml_escape "$RUNNER")"

  cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${LABEL}</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-l</string>
        <string>${runner_escaped}</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>HOME</key>
        <string>${HOME}</string>
    </dict>
    <key>StartCalendarInterval</key>
    <dict>
        <key>Weekday</key>
        <integer>${weekday}</integer>
        <key>Hour</key>
        <integer>${hour}</integer>
        <key>Minute</key>
        <integer>${minute}</integer>
    </dict>
    <key>StandardOutPath</key>
    <string>${OUT_LOG}</string>
    <key>StandardErrorPath</key>
    <string>${ERR_LOG}</string>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
PLIST

  # Reload: unload if present, then load.
  launchctl unload "$PLIST" 2>/dev/null || true
  launchctl load "$PLIST"

  echo "Installed: $LABEL"
  echo "  Runs:      $day @ $time"
  echo "  Output:    $output_dir"
  echo "  Plist:     $PLIST"
  echo "  Logs:      $OUT_LOG"
  echo "             $ERR_LOG"
}

cmd_uninstall() {
  if [ -f "$PLIST" ]; then
    launchctl unload "$PLIST" 2>/dev/null || true
    rm -f "$PLIST" "$RUNNER"
    echo "Uninstalled: $LABEL"
  else
    echo "Not installed (no plist at $PLIST)"
  fi
}

cmd_status() {
  if [ -f "$PLIST" ]; then
    echo "Plist:   $PLIST"
  else
    echo "Plist:   not installed"
    return 0
  fi
  local loaded
  loaded="$(launchctl list | awk -v l="$LABEL" '$3==l {print $0}')"
  if [ -n "$loaded" ]; then
    echo "Loaded:  yes"
    echo "$loaded" | awk '{printf "  PID=%s  LastExit=%s\n", $1, $2}'
  else
    echo "Loaded:  no"
  fi
  echo "Logs:    $OUT_LOG"
  echo "         $ERR_LOG"
}

cmd_logs() {
  [ -f "$OUT_LOG" ] && { echo "== stdout ($OUT_LOG) =="; tail -n 40 "$OUT_LOG"; echo; }
  [ -f "$ERR_LOG" ] && { echo "== stderr ($ERR_LOG) =="; tail -n 40 "$ERR_LOG"; }
  [ ! -f "$OUT_LOG" ] && [ ! -f "$ERR_LOG" ] && echo "No logs yet."
}

cmd_run_now() {
  [ -f "$PLIST" ] || die "Not installed. Run: install_cron.sh install --output-dir \"...\""
  launchctl start "$LABEL"
  echo "Triggered: $LABEL"
  echo "Watch: tail -f \"$OUT_LOG\" \"$ERR_LOG\""
}

case "${1:-}" in
  install)   shift; cmd_install   "$@" ;;
  uninstall) cmd_uninstall ;;
  status)    cmd_status ;;
  logs)      cmd_logs ;;
  run-now)   cmd_run_now ;;
  ""|help|-h|--help)
    sed -n '2,12p' "$0"
    ;;
  *) die "Unknown action: $1 (use install|uninstall|status|logs|run-now)" ;;
esac
