#!/usr/bin/env bash
# Perform OAuth 2.0 loopback + PKCE login for the YouTube Data API v3 against
# the active gws account's client_secret.json (an "installed" / desktop-type
# OAuth client). Persists access+refresh tokens to
# <account-dir>/youtube_credentials.json (mode 0600).
#
# Device flow does NOT work with installed-type clients (Google returns
# invalid_client / "Invalid client type"). Loopback + PKCE is the standard
# installed-app flow and is what google-auth-oauthlib's run_local_server uses.
#
# Usage:
#   youtube-login.sh                 # active account
#   youtube-login.sh --account=LABEL # specific account dir
#   youtube-login.sh --force         # re-auth even if credentials exist
#   youtube-login.sh --json          # JSON output instead of human text
#   youtube-login.sh --no-browser    # print URL only; don't open browser

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=youtube-common.sh
source "$SCRIPT_DIR/youtube-common.sh"

YT_ACCOUNT_OVERRIDE=""
FORCE=0
JSON=0
NO_BROWSER=0
for arg in "$@"; do
  case "$arg" in
    --account=*)  YT_ACCOUNT_OVERRIDE="${arg#--account=}";;
    --force)      FORCE=1;;
    --json)       JSON=1;;
    --no-browser) NO_BROWSER=1;;
    -h|--help)
      awk 'NR==1{next} /^#/{sub(/^# ?/,""); print; next} {exit}' "$0"; exit 0;;
    *)
      echo "youtube-login.sh: unknown arg '$arg'" >&2; exit 2;;
  esac
done
export YT_ACCOUNT_OVERRIDE

yt_require_jq

if ! command -v python3 >/dev/null 2>&1; then
  echo "youtube-login.sh: requires python3 (used only for PKCE + loopback HTTP server)" >&2
  exit 1
fi

ACCOUNT_DIR="$(yt_resolve_account_dir)"
CS_PATH="$ACCOUNT_DIR/client_secret.json"
CREDS_PATH="$ACCOUNT_DIR/youtube_credentials.json"

if [[ ! -f "$CS_PATH" ]]; then
  echo "youtube-login.sh: missing $CS_PATH" >&2
  echo "  Run 'gws auth login' for this account first to install client_secret.json." >&2
  exit 1
fi

if [[ -f "$CREDS_PATH" && $FORCE -eq 0 ]]; then
  if [[ $JSON -eq 1 ]]; then
    jq -n --arg p "$CREDS_PATH" '{status:"already_authorized", credentials:$p}'
  else
    echo "Already authorized. Credentials at: $CREDS_PATH"
    echo "Pass --force to re-authenticate."
  fi
  exit 0
fi

CLIENT_ID="$(jq -r '.installed.client_id // .web.client_id // empty' "$CS_PATH")"
CLIENT_SECRET="$(jq -r '.installed.client_secret // .web.client_secret // empty' "$CS_PATH")"
if [[ -z "$CLIENT_ID" || -z "$CLIENT_SECRET" ]]; then
  echo "youtube-login.sh: could not parse client_id/client_secret from $CS_PATH" >&2
  exit 1
fi

# --- Step 1: PKCE verifier + challenge --------------------------------------
PKCE_PAIR="$(python3 - <<'PY'
import base64, hashlib, secrets
verifier = base64.urlsafe_b64encode(secrets.token_bytes(32)).rstrip(b"=").decode()
challenge = base64.urlsafe_b64encode(
    hashlib.sha256(verifier.encode()).digest()
).rstrip(b"=").decode()
state = secrets.token_urlsafe(16)
print(verifier)
print(challenge)
print(state)
PY
)"
VERIFIER="$(echo "$PKCE_PAIR" | sed -n 1p)"
CHALLENGE="$(echo "$PKCE_PAIR" | sed -n 2p)"
STATE="$(echo "$PKCE_PAIR" | sed -n 3p)"

