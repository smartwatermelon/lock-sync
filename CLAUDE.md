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
- **Per-client overrides:** local config (path/format TBD at implementation time). Stores username overrides only.

## Runtime

Bash, shellcheck-clean (project follows the user's global bash standards in `~/.claude/CLAUDE.md`). Deployed as a macOS user-level LaunchAgent (`~/Library/LaunchAgents/*.plist`), auto-started on login, running a persistent process blocked on `notifyutil -w`.

## Current state

Slice (a) implemented: `bin/list-clients` parses the Synergy conf and emits `<short>.local` hostnames. Slice (b) (notification watcher) and slice (c) (end-to-end ssh/pmset + LaunchAgent) are not yet implemented. Per-slice design docs live under `docs/plans/`.

## Commands

- `bats tests/` — run the test suite. Local: `brew install bats-core`. CI: installs via `npm install -g bats`.
- `shellcheck -S info bin/*` — lint shell scripts (matches CI and the global bash standard).
- `bin/list-clients [path]` — run the parser. No arg → reads `~/Library/Preferences/Synergy/synergy.conf`.

## `.claude/` directory

Boilerplate installed automatically by a git template (see `.claude/README.md`). Not project code. Add `config.sh` or `hooks/extensions/*.sh` only if this project genuinely needs project-specific preflight or hook logic.
