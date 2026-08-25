# `lock-guard`: suppress lock during meetings

Date: 2026-08-12
Status: implemented, with one deviation (see "Implementation note" below)

## Implementation note: mic-active check uses `pmset`, not `ioreg`

This document is the plan as approved on 2026-08-12 and is kept as the
historical record. The shipped implementation deviates from it in one
place: **the microphone-active signal.**

- **Planned:** `ioreg -c IOAudioEngine -r -l`, matching an audio engine in
  `running` state, stubbed in tests via `LOCK_SYNC_IOREG`.
- **Shipped:** `pmset -g assertions`, matching
  `coreaudiod.*preventuseridlesleep`, stubbed in tests via
  `LOCK_SYNC_PMSET` (the same override already used for the
  `pmset displaysleepnow` call, so there is no separate mic stub).

**Why:** `IOAudioEngine` is a legacy Intel/kext-era class. On Apple Silicon
the audio HAL runs in userspace and publishes no live `IOAudioEngine`
instances, so the planned check never matched — it would have silently
failed open on every current Mac. `pmset -g assertions` reports the power
assertion `coreaudiod` takes while an audio input stream is open, which was
verified against real mic open/close on Apple Silicon.

Every `ioreg`, `IOAudioEngine`, and `LOCK_SYNC_IOREG` reference below is
part of the superseded plan and does **not** describe the shipped code.
See `check_mic_active` in `bin/lock-guard` for the real implementation.

## Purpose

When the user is on a call on `arich-mac` (a Synergy client), the Synergy
*server* machine going to its own idle-timeout screensaver and locking fires
`lock-fanout`, which SSHes `pmset displaysleepnow` to `arich-mac` — sleeping
its display mid-meeting. This is a client-side, self-contained fix: the
client refuses to sleep its own display when it detects it's in a call.

## Non-goals

No change to the project's stated non-goals (no unlock, no bidirectional
sync, no remote wake). The client does not signal the server. The server's
behavior (fanout to all clients) is unchanged. Suppression is a purely local
decision made by each client about its own lock command.

## Design

Today `lock-fanout` runs `pmset displaysleepnow` directly on each client via
SSH. This plan inserts a new script, `bin/lock-guard`, between them: SSH
invokes `lock-guard` instead, and `lock-guard` decides whether to actually
call `pmset displaysleepnow` or skip it and log why.

`lock-guard` suppresses (skips the sleep) if **any** of these are true:

