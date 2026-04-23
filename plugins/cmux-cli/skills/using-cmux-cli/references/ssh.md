# cmux SSH workspaces

`cmux ssh <destination>` creates a workspace bound to a remote host. It's not just a shell: cmux uploads a remote relay daemon (`cmuxd-remote`) that routes browser traffic through the remote's network, uploads dropped files via `scp`, makes remote `cmux` calls appear as local notifications, and persists the session across connection drops.

This reference is loaded on demand. Main SKILL.md keeps only the natural-language trigger for SSH work — read this file when the user's task involves a remote host.

## When to use `cmux ssh` vs plain `ssh` in a split

**Default**: for most "ssh to host X" requests, prefer a **side-by-side split with plain `ssh`** — it's visible to the user immediately. Only reach for `cmux ssh <host>` when you actually need the remote integration (browser routing, drag-drop, remote agent notifications, reconnect-across-drops). See the [visibility-default principle in SKILL.md](../SKILL.md#default-principle-make-new-work-visible-to-the-user) for the one-call recipe.

Concrete picker:

| User's intent | Pick | Why |
|---------------|------|-----|
| "ssh to X to check a log" / "run a quick command on X" / "poke around on X" | Side-by-side split + plain `ssh user@host` | Visible in the current window immediately. No relay daemon needed. |
| "ssh to X and run a coding agent" / "start `claude-teams` on the remote" | `cmux ssh user@host` | Needs the reverse-tunnel relay so remote `cmux notify` / `cmux set-status` reach the local sidebar. |
| "I want to drag files into that remote terminal" | `cmux ssh user@host` | Drag-drop → `scp` through `ControlMaster` multiplexing only works with the workspace path. |
| "I want to hit the remote's `localhost:3000` from a cmux browser pane" | `cmux ssh user@host` | Browser traffic routing through the remote's network requires the daemon. |
| "I want this session to survive connection drops and a screen resize" | `cmux ssh user@host` | Session persistence + PTY resize coordination are daemon features. |

**Important**: `cmux ssh` always creates a **new workspace** (hidden behind a tab switch). When you pick it, tell the user: "I'm opening this as a new workspace — you'll need to switch tabs to see it." That warning turns the tab-switch into an informed choice rather than a surprise.

## Quick reference

Get flags live from the running build:

```
cmux ssh --help
```

Canonical examples:

```
cmux ssh user@host
cmux ssh user@host --name "dev server"
cmux ssh user@host --port 2222
cmux ssh user@host --identity ~/.ssh/id_ed25519
cmux ssh user@host --ssh-option StrictHostKeyChecking=no --ssh-option UserKnownHostsFile=/dev/null
cmux ssh user@host --no-focus
```

Passes through `~/.ssh/config` for host aliases, identity files, and proxy settings. Repeatable `--ssh-option` mirrors `ssh -o`.

## What happens on first connect

cmux probes the remote host (`uname -s`, `uname -m`) and uploads a versioned `cmuxd-remote` binary. The binary:

- Speaks JSON-RPC over stdio.
- Proxies browser traffic (SOCKS5 + HTTP CONNECT through the daemon's stdio channel).
- Relays remote `cmux` calls back to the local instance via a reverse TCP tunnel authenticated with HMAC-SHA256.
- Persists sessions across reconnects and coordinates PTY resize across multiple attachments.

Stored at `~/.cmux/bin/cmuxd-remote/<version>/<os>-<arch>/cmuxd-remote` on the remote host, verified against a SHA-256 manifest embedded in the local app.

### Inspecting daemon status

```
cmux remote-daemon-status [--os <darwin|linux>] [--arch <arm64|amd64>]
```

Reports app version, build, commit, expected SHA-256, local cache path (under `~/Library/Application Support/cmux/remote-daemons/...`), whether the cache exists and verifies, and the `gh release download` commands you'd need to re-fetch manually. First stop when a remote workspace is misbehaving.

## Capabilities you get for free inside an SSH workspace

### Browser panes route through the remote

`cmux browser open http://localhost:3000` inside a remote workspace hits the *remote's* `localhost:3000`, not yours. No `-L` port forwarding required. Each remote workspace has an isolated cookie store, so auth sessions are scoped per-connection. Details in [browser.md](browser.md).

### Drag-and-drop files

Drag an image or file into a remote terminal and cmux uploads it via `scp` through the existing SSH connection. Foreground SSH process is detected by TTY; upload uses `ControlMaster` multiplexing so there's no second auth handshake.

### Remote processes can call `cmux` locally

A process on the remote box can invoke `cmux notify`, `cmux set-status`, `cmux log`, etc. — those calls get relayed to your local cmux instance. Build scripts on the remote can light up the local sidebar. Notification spam from flaky connections is suppressed with a per-host cooldown.

### Coding agents over SSH

`cmux claude-teams` and `cmux omo` both work inside SSH sessions. Teammate agents spawn as native cmux splits **on your local machine** while computation runs on the remote box. Inside a remote shell:

```
cmux claude-teams
cmux omo
```

### Resilient reconnect

On connection drop, cmux reconnects with exponential backoff (3s, 6s, 12s, up to 60s). The remote session persists and cmux reattaches on reconnect, resizing to smallest-screen-wins. Default keepalives (`ServerAliveInterval=20`, `ServerAliveCountMax=2`) are injected unless `~/.ssh/config` already sets them.

## Natural-language quick reference

| User says | cmux command |
|-----------|--------------|
| "ssh into box.example.com as a workspace" | `cmux ssh box.example.com` |
| "open a remote workspace named 'dev'" | `cmux ssh user@host --name "dev"` |
| "use my ed25519 key for this host" | `cmux ssh user@host --identity ~/.ssh/id_ed25519` |
| "connect on port 2222" | `cmux ssh user@host --port 2222` |
| "skip host key prompt" | `cmux ssh user@host --ssh-option StrictHostKeyChecking=no` |
| "create the workspace but don't focus it" | `cmux ssh user@host --no-focus` |

## Troubleshooting

- **Remote daemon fails to upload** — check `cmux remote-daemon-status`. Permissions on `~/.cmux/bin/` on the remote, or restrictive shell init that errors on unknown commands, are the usual causes. The status output gives you the `gh release download` commands to verify the binary manually.
- **Browser in remote workspace can't reach `localhost`** — verify you opened the browser pane *inside* the remote workspace (the one created by `cmux ssh`), not in your local workspace.
- **Reconnect loop** — if the backoff hits 60s and keeps failing, check `~/.ssh/config` for conflicting keepalive settings, and verify the remote host's `sshd` actually accepts the keepalives cmux injects.
- **Shell init noise on the remote** — if the remote's `.bashrc` / `.zshrc` prints errors or requires interactivity, daemon upload can fail silently. Quieting init output for non-interactive sessions typically fixes it.
