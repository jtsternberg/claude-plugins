#!/usr/bin/env python3
# =============================================================================
# Control-socket stub for the hotline suites.
#
# WHY THIS EXISTS: hotline delivers payloads by writing straight to cmux's unix
# control socket, which a PATH stub cannot intercept. Without this seam the
# poison-stub discipline the other suites rely on has a hole exactly where the
# payload is — a test could "pass" while pasting a fixture into the developer's
# own live REPL.
#
# So every suite that can reach a socket call points $CMUX_SOCKET_PATH here. The
# stub logs each request LINE verbatim (one per line, newline-escaped by the
# sender's own json.dumps, so a multi-line payload stays one log line) and answers
# from a canned response file.
#
# POISON BY DEFAULT: started with --poison, it answers ok:false and appends the
# request to the violations file, so a case that forgot to stage a response fails
# loudly instead of silently succeeding.
#
# Usage:
#   socket-stub.py --socket <path> --requests <log> [--responses <json>]
#                  [--poison --violations <log>] [--pidfile <path>]
#
# --responses is a JSON object mapping method name -> response object, plus an
# optional "_default". Each response is echoed with the request's own id merged
# in, which is what the real socket does.
#
# Runs until killed. Serves connections one at a time, which matches the wire
# protocol: one request line per connection, one response line back.
# =============================================================================
import argparse
import json
import os
import socket
import sys
import threading

ap = argparse.ArgumentParser()
ap.add_argument("--socket", required=True)
ap.add_argument("--requests", required=True)
ap.add_argument("--responses")
ap.add_argument("--poison", action="store_true")
ap.add_argument("--violations")
ap.add_argument("--pidfile")
# Appends a terminal.paste's `text` to a file, so a `cmux read-screen` stub can
# cat it and the pasted nonce shows up on the fake screen exactly as it would in
# a real REPL. Omit it to model a paste whose bytes never arrived.
ap.add_argument("--echo-file")
# Rejects terminal.paste for ONE surface id while accepting it everywhere else —
# the shape a suite needs to make delivery into a stale surface fail without
# breaking delivery into its replacement.
ap.add_argument("--reject-surface")
args = ap.parse_args()

RESPONSES = {}
if args.responses:
    with open(args.responses) as fh:
        RESPONSES = json.load(fh)

try:
    os.unlink(args.socket)
except OSError:
    pass

srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
srv.bind(args.socket)
os.chmod(args.socket, 0o600)
srv.listen(8)

if args.pidfile:
    with open(args.pidfile, "w") as fh:
        fh.write(str(os.getpid()))

# Announce readiness on stdout so a shell harness can block on it rather than
# sleeping and hoping. A fixed sleep here is the classic flaky-test source.
sys.stdout.write("READY\n")
sys.stdout.flush()


def log(path, text):
    with open(path, "a") as fh:
        fh.write(text.rstrip("\n") + "\n")


def handle(conn):
    conn.settimeout(10.0)
    buf = b""
    try:
        while b"\n" not in buf:
            chunk = conn.recv(65536)
            if not chunk:
                break
            buf += chunk
        if not buf:
            return
        line = buf.split(b"\n", 1)[0].decode("utf-8", "replace")
        log(args.requests, line)

        # The capability envelope is a prefix on the same line; strip it before
        # parsing, and record that it was present so a test can assert on it.
        payload = line
        if payload.startswith("_cmux_capability_v1 "):
            parts = payload.split(" ", 2)
            payload = parts[2] if len(parts) == 3 else "{}"
        try:
            req = json.loads(payload)
        except ValueError:
            req = {}
        method = req.get("method", "")
        req_id = req.get("id", "")

        surface = req.get("params", {}).get("surface_id", "")
        rejected = (method == "terminal.paste"
                    and args.reject_surface
                    and surface == args.reject_surface)

        if args.echo_file and method == "terminal.paste" and not rejected:
            log(args.echo_file, req.get("params", {}).get("text", ""))

        if args.poison:
            if args.violations:
                log(args.violations, "UNSTUBBED SOCKET CALL: " + line[:400])
            resp = {"ok": False,
                    "error": {"message": "TEST BUG: unstubbed socket call"}}
        elif rejected:
            resp = {"ok": False,
                    "error": {"message": "surface %s refused the paste" % surface}}
        else:
            resp = RESPONSES.get(method) or RESPONSES.get("_default") \
                or {"ok": True, "result": {}}
        resp = dict(resp)
        resp["id"] = req_id
        conn.sendall((json.dumps(resp, separators=(",", ":")) + "\n").encode())
    except Exception as exc:  # never take the stub down over one bad client
        log(args.requests, "STUB ERROR: %s" % exc)
    finally:
        try:
            conn.close()
        except OSError:
            pass


while True:
    try:
        client, _ = srv.accept()
    except OSError:
        break
    threading.Thread(target=handle, args=(client,), daemon=True).start()
