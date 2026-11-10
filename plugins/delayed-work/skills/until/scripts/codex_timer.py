#!/usr/bin/env python3
"""Detached one-shot `codex queue` timer for the current Codex thread.

arm  --when <ISO with offset> --payload-file <path>   arm a job, print JSON
fire <job-dir>                                         timer body (run detached)
"""
import argparse, datetime, json, os, pathlib, shutil, signal, subprocess, sys, tempfile, time, uuid

# Bounded so a chatty failure cannot fill the disk; the head of stderr carries the cause.
DIAG_LIMIT = 8192
STATUS_DETAIL_LIMIT = 300


class ArmError(Exception):
    pass


def has_rollout(home, thread):
    sessions = pathlib.Path(home) / "sessions"
    return sessions.is_dir() and any(sessions.rglob(f"rollout-*-{thread}.jsonl"))


def resolve_codex_home(thread, env, user_home):
    """Pin the Codex home whose thread store holds this thread.

    `codex queue` reads the thread from $CODEX_HOME's store; with several homes
    (e.g. ~/.codex and ~/.codex-work, each with its own daemon) a timer that
    resolves the wrong one fails with "no rollout found" at fire time.
    """
    current = pathlib.Path(env.get("CODEX_HOME") or pathlib.Path(user_home) / ".codex")
    if has_rollout(current, thread):
        return current.resolve(), "current"
    others = sorted(p.resolve() for p in pathlib.Path(user_home).glob(".codex*")
                    if p.is_dir() and p.resolve() != current.resolve() and has_rollout(p, thread))
    if len(others) == 1:
        return others[0], "alternative"
    if not others:
        raise ArmError(f"no rollout for thread {thread} under {current} or any ~/.codex* home; "
                       "set CODEX_HOME to the home that owns this thread")
    raise ArmError(f"thread {thread} found in several Codex homes ({', '.join(map(str, others))}) "
                   f"and not in current {current}; set CODEX_HOME explicitly")


def prepare(when_text, payload_file, env, user_home, codex=None):
    codex = codex or shutil.which("codex")
    if not codex:
        raise ArmError("codex unavailable")
    help_result = subprocess.run([codex, "queue", "--help"], capture_output=True, text=True)
    if help_result.returncode or not all(x in help_result.stdout for x in ("--thread", "--message")):
        raise ArmError("installed codex lacks queue capability")
    thread = env.get("CODEX_THREAD_ID", "")
    try:
        uuid.UUID(thread)
    except ValueError:
        raise ArmError("CODEX_THREAD_ID missing or malformed")
    when = datetime.datetime.fromisoformat(when_text)
    if when.tzinfo is None or when.timestamp() <= time.time():
        raise ArmError("resolve a future target with an explicit timezone first")
    home, source = resolve_codex_home(thread, env, user_home)
    payload = pathlib.Path(payload_file).read_bytes().decode("utf-8")
    return {"codex": codex, "thread": thread, "codex_home": str(home), "home_source": source,
            "target": when.timestamp(), "target_iso": when.isoformat(), "payload": payload}


def arm(config):
    os.umask(0o077)
    job = pathlib.Path(tempfile.mkdtemp(prefix="codex-until-"))
    (job / "job.json").write_text(json.dumps(config), encoding="utf-8")
    with (job / "timer.log").open("ab") as log:
        process = subprocess.Popen([sys.executable, os.path.abspath(__file__), "fire", str(job)],
            stdin=subprocess.DEVNULL, stdout=log, stderr=log,
            start_new_session=True, close_fds=True)
    (job / "pid").write_text(str(process.pid) + "\n", encoding="utf-8")
    return {"job": str(job), "pid": process.pid, "thread": config["thread"],
            "codex_home": config["codex_home"], "home_source": config["home_source"],
            "target": config["target_iso"]}


def write_bounded(path, data):
    path.write_bytes(data[:DIAG_LIMIT])


def first_line(data):
    for line in data.decode("utf-8", "replace").splitlines():
        if line.strip():
            return line.strip()[:STATUS_DETAIL_LIMIT]
    return ""


def fire(job):
    os.umask(0o077)
    job = pathlib.Path(job)
    config = json.loads((job / "job.json").read_text(encoding="utf-8"))

    def status(value):
        (job / "status").write_text(value + "\n", encoding="utf-8")
        print(datetime.datetime.now(datetime.timezone.utc).isoformat(), value, flush=True)

    def cancel(signum, frame):
        status("cancelled")
        raise SystemExit(0)

    signal.signal(signal.SIGTERM, cancel)
    status("armed")
    while True:
        if (job / "cancel").exists():
            status("cancelled")
            return
        remaining = config["target"] - time.time()
        if remaining <= 0:
            break
        time.sleep(min(1.0, remaining))
    if (job / "cancel").exists():
        status("cancelled")
        return
    status("enqueue_started")
    env = dict(os.environ, CODEX_HOME=config["codex_home"])
    try:
        result = subprocess.run([config["codex"], "queue", "--thread", config["thread"],
            "--message", config["payload"]], stdin=subprocess.DEVNULL,
            capture_output=True, env=env, timeout=60)
    except subprocess.TimeoutExpired:
        status("enqueue_timeout outcome_unknown")
        return
    except OSError as error:
        status("enqueue_failed " + type(error).__name__)
        return
    write_bounded(job / "queue.stdout", result.stdout)
    write_bounded(job / "queue.stderr", result.stderr)
    if result.returncode == 0:
        status("enqueued")
    else:
        detail = first_line(result.stderr) or first_line(result.stdout)
        status(f"enqueue_failed rc={result.returncode}" + (f": {detail}" if detail else ""))


def main(argv):
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    arm_parser = sub.add_parser("arm")
    arm_parser.add_argument("--when", required=True)
    arm_parser.add_argument("--payload-file", required=True)
    fire_parser = sub.add_parser("fire")
    fire_parser.add_argument("job")
    args = parser.parse_args(argv)
    if args.command == "fire":
        fire(args.job)
        return 0
    try:
        config = prepare(args.when, args.payload_file, os.environ, pathlib.Path.home())
    except ArmError as error:
        print(f"arm refused: {error}", file=sys.stderr)
        return 2
    print(json.dumps(arm(config)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
