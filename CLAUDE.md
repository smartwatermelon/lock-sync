# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`lock-sync` locks Synergy-client Macs when the Synergy server (the primary Mac running this tool) locks its screen. It is a deliberate simplification of the abandoned `lock-sync-old` project.

**Scope:** one-way, lock-only. The server watches for `com.apple.sessionagent.screenIsLocked`, then SSHes `pmset displaysleepnow` to each Synergy client.

## Non-goals (do not add these)

- **No unlock.** Wake/unlock-on-server-unlock is explicitly out of scope. `lock-sync-old` failed trying to do this; reintroducing it reopens the problem this rewrite exists to avoid.
- **No passwords / no keychain.** Auth is SSH key-based.
- **No remote wake.** Sleeping clients stay asleep.
- **No bidirectional sync.** A client locking does not propagate back to the server or to other clients.

## Workflow

1. Subscribe to the `com.apple.sessionagent.screenIsLocked` Darwin notification (`notifyutil -w com.apple.sessionagent.screenIsLocked` is the shell-native way).
2. On notification, read the Synergy client list from `~/Library/Preferences/Synergy/synergy.conf`.
3. For each client:
   - Apply per-client username override from local config if present, else default to current user (`ssh $CLIENT` vs `ssh $OVERRIDEUSER@$CLIENT`).
   - `ssh [user@]client pmset displaysleepnow`.
   - Log exit status per client.

SSH-to-self is a no-op on an already-locked Mac — do not special-case it.

## Key external inputs

- **Synergy client list:** `~/Library/Preferences/Synergy/synergy.conf`. This is the source of truth for which hosts to lock — do not maintain a parallel client list.
- **Synergy display names:** `~/Library/Preferences/Synergy/db.json` (sibling of the conf; overridable via `LOCK_SYNC_DB`). Synergy sanitizes screen names before writing the conf (e.g. it drops hyphens: `arich-mac` becomes the screen `arichmac-3181d4b4`), so the conf alone cannot reproduce a client's real hostname. `list-clients` recovers the true name from db.json's `computers[].name`, joined on the last 8 hex of `id` matching the conf's instance suffix. Read via `jq` (a soft dependency — macOS ships `/usr/bin/jq`; Homebrew paths are probed as a fallback). When jq or db.json is unavailable, it degrades to stripping the suffix. Use `name`, not `hostname` — the two diverge (`hostname` can be the default `Andrews-Mac-mini.local`).
- **Per-client username overrides:** `~/.config/lock-sync/config` (overridable via `LOCK_SYNC_CONFIG`). Plain text, whitespace-separated `<host> <user>`, `#` line comments. Unlisted hosts use `$USER`. Absent or empty file is a valid state.
- **Meeting-app suppression list:** `~/.config/lock-sync/guard-processes` (overridable via `LOCK_SYNC_GUARD_PROCESSES`). Same shape as the username-override config: plain text, one process name per line, `#` comments. Absent file uses the built-in default list (`zoom.us`, `Microsoft Teams`, `FaceTime`). Present file replaces the default list entirely (not merged).

## Runtime

Bash, shellcheck-clean (project follows the user's global bash standards in `~/.claude/CLAUDE.md`). Deployed as a macOS user-level LaunchAgent (`~/Library/LaunchAgents/*.plist`), auto-started on login, running a persistent process blocked on `notifyutil -w`.

## Current state

All slices shipped. Install with `bin/install`; uninstall with `bin/uninstall`. The LaunchAgent auto-starts the watcher on login and writes its log to `~/Library/Logs/lock-sync.log`. Per-slice design docs live under `docs/plans/`.

**Upgrade path:** only the controller (the machine running `lock-watcher`/`lock-fanout`, i.e. the Synergy server) needs `bin/install` run on it, including on upgrade — `git pull` there is enough to pick up a new `lock-guard`. Clients never run `bin/install` and never clone this repo: `lock-fanout`'s `provision_host` function pushes `bin/lock-guard` to each client over SSH automatically, at lock time, on demand. It compares checksums first (`shasum -a 256`, local vs. `~/.local/bin/lock-guard` on the client) and only pushes when the file is missing or stale, creating `~/.local/bin` with `mkdir -p` for a never-before-provisioned client. If provisioning itself fails for a client (e.g. unreachable, or the client is missing `shasum`), `lock-fanout` logs `warn=provision-failed` for that client and falls back to a direct `pmset displaysleepnow` call for that cycle — the client still locks, it just loses meeting-suppression for that one cycle (self-heals next cycle once the client is reachable again). Watch `~/Library/Logs/lock-sync.log` for `warn=provision-failed` to recognize this case.

## lock-guard: one-time Chrome Automation permission

`lock-guard`'s Google Meet detection drives Chrome via `osascript`. The
first time this runs on a client, macOS prompts for Automation permission
(System Settings > Privacy & Security > Automation). Because `lock-guard`
runs non-interactively over SSH from launchd, there is no interactive
session to click "Allow" in — grant this manually once per client, by
running `~/.local/bin/lock-guard` interactively at a local Terminal on that
client (auto-provisioned there by `lock-fanout` on the first lock cycle; no
repo clone or `bin/install` needed on the client — see "Upgrade path"
above), approving the Chrome automation prompt when it appears. If the
permission is never granted, Meet-tab detection silently fails open
(treated as "no Meet tab found," never as a fatal error) — the process-list
and mic-active checks still work normally.

## Commands

- `bats tests/` — run the test suite. Local: `brew install bats-core`. CI: installs bats-core v1.10.0 from source to `$HOME/.local` (see `.github/workflows/ci.yml`).
- `shellcheck -S info bin/*` — lint shell scripts (matches CI and the global bash standard).
- `bin/install` — symlink binaries into `~/.local/bin/`, write the LaunchAgent plist, bootstrap into launchd. Idempotent.
- `bin/uninstall` — bootout the agent, remove plist and symlinks. Preserves the log file. Idempotent.
- `bin/list-clients [path]` — slice (a). Parse Synergy conf, emit `<host>.local` hostnames, resolving real display names via the sibling `db.json` when available (see Key external inputs). No arg → reads `~/Library/Preferences/Synergy/synergy.conf`.
- `bin/lock-watcher` — slices (b)+(c1). Subscribe to `com.apple.sessionagent.screenIsLocked`; on each event emit `<ISO-8601> locked` and invoke `bin/lock-fanout`. Blocks until signaled.
- `bin/lock-fanout` — slice (c1). Reads hosts from `list-clients`, applies per-host overrides from `~/.config/lock-sync/config`, provisions `lock-guard` on each client on demand over SSH if missing or stale (checksum-compared; see "Upgrade path" above), then SSHes `lock-guard` to each client (see the `bin/lock-guard` bullet below; falls back to bare `pmset displaysleepnow` if provisioning fails), emits one `<ISO-8601> client=<host> user=<user> ssh_exit=<rc>` line per host (plus a `warn=provision-failed` line when provisioning itself failed for that host).
- `bin/lock-guard` — runs on each client (invoked remotely by `lock-fanout` in place of a bare `pmset displaysleepnow`). Skips the lock and logs why if the client looks like it's in a call: a known meeting app is running (`~/.config/lock-sync/guard-processes`), the microphone is actively in use, or a Google Meet room tab is open in Chrome. Emits `<ISO-8601> action=sleep` or `<ISO-8601> action=suppress reason=<reason>`.

## `.claude/` directory

Boilerplate installed automatically by a git template (see `.claude/README.md`). Not project code. Add `config.sh` or `hooks/extensions/*.sh` only if this project genuinely needs project-specific preflight or hook logic.
