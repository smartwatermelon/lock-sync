# Slice c2 — LaunchAgent install tooling

Date: 2026-04-17
Status: approved, ready to implement

## Purpose

Final slice of lock-sync. Ship the LaunchAgent plist and install/uninstall
tooling so the watcher auto-starts on user login.

## Scope

- `bin/install` (new) — create symlinks, generate plist, load into launchd.
- `bin/uninstall` (new) — reverse install, preserve log.
- `tests/install.bats` (new) — 6 bats tests covering both scripts.
- CLAUDE.md — mark project complete; document install/uninstall commands.

## Contract

**Install (`bin/install`):**

```text
<repo>/bin/install
```

No args. Idempotent. Side effects:

- Symlinks `<repo>/bin/{lock-watcher,lock-fanout,list-clients}` into
  `~/.local/bin/` (creating that dir if missing).
- Writes `~/Library/LaunchAgents/com.smartwatermelon.lock-sync.plist` with
  `$HOME` expanded to absolute path (launchd does not expand env vars in
  plists).
- Creates `~/Library/Logs/` (if missing).
- `launchctl bootout gui/<uid>/com.smartwatermelon.lock-sync` (tolerated as
  missing), then `launchctl bootstrap gui/<uid> <plist>`.

**Uninstall (`bin/uninstall`):**

```text
<repo>/bin/uninstall
```

No args. Idempotent. Side effects:

- `launchctl bootout gui/<uid>/com.smartwatermelon.lock-sync` (tolerated as
  missing).
- Removes the plist if present.
- Removes the three symlinks if present.
- **Preserves** `~/Library/Logs/lock-sync.log` so users can inspect history.

## Plist

Label: `com.smartwatermelon.lock-sync`. File:
`~/Library/LaunchAgents/com.smartwatermelon.lock-sync.plist`.

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTD/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>com.smartwatermelon.lock-sync</string>
    <key>ProgramArguments</key><array>
        <string>$HOME/.local/bin/lock-watcher</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict>
        <key>SuccessfulExit</key><false/>
    </dict>
    <key>StandardOutPath</key><string>$HOME/Library/Logs/lock-sync.log</string>
    <key>StandardErrorPath</key><string>$HOME/Library/Logs/lock-sync.log</string>
    <key>ProcessType</key><string>Background</string>
    <key>ThrottleInterval</key><integer>10</integer>
</dict>
</plist>
```

- `RunAtLoad` + `KeepAlive={SuccessfulExit:false}` — start on login, restart
  only on abnormal exit. SIGTERM (exit 143) is a successful signal-exit under
  launchd semantics, so logout/shutdown doesn't trigger a restart loop.
- `StandardOut/ErrPath` both point at `~/Library/Logs/lock-sync.log`, the
  macOS convention. Console.app surfaces it; `log` CLI knows it.
- `ProcessType=Background` — hints the scheduler the agent shouldn't compete
  with interactive work.
- `ThrottleInterval=10` — minimum 10s between restarts; guards against
  crashloop churn.

## Implementation

### `bin/install`

```bash
#!/usr/bin/env bash
set -euo pipefail

LABEL="com.smartwatermelon.lock-sync"

script_dir="$(cd -- "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
repo_root="$(cd -- "$script_dir/.." && pwd)"
bin_dir="$HOME/.local/bin"
plist_dir="$HOME/Library/LaunchAgents"
plist_path="$plist_dir/$LABEL.plist"
log_path="$HOME/Library/Logs/lock-sync.log"

say() { printf 'install: %s\n' "$*"; }

mkdir -p "$bin_dir" "$plist_dir" "$(dirname "$log_path")"

for b in lock-watcher lock-fanout list-clients; do
  ln -sf "$repo_root/bin/$b" "$bin_dir/$b"
  say "symlinked $bin_dir/$b -> $repo_root/bin/$b"
done

cat >"$plist_path" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTD/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key><string>$LABEL</string>
    <key>ProgramArguments</key><array>
        <string>$bin_dir/lock-watcher</string>
    </array>
    <key>RunAtLoad</key><true/>
    <key>KeepAlive</key><dict>
        <key>SuccessfulExit</key><false/>
    </dict>
    <key>StandardOutPath</key><string>$log_path</string>
    <key>StandardErrorPath</key><string>$log_path</string>
    <key>ProcessType</key><string>Background</string>
    <key>ThrottleInterval</key><integer>10</integer>
