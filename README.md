# lock-sync

Lock every Synergy-client Mac when the Synergy server Mac locks its screen.

When you lock your primary Mac (via Ctrl+Cmd+Q, idle timeout, or anything
else), a LaunchAgent fires `ssh <host> pmset displaysleepnow` at each host
in your `synergy.conf`. One-way, lock-only — no unlock, no remote wake, no
password handling.

## Requirements

- macOS on the server (uses `notifyutil`, `pmset`, and LaunchAgent —
  no Linux support).
- [Synergy](https://symless.com/synergy) running as a server on this Mac,
  with a `~/Library/Preferences/Synergy/synergy.conf` listing your clients.
- Passwordless SSH from the server to every client (`ssh <client> true`
  must succeed without a prompt). Set up keys with `ssh-copy-id` if needed.
- mDNS resolution working — the default targets client screens as
  `<short-name>.local`.

## Install

```sh
git clone git@github.com:smartwatermelon/lock-sync.git ~/Developer/lock-sync
cd ~/Developer/lock-sync
bin/install
```

`bin/install` is idempotent. It:

- Symlinks `bin/lock-watcher`, `bin/lock-fanout`, and `bin/list-clients`
  into `~/.local/bin/`.
- Writes the LaunchAgent plist to
  `~/Library/LaunchAgents/com.smartwatermelon.lock-sync.plist`.
- Loads the agent via `launchctl bootstrap gui/$UID`.

The agent logs to `~/Library/Logs/lock-sync.log`.

## Configure per-host username overrides (optional)

By default every client is targeted as `$USER@<host>.local`. If some hosts
need a different SSH user, create `~/.config/lock-sync/config` (overridable
via `LOCK_SYNC_CONFIG`):

```text
# ~/.config/lock-sync/config
# whitespace-separated pairs, `#` starts a line comment
tilsit.local      operator
mimolette.local   admin
```

Unlisted hosts fall back to `$USER`. Absent or empty file is a valid state.

## Configure meeting-app suppression (optional)

By default, `lock-guard` (running on each client) suppresses the lock if it
detects `zoom.us`, `Microsoft Teams`, or `FaceTime` running. To customize
this list, create `~/.config/lock-sync/guard-processes` (overridable via
`LOCK_SYNC_GUARD_PROCESSES`):

```text
# ~/.config/lock-sync/guard-processes
# one process name per line, `#` starts a line comment
zoom.us
Microsoft Teams
FaceTime
Slack
```

Absent file uses the built-in default. Present file replaces it entirely
(not merged).

## Chrome Automation permission (one-time setup)

`lock-guard`'s Google Meet detection requires macOS Automation permission.
Clients don't need the repo cloned or `bin/install` run on them — `lock-fanout`
pushes `lock-guard` to each client automatically over SSH the first time it
locks that client (see "How clients get `lock-guard`" below). After that's
happened once, grant the Automation permission by running the provisioned
copy interactively at a Terminal on the client:

```sh
~/.local/bin/lock-guard
```

When prompted, navigate to System Settings > Privacy & Security > Automation
and allow Terminal (or your shell's name) to automate Chrome. Without this
permission, Meet-tab detection silently skips (the process-list and
microphone checks still work).

## How clients get `lock-guard`

Clients are zero-footprint: no clone, no `bin/install`, no manual copying.
Each time `lock-fanout` runs, it checksums the local `bin/lock-guard`
against the copy at `~/.local/bin/lock-guard` on the client (`shasum -a
256` over SSH) and pushes a fresh copy only if it's missing or stale,
creating `~/.local/bin` on the client if needed. If that provisioning step
fails for a client (unreachable, missing `shasum`, etc.), `lock-fanout`
logs `warn=provision-failed` for that client and falls back to a bare
`pmset displaysleepnow` call for that cycle — the client still locks, just
without meeting-suppression until the client is reachable again.

## Verify

After install, lock the screen (Ctrl+Cmd+Q) and tail the log:

```sh
tail -f ~/Library/Logs/lock-sync.log
```

Expected output for each lock event:

```text
2026-04-17T21:20:25Z locked
2026-04-17T21:20:26Z client=asiago.local    user=andrewrich ssh_exit=0
2026-04-17T21:20:26Z client=tilsit.local    user=operator   ssh_exit=0
2026-04-17T21:20:26Z client=mimolette.local user=andrewrich ssh_exit=0
```

`ssh_exit=0` means the client accepted the lock. A non-zero value flags a
per-host problem (ssh keys, network, or mDNS name) that doesn't block the
rest of the fan-out.

## Update

```sh
cd ~/Developer/lock-sync
git pull
launchctl kickstart -k "gui/$(id -u)/com.smartwatermelon.lock-sync"
```

The symlinks in `~/.local/bin/` point at the repo, so `git pull` is
live. `kickstart -k` restarts the running agent so it picks up the new
binary.

## Uninstall

```sh
cd ~/Developer/lock-sync
bin/uninstall
```

Idempotent. Reverses install; preserves `~/Library/Logs/lock-sync.log` so
you can inspect history.

## Troubleshooting

**Nothing in the log after locking.** Check the agent is running:

```sh
launchctl print "gui/$(id -u)/com.smartwatermelon.lock-sync" | head -5
```

`state = running` and a recent `pid` are what you want. If not running,
check `~/Library/Logs/lock-sync.log` and the agent's spawn errors with
`launchctl print` full output.

**`ssh_exit=255` on one client.** That's the ssh "connection failed"
exit. Test manually:

```sh
/usr/bin/ssh -o BatchMode=yes <client>.local true
```

Fix the key or DNS issue until that succeeds, then re-lock the screen to
retry. No agent restart needed.

**`error=list-clients` in the log.** Something's wrong with the Synergy
conf parser. Run it directly:

```sh
bin/list-clients
```

That should emit one hostname per line. If not, check
`~/Library/Preferences/Synergy/synergy.conf` exists and has a
`section: screens` block.

## Layout

```text
bin/
├── install          # set up symlinks + plist, bootstrap into launchd
├── uninstall        # reverse install, preserve log
├── list-clients     # parse synergy.conf → <short>.local hostnames
├── lock-watcher     # subscribe to Darwin screen-lock notification
├── lock-fanout      # provision + ssh lock-guard to each client
└── lock-guard       # client-side lock suppression (meeting detection)

tests/               # bats test suite (`bats tests/` to run)
docs/plans/          # per-slice design docs
```

## License

MIT — see `LICENSE.md`.