# --- Step 2: launch one-shot loopback HTTP server ----------------------------
CAPTURE="$(mktemp -t yt-oauth-capture.XXXXXX)"
SERVER_LOG="$(mktemp -t yt-oauth-server.XXXXXX)"
trap 'rm -f "$CAPTURE" "$SERVER_LOG"' EXIT

# Server writes "code=<code>\nstate=<state>\n" to CAPTURE then exits 0. On
# error it writes "error=<msg>\n" and exits 1. Binds 127.0.0.1 on an OS-assigned
# free port and prints "PORT=<n>" to stdout so we can read it back.
python3 - "$CAPTURE" "$STATE" > "$SERVER_LOG" 2>&1 <<'PY' &
import http.server, socket, sys, urllib.parse, threading

capture_path, expected_state = sys.argv[1], sys.argv[2]

class Handler(http.server.BaseHTTPRequestHandler):
    def log_message(self, *a, **kw): pass
    def do_GET(self):
        qs = urllib.parse.urlparse(self.path).query
        params = dict(urllib.parse.parse_qsl(qs))
        if params.get("state") != expected_state:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(b"state mismatch")
            with open(capture_path, "w") as f:
                f.write("error=state_mismatch\n")
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return
        if "error" in params:
            self.send_response(400)
            self.end_headers()
            self.wfile.write(("auth error: " + params["error"]).encode())
            with open(capture_path, "w") as f:
                f.write("error=" + params["error"] + "\n")
            threading.Thread(target=self.server.shutdown, daemon=True).start()
            return
        code = params.get("code", "")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.end_headers()
        self.wfile.write(b"<html><body><h2>Authorization received.</h2>"
                         b"<p>You can close this tab and return to the terminal.</p>"
                         b"</body></html>")
        with open(capture_path, "w") as f:
            f.write("code=" + code + "\n")
            f.write("state=" + params.get("state", "") + "\n")
        threading.Thread(target=self.server.shutdown, daemon=True).start()

sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
sock.bind(("127.0.0.1", 0))
port = sock.getsockname()[1]
sock.close()
print("PORT=" + str(port), flush=True)

srv = http.server.HTTPServer(("127.0.0.1", port), Handler)
srv.timeout = 600
try:
    srv.serve_forever()
except Exception as e:
    print("server error: " + str(e), file=sys.stderr)
PY
SERVER_PID=$!
trap 'rm -f "$CAPTURE" "$SERVER_LOG"; kill "$SERVER_PID" 2>/dev/null || true' EXIT

# Wait for the server to print PORT=
PORT=""
for _ in $(seq 1 50); do
  if [[ -s "$SERVER_LOG" ]]; then
    PORT="$(grep -o 'PORT=[0-9]\+' "$SERVER_LOG" | head -1 | cut -d= -f2)"
    [[ -n "$PORT" ]] && break
  fi
  sleep 0.1
done
if [[ -z "$PORT" ]]; then
  echo "youtube-login.sh: failed to start loopback server" >&2
  cat "$SERVER_LOG" >&2
  exit 1
fi
REDIRECT_URI="http://127.0.0.1:$PORT"

# --- Step 3: build authorization URL + open browser --------------------------
SCOPE_ENC="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$YT_SCOPE")"
REDIRECT_ENC="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$REDIRECT_URI")"
CLIENT_ENC="$(python3 -c 'import urllib.parse,sys; print(urllib.parse.quote(sys.argv[1], safe=""))' "$CLIENT_ID")"
AUTH_URL="https://accounts.google.com/o/oauth2/v2/auth"
AUTH_URL+="?response_type=code"
AUTH_URL+="&client_id=$CLIENT_ENC"
AUTH_URL+="&redirect_uri=$REDIRECT_ENC"
AUTH_URL+="&scope=$SCOPE_ENC"
AUTH_URL+="&code_challenge=$CHALLENGE"
AUTH_URL+="&code_challenge_method=S256"
AUTH_URL+="&state=$STATE"
AUTH_URL+="&access_type=offline"
AUTH_URL+="&prompt=consent"

echo ""
echo "  Opening browser to:"
echo "    $AUTH_URL"
echo ""
echo "  (Listening on $REDIRECT_URI for the redirect.)"
echo ""

