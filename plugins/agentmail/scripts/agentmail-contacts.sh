#!/usr/bin/env bash
# =============================================================================
# agentmail-contacts.sh — the local address book for agent mail.
#
# AgentMail has no contacts resource. Verified three ways: 0 hits for "contact"
# across the 82 paths in its OpenAPI spec, no contacts page in its docs index,
# and no contacts resource in CLI 0.7.14. The nearest native thing is Lists,
# which are send/receive allow-and-block ACLs — an address plus an optional
# reason, no name, no role. Writing one changes what the inbox is ALLOWED to
# talk to, so using it as an address book would make "remove a contact" quietly
# alter deliverability. Hence: a local file.
#
# Store: ${XDG_CONFIG_HOME:-$HOME/.config}/agentmail/contacts.json, mode 0600.
# Beside the state.json this plugin already writes, and deliberately NOT in the
# repo — an address book under a git worktree is one `git add` from publication.
#
# There is no --store flag. The path is derived from the environment only. A
# path argument is one hallucinated value away from writing personal addresses
# somewhere they get committed, and no caller has a legitimate need for it.
#
# Exit codes are the interface:
#    0  ok
#    3  no such contact
#    4  conflict — email already present, ambiguous query, or init over an
#       existing store. Nothing is written in this case.
#    5  the store exists but does not parse. Never rewritten: a hand-editable
#       file the user can still fix is worth more than a clean empty one.
#    6  no python3/python available
#   64  usage error
#
# Subcommands:
#   init
#   list                        [--format json|text]
#   get    <query>              [--format json|text]
#   add    --name N --email E   [--kind human|agent] [--role R] [--notes T]
#                               [--alias A]... [--verified-from V]
#   update <query>              [any add flag]
#   remove <query>              --yes
# =============================================================================
set -uo pipefail

PY="$(command -v python3 || command -v python || true)"
if [ -z "$PY" ]; then
	printf 'agentmail-contacts: needs python3 (or python) to read and write the store safely.\n' >&2
	exit 6
fi

exec "$PY" - "$@" <<'PYEOF'
import json
import os
import re
import sys
import stat
import tempfile

OK, NOT_FOUND, CONFLICT, MALFORMED, USAGE = 0, 3, 4, 5, 64

FIELDS = ("name", "email", "kind", "role", "notes", "verified_from")
KINDS = ("human", "agent")
EMAIL_RE = re.compile(r"^[^@\s,;<>]+@[^@\s,;<>]+\.[^@\s,;<>]+$")


def die(msg, code):
    print("agentmail-contacts: " + msg, file=sys.stderr)
    sys.exit(code)


def store_path():
    base = os.environ.get("XDG_CONFIG_HOME") or os.path.join(
        os.environ.get("HOME", ""), ".config"
    )
    return os.path.join(base, "agentmail", "contacts.json")


def load(path):
    """Returns (data, existed). A missing store reads as empty; a broken one is
    an error, because rewriting it would throw away addresses the user can still
    recover by hand."""
    if not os.path.exists(path):
        return {"version": 1, "contacts": []}, False
    try:
        with open(path, "r", encoding="utf-8") as fh:
            data = json.load(fh)
    except Exception as exc:
        die(
            "the store at %s does not parse (%s).\n"
            "It has NOT been modified. Fix or delete it by hand — rewriting it "
            "would discard whatever is still in there." % (path, exc),
            MALFORMED,
        )
    if not isinstance(data, dict) or not isinstance(data.get("contacts"), list):
        die(
            "the store at %s is not a contacts document (expected an object with "
            "a 'contacts' list). It has NOT been modified." % path,
            MALFORMED,
        )
    return data, True


