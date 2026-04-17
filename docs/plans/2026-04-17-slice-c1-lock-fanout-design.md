# Slice (c1) — `lock-fanout` design

Date: 2026-04-17
Status: approved, ready to implement

## Purpose

Third implementation slice of lock-sync, first of two c-slices. Wires the
existing slice (a) parser and slice (b) watcher end-to-end: on each
`com.apple.sessionagent.screenIsLocked` event, fan out to every Synergy client via ssh,
running `pmset displaysleepnow` on each, with per-client username overrides
and per-client result logging.

Slice c2 — the LaunchAgent plist and install tooling — is a separate PR.

## Scope

**Changes:**

- `bin/lock-watcher` — `on_lock` body invokes a new fan-out helper in addition
  to its existing `<ts> locked` log line. Invocation target is overridable via
  `LOCK_SYNC_FANOUT` for tests.
- `bin/lock-fanout` (new) — reads hosts from `list-clients`, looks up per-host
  overrides from `~/.config/lock-sync/config`, runs `ssh <user>@<host> pmset
  displaysleepnow` per host, logs a key-value result line per host.
- `tests/lock-watcher.bats` — `setup()` stubs `LOCK_SYNC_FANOUT=/usr/bin/true`;
  new test asserts fanout is actually invoked on lock.
- `tests/lock-fanout.bats` — 7 tests, PATH-shimmed `ssh` + stubbed siblings.

**Non-goals for c1:**

- No LaunchAgent plist. (c2.)
- No install helper. (c2.)
- No parallel fan-out. Sequential, N × 5s worst case for N hosts.
- No retries on failed ssh.

## Config

**Path:** `~/.config/lock-sync/config`, overridable via `LOCK_SYNC_CONFIG`
env var for tests.

**Format:** plain text, whitespace-separated `<host> <user>`, `#` line
comments. Unlisted hosts use `$USER` (current local username). Absent or
empty file is a valid state — everyone uses the default.

```text
# ~/.config/lock-sync/config
# lock-sync per-client username overrides
# <hostname>       <user>
asiago.local       admin
tilsit.local       alex
```

Hostname match is exact string; no wildcards. Duplicate hostnames: first
match wins.

## SSH invocation per client

```bash
"$ssh_cmd" -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=accept-new \
    <user>@<host> pmset displaysleepnow
```

- `$ssh_cmd` resolves to `${LOCK_SYNC_SSH:-/usr/bin/ssh}`. Hard-coding the
  system binary by default sidesteps any PATH-injected ssh wrapper (e.g. a
  1Password-token shim) that can't satisfy `BatchMode=yes`. `LOCK_SYNC_SSH`
  overrides for tests.
- `BatchMode=yes` — keys only; no interactive prompts. Unconfigured hosts
  fail immediately instead of hanging.
- `ConnectTimeout=5` — 5 seconds; unreachable hosts don't block the next.
- `StrictHostKeyChecking=accept-new` — first-time keys auto-accepted;
  *changed* keys still rejected (MITM guard).

## Log format

Per event, stdout gets one watcher line plus one fan-out line per host:

```text
2026-04-17T18:42:13Z locked
2026-04-17T18:42:13Z client=asiago.local user=admin ssh_exit=0
2026-04-17T18:42:13Z client=tilsit.local user=alex ssh_exit=255
2026-04-17T18:42:14Z client=mimolette.local user=andrewrich ssh_exit=0
```

Fan-out additionally logs:

- `<ts> warn=no-clients` when `list-clients` succeeds with zero hosts.
- `<ts> error=list-clients rc=N output=<captured>` when `list-clients` fails.

All lines follow `<ISO-8601 ts> <key>=<val> [<key>=<val> ...]` for easy
grep/awk consumption by the user when reading logs.

## Implementation

### `bin/lock-watcher` (edit)

```bash
#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

on_lock() {
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  printf '%s locked\n' "$ts"
  "${LOCK_SYNC_FANOUT:-$script_dir/lock-fanout}" || true
}

notifyutil -w com.apple.sessionagent.screenIsLocked | while IFS= read -r _; do
  on_lock
done
```

### `bin/lock-fanout` (new)

