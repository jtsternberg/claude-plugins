#!/usr/bin/env python3
# =============================================================================
# cmux-rpc — speak one JSON-RPC call to cmux's control socket.
#
# Exists because `cmux rpc` is ARGV-ONLY: it takes its params as a positional
# JSON string, with no stdin, no @file, and no env form (verified against
# cmux.swift:19845). Putting a hotline payload there would publish whole work
# orders to `ps` for every local user, which is the leak this helper closes
# (claude-plugins-86ka). Here the payload is read from a FILE and JSON-escaped
# in-process, so it never appears in an argument list or an environment.
#
# python3 stdlib only — no third-party imports, nothing to install.
#
# Wire protocol (cmux CmuxControlSocket): a unix stream socket carrying
# newline-delimited JSON. One request line {"id","method","params"} in, one
# response line {"id","ok",...} back. Single-line requests are accepted well past
# any plausible hotline payload — a live probe put 16MB through in one line — so
# the whole payload always goes in one paste and there is no size tier to pick.
# (An earlier comment here said 256KB, which is ~64x low; don't size a guard from
# that number.)
#
# Usage:
#   cmux-rpc.py --method terminal.paste --workspace <uuid> --surface <uuid>
#               --payload-file <path> [--submit-key return|ctrl+enter|none]
#   cmux-rpc.py --method system.capabilities
#   cmux-rpc.py --method terminal.replay --workspace <uuid> --surface <uuid>
#                                        [--anchor screen|viewport]
#   cmux-rpc.py --method <any> --params-file <path-to-json>
#
# EVERY PARAM KEY IS snake_case, and that is not a style choice. cmux DROPS
# unrecognised targeting keys and then resolves the call against the FOCUSED
# surface, returning ok:true: `{"workspaceId":…,"surfaceId":…}` reads a bystander's
# terminal and reports success (claude-plugins-r465.9). Because a silent retarget
# cannot be detected from ok:true alone, this helper also VERIFIES that the reply's
# result.surface_id is the surface it asked for, and exits 4 when it is not.
#
# The response line is echoed on stdout exactly as received, so callers can
# jq it. Diagnostics go to stderr.
#
# Exit codes — an exit code alone never means "the callee got it", only "the
# socket accepted it"; delivery is confirmed separately by the caller:
#   0  response had ok:true, for the surface we addressed
#   1  response had ok:false (its .error is on stderr too)
#   2  usage error (bad flags, unreadable payload file)
#   3  transport failure: no socket, connect/timeout, unparseable response
#   4  ok:true but the reply names a DIFFERENT surface than the request did —
#      treat the payload as another surface's and never act on it
# =============================================================================
import argparse
import json
import os
import socket
import sys
import uuid

DEFAULT_TIMEOUT = 20.0


def resolve_socket_path():
    """$CMUX_SOCKET_PATH → ~/.local/state/cmux/last-socket-path → cmux.sock.

    The middle hop is not optional politeness: cmux writes a per-uid socket
    (cmux-501.sock) and records its path in last-socket-path, while the legacy
    cmux.sock can still exist from an older run and accept nothing. Skipping
    straight to the legacy name reaches a dead socket on a live machine.
    """
    env = os.environ.get("CMUX_SOCKET_PATH")
    if env:
        return env
    pointer = os.path.expanduser("~/.local/state/cmux/last-socket-path")
    try:
        with open(pointer, "r") as fh:
            recorded = fh.read().strip()
        if recorded:
            return recorded
    except OSError:
        pass
    return os.path.expanduser("~/.local/state/cmux/cmux.sock")


def build_line(method, params):
    """One request line. json.dumps escapes newlines, quotes and control bytes,
    so a multi-line payload stays a single line on the wire."""
    request = {"id": str(uuid.uuid4()), "method": method, "params": params}
    line = json.dumps(request, separators=(",", ":"))
    # Callers that are NOT descendants of the cmux app (cron, LaunchAgent) must
    # present a capability token; descendants are authorised by ancestry and
    # need no envelope. Sending it when it exists is harmless either way.
    token = os.environ.get("CMUX_SOCKET_CAPABILITY")
    if token:
        line = "_cmux_capability_v1 %s %s" % (token, line)
    return line