def save(path, data):
    """One rename, so a concurrent reader never sees half a file. Two sessions
    racing is last-writer-wins; the cost is a re-added contact, which is not
    worth a lock file."""
    parent = os.path.dirname(path)
    os.makedirs(parent, mode=0o700, exist_ok=True)
    fd, tmp = tempfile.mkstemp(prefix=".contacts-", suffix=".tmp", dir=parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            json.dump(data, fh, indent=2, ensure_ascii=False)
            fh.write("\n")
        os.chmod(tmp, stat.S_IRUSR | stat.S_IWUSR)
        os.replace(tmp, path)          # atomic rename
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def slug(name):
    s = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")
    return s or "contact"


def unique_id(contacts, base):
    taken = {c.get("id") for c in contacts}
    if base not in taken:
        return base
    n = 2
    while "%s-%d" % (base, n) in taken:
        n += 1
    return "%s-%d" % (base, n)


def haystack(c):
    vals = [c.get("id") or "", c.get("name") or "", c.get("email") or ""]
    vals += [a for a in (c.get("aliases") or []) if isinstance(a, str)]
    return [v.lower() for v in vals if v]


def resolve(contacts, query):
    """Exact before substring, and an exact hit in ANY field beats every
    substring hit. Without that ordering, `get Al` resolves to whichever of
    Al and Alberta happens to be listed first."""
    q = query.lower().strip()
    if not q:
        die("empty query", USAGE)
    exact = [c for c in contacts if q in haystack(c)]
    if exact:
        return exact
    return [c for c in contacts if any(q in h for h in haystack(c))]


def render(contacts, fmt):
    if fmt == "json":
        print(json.dumps({"version": 1, "count": len(contacts),
                          "contacts": contacts}, indent=2, ensure_ascii=False))
        return
    if not contacts:
        print("No contacts yet. Add one with: agentmail-contacts.sh add "
              "--name <name> --email <address> --kind human|agent")
        return
    width = max(len(c.get("name") or "") for c in contacts)
    for c in contacts:
        bits = [(c.get("name") or "").ljust(width), c.get("email") or ""]
        tail = " · ".join(
            x for x in (c.get("kind"), c.get("role")) if x and x != "unknown"
        )
        if tail:
            bits.append("(%s)" % tail)
        print("  ".join(bits))
        for extra, label in ((c.get("notes"), ""), (c.get("verified_from"), "verified: ")):
            if extra:
                print(" " * (width + 2) + label + extra)


def parse_args(argv):
    """Hand-rolled on purpose: an unknown flag must be a usage error with our
    own exit code, not a library's."""
    if not argv:
        die("no subcommand. Try: init | list | get | add | update | remove", USAGE)
    cmd, rest = argv[0], argv[1:]
    if cmd not in ("init", "list", "get", "add", "update", "remove"):
        die("unknown subcommand: %s" % cmd, USAGE)

    opts = {"aliases": [], "format": "text", "yes": False}
    positional = []
    i = 0
    while i < len(rest):
        arg = rest[i]
        if arg == "--yes":
            opts["yes"] = True
        elif arg in ("-h", "--help"):
            opts["help"] = True
        elif arg.startswith("--"):
            key = arg[2:].replace("-", "_")
            if key == "alias":
                key = "aliases"
            if key not in ("name", "email", "kind", "role", "notes",
                           "verified_from", "aliases", "format"):
                die("unknown option: %s" % arg, USAGE)
            i += 1
            if i >= len(rest):
                die("%s needs a value" % arg, USAGE)
            if key == "aliases":
                opts["aliases"].append(rest[i])
            else:
                opts[key] = rest[i]
        elif arg.startswith("-"):
            die("unknown option: %s" % arg, USAGE)
        else:
            positional.append(arg)
        i += 1

    if opts.get("format") not in ("json", "text"):
        die("--format must be json or text", USAGE)
    if "kind" in opts and opts["kind"] not in KINDS:
        die("--kind must be one of: %s" % ", ".join(KINDS), USAGE)
    if "email" in opts and not EMAIL_RE.match(opts["email"]):
        die("'%s' is not an email address" % opts["email"], USAGE)
    return cmd, positional, opts


def main():
    cmd, positional, opts = parse_args(sys.argv[1:])
    path = store_path()

    if cmd == "init":
        if os.path.exists(path):
            die("a store already exists at %s — refusing to overwrite it.\n"
                "Edit it directly, or delete it first if that is really what you "
                "want." % path, CONFLICT)
        save(path, {"version": 1, "contacts": []})
        print("Created an empty contacts store: %s (mode 600)" % path)
        return OK

    data, _ = load(path)
    contacts = data["contacts"]

    if cmd == "list":
        render(contacts, opts["format"])
        return OK

    if cmd == "add":
        if "name" not in opts:
            die("add needs --name", USAGE)
        if "email" not in opts:
            die("add needs --email", USAGE)
        clash = [c for c in contacts
                 if (c.get("email") or "").lower() == opts["email"].lower()]
        if clash:
            die("%s is already on file as '%s' (id %s). Use `update` to change it."
                % (opts["email"], clash[0].get("name"), clash[0].get("id")), CONFLICT)
        entry = {
            "id": unique_id(contacts, slug(opts["name"])),
            "name": opts["name"],
            "email": opts["email"],
            # Not defaulted to "human": kind decides whether the relay protocol
            # applies and whether approval routes through this contact, so a
            # wrong guess is worse than a visible gap.
            "kind": opts.get("kind", "unknown"),
            "role": opts.get("role", ""),
            "notes": opts.get("notes", ""),
            "aliases": opts["aliases"],
            "verified_from": opts.get("verified_from", ""),
        }
        contacts.append(entry)
        save(path, data)
        print("Added %s <%s> (id %s)" % (entry["name"], entry["email"], entry["id"]))
        return OK

    if not positional:
        die("%s needs a name, alias, id, or email to look up" % cmd, USAGE)
    query = positional[0]
    matches = resolve(contacts, query)

    if not matches:
        die("no contact matches '%s'" % query, NOT_FOUND)
    if len(matches) > 1:
        print("agentmail-contacts: '%s' matches %d contacts — be more specific."
              % (query, len(matches)), file=sys.stderr)
        for c in matches:
            print("  %s <%s> (id %s)" % (c.get("name"), c.get("email"), c.get("id")),
                  file=sys.stderr)
        sys.exit(CONFLICT)
    target = matches[0]

    if cmd == "get":
        render([target], opts["format"])
        return OK

    if cmd == "update":
        if "email" in opts:
            clash = [c for c in contacts
                     if c is not target
                     and (c.get("email") or "").lower() == opts["email"].lower()]
            if clash:
                die("%s already belongs to '%s'" % (opts["email"], clash[0].get("name")),
                    CONFLICT)
        changed = []
        for f in FIELDS:
            if f in opts:
                target[f] = opts[f]
                changed.append(f)
        # Aliases replace rather than append: an append-only list has no way to
        # correct a wrong alias.
        if opts["aliases"]:
            target["aliases"] = opts["aliases"]
            changed.append("aliases")
        if not changed:
            die("update needs at least one field to change", USAGE)
        save(path, data)
        print("Updated %s (%s)" % (target.get("name"), ", ".join(changed)))
        return OK

    if cmd == "remove":
        if not opts["yes"]:
            die("remove needs --yes. Would delete: %s <%s> (id %s)"
                % (target.get("name"), target.get("email"), target.get("id")), USAGE)
        contacts.remove(target)
        save(path, data)
        print("Removed %s <%s>" % (target.get("name"), target.get("email")))
        return OK

    die("unreachable", USAGE)


if __name__ == "__main__":
    sys.exit(main())
PYEOF