```bash
#!/usr/bin/env bash
set -euo pipefail

conf="${LOCK_SYNC_CONFIG:-$HOME/.config/lock-sync/config}"
script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
list_clients_cmd="${LOCK_SYNC_LIST_CLIENTS:-$script_dir/list-clients}"
ssh_cmd="${LOCK_SYNC_SSH:-/usr/bin/ssh}"
default_user="${USER:-$(id -un)}"

log() {
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  printf '%s %s\n' "$ts" "$*"
}

lookup_user() {
  local host="$1"
  [[ -r "$conf" ]] || return 0
  awk -v h="$host" '
    /^[[:space:]]*(#|$)/ { next }
    $1 == h { print $2; exit }
  ' "$conf"
}

fanout_host() {
  local host="$1" override user rc=0
  override=$(lookup_user "$host")
  user="${override:-$default_user}"
  "$ssh_cmd" -o BatchMode=yes \
      -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=accept-new \
      "$user@$host" pmset displaysleepnow >/dev/null 2>&1 || rc=$?
  log "client=$host user=$user ssh_exit=$rc"
}

main() {
  local clients
  if ! clients=$("$list_clients_cmd" 2>&1); then
    log "error=list-clients rc=$? output=$clients"
    return 0
  fi
  if [[ -z "$clients" ]]; then
    log "warn=no-clients"
    return 0
  fi
  while IFS= read -r host; do
    fanout_host "$host"
  done <<< "$clients"
}

main "$@"
```

## Tests

### `tests/lock-watcher.bats` changes

- `setup()` adds `export LOCK_SYNC_FANOUT=/usr/bin/true` so existing 4 tests stay
  green without real fan-out side-effects.
- New 5th test: stub fanout writes a sentinel file; assert the file exists
  after a lock event. This drives the red-green for the watcher edit.

### `tests/lock-fanout.bats` (7 tests)

1. **Zero clients** — list-clients stub exits 0 with no output. Assert one
   `warn=no-clients` line, exit 0.
2. **All clients succeed** — three hosts, ssh stub exits 0. Assert three
   `ssh_exit=0` lines, one per host, in order.
3. **One client fails** — three hosts, ssh stub exits 255 for one. Assert
   two `ssh_exit=0` + one `ssh_exit=255`, overall exit 0.
4. **Override applied** — one host, config has `asiago.local adminuser`, ssh
   stub logs its args. Assert recorded target is `adminuser@asiago.local`.
5. **No config file** — `LOCK_SYNC_CONFIG` points at nonexistent path; ssh
   stub records args. Assert target is `$USER@host`.
6. **list-clients fails** — list-clients stub exits 1. Assert
   `error=list-clients rc=1` line, overall exit 0.
7. **Config with comments and blanks** — config has `#` lines and blank
   lines and one override entry. Assert only the matching host gets the
   override; unrelated hosts use `$USER`.

### Stub strategy

- `$STUB_DIR` prepended to PATH — covers `ssh` (looked up via PATH).
- `LOCK_SYNC_LIST_CLIENTS` points at a per-test bash stub.
- `LOCK_SYNC_CONFIG` points at a per-test config file (or nonexistent path).
- `ssh` stub writes its args to `$TMPDIR/ssh.log` for assertions on target.

## CI integration

No workflow changes. Existing `bats tests/` picks up new file. Shellcheck
`bin/*` glob covers `bin/lock-fanout`.

## Manual smoke test

```text
# Ensure ssh to at least one Synergy client works with keys
ssh adminuser@asiago.local true

# Run the end-to-end watcher in a terminal
bin/lock-watcher

# Ctrl+Cmd+Q to lock. Expect:
#   <ts> locked
#   <ts> client=asiago.local user=adminuser ssh_exit=0
#   ... (one per client)

# Ctrl+C to exit watcher
```

## Implementation order (TDD)

1. Update `tests/lock-watcher.bats` (`LOCK_SYNC_FANOUT` in setup + 5th test).
   Run → 5th RED, first 4 GREEN.
2. Edit `bin/lock-watcher` to invoke the env-overridable fanout. Run → all 5
   GREEN.
3. Write `tests/lock-fanout.bats` (7 tests). Run → 7 RED (script missing).
4. Write `bin/lock-fanout`. Run → all 12 GREEN.
5. `shellcheck -S info bin/*` clean.
6. Update CLAUDE.md "Current state" + Commands.
7. Commit, push, PR.
