#!/usr/bin/env python3
"""Detached one-shot or recurring `codex queue` timer for the current thread.

arm  --when <ISO with offset> --payload-file <path> [--every <seconds>]
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


def is_cmux_wrapper(path):
    try:
        with open(path, "rb") as handle:
            return b"cmux-codex-wrapper" in handle.read(16384)
    except OSError:
        return False


def resolve_codex(env):
    """First real `codex` on PATH, skipping cmux's shim.

    Inside cmux, PATH starts with a shim that execs cmux-codex-wrapper, which adds
    --dangerously-bypass-hook-trust to `codex queue`; queue rejects it (exit 2)
    while `queue --help` still passes, so the shim must be skipped, not probed.
    """
    skipped = False
    for directory in env.get("PATH", "").split(os.pathsep):
        candidate = shutil.which("codex", path=directory) if directory else None
        if not candidate:
            continue
        if "cmux-cli-shims" in pathlib.Path(candidate).parts or is_cmux_wrapper(candidate):
            skipped = True
            continue
        return candidate
    raise ArmError("only the cmux codex wrapper is on PATH, and it breaks `codex queue`; "
                   "put the real codex binary on PATH" if skipped else "codex unavailable")


def prepare(when_text, payload_file, env, user_home, codex=None):
    codex = codex or resolve_codex(env)
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
    job = pathlib.Path(tempfile.mkdtemp(prefix="codex-every-" if config.get("every") else "codex-until-"))
    (job / "job.json").write_text(json.dumps(config), encoding="utf-8")
    with (job / "timer.log").open("ab") as log:
        process = subprocess.Popen([sys.executable, os.path.abspath(__file__), "fire", str(job)],
            stdin=subprocess.DEVNULL, stdout=log, stderr=log,
            start_new_session=True, close_fds=True)
    (job / "pid").write_text(str(process.pid) + "\n", encoding="utf-8")
    return {"job": str(job), "pid": process.pid, "thread": config["thread"],
            "codex_home": config["codex_home"], "home_source": config["home_source"],
            "target": config["target_iso"], "every": config.get("every"),
            "expires": config.get("expires")}


def write_bounded(path, data):
    path.write_bytes(data[:DIAG_LIMIT])


def write_config(job, config):
    temporary = job / "job.json.tmp"
    temporary.write_text(json.dumps(config), encoding="utf-8")
    temporary.replace(job / "job.json")


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
        if config.get("expires") and time.time() >= config["expires"]:
            status("expired")
            return
        remaining = config["target"] - time.time()
        if remaining <= 0:
            break
        time.sleep(min(1.0, remaining))
    if (job / "cancel").exists():
        status("cancelled")
        return
    if config.get("every") and (job / "pending").exists():
        status("waiting_for_ack")
        return "pending"
    payload = config["payload"]
    if config.get("every"):
        # Written before queue: even an ambiguous timeout must not be retried.
        (job / "pending").touch(mode=0o600)
        payload = (payload + f"\n\n[Recurring delivery metadata] Job: {job}\n"
                   "Read this job's status, job.json expiry and cancel marker before acting. If cancelled or expired, "
                   "skip the payload. Otherwise run the supplied payload, then remove only this job's "
                   "pending file to acknowledge it. Do not re-arm the timer. "
                   "To stop recurrence, create this job's cancel file before acknowledging.\n")
    status("enqueue_started")
    env = dict(os.environ, CODEX_HOME=config["codex_home"])
    try:
        result = subprocess.run([config["codex"], "queue", "--thread", config["thread"],
            "--message", payload], stdin=subprocess.DEVNULL,
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
        return "enqueued"
    else:
        detail = first_line(result.stderr) or first_line(result.stdout)
        status(f"enqueue_failed rc={result.returncode}" + (f": {detail}" if detail else ""))


def repeat(job):
    """One timer owns cadence; pending coalesces pings until the receiver acks.

    fire() remains the one-shot implementation. Each iteration reads its next
    target from job.json; missed intervals are skipped, never replayed in a burst.
    A failed or ambiguous enqueue stops the job for human reconciliation.
    """
    job = pathlib.Path(job)
    config = json.loads((job / "job.json").read_text(encoding="utf-8"))
    while True:
        outcome = fire(job)
        if outcome not in ("enqueued", "pending"):
            return
        now = time.time()
        steps = max(1, int((now - config["target"]) // config["every"]) + 1)
        config["target"] += steps * config["every"]
        config["target_iso"] = datetime.datetime.fromtimestamp(
            config["target"], datetime.timezone.utc).isoformat()
        write_config(job, config)


def interval(text):
    try:
        value = int(text)
    except ValueError:
        raise argparse.ArgumentTypeError("interval must be whole seconds, at least 60")
    if value < 60:
        raise argparse.ArgumentTypeError("interval must be at least 60 seconds")
    return value


def main(argv):
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="command", required=True)
    arm_parser = sub.add_parser("arm")
    arm_parser.add_argument("--when", required=True)
    arm_parser.add_argument("--payload-file", required=True)
    arm_parser.add_argument("--every", type=interval, help="repeat every N seconds (minimum 60); expires after 7 days")
    fire_parser = sub.add_parser("fire")
    fire_parser.add_argument("job")
    args = parser.parse_args(argv)
    if args.command == "fire":
        config = json.loads((pathlib.Path(args.job) / "job.json").read_text(encoding="utf-8"))
        if config.get("every"):
            repeat(args.job)
        else:
            fire(args.job)
        return 0
    try:
        config = prepare(args.when, args.payload_file, os.environ, pathlib.Path.home())
        if args.every:
            config["every"] = args.every
            config["expires"] = time.time() + 7 * 24 * 60 * 60
    except ArmError as error:
        print(f"arm refused: {error}", file=sys.stderr)
        return 2
    print(json.dumps(arm(config)))
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
