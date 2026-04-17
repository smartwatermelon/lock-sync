#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# bats injects BATS_TEST_DIRNAME; pre-declare for shellcheck SC2154.
: "${BATS_TEST_DIRNAME:=}"

LABEL="com.smartwatermelon.lock-sync"

setup() {
  SCRIPT_INSTALL="$BATS_TEST_DIRNAME/../bin/install"
  SCRIPT_UNINSTALL="$BATS_TEST_DIRNAME/../bin/uninstall"
  TMPDIR="$(mktemp -d)"
  STUB_DIR="$TMPDIR/stub"
  mkdir -p "$STUB_DIR"
  PATH="$STUB_DIR:$PATH"

  export HOME="$TMPDIR/home"
  mkdir -p "$HOME"
  LAUNCHCTL_LOG="$TMPDIR/launchctl.log"
  export LAUNCHCTL_LOG

  # Shim launchctl so tests don't touch real launchd.
  cat >"$STUB_DIR/launchctl" <<'STUBEOF'
#!/bin/bash
echo "$*" >>"$LAUNCHCTL_LOG"
# `bootout` on a non-loaded agent returns non-zero in real life;
# the install/uninstall scripts tolerate that via `|| true`/`|| say`.
# The stub always exits 0 because tests aren't exercising that path.
exit 0
STUBEOF
  chmod +x "$STUB_DIR/launchctl"

  plist_path="$HOME/Library/LaunchAgents/$LABEL.plist"
  bin_dir="$HOME/.local/bin"
  log_path="$HOME/Library/Logs/lock-sync.log"
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "fresh install creates symlinks, plist, and bootstraps via launchctl" {
  run "$SCRIPT_INSTALL"
  [ "$status" -eq 0 ]

  [ -L "$bin_dir/lock-watcher" ]
  [ -L "$bin_dir/lock-fanout" ]
  [ -L "$bin_dir/list-clients" ]
  [ -f "$plist_path" ]
  [ -d "$(dirname "$log_path")" ]

  grep -q "^bootstrap gui/$(id -u) $plist_path\$" "$LAUNCHCTL_LOG"
}

@test "install is idempotent: second run succeeds and calls bootout before bootstrap" {
  run "$SCRIPT_INSTALL"
  [ "$status" -eq 0 ]
  : >"$LAUNCHCTL_LOG"

  run "$SCRIPT_INSTALL"
  [ "$status" -eq 0 ]

  [ -L "$bin_dir/lock-watcher" ]
  [ -f "$plist_path" ]
  grep -q "^bootout gui/$(id -u)/$LABEL\$" "$LAUNCHCTL_LOG"
  grep -q "^bootstrap gui/$(id -u) $plist_path\$" "$LAUNCHCTL_LOG"
}

@test "plist content has expected Label, ProgramArguments, and log paths" {
  run "$SCRIPT_INSTALL"
  [ "$status" -eq 0 ]

  grep -q "<string>$LABEL</string>" "$plist_path"
  grep -q "<string>$bin_dir/lock-watcher</string>" "$plist_path"
  grep -q "<string>$log_path</string>" "$plist_path"
  grep -q "<key>RunAtLoad</key>" "$plist_path"
  grep -q "<key>KeepAlive</key>" "$plist_path"
}

@test "uninstall on clean state exits 0 tolerating missing agent" {
  run "$SCRIPT_UNINSTALL"
  [ "$status" -eq 0 ]
  [ ! -f "$plist_path" ]
  [ ! -L "$bin_dir/lock-watcher" ]
}

@test "uninstall after install removes plist, symlinks, and calls bootout" {
  run "$SCRIPT_INSTALL"
  [ "$status" -eq 0 ]
  : >"$LAUNCHCTL_LOG"

  run "$SCRIPT_UNINSTALL"
  [ "$status" -eq 0 ]

  [ ! -f "$plist_path" ]
  [ ! -L "$bin_dir/lock-watcher" ]
  [ ! -L "$bin_dir/lock-fanout" ]
  [ ! -L "$bin_dir/list-clients" ]
  grep -q "^bootout gui/$(id -u)/$LABEL\$" "$LAUNCHCTL_LOG"
}

@test "uninstall preserves the log file" {
  run "$SCRIPT_INSTALL"
  [ "$status" -eq 0 ]
  echo "pre-uninstall log content" >"$log_path"

  run "$SCRIPT_UNINSTALL"
  [ "$status" -eq 0 ]

  [ -f "$log_path" ]
  [ "$(cat "$log_path")" = "pre-uninstall log content" ]
}
