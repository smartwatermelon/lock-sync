#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# bats injects BATS_TEST_DIRNAME; pre-declare for shellcheck SC2154.
: "${BATS_TEST_DIRNAME:=}"

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../bin/lock-watcher"
  TMPDIR="$(mktemp -d)"
  STUB_DIR="$TMPDIR/stub"
  mkdir -p "$STUB_DIR"
  PATH="$STUB_DIR:$PATH"
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "single lock event emits one ISO-8601 log line and exits 0" {
  cat >"$STUB_DIR/notifyutil" <<'EOF'
#!/bin/bash
echo "com.apple.screenIsLocked"
EOF
  chmod +x "$STUB_DIR/notifyutil"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ locked$ ]]
}

@test "three lock events emit three log lines in order" {
  cat >"$STUB_DIR/notifyutil" <<'EOF'
#!/bin/bash
echo "com.apple.screenIsLocked"
echo "com.apple.screenIsLocked"
echo "com.apple.screenIsLocked"
EOF
  chmod +x "$STUB_DIR/notifyutil"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  for line in "${lines[@]}"; do
    [[ "$line" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ locked$ ]]
  done
}

@test "zero events (notifyutil exits cleanly before firing) emits nothing with exit 0" {
  cat >"$STUB_DIR/notifyutil" <<'EOF'
#!/bin/bash
exit 0
EOF
  chmod +x "$STUB_DIR/notifyutil"

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "notifyutil dying non-zero mid-stream propagates via pipefail" {
  cat >"$STUB_DIR/notifyutil" <<'EOF'
#!/bin/bash
echo "com.apple.screenIsLocked"
exit 1
EOF
  chmod +x "$STUB_DIR/notifyutil"

  run "$SCRIPT"
  [ "$status" -ne 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z\ locked$ ]]
}
