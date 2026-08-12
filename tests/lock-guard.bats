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

make_osascript_stub_meet_tab() {
  cat >"$STUB_DIR/osascript" <<'STUBEOF'
#!/bin/bash
echo "https://meet.google.com/abc-defg-hij"
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

@test "Meet tab open in Chrome: suppresses and does not call pmset" {
  make_pgrep_stub_no_match
  make_ioreg_stub_idle
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
  make_ioreg_stub_idle
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
  make_ioreg_stub_idle
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
  make_ioreg_stub_idle
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
