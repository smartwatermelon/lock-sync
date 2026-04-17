# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project

`lock-sync` locks Synergy-client Macs when the Synergy server (the primary Mac running this tool) locks its screen. It is a deliberate simplification of the abandoned `lock-sync-old` project.

**Scope:** one-way, lock-only. The server watches for `com.apple.screenIsLocked`, then SSHes `pmset displaysleepnow` to each Synergy client.

## Non-goals (do not add these)

- **No unlock.** Wake/unlock-on-server-unlock is explicitly out of scope. `lock-sync-old` failed trying to do this; reintroducing it reopens the problem this rewrite exists to avoid.
- **No passwords / no keychain.** Auth is SSH key-based.
- **No remote wake.** Sleeping clients stay asleep.
- **No bidirectional sync.** A client locking does not propagate back to the server or to other clients.

## Workflow

1. Subscribe to the `com.apple.screenIsLocked` Darwin notification (`notifyutil -w com.apple.screenIsLocked` is the shell-native way).
2. On notification, read the Synergy client list from `~/Library/Preferences/Synergy/synergy.conf`.
3. For each client:
   - Apply per-client username override from local config if present, else default to current user (`ssh $CLIENT` vs `ssh $OVERRIDEUSER@$CLIENT`).
   - `ssh [user@]client pmset displaysleepnow`.
   - Log exit status per client.

SSH-to-self is a no-op on an already-locked Mac — do not special-case it.

## Key external inputs

- **Synergy client list:** `~/Library/Preferences/Synergy/synergy.conf`. This is the source of truth for which hosts to lock — do not maintain a parallel client list.
- **Per-client username overrides:** `~/.config/lock-sync/config` (overridable via `LOCK_SYNC_CONFIG`). Plain text, whitespace-separated `<host> <user>`, `#` line comments. Unlisted hosts use `$USER`. Absent or empty file is a valid state.

## Runtime

Bash, shellcheck-clean (project follows the user's global bash standards in `~/.claude/CLAUDE.md`). Deployed as a macOS user-level LaunchAgent (`~/Library/LaunchAgents/*.plist`), auto-started on login, running a persistent process blocked on `notifyutil -w`.

## Current state

Slices (a), (b), and (c1) implemented: end-to-end ssh/pmset fan-out works when `bin/lock-watcher` is run manually. Slice (c2) — the LaunchAgent plist and install tooling — is not yet implemented. Per-slice design docs live under `docs/plans/`.

## Commands

- `bats tests/` — run the test suite. Local: `brew install bats-core`. CI: installs bats-core v1.10.0 from source to `$HOME/.local` (see `.github/workflows/ci.yml`).
- `shellcheck -S info bin/*` — lint shell scripts (matches CI and the global bash standard).
- `bin/list-clients [path]` — slice (a). Parse Synergy conf, emit `<short>.local` hostnames. No arg → reads `~/Library/Preferences/Synergy/synergy.conf`.
- `bin/lock-watcher` — slices (b)+(c1). Subscribe to `com.apple.screenIsLocked`; on each event emit `<ISO-8601> locked` and invoke `bin/lock-fanout`. Blocks until signaled.
- `bin/lock-fanout` — slice (c1). Reads hosts from `list-clients`, applies per-host overrides from `~/.config/lock-sync/config`, SSHes `pmset displaysleepnow` per host, emits one `<ISO-8601> client=<host> user=<user> ssh_exit=<rc>` line per host.

## `.claude/` directory

Boilerplate installed automatically by a git template (see `.claude/README.md`). Not project code. Add `config.sh` or `hooks/extensions/*.sh` only if this project genuinely needs project-specific preflight or hook logic.
