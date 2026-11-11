#!/usr/bin/env python3
"""Opt-in, one-shot Codex caller wake. A shell waiter alone is not a callback.

arm CALL_DIR --caller-thread UUID --caller-home ABSOLUTE_HOME [--timeout SECONDS]
status CALL_DIR

Arming checks the owning rollout and running local daemon, snapshots the waiter
runtime into the private call dir, and waits for a detached worker handshake.
`arrived` means a nonce-bearing USER message was observed in that caller's rollout;
it does not mean the model acted on it. Queue acceptance alone is `enqueued`.
One enqueue attempt per call, including ambiguous failures. Re-arming resumes
only a dead pre-enqueue waiter; it never re-dials or retries an uncertain enqueue.
"""
import argparse
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import signal
import subprocess
import sys
import time
import uuid


LIMIT = 8192
TERMINAL = {"arrived", "arrival_unconfirmed", "enqueue_failed", "enqueue_unknown",
            "receiver_unavailable", "arm_failed"}


def write_json(path, value):
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value) + "\n")
    temporary.replace(path)


def read_json(path):
    return json.loads(path.read_text())


def record(job, state, **details):
    value = {"state": state, "time": time.time(), **details}
    write_json(job / "status.json", value)
    return value


def owning_rollout(home, thread):
    if not home.is_absolute() or not home.is_dir():
        raise ValueError("caller home must be an existing absolute directory")
    matches = list((home / "sessions").rglob(f"rollout-*-{thread}.jsonl"))
    if len(matches) != 1:
        raise ValueError("caller home must contain exactly one rollout for the exact caller thread; no home fallback")
    path = matches[0].resolve()
    if not path.is_relative_to(home.resolve()):
        raise ValueError("caller rollout escapes its home")
    with path.open() as handle:
        meta = json.loads(handle.readline())
    if meta.get("type") != "session_meta" or meta.get("payload", {}).get("id") != thread:
        raise ValueError("caller rollout identity mismatch")
    return path


def codex_binary():
    # cmux's codex shim adds flags that queue rejects. Inspect executable wrappers,
    # never credentials/config or process environments.
    for directory in os.get_exec_path():
        candidate = shutil.which("codex", path=directory) if directory else None
        if not candidate or "cmux-cli-shims" in Path(candidate).parts:
            continue
        with open(candidate, "rb") as handle:
            if b"cmux-codex-wrapper" in handle.read(16384):
                continue
        return os.path.abspath(candidate)
    raise ValueError("real codex executable unavailable")


def command(config, args, timeout=10):
    return subprocess.run([config["codex"], *args], stdin=subprocess.DEVNULL,
        capture_output=True, env=dict(os.environ, CODEX_HOME=config["home"]), timeout=timeout)


def receiver(config):
    result = command(config, ["app-server", "daemon", "version"])
    if result.returncode:
        raise ValueError("cannot check running Codex daemon")
    data = json.loads(result.stdout)
    expected = Path(config["home"]) / "app-server-control/app-server-control.sock"
    if data.get("status") != "running" or data.get("socketPath") != str(expected):
        raise ValueError("caller home has no verified running local Codex daemon")
    # This is a process/receiver check, not a claim that a future enqueue will land.
    return data


def live_worker(job, pid):
    result = subprocess.run(["ps", "-p", str(pid), "-o", "command="], capture_output=True, text=True)
    return result.returncode == 0 and f"{job}/runtime/scripts/completion-watch.py work {job}" in result.stdout


def snapshot(job):
    root = Path(__file__).resolve().parents[1]
    # Preserve the waiter's relative layout and all bundled transitive helpers.
    # Only shipped script directories are copied; no caller files or credentials.
    for relative in ("scripts", "skills/dial/scripts"):
        shutil.copytree(root / relative, job / "runtime" / relative, dirs_exist_ok=True)


