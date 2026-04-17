# Slice (b) — `lock-watcher` design

Date: 2026-04-17
Status: approved, ready to implement

## Purpose

Second implementation slice of lock-sync. A long-running bash script that
subscribes to the `com.apple.sessionagent.screenIsLocked` Darwin notification and emits one
log line to stdout per lock event. No ssh yet — that's slice (c).

## Contract

**File:** `bin/lock-watcher`

**Usage:**

```text
bin/lock-watcher
```

No args. Blocks, watches `com.apple.sessionagent.screenIsLocked`, emits one log line to
stdout per lock event, runs until signaled (`SIGTERM` / `SIGINT`).

**Output (stdout):** one line per lock event, ISO 8601 UTC timestamp + tag:

```text
2026-04-17T18:42:13Z locked
```

Stdout is the caller's (LaunchAgent in slice (c)) responsibility to redirect
to a file. stderr carries errors only.

**Exit codes:**

- `143` — `SIGTERM` (128 + 15). Expected termination signal from launchd;
  launchd treats this as a clean signal-exit, not a failure, so KeepAlive in
  slice (c) will not churn-restart on it.
- `130` — `SIGINT` (Ctrl-C).
- non-zero other — `notifyutil` unavailable or died unexpectedly; slice (c)'s
  KeepAlive will restart.
- `0` — practically unreachable under normal operation (would require
  `notifyutil` to exit cleanly on its own).

## Implementation

```bash
#!/usr/bin/env bash
set -euo pipefail

on_lock() {
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  printf '%s locked\n' "$ts"
}

notifyutil -w com.apple.sessionagent.screenIsLocked | while IFS= read -r _; do
  on_lock
done
```

The `ts` variable capture (vs inline `$(date ...)`) is a shellcheck SC2312
requirement: under `set -e`, a command substitution inside another command's
arguments masks the substitution's exit status. The assignment `ts=$(...)`
propagates date's failure under `set -e`.

### Why this shape

- **Handler as a function, not inline:** slice (c) replaces the body of
  `on_lock` with the ssh fan-out. Nothing else in the script changes. The
  loop stays handler-agnostic.
- **`_` as the read variable:** the line content is always
  `com.apple.sessionagent.screenIsLocked` (the key we already subscribed to); it's noise.
  `_` is the bash convention for "I don't care."
- **`set -o pipefail`:** makes the script's exit code reflect `notifyutil`
  failures. Without it, the pipeline exit would always be the `while`'s
  status, masking `notifyutil`'s fate.
- **No explicit `trap`:** bash's default signal propagation kills
  `notifyutil`, the pipe closes, and `while` exits. Adding a trap would add
  moving parts without benefit.
- **ISO 8601 UTC timestamp:** unambiguous, sortable, timezone-independent.
  POSIX `date -u '+%Y-%m-%dT%H:%M:%SZ'`.

### Non-goals for slice (b)

- No ssh. (Slice c.)
- No LaunchAgent plist. (Slice c.)
- No per-client config. (Slice c.)
- No signal handlers beyond bash defaults.

## Tests

**Framework:** bats-core (same as slice a).

**Layout:**

```text
tests/
  lock-watcher.bats
```

No new fixture file — stubs are generated per-test.

### Testing strategy

PATH-shim `notifyutil` with a per-test stub bash script. Real `notifyutil`
lives in `/usr/bin` on macOS; prepending `$STUB_DIR` to `PATH` makes the
script use our stub instead.

```bash
setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../bin/lock-watcher"
  TMPDIR="$(mktemp -d)"
  STUB_DIR="$TMPDIR/stub"
  mkdir -p "$STUB_DIR"
  PATH="$STUB_DIR:$PATH"
}
```

### Cases

1. **Single event → one log line, exit 0, correct format.** Stub emits one
   `com.apple.sessionagent.screenIsLocked` line, exits 0. Watcher emits one line matching
   `^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z locked$`.
2. **Three events → three log lines in order.** Stub emits three lines.
   Watcher emits three log lines, all format-valid.
3. **Zero events (stub exits 0 without output) → zero log lines, exit 0.**
4. **Stub exits non-zero mid-stream → pipefail propagates.** Stub emits one
   line then `exit 1`. Watcher logs one line; script exits non-zero. Proves
   pipefail is actually effective.

### Deliberately not tested

- `SIGTERM` propagation — timing-sensitive in bats; bash signal defaults are
  well-covered upstream. Slice (c)'s real LaunchAgent test will surface it.
- Missing `notifyutil` binary — system binary always present on macOS;
  simulating its absence via PATH scrubbing also breaks `date`, making the
  test less realistic than its value.

## CI integration

No workflow changes. The existing `bats` job runs `bats tests/` which picks
up new `.bats` files automatically. The `shellcheck` step's `bin/*` glob
already catches `bin/lock-watcher`.

## Manual smoke test

```text
bin/lock-watcher              # in Terminal
# Ctrl+Cmd+Q to lock the screen
# expect one line like: 2026-04-17T18:42:13Z locked
# Ctrl+C to exit
```

## Implementation order (TDD)

1. Write all 4 bats tests.
2. Run `bats tests/` — confirm all 4 fail because script is missing.
3. Write `bin/lock-watcher`.
4. Run `bats tests/` — confirm all 4 green.
5. Update CLAUDE.md "Current state" paragraph.
6. Commit, push, PR.