def rpc(line, sock_path, timeout=DEFAULT_TIMEOUT):
    conn = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    conn.settimeout(timeout)
    try:
        conn.connect(sock_path)
        conn.sendall((line + "\n").encode("utf-8"))
        buf = b""
        while b"\n" not in buf:
            chunk = conn.recv(65536)
            if not chunk:
                break
            buf += chunk
    finally:
        conn.close()
    if not buf:
        raise IOError("socket closed with no response")
    return buf.split(b"\n", 1)[0].decode("utf-8", "replace")


def main(argv):
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("--method", default="terminal.paste")
    ap.add_argument("--workspace")
    ap.add_argument("--surface")
    ap.add_argument("--payload-file")
    ap.add_argument("--params-file")
    ap.add_argument("--submit-key", default="return")
    ap.add_argument("--anchor")
    ap.add_argument("--timeout", type=float, default=DEFAULT_TIMEOUT)
    args = ap.parse_args(argv)

    if args.params_file:
        try:
            with open(args.params_file, "r") as fh:
                params = json.load(fh)
        except (OSError, ValueError) as exc:
            sys.stderr.write("cmux-rpc: --params-file unreadable: %s\n" % exc)
            return 2
    elif args.method == "terminal.paste":
        if not (args.workspace and args.surface and args.payload_file):
            sys.stderr.write(
                "cmux-rpc: terminal.paste needs --workspace, --surface and "
                "--payload-file\n")
            return 2
        try:
            with open(args.payload_file, "rb") as fh:
                text = fh.read().decode("utf-8")
        except OSError as exc:
            sys.stderr.write("cmux-rpc: --payload-file unreadable: %s\n" % exc)
            return 2
        except UnicodeDecodeError as exc:
            sys.stderr.write("cmux-rpc: --payload-file is not UTF-8: %s\n" % exc)
            return 2
        if not text:
            sys.stderr.write("cmux-rpc: --payload-file is empty\n")
            return 2
        params = {
            "text": text,
            "workspace_id": args.workspace,
            "surface_id": args.surface,
            "submit_key": args.submit_key,
        }
    else:
        # Any other method addresses a surface the same way terminal.paste does, so
        # --workspace/--surface build its params without a --params-file detour.
        # UUIDs in an argv are not the leak --payload-file exists to close; they are
        # already there for the paste.
        params = {}
        if args.workspace:
            params["workspace_id"] = args.workspace
        if args.surface:
            params["surface_id"] = args.surface
        # anchor:"screen" pins a render_grid read to the live primary screen, so a
        # user-scrolled pane still answers with the current tail; the default
        # "viewport" follows the scroll. Passed through rather than defaulted here,
        # because a cmux without terminal.render_grid.screen_anchor.v1 should not be
        # handed a param it does not know.
        if args.anchor:
            params["anchor"] = args.anchor

    sock_path = resolve_socket_path()
    line = build_line(args.method, params)
    try:
        response = rpc(line, sock_path, args.timeout)
    except (OSError, IOError, socket.timeout) as exc:
        sys.stderr.write("cmux-rpc: %s (socket %s)\n" % (exc, sock_path))
        return 3

    print(response)
    try:
        parsed = json.loads(response)
    except ValueError:
        sys.stderr.write("cmux-rpc: response was not JSON\n")
        return 3
    if parsed.get("ok") is True:
        # Did we get an answer about the surface we ASKED about? ok:true does not
        # say so: a dropped or unparseable target silently becomes the focused
        # surface. Compared against the params actually sent, so a --params-file
        # caller is covered too, and skipped when either side has no surface_id
        # (system.capabilities has none to echo).
        asked = params.get("surface_id") if isinstance(params, dict) else None
        got = (parsed.get("result") or {}).get("surface_id")
        if (isinstance(asked, str) and isinstance(got, str)
                and asked.lower() != got.lower()):
            sys.stderr.write(
                "cmux-rpc: RETARGETED — asked for surface %s, reply is for %s. "
                "cmux fell back to the focused surface; refusing to return its "
                "payload as ours (claude-plugins-r465.9).\n" % (asked, got))
            return 4
        return 0
    sys.stderr.write("cmux-rpc: ok:false — %s\n" % json.dumps(parsed.get("error")))
    return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