def arm(args):
    thread = str(uuid.UUID(args.caller_thread))
    current_thread = os.environ.get("CODEX_THREAD_ID")
    if current_thread and str(uuid.UUID(current_thread)) != thread:
        raise ValueError("caller UUID differs from the calling thread's CODEX_THREAD_ID")
    call = Path(args.call_dir).resolve(strict=True)
    nonce = (call / "call_id.txt").read_text().strip()
    if not re.fullmatch(r"[A-Za-z0-9_-]+", nonce):
        raise ValueError("call_id.txt must contain a call nonce")
    home_arg = Path(args.caller_home)
    rollout = owning_rollout(home_arg, thread)
    config = {"thread": thread, "home": str(home_arg.resolve()), "call": str(call),
              "nonce": nonce, "rollout": str(rollout), "codex": codex_binary(),
              "timeout": args.timeout, "arrival_timeout": args.arrival_timeout}
    job = call / "completion"
    job.mkdir(mode=0o700, exist_ok=True)
    if job.is_symlink() or job.stat().st_uid != os.getuid():
        raise ValueError("completion directory must be owned by this user and not a symlink")
    job.chmod(0o700)
    with (job / "arm.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        if (job / "config.json").exists():
            old = read_json(job / "config.json")
            if any(old[key] != config[key] for key in ("thread", "home", "call", "nonce", "rollout")):
                raise ValueError("call already armed with a different caller identity")
            state = read_json(job / "status.json") if (job / "status.json").exists() else {}
            if state.get("state") in TERMINAL:
                return {"job": str(job), **state, "reused": True}
            if (job / "ready.json").exists():
                ready = read_json(job / "ready.json")
                if live_worker(job, ready["pid"]):
                    return {"job": str(job), **state, "pid": ready["pid"], "watcher_live": True, "reused": True}
            if (job / "enqueue.started").exists():
                state = record(job, "enqueue_unknown", detail="worker stopped after enqueue attempt began; do not retry")
                return {"job": str(job), **state, "reused": True}
        else:
            snapshot(job)
        try:
            receiver(config)
            help_result = command(config, ["queue", "--help"])
            if help_result.returncode or not all(x in help_result.stdout for x in (b"--thread", b"--message", b"--resume")):
                raise ValueError("codex queue --resume capability unavailable")
        except (ValueError, OSError, subprocess.SubprocessError) as error:
            record(job, "arm_failed", detail=str(error)[:1000])
            raise
        config["handshake"] = uuid.uuid4().hex
        write_json(job / "config.json", config)
        (job / "go").unlink(missing_ok=True)
        (job / "ready.json").unlink(missing_ok=True)
        with (job / "worker.log").open("ab") as log:
            process = subprocess.Popen([sys.executable, str(job / "runtime/scripts/completion-watch.py"), "work", str(job)],
                stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True, close_fds=True)
        deadline = time.monotonic() + 15
        while time.monotonic() < deadline:
            if process.poll() is not None:
                raise ValueError(f"worker exited before arming; inspect {job}/status.json and worker.log")
            if (job / "ready.json").exists():
                ready = read_json(job / "ready.json")
                if ready.get("handshake") == config["handshake"] and ready.get("pid") == process.pid:
                    (job / "go").touch()
                    return {"state": "armed", "job": str(job), "pid": process.pid,
                            "thread": thread, "home": config["home"]}
            time.sleep(0.02)
        process.terminate()
        process.wait(timeout=5)
        record(job, "arm_failed", detail="worker handshake timeout")
        raise ValueError("worker handshake timeout; keep waiting in foreground")


def arrival(path, offset, marker):
    # Only submitted user input counts. Queue rows, assistant text and tool calls
    # containing the nonce cannot turn an enqueue acknowledgment into delivery.
    with path.open() as handle:
        handle.seek(offset)
        for line in handle:
            try:
                row = json.loads(line)
            except ValueError:
                continue
            payload = row.get("payload", {})
            if row.get("type") == "event_msg" and payload.get("type") == "user_message" and marker in payload.get("message", ""):
                return True
            if row.get("type") == "response_item" and payload.get("type") == "message" and payload.get("role") == "user":
                if any(marker in part.get("text", "") for part in payload.get("content", [])):
                    return True
    return False


def work(job):
    config = read_json(job / "config.json")
    with (job / "worker.lock").open("a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            receiver(config)
            record(job, "armed")
            write_json(job / "ready.json", {"pid": os.getpid(), "handshake": config["handshake"]})
            deadline = time.monotonic() + 15
            while not (job / "go").exists():
                if time.monotonic() >= deadline:
                    raise ValueError("arming parent never acknowledged worker")
                time.sleep(0.02)
            record(job, "waiting")
            call = Path(config["call"])
            try:
                process = subprocess.Popen(["bash", str(job / "runtime/skills/dial/scripts/wait-for-response.sh"),
                    str(call), "--timeout", str(config["timeout"])], stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, start_new_session=True)
                _, stderr = process.communicate(timeout=config["timeout"] + 15)
                (job / "waiter.stderr").write_bytes(stderr[:LIMIT])
                rc = process.returncode
            except subprocess.TimeoutExpired as error:
                # The group is ours and its unreaped leader is still alive. Kill
                # only this waiter's descendants, then reap before reporting.
                if process.poll() is None:
                    os.killpg(process.pid, signal.SIGKILL)
                process.communicate()
                (job / "waiter.stderr").write_bytes((error.stderr or b"")[:LIMIT])
                rc = 124
            # Notify even for a resumable waiter failure: the caller must learn that
            # waiting stopped. Never call dial.sh; resuming cannot resend the work.
            record(job, "waiting", waiter_exit=rc)
            rollout = owning_rollout(Path(config["home"]), config["thread"])
            if (call / "call_id.txt").read_text().strip() != config["nonce"]:
                raise ValueError("call nonce changed after arming")
            receiver(config)
            offset = rollout.stat().st_size
            marker = f"[Hotline completion] call_id={config['nonce']}"
            message = (f"{marker} waiter_exit={rc}. Read {call}/response.json if present and "
                       f"{job}/status.json, waiter.stderr. Relay the result or failure. "
                       "If waiting must resume, use the SAME call directory; do not re-dial.")
            # At-most-one attempt, persisted BEFORE the side effect. Even a crash
            # between this marker and exec is unknown; recovery must not auto-resend.
            with (job / "enqueue.started").open("x") as handle:
                handle.write(marker + "\n")
            record(job, "enqueue_started", waiter_exit=rc)
            try:
                socket = Path(config["home"]) / "app-server-control/app-server-control.sock"
                result = command(config, ["queue", "--remote", "unix://" + str(socket),
                    "--thread", config["thread"], "--message", message, "--resume"], timeout=30)
            except (OSError, subprocess.TimeoutExpired) as error:
                record(job, "enqueue_unknown", waiter_exit=rc, detail=type(error).__name__)
                return
            (job / "queue.stdout").write_bytes(result.stdout[:LIMIT])
            (job / "queue.stderr").write_bytes(result.stderr[:LIMIT])
            if result.returncode:
                record(job, "enqueue_failed", waiter_exit=rc, queue_exit=result.returncode)
                return
            record(job, "enqueued", waiter_exit=rc, warning=bool(result.stderr))
            deadline = time.monotonic() + config["arrival_timeout"]
            while True:
                if arrival(rollout, offset, marker):
                    record(job, "arrived", waiter_exit=rc, thread=config["thread"], home=config["home"], marker=marker)
                    return
                if time.monotonic() >= deadline:
                    record(job, "arrival_unconfirmed", waiter_exit=rc, warning=bool(result.stderr))
                    return
                time.sleep(0.1)
        except Exception as error:
            record(job, "enqueue_unknown" if (job / "enqueue.started").exists() else "receiver_unavailable",
                   detail=f"{type(error).__name__}: {error}"[:1000])


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="command", required=True)
    arm_parser = sub.add_parser("arm")
    arm_parser.add_argument("call_dir")
    arm_parser.add_argument("--caller-thread", required=True)
    arm_parser.add_argument("--caller-home", required=True)
    arm_parser.add_argument("--timeout", type=int, default=1800)
    arm_parser.add_argument("--arrival-timeout", type=float, default=120)
    for name in ("status", "work"):
        sub.add_parser(name).add_argument("call_dir")
    args = parser.parse_args()
    try:
        if args.command == "arm":
            if not 1 <= args.timeout <= 86400 or not 0 < args.arrival_timeout <= 3600:
                raise ValueError("timeout must be 1..86400; arrival-timeout must be >0..3600")
            print(json.dumps(arm(args)))
        elif args.command == "status":
            print(json.dumps(read_json(Path(args.call_dir) / "completion/status.json")))
        else:
            work(Path(args.call_dir))
        return 0
    except (ValueError, OSError, subprocess.SubprocessError) as error:
        print(f"completion watcher refused: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