1. **Known meeting app running** — `pgrep -q` matches a line in
   `~/.config/lock-sync/guard-processes` (or a built-in default list if that
   file doesn't exist): `zoom.us`, `Microsoft Teams`, `FaceTime`.
2. **Microphone actively in use** — `ioreg -c IOAudioEngine -r -l` shows an
   audio engine in `running` state. Catches apps not in the process list,
   and any call where you're actually speaking.
   (**Superseded:** shipped as `pmset -g assertions` — see "Implementation
   note" above.)
3. **Google Meet tab open in Chrome** — `osascript` asks Chrome for open tab
   URLs and checks for the Meet in-call URL pattern
   (`meet.google.com/xxx-yyyy-zzz`, not the bare landing page). This is the
   one signal that catches a *muted* all-hands, where the mic check (#2)
   would otherwise miss it.

Each signal is checked independently; the first match wins and is logged by
name so the log line says *why* a lock was skipped
(`reason=process:zoom.us`, `reason=mic-active`, `reason=meet-tab-open`). If
none match, `lock-guard` calls `pmset displaysleepnow` as before.

### Why not just check `osascript`/Chrome for everything

Zoom/Teams/FaceTime are native apps with stable process names — `pgrep` is
cheaper and more reliable than driving them via Accessibility/AppleEvents,
which they don't reliably support anyway. Chrome tab enumeration is reserved
for the one case (Meet) that has no process-level signal.

### macOS Automation permission

The first time `lock-guard` runs the `osascript`/Chrome step, macOS will
prompt for one-time Automation permission (System Settings > Privacy &
Security > Automation > `lock-guard`'s parent process (ssh via launchd) >
Google Chrome). Since `lock-guard` runs non-interactively over SSH from
launchd, there's no user session to click "Allow" in reliably — document this
as a manual one-time setup step per client machine in the script's own
comments and in this doc. If the permission is not granted, `osascript` exits
non-zero / returns empty; treat that the same as "no Meet tab found" (fail
open on this signal only — do not let a missing permission block the whole
guard).

### Failure mode philosophy

`lock-guard` must never let a broken signal-check prevent locking
indefinitely, and must never crash in a way that leaves the display awake
with no explanation. Every individual check is independently guarded: a
non-zero/errored `pgrep`, `ioreg`, or `osascript` counts as "signal not
present" (does not suppress), not as a fatal error. Only an explicit match
suppresses. This mirrors `lock-fanout`'s existing philosophy of "degrade to
inaction, but always log why."

## Files touched

- **Create:** `bin/lock-guard` — the new client-side script.
- **Modify:** `bin/lock-fanout` — remote command changes from
  `pmset displaysleepnow` to `lock-guard`.
- **Modify:** `bin/install` — add `lock-guard` to the list of symlinked
  binaries (every machine is symmetrically a potential client, so every
  machine needs `lock-guard` on its `PATH`).
- **Modify:** `bin/uninstall` — no logic change needed since it already
  iterates the same binary list as `install` (verify during implementation;
  update if uninstall hardcodes a separate list).
- **Create:** `tests/lock-guard.bats` — new test file.
- **Modify:** `tests/lock-fanout.bats` — update the ssh stub assertion: the
  remote command is now `lock-guard`, not `pmset displaysleepnow`.
- **Modify:** `tests/install.bats` — assert `lock-guard` is symlinked too.
- **Modify:** `README.md` / `CLAUDE.md` — document the new script, its
  config file, and the one-time Automation permission step.

## Testability

`pgrep`, `ioreg`, and `osascript` cannot be run for real inside `bats` (no
real meeting apps, no real mic hardware state, no real Chrome automation
permission in CI). Following the existing pattern in this repo (SSH is
stubbed via `LOCK_SYNC_SSH`, `list-clients` is stubbed via
`LOCK_SYNC_LIST_CLIENTS`), `lock-guard` takes the same approach: each of the
three external commands is invoked through an overridable variable
(`LOCK_SYNC_PGREP`, `LOCK_SYNC_IOREG`, `LOCK_SYNC_OSASCRIPT`), each
defaulting to the real absolute-path binary. Tests point these at stub
scripts under a `STUB_DIR`, matching `lock-fanout.bats`'s `make_ssh_stub`
pattern. `pmset` itself is also stubbed the same way
(`LOCK_SYNC_PMSET`), so tests can assert whether it was called or not.

**Superseded:** `LOCK_SYNC_IOREG` was never implemented. Because the mic
check shipped on `pmset -g assertions` (see "Implementation note" above),
the mic-active stub is `LOCK_SYNC_PMSET` — the same override that already
covers the `pmset displaysleepnow` call. `lock-guard` therefore has three
overridable commands, not four: `LOCK_SYNC_PGREP`, `LOCK_SYNC_OSASCRIPT`,
and `LOCK_SYNC_PMSET`.

## Config file: `~/.config/lock-sync/guard-processes`

Same shape as the existing `~/.config/lock-sync/config` (plain text,
one-per-line, `#` comments, blank lines ignored). One process name per line.
Absent file → built-in default list (`zoom.us`, `Microsoft Teams`,
`FaceTime`). Present file → completely replaces the default list (not
merged — consistent with "you're editing this because the defaults don't
fit you").

---

## Task 1: `lock-guard` core — process-list and mic-active signals, `pmset` gate

**Files:**

- Create: `bin/lock-guard`
- Test: `tests/lock-guard.bats`

**Interfaces:**

- Produces: `bin/lock-guard` executable script, no arguments. Reads
  `LOCK_SYNC_GUARD_PROCESSES` (config file path override, defaults to
  `~/.config/lock-sync/guard-processes`), `LOCK_SYNC_PGREP` (defaults to
  `/usr/bin/pgrep`), `LOCK_SYNC_IOREG` (defaults to `/usr/sbin/ioreg`),
  `LOCK_SYNC_PMSET` (defaults to `/usr/bin/pmset`). Exits 0 always (mirrors
  `lock-fanout`'s "never let this script's own exit code break the caller's
  loop" philosophy — the interesting signal is the log line, not the exit
  code). Emits one line to stdout: either
  `<ISO-8601> action=sleep` (mic/process/meet checks all clear, pmset
  called) or `<ISO-8601> action=suppress reason=<reason>` (one of the
  checks matched, pmset not called).

- [ ] **Step 1: Write the failing tests for process-list and mic-active suppression**

Create `tests/lock-guard.bats`:

```bash
#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# bats injects BATS_TEST_DIRNAME; pre-declare for shellcheck SC2154.
: "${BATS_TEST_DIRNAME:=}"

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../bin/lock-guard"
  TMPDIR="$(mktemp -d)"
  STUB_DIR="$TMPDIR/stub"
  mkdir -p "$STUB_DIR"

  PMSET_LOG="$TMPDIR/pmset.log"
  export PMSET_LOG

  export LOCK_SYNC_GUARD_PROCESSES="$TMPDIR/no-such-guard-processes"
  export LOCK_SYNC_PGREP="$STUB_DIR/pgrep"
  export LOCK_SYNC_IOREG="$STUB_DIR/ioreg"
  export LOCK_SYNC_OSASCRIPT="$STUB_DIR/osascript"
  export LOCK_SYNC_PMSET="$STUB_DIR/pmset"

  # Default stubs: nothing matches, nothing running, no tabs. Tests override
  # individual stubs to trigger specific signals.
  make_pgrep_stub_no_match
  make_ioreg_stub_idle
  make_osascript_stub_no_tabs
  make_pmset_stub
}

teardown() {
  rm -rf "$TMPDIR"
}

make_pgrep_stub_no_match() {
  cat >"$STUB_DIR/pgrep" <<'STUBEOF'
#!/bin/bash
exit 1
STUBEOF
  chmod +x "$STUB_DIR/pgrep"
}

# Matches only when the pattern passed to pgrep -x equals $1.
make_pgrep_stub_match() {
  local want="$1"
  cat >"$STUB_DIR/pgrep" <<STUBEOF
#!/bin/bash
for a in "\$@"; do
  if [[ "\$a" == "$want" ]]; then
    exit 0
  fi
done
exit 1
STUBEOF
  chmod +x "$STUB_DIR/pgrep"
}

make_ioreg_stub_idle() {
  cat >"$STUB_DIR/ioreg" <<'STUBEOF'
#!/bin/bash
cat <<'EOF'
    "IOAudioEngineState" = 0
EOF
STUBEOF
  chmod +x "$STUB_DIR/ioreg"
}

make_ioreg_stub_running() {
  cat >"$STUB_DIR/ioreg" <<'STUBEOF'
#!/bin/bash
cat <<'EOF'
    "IOAudioEngineState" = "running"
EOF
STUBEOF
  chmod +x "$STUB_DIR/ioreg"
}

make_osascript_stub_no_tabs() {
  cat >"$STUB_DIR/osascript" <<'STUBEOF'
#!/bin/bash
exit 0
STUBEOF
  chmod +x "$STUB_DIR/osascript"
}

make_pmset_stub() {
  cat >"$STUB_DIR/pmset" <<STUBEOF
#!/bin/bash
echo "\$*" >>"$PMSET_LOG"
exit 0
STUBEOF
  chmod +x "$STUB_DIR/pmset"
}

@test "no signals present: calls pmset and logs action=sleep" {
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == *"action=sleep"* ]]
  grep -q '^displaysleepnow$' "$PMSET_LOG"
}

@test "known process running: suppresses and does not call pmset" {
  make_pgrep_stub_match "zoom.us"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == *"action=suppress"* ]]
  [[ "${lines[0]}" == *"reason=process:zoom.us"* ]]
  [ ! -s "$PMSET_LOG" ]
}

@test "mic active: suppresses and does not call pmset" {
  make_ioreg_stub_running
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == *"action=suppress"* ]]
  [[ "${lines[0]}" == *"reason=mic-active"* ]]
  [ ! -s "$PMSET_LOG" ]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/lock-guard.bats`
Expected: FAIL — `bin/lock-guard` does not exist yet.

- [ ] **Step 3: Write `bin/lock-guard` (process-list and mic-active checks only; Meet check added in Task 2)**

```bash
#!/usr/bin/env bash
set -euo pipefail

conf="${LOCK_SYNC_GUARD_PROCESSES:-$HOME/.config/lock-sync/guard-processes}"
pgrep_cmd="${LOCK_SYNC_PGREP:-/usr/bin/pgrep}"
ioreg_cmd="${LOCK_SYNC_IOREG:-/usr/sbin/ioreg}"
osascript_cmd="${LOCK_SYNC_OSASCRIPT:-/usr/bin/osascript}"
pmset_cmd="${LOCK_SYNC_PMSET:-/usr/bin/pmset}"

default_processes=("zoom.us" "Microsoft Teams" "FaceTime")

log() {
  local ts
  ts=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
  printf '%s %s\n' "$ts" "$*"
}

guard_processes() {
  if [[ -r "$conf" ]]; then
    awk '/^[[:space:]]*(#|$)/ { next } { print }' "$conf"
  else
    printf '%s\n' "${default_processes[@]}"
  fi
}

# Prints the matching process name on stdout and returns 0 if any known
# meeting process is running; returns 1 (no output) otherwise. A pgrep
# failure for an individual name is treated as "not running", never fatal.
check_process() {
  local name
  while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    if "$pgrep_cmd" -xq "$name" 2>/dev/null; then
      printf '%s\n' "$name"
      return 0
    fi
  done < <(guard_processes)
  return 1
}

# Returns 0 if any audio engine reports a running input stream. ioreg
# failure/unexpected output is treated as "not active", never fatal.
check_mic_active() {
  "$ioreg_cmd" -c IOAudioEngine -r -l 2>/dev/null \
    | grep -q '"IOAudioEngineState" = "running"'
}

main() {
  local match
  if match="$(check_process)"; then
    log "action=suppress reason=process:$match"
    return 0
  fi
  if check_mic_active; then
    log "action=suppress reason=mic-active"
    return 0
  fi
  "$pmset_cmd" displaysleepnow >/dev/null 2>&1 || true
  log "action=sleep"
}

main "$@"
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/lock-guard.bats`
Expected: all 3 tests PASS.

- [ ] **Step 5: shellcheck**

Run: `shellcheck -S info bin/lock-guard`
Expected: no findings. Fix any and re-run.

- [ ] **Step 6: Commit**

```bash
git add bin/lock-guard tests/lock-guard.bats
git commit -m "feat: add lock-guard with process-list and mic-active suppression checks"
```

---

## Task 2: Google Meet tab detection via `osascript`

**Files:**

- Modify: `bin/lock-guard`
- Modify: `tests/lock-guard.bats`

**Interfaces:**

- Consumes: `LOCK_SYNC_OSASCRIPT` env var (already wired into `setup()` in
  Task 1's test file, unused until now), `check_process`, `check_mic_active`,
  `log` from Task 1.
- Produces: `check_meet_tab_open` function, wired into `main`'s suppression
  chain after the mic check.

- [ ] **Step 1: Write the failing test**

Add to `tests/lock-guard.bats`:

```bash
make_osascript_stub_meet_tab() {
  cat >"$STUB_DIR/osascript" <<'STUBEOF'
#!/bin/bash
echo "https://meet.google.com/abc-defg-hij"
STUBEOF
  chmod +x "$STUB_DIR/osascript"
}

@test "Meet tab open in Chrome: suppresses and does not call pmset" {
  make_osascript_stub_meet_tab
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == *"action=suppress"* ]]
  [[ "${lines[0]}" == *"reason=meet-tab-open"* ]]
  [ ! -s "$PMSET_LOG" ]
}

@test "Meet landing page open (no room code) does not suppress" {
  cat >"$STUB_DIR/osascript" <<'STUBEOF'
#!/bin/bash
echo "https://meet.google.com/landing"
STUBEOF
  chmod +x "$STUB_DIR/osascript"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"action=sleep"* ]]
  grep -q '^displaysleepnow$' "$PMSET_LOG"
}

@test "osascript failure (e.g. missing Automation permission) does not suppress or crash" {
  cat >"$STUB_DIR/osascript" <<'STUBEOF'
#!/bin/bash
exit 1
STUBEOF
  chmod +x "$STUB_DIR/osascript"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"action=sleep"* ]]
  grep -q '^displaysleepnow$' "$PMSET_LOG"
}
```

- [ ] **Step 2: Run tests to verify the new ones fail**

Run: `bats tests/lock-guard.bats`
Expected: the 3 new tests FAIL (Meet tab match not implemented; landing-page
and osascript-failure cases currently pass trivially since nothing calls
osascript yet — confirm those two still assert real behavior once Step 3
lands, they are guards against future regressions).

- [ ] **Step 3: Add Meet tab check to `bin/lock-guard`**

Add this function, and wire it into `main`:

```bash
# Returns 0 if any open Chrome tab's URL matches an active Meet room
# (meet.google.com/xxx-yyyy-zzz), as opposed to the bare landing page.
# osascript failure (e.g. Automation permission not yet granted, or Chrome
# not running) is treated as "no match", never fatal — see design doc's
# "macOS Automation permission" section.
check_meet_tab_open() {
  local urls
  urls="$("$osascript_cmd" -e '
    tell application "Google Chrome"
      set theURLs to {}
      repeat with w in windows
        repeat with t in tabs of w
          set end of theURLs to URL of t
        end repeat
      end repeat
      return theURLs
    end tell
  ' 2>/dev/null)" || return 1
  [[ "$urls" =~ meet\.google\.com/[a-z]{3}-[a-z]{4}-[a-z]{3} ]]
}
```

Update `main`:

```bash
main() {
  local match
  if match="$(check_process)"; then
    log "action=suppress reason=process:$match"
    return 0
  fi
  if check_mic_active; then
    log "action=suppress reason=mic-active"
    return 0
  fi
  if check_meet_tab_open; then
    log "action=suppress reason=meet-tab-open"
    return 0
  fi
  "$pmset_cmd" displaysleepnow >/dev/null 2>&1 || true
  log "action=sleep"
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/lock-guard.bats`
Expected: all 6 tests PASS.

- [ ] **Step 5: shellcheck**

Run: `shellcheck -S info bin/lock-guard`
Expected: no findings.

- [ ] **Step 6: Commit**

```bash
git add bin/lock-guard tests/lock-guard.bats
git commit -m "feat: detect active Google Meet tabs as a lock-guard suppression signal"
```

---

## Task 3: guard-processes config file support

**Files:**

- Modify: `tests/lock-guard.bats`

**Interfaces:**

- Consumes: `guard_processes` function from Task 1 (already reads
  `LOCK_SYNC_GUARD_PROCESSES` — this task is test-only, confirming the
  behavior already implemented in Task 1 works end-to-end with a real file).

- [ ] **Step 1: Write the failing tests**

Add to `tests/lock-guard.bats`:

```bash
@test "custom guard-processes config replaces the default list" {
  cat >"$TMPDIR/guard-processes" <<'EOF'
# lock-sync guard-processes

Slack Huddle

# zoom.us intentionally not listed here
EOF
  export LOCK_SYNC_GUARD_PROCESSES="$TMPDIR/guard-processes"
  make_pgrep_stub_match "Slack Huddle"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"reason=process:Slack Huddle"* ]]
}

@test "custom guard-processes config: zoom.us not matched when absent from custom list" {
  cat >"$TMPDIR/guard-processes" <<'EOF'
Slack Huddle
EOF
  export LOCK_SYNC_GUARD_PROCESSES="$TMPDIR/guard-processes"
  make_pgrep_stub_match "zoom.us"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"action=sleep"* ]]
  grep -q '^displaysleepnow$' "$PMSET_LOG"
}
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `bats tests/lock-guard.bats`
Expected: all 8 tests PASS without further implementation changes — Task 1's
`guard_processes` function already implements this. If either test fails,
the failure is a real bug in Task 1's implementation; fix `bin/lock-guard`
before proceeding.

- [ ] **Step 3: Commit**

```bash
git add tests/lock-guard.bats
git commit -m "test: cover guard-processes config file override in lock-guard"
```

---

## Task 4: Wire `lock-guard` into `lock-fanout`

**Files:**

- Modify: `bin/lock-fanout:38`
- Modify: `tests/lock-fanout.bats`

**Interfaces:**

- Consumes: `bin/lock-guard` (Task 1-2's finished script) as the new SSH
  remote command, replacing the literal `pmset displaysleepnow`.

- [ ] **Step 1: Update the failing assertions in `tests/lock-fanout.bats`**

The existing ssh stub in `tests/lock-fanout.bats` doesn't currently assert
which remote command ssh was given — it only checks `TARGET=user@host`. Add
one assertion to confirm the remote command changed. Modify
`make_ssh_stub`'s stub body to also capture the remote command:

```bash
# Replace the existing make_ssh_stub function body with this version, which
# additionally records the remote command (the last non-flag, non-target arg)
# to a second log file for assertion.
make_ssh_stub() {
  cat >"$STUB_DIR/ssh" <<'STUBEOF'
#!/bin/bash
has_n=0
target=""
remote_cmd=""
for a in "$@"; do
  case "$a" in
    -n) has_n=1 ;;
    -o|BatchMode=yes|ConnectTimeout=5|StrictHostKeyChecking=accept-new) ;;
    *@*) target="$a" ;;
    *) [[ -n "$target" ]] && remote_cmd="$a" ;;
  esac
done
if (( has_n == 0 )); then
  cat >/dev/null
fi
echo "TARGET=$target" >>"$SSH_LOG"
echo "REMOTE_CMD=$remote_cmd" >>"$SSH_LOG"
if [[ -n "${STUB_SSH_FAIL_HOST:-}" && "$target" == *"$STUB_SSH_FAIL_HOST"* ]]; then
  exit 255
fi
exit 0
STUBEOF
  chmod +x "$STUB_DIR/ssh"
}
```

Add a new test:

```bash
@test "remote command is lock-guard, not a bare pmset call" {
  make_list_clients_stub "asiago.local"
  make_ssh_stub

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q '^REMOTE_CMD=lock-guard$' "$SSH_LOG"
}
```

- [ ] **Step 2: Run tests to verify the new test fails**

Run: `bats tests/lock-fanout.bats`
Expected: `remote command is lock-guard, not a bare pmset call` FAILS
(`REMOTE_CMD=pmset` currently).

- [ ] **Step 3: Update `bin/lock-fanout`**

In `fanout_host`, change:

```bash
    "$user@$host" pmset displaysleepnow >/dev/null 2>&1 || rc=$?
```

to:

```bash
    "$user@$host" lock-guard >/dev/null 2>&1 || rc=$?
```

- [ ] **Step 4: Run all lock-fanout tests to verify they pass**

Run: `bats tests/lock-fanout.bats`
Expected: all tests PASS, including the pre-existing ones (the stub change
in Step 1 is additive and must not break the existing `TARGET=` assertions).

- [ ] **Step 5: shellcheck**

Run: `shellcheck -S info bin/lock-fanout`
Expected: no findings.

- [ ] **Step 6: Commit**

```bash
git add bin/lock-fanout tests/lock-fanout.bats
git commit -m "feat: fanout invokes lock-guard on clients instead of bare pmset"
```

---

## Task 5: Install/uninstall symlink `lock-guard`

**Files:**

- Modify: `bin/install`
- Modify: `bin/uninstall`
- Modify: `tests/install.bats`

**Interfaces:**

- Consumes: `bin/lock-guard` (must exist as a file in the repo — completed
  in Task 1).

- [ ] **Step 1: Read `bin/uninstall` to confirm how it enumerates symlinks**

Run: `cat bin/uninstall`

If it hardcodes a binary list (mirroring `install`'s `for b in lock-watcher
lock-fanout list-clients`), add `lock-guard` to it in Step 3 below. If it
instead globs `$bin_dir/*` or reads the plist, no change is needed there —
note that in the commit message.

- [ ] **Step 2: Write the failing test**

Add to `tests/install.bats`, inside the existing `"fresh install creates
symlinks, plist, and bootstraps via launchctl"` test, alongside the other
`[ -L ... ]` assertions:

```bash
  [ -L "$bin_dir/lock-guard" ]
```

Also add a dedicated uninstall assertion — find the existing uninstall test
(e.g. `"uninstall removes symlinks..."`) and add:

```bash
  [ ! -e "$bin_dir/lock-guard" ]
```

to its post-uninstall checks list.

- [ ] **Step 3: Run tests to verify they fail**

Run: `bats tests/install.bats`
Expected: the new `[ -L "$bin_dir/lock-guard" ]` assertion FAILS.

- [ ] **Step 4: Update `bin/install`**

Change:

```bash
for b in lock-watcher lock-fanout list-clients; do
```

to:

```bash
for b in lock-watcher lock-fanout list-clients lock-guard; do
```

If Step 1 found a hardcoded list in `bin/uninstall`, apply the same addition
there.

- [ ] **Step 5: Run tests to verify they pass**

Run: `bats tests/install.bats`
Expected: all tests PASS.

- [ ] **Step 6: shellcheck**

Run: `shellcheck -S info bin/install bin/uninstall`
Expected: no findings.

- [ ] **Step 7: Commit**

```bash
git add bin/install bin/uninstall tests/install.bats
git commit -m "feat: install/uninstall lock-guard alongside the other lock-sync binaries"
```

---

## Task 6: Documentation

**Files:**

- Modify: `CLAUDE.md`
- Modify: `README.md` (if it exists and documents the binaries/config files
  — check first)

- [ ] **Step 1: Check for README.md**

Run: `ls README.md 2>/dev/null && cat README.md`

- [ ] **Step 2: Update `CLAUDE.md`**

In the "Key external inputs" section, add a new bullet after the per-client
username override bullet:

```markdown
- **Meeting-app suppression list:** `~/.config/lock-sync/guard-processes` (overridable via `LOCK_SYNC_GUARD_PROCESSES`). Same shape as the username-override config: plain text, one process name per line, `#` comments. Absent file uses the built-in default list (`zoom.us`, `Microsoft Teams`, `FaceTime`). Present file replaces the default list entirely (not merged).
```

In the "Commands" section, add a new bullet after the `lock-fanout` bullet:

```markdown
- `bin/lock-guard` — runs on each client (invoked remotely by `lock-fanout` in place of a bare `pmset displaysleepnow`). Skips the lock and logs why if the client looks like it's in a call: a known meeting app is running (`~/.config/lock-sync/guard-processes`), the microphone is actively in use, or a Google Meet room tab is open in Chrome. Emits `<ISO-8601> action=sleep` or `<ISO-8601> action=suppress reason=<reason>`.
```

Add a new subsection after "Current state" documenting the one-time
Automation permission requirement:

```markdown
## lock-guard: one-time Chrome Automation permission

`lock-guard`'s Google Meet detection drives Chrome via `osascript`. The
first time this runs on a client, macOS prompts for Automation permission
(System Settings > Privacy & Security > Automation). Because `lock-guard`
runs non-interactively over SSH from launchd, there is no interactive
session to click "Allow" in — grant this manually once per client, by
running `bin/lock-guard` interactively at a local Terminal on that client
after install, approving the Chrome automation prompt when it appears. If
the permission is never granted, Meet-tab detection silently fails open
(treated as "no Meet tab found," never as a fatal error) — the process-list
and mic-active checks still work normally.
```

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: document lock-guard, guard-processes config, and Chrome Automation setup"
```

---

## Self-review checklist (already applied above, kept for reference)

- Spec coverage: process-list check (Task 1), mic-active check (Task 1),
  Meet-tab check (Task 2), configurable process list (Task 3), fanout wiring
  (Task 4), install/uninstall (Task 5), docs incl. one-time permission setup
  (Task 6). All three signals from the design are implemented and tested
  independently plus in combination via the "no signals" and priority-order
  tests.
- No placeholders: every step has literal code or literal shell commands.
- Type/name consistency: `check_process`, `check_mic_active`,
  `check_meet_tab_open`, `guard_processes`, `log` are used with the same
  names across Tasks 1–2 as introduced.
</content>