if [[ $NO_BROWSER -eq 0 ]]; then
  if [[ "$OSTYPE" == darwin* ]] && command -v open >/dev/null 2>&1; then
    open "$AUTH_URL" >/dev/null 2>&1 || true
  elif command -v xdg-open >/dev/null 2>&1; then
    xdg-open "$AUTH_URL" >/dev/null 2>&1 || true
  else
    echo "  (no browser-open command; copy the URL above into a browser manually)"
  fi
fi

# --- Step 4: wait for callback ----------------------------------------------
DEADLINE=$(( $(date +%s) + 600 ))
while :; do
  if [[ -s "$CAPTURE" ]]; then break; fi
  if (( $(date +%s) >= DEADLINE )); then
    echo "youtube-login.sh: timed out waiting for browser callback" >&2
    exit 1
  fi
  sleep 0.5
done
wait "$SERVER_PID" 2>/dev/null || true

CALLBACK_ERR="$(grep -E '^error=' "$CAPTURE" | head -1 | cut -d= -f2- || true)"
if [[ -n "$CALLBACK_ERR" ]]; then
  echo "youtube-login.sh: $CALLBACK_ERR" >&2
  exit 1
fi
CODE="$(grep -E '^code=' "$CAPTURE" | head -1 | cut -d= -f2-)"
if [[ -z "$CODE" ]]; then
  echo "youtube-login.sh: no authorization code in callback" >&2
  cat "$CAPTURE" >&2
  exit 1
fi

# --- Step 5: exchange code + verifier for tokens -----------------------------
TOKEN_RESP="$(curl -sS -X POST "$YT_TOKEN_URL" \
  --data-urlencode "client_id=$CLIENT_ID" \
  --data-urlencode "client_secret=$CLIENT_SECRET" \
  --data-urlencode "code=$CODE" \
  --data-urlencode "code_verifier=$VERIFIER" \
  --data-urlencode "redirect_uri=$REDIRECT_URI" \
  --data-urlencode "grant_type=authorization_code")"

ACCESS="$(echo "$TOKEN_RESP" | jq -r '.access_token // empty')"
REFRESH="$(echo "$TOKEN_RESP" | jq -r '.refresh_token // empty')"
EXPIRES_IN="$(echo "$TOKEN_RESP" | jq -r '.expires_in // empty')"
SCOPE_GRANTED="$(echo "$TOKEN_RESP" | jq -r '.scope // empty')"

if [[ -z "$ACCESS" || -z "$EXPIRES_IN" ]]; then
  echo "youtube-login.sh: token exchange failed:" >&2
  echo "$TOKEN_RESP" >&2
  exit 1
fi
if [[ -z "$REFRESH" ]]; then
  echo "youtube-login.sh: no refresh_token in response — revoke prior grant at" >&2
  echo "  https://myaccount.google.com/permissions and re-run with --force." >&2
  exit 1
fi

NOW="$(date +%s)"
EXP=$(( NOW + EXPIRES_IN - 30 ))

umask 077
TMP="$(mktemp "${CREDS_PATH}.XXXXXX")"
jq -n \
  --arg at "$ACCESS" \
  --arg rt "$REFRESH" \
  --argjson exp "$EXP" \
  --arg sc "$SCOPE_GRANTED" \
  '{access_token:$at, refresh_token:$rt, expires_at:$exp, scope:$sc, token_uri:"https://oauth2.googleapis.com/token"}' \
  > "$TMP"
chmod 600 "$TMP"
mv "$TMP" "$CREDS_PATH"

if [[ $JSON -eq 1 ]]; then
  jq -n --arg p "$CREDS_PATH" --arg a "$(yt_active_label)" \
    '{status:"success", account:$a, credentials:$p}'
else
  echo "Authorization successful."
  echo "  Account: $(yt_active_label)"
  echo "  Credentials: $CREDS_PATH (mode 0600)"
  echo ""
  echo "  When done with YouTube ops, run:"
  echo "    bash $SCRIPT_DIR/youtube-logout.sh"
fi
