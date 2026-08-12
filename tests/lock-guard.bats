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
  export LOCK_SYNC_OSASCRIPT="$STUB_DIR/osascript"
  export LOCK_SYNC_PMSET="$STUB_DIR/pmset"

  # Default stubs: nothing matches, nothing running, no tabs. Tests override
  # individual stubs to trigger specific signals.
  make_pgrep_stub_no_match
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

make_osascript_stub_no_tabs() {
  cat >"$STUB_DIR/osascript" <<'STUBEOF'
#!/bin/bash
exit 0
STUBEOF
  chmod +x "$STUB_DIR/osascript"
}

make_osascript_stub_meet_tab() {
  cat >"$STUB_DIR/osascript" <<'STUBEOF'
#!/bin/bash
echo "https://meet.google.com/abc-defg-hij"
STUBEOF
  chmod +x "$STUB_DIR/osascript"
}

# Combined pmset stub, branching on its arguments: when called with
# `-g assertions` (the mic-active check), prints nothing — idle mic. When
# called with anything else (i.e. `displaysleepnow`), logs the args to
# PMSET_LOG as before, so existing displaysleepnow assertions keep working.
make_pmset_stub() {
  cat >"$STUB_DIR/pmset" <<STUBEOF
#!/bin/bash
if [[ "\$1" == "-g" && "\$2" == "assertions" ]]; then
  exit 0
fi
echo "\$*" >>"$PMSET_LOG"
exit 0
STUBEOF
  chmod +x "$STUB_DIR/pmset"
}

# Same idle behavior as make_pmset_stub; kept as a distinct, clearly-named
# entry point for tests that want to be explicit about the mic state.
make_pmset_stub_mic_idle() {
  make_pmset_stub
}

# Same branching pmset stub, but `-g assertions` prints a real captured line
# from a live mic-open state on Apple Silicon (macOS 26.6.1) — per the
# review's lesson not to hand-write stub output that merely echoes what the
# implementation expects. Still logs displaysleepnow calls to PMSET_LOG.
make_pmset_stub_mic_active() {
  cat >"$STUB_DIR/pmset" <<STUBEOF
#!/bin/bash
if [[ "\$1" == "-g" && "\$2" == "assertions" ]]; then
  cat <<'EOF'
   pid 601(coreaudiod): [0x0006b3c500019811] 00:00:01 PreventUserIdleSystemSleep named: "com.apple.audio.BuiltInMicrophoneDevice.context.preventuseridlesleep"
EOF
  exit 0
fi
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
  make_pmset_stub_mic_active
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == *"action=suppress"* ]]
  [[ "${lines[0]}" == *"reason=mic-active"* ]]
  [ ! -s "$PMSET_LOG" ]
}

@test "Meet tab open in Chrome: suppresses and does not call pmset" {
  make_pgrep_stub_no_match
  make_pmset_stub_mic_idle
  make_osascript_stub_meet_tab
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == *"action=suppress"* ]]
  [[ "${lines[0]}" == *"reason=meet-tab-open"* ]]
  [ ! -s "$PMSET_LOG" ]
}

@test "Meet landing page open (no room code) does not suppress" {
  make_pgrep_stub_no_match
  make_pmset_stub_mic_idle
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
  make_pgrep_stub_no_match
  make_pmset_stub_mic_idle
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

@test "Meet tab with mixed-case room code: suppresses and does not call pmset" {
  make_pgrep_stub_no_match
  make_pmset_stub_mic_idle
  cat >"$STUB_DIR/osascript" <<'STUBEOF'
#!/bin/bash
echo "https://meet.google.com/ABC-defG-hij"
STUBEOF
  chmod +x "$STUB_DIR/osascript"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == *"action=suppress"* ]]
  [[ "${lines[0]}" == *"reason=meet-tab-open"* ]]
  [ ! -s "$PMSET_LOG" ]
}

@test "URL with meet.google.com as a substring but wrong host does not suppress" {
  make_pgrep_stub_no_match
  make_pmset_stub_mic_idle
  cat >"$STUB_DIR/osascript" <<'STUBEOF'
#!/bin/bash
echo "https://evil.com/?r=meet.google.com/abc-defg-hij"
STUBEOF
  chmod +x "$STUB_DIR/osascript"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"action=sleep"* ]]
  grep -q '^displaysleepnow$' "$PMSET_LOG"
}

@test "URL with notmeet.google.com host does not suppress" {
  make_pgrep_stub_no_match
  make_pmset_stub_mic_idle
  cat >"$STUB_DIR/osascript" <<'STUBEOF'
#!/bin/bash
echo "https://notmeet.google.com/abc-defg-hij"
STUBEOF
  chmod +x "$STUB_DIR/osascript"
  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"action=sleep"* ]]
  grep -q '^displaysleepnow$' "$PMSET_LOG"
}

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

@test "guard-processes config line with trailing whitespace still matches" {
  printf 'Slack Huddle   \n' >"$TMPDIR/guard-processes"
  export LOCK_SYNC_GUARD_PROCESSES="$TMPDIR/guard-processes"
  make_pgrep_stub_match "Slack Huddle"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"action=suppress"* ]]
  [[ "${lines[0]}" == *"reason=process:Slack Huddle"* ]]
  [ ! -s "$PMSET_LOG" ]
}