</dict>
</plist>
EOF
say "wrote plist: $plist_path"

domain="gui/$(id -u)"
launchctl bootout "$domain/$LABEL" 2>/dev/null || true
launchctl bootstrap "$domain" "$plist_path"
say "bootstrapped into $domain"
say "done"
```

### `bin/uninstall`

```bash
#!/usr/bin/env bash
set -euo pipefail

LABEL="com.smartwatermelon.lock-sync"
bin_dir="$HOME/.local/bin"
plist_path="$HOME/Library/LaunchAgents/$LABEL.plist"

say() { printf 'uninstall: %s\n' "$*"; }

domain="gui/$(id -u)"
launchctl bootout "$domain/$LABEL" 2>/dev/null || say "(agent was not loaded)"

if [[ -f "$plist_path" ]]; then
  rm "$plist_path"
  say "removed $plist_path"
fi

for b in lock-watcher lock-fanout list-clients; do
  if [[ -L "$bin_dir/$b" ]]; then
    rm "$bin_dir/$b"
    say "removed $bin_dir/$b"
  fi
done

say "done (log file at \$HOME/Library/Logs/lock-sync.log preserved)"
```

### Why these shapes

- **`ln -sf`, `mkdir -p`, `|| true` on bootout, `[[ -f/-L ]]` guards on remove**
  — full idempotency.
- **`bootout` before `bootstrap` in install** — picks up plist changes on
  re-install.
- **Modern `launchctl bootstrap/bootout gui/<uid>`** over deprecated
  `load/unload`. Works on macOS 10.11+.
- **Log file preserved on uninstall** — users may want to inspect history.
- **Plist points at `$bin_dir/lock-watcher`** (the `~/.local/bin` symlink),
  decoupling the plist from the repo's on-disk location.

## Tests

**Framework:** bats-core.

**Layout:** `tests/install.bats` covers both scripts (single setup).

### Testing strategy

- `HOME` redirected to `$TMPDIR/home` so symlinks/plist/log land in the
  sandbox, not real `~`.
- PATH-shim `launchctl`: `$STUB_DIR/launchctl` records args to
  `$TMPDIR/launchctl.log` and exits 0. Tests grep that log.
- Symlink targets point at `$BATS_TEST_DIRNAME/../bin/<script>` — valid
  because the real binaries exist in the repo checkout.

### Cases (6)

*Install (3):*

1. Fresh install creates three symlinks under `~/.local/bin/`, creates
   plist, calls `launchctl bootstrap gui/<uid>`.
2. Install is idempotent — run twice; both exit 0, final state identical,
   second run invokes `bootout` before `bootstrap`.
3. Plist content is correct — contains `Label`, `ProgramArguments`,
   `StandardOutPath`, `StandardErrorPath` with expected substrings.

*Uninstall (3):*

1. Uninstall on clean state — exits 0, no errors, tolerates missing agent.
2. Uninstall after install — plist gone, all three symlinks gone, `launchctl
   bootout` invoked with the label.
3. Uninstall preserves log — pre-populate log with known content, run
   uninstall, content still there.

## CI integration

No workflow changes. `bats tests/` picks up the new file. Shellcheck `bin/*`
glob covers the two new scripts.

## Manual smoke test

```text
bin/install
launchctl list | grep com.smartwatermelon.lock-sync   # should show agent
# Ctrl+Cmd+Q to lock; unlock; inspect:
tail ~/Library/Logs/lock-sync.log
bin/uninstall
launchctl list | grep com.smartwatermelon.lock-sync   # should be empty
```

This actually modifies real system state, so it runs after bats is green
and only with user confirmation.

## Implementation order (TDD)

1. Write `tests/install.bats` (6 tests). Run → 6 RED.
2. Write `bin/install`. Run → install tests (1-3) GREEN, uninstall tests
   (4-6) still RED.
3. Write `bin/uninstall`. Run → all 6 GREEN.
4. `shellcheck -S info bin/*` clean.
5. Update CLAUDE.md "Current state" (project complete), "Commands"
   (install/uninstall), "Runtime" (LaunchAgent now real, not planned).
6. Commit, push, PR.
