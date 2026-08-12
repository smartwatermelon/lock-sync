# `lock-fanout` remote provisioning of `lock-guard`

Date: 2026-08-12
Status: approved, ready to implement

## Purpose

PR #25 (docs/plans/2026-08-12-lock-guard-meeting-suppression-design.md)
changed `lock-fanout` to invoke `lock-guard` on each client over SSH, in
place of a bare `pmset displaysleepnow`. This silently broke the project's
deployment model: before PR #25, clients needed **zero footprint** — no
git clone, no `bin/install`, nothing beyond an SSH key and a stock macOS
`pmset` binary. After PR #25, every client needs `lock-guard` symlinked
into `~/.local/bin` via `bin/install`, which requires cloning this repo
onto every client. The repo
owner does not want clients to ever clone this repo — that was never the
model and isn't going to become the model.

This plan restores the zero-footprint client property by having the
controller push `lock-guard`'s content directly over SSH, on demand, as
part of the lock flow — no client-side git clone or `bin/install` ever
required.

## Non-goals reminder

Per CLAUDE.md: no unlock, no passwords/keychain, no remote wake, no
bidirectional sync. This plan is push-only and lock-triggered — the
controller pushes a file to a client as part of handling its own lock
event; the client never initiates anything back to the controller, and
nothing here reintroduces bidirectional sync or a persistent client-side
agent. This is an extension of the trust model `lock-fanout` already has
(SSH key auth, remote command execution) — not a new one.

## Design

### Flow

```text
1. bin/install runs on the controller (unchanged, today's behavior).
2. Controller locks -> lock-watcher fires -> lock-fanout runs (unchanged).
3. For each client (from list-clients, unchanged):
   a. provision_host: SSH a checksum check of the client's
      ~/.local/bin/lock-guard against the controller's local copy.
      - Missing or mismatched -> push lock-guard's content over SSH,
        chmod +x remotely.
      - Matches -> no push, nothing to do.
      - The checksum-check/push SSH call itself fails (client
        unreachable, remote error) -> log a provisioning warning and
        fall back to invoking `pmset displaysleepnow` directly for this
        client THIS CYCLE ONLY (skip lock-guard's suppression checks
        entirely for this client on this lock event) rather than
        attempting a lock-guard call that would just fail the same way
        #25 did.
   b. If provisioning succeeded (pushed or already current): invoke
      lock-guard as today (unchanged call, unchanged log line shape).
```

### Why fall back to bare `pmset` on provisioning failure, not skip the client

A client lock-fanout can't provision this cycle is still a client that
should lock (without meeting-suppression) rather than not lock at all —
falling back to the pre-#25 behavior avoids quietly reintroducing #25's
exact failure mode (a client that silently never locks) for any client the
provisioning step itself can't reach. This trades away that client's
meeting-suppression for one cycle in exchange for guaranteeing the client
still locks.

### Why two SSH round-trips per client, not one combined call

Keeps each concern (provisioning vs. locking) in its own function/call,
matching the existing separation between `lock-fanout` (orchestration) and
`lock-guard` (client-side decision). A combined single-SSH-call approach
(push+run in one invocation) is more complex to get right and doesn't
meaningfully reduce round-trips in practice (pushing file content and then
executing it are different operations even within one SSH session). The
extra round-trip's latency cost is accepted for this minimal version;
issue #26 tracks reconsidering whether provisioning should move out of the
per-lock critical path entirely (e.g. only at controller boot / on
`bin/install`) as a later optimization — out of scope here.

### Checksum mechanism

`shasum -a 256` (already present on stock macOS, no new dependency,
consistent with the project's "minimal footprint" philosophy). The
controller computes its own `bin/lock-guard`'s checksum locally (no SSH
needed — it's the controller's own file) and compares against what the
client reports.

### Push mechanism

`ssh client 'cat > ~/.local/bin/lock-guard && chmod +x ~/.local/bin/lock-guard'`,
fed the controller's local `bin/lock-guard` file content via SSH's stdin.
This requires `~/.local/bin` to exist on the client — create it as part of
the same remote command if missing (`mkdir -p ~/.local/bin`), since a
client that's never been provisioned won't have that directory either
(consistent with "clients need zero prior setup").

### Failure mode philosophy

Matches `lock-fanout`'s existing philosophy: log clearly, never let one
client's failure block others, never crash the loop. Every new SSH call
this plan introduces (checksum check, push) follows the same pattern
already used for the `lock-guard`/`pmset` calls: capture `rc=$?`, log it,
move on.

## Files touched

- **Modify:** `bin/lock-fanout` — add `provision_host` (checksum check +
  conditional push), call it before the existing `lock-guard` invocation
  in `fanout_host`, add the bare-`pmset`-fallback path for provisioning
  failure.
- **Modify:** `tests/lock-fanout.bats` — new tests for: successful
  provisioning push, skip-push-when-checksum-matches, provisioning
  failure falls back to bare `pmset displaysleepnow`.

`bin/lock-guard` itself is unchanged by this plan — it's the payload being
pushed, not modified.

## Testability

Following the existing pattern (SSH is stubbed via `LOCK_SYNC_SSH`), the
new `provision_host` logic reuses the same `ssh_cmd` variable and the same
test-stub SSH binary already used by every other `lock-fanout` test. No new
environment-variable overrides are needed — `shasum` is not stubbed;
`provision_host`'s local checksum of the controller's own `bin/lock-guard`
runs unstubbed in tests too, since it's a real, fast, local, no-network
operation reading a real file that's already present in the test
environment (the repo's own `bin/lock-guard`). Only the SSH round-trips to
the "client" are stubbed.

---

## Task 1: `provision_host` — checksum check, conditional push, fallback on failure

**Files:**

- Modify: `bin/lock-fanout`
- Modify: `tests/lock-fanout.bats`

**Interfaces:**

- Produces: `provision_host(host, user)` function in `bin/lock-fanout`.
  Returns 0 if the client now has (or already had) a current
  `~/.local/bin/lock-guard`. Returns 1 if provisioning failed (client
  unreachable, checksum-check or push SSH call failed) — callers use this
  return value to decide whether to invoke `lock-guard` normally or fall
  back to bare `pmset displaysleepnow`.
- Consumes: `ssh_cmd`, `log()` (both already defined earlier in
  `bin/lock-fanout`, unchanged).

- [ ] **Step 1: Write the failing tests**

Add to `tests/lock-fanout.bats`. These tests need the ssh stub to
distinguish between the two different remote commands `provision_host` and
the existing `lock-guard` call will send (a `shasum` check vs. a `cat >`
push vs. the existing `lock-guard` invocation vs. a `pmset` fallback), so
extend `make_ssh_stub` to log every distinct remote command it receives (not
just the last one) to `SSH_LOG`, and to support per-call scripted responses
via env vars. Replace the existing `make_ssh_stub` function with this
version:

```bash
# Stub for ssh; records EVERY distinct remote command invocation to SSH_LOG
# as "TARGET=<user@host> CMD=<remote command or stdin-marker>", one line per
# ssh call (not just the last, since provisioning now makes multiple calls
# per client). Exits with code from arg-match. By default exits 0; set
# STUB_SSH_FAIL_HOST to have all calls targeting that host exit 255.
# STUB_SSH_CHECKSUM_HOST/STUB_SSH_CHECKSUM_VALUE let a test script a
# specific shasum stdout for a specific host's checksum-check call.
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
stdin_marker=""
if (( has_n == 0 )); then
  stdin_marker="STDIN=$(cat)"
fi
echo "TARGET=$target CMD=${remote_cmd} ${stdin_marker}" >>"$SSH_LOG"
if [[ -n "${STUB_SSH_FAIL_HOST:-}" && "$target" == *"$STUB_SSH_FAIL_HOST"* ]]; then
  exit 255
fi
if [[ -n "${STUB_SSH_CHECKSUM_HOST:-}" && "$target" == *"$STUB_SSH_CHECKSUM_HOST"* && "$remote_cmd" == *shasum* ]]; then
  echo "${STUB_SSH_CHECKSUM_VALUE:-}"
fi
exit 0
STUBEOF
  chmod +x "$STUB_DIR/ssh"
}
```

Add these tests:

```bash
@test "provisioning: checksum mismatch pushes lock-guard content and chmods it" {
  make_list_clients_stub "asiago.local"
  export STUB_SSH_CHECKSUM_HOST="asiago.local"
  export STUB_SSH_CHECKSUM_VALUE="0000000000000000000000000000000000000000000000000000000000000000  lock-guard"
  make_ssh_stub

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'TARGET=.*asiago.local CMD=.*shasum' "$SSH_LOG"
  grep -q 'TARGET=.*asiago.local CMD=.*cat >' "$SSH_LOG"
  grep -q "TARGET=.*asiago.local CMD=.*chmod +x" "$SSH_LOG"
}

@test "provisioning: matching checksum skips the push" {
  make_list_clients_stub "asiago.local"
  local_sha=$(shasum -a 256 "$BATS_TEST_DIRNAME/../bin/lock-guard" | awk '{print $1}')
  export STUB_SSH_CHECKSUM_HOST="asiago.local"
  export STUB_SSH_CHECKSUM_VALUE="$local_sha  lock-guard"
  make_ssh_stub

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'TARGET=.*asiago.local CMD=.*shasum' "$SSH_LOG"
  ! grep -q 'CMD=.*cat >' "$SSH_LOG"
}

@test "provisioning failure falls back to bare pmset displaysleepnow for that client" {
  make_list_clients_stub "asiago.local"
  export STUB_SSH_FAIL_HOST="asiago.local"
  make_ssh_stub

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'TARGET=.*asiago.local CMD=.*pmset displaysleepnow' "$SSH_LOG"
  ! grep -q 'CMD=.*lock-guard' "$SSH_LOG"
  [[ "${lines[0]}" == *"client=asiago.local"* ]]
  [[ "${lines[0]}" == *"warn=provision-failed"* ]]
}

@test "successful provisioning still invokes lock-guard normally afterward" {
  make_list_clients_stub "asiago.local"
  local_sha=$(shasum -a 256 "$BATS_TEST_DIRNAME/../bin/lock-guard" | awk '{print $1}')
  export STUB_SSH_CHECKSUM_HOST="asiago.local"
  export STUB_SSH_CHECKSUM_VALUE="$local_sha  lock-guard"
  make_ssh_stub

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'TARGET=.*asiago.local CMD=.*\$HOME/.local/bin/lock-guard' "$SSH_LOG"
  [[ "${lines[0]}" == *"client=asiago.local"* ]]
  [[ "${lines[0]}" == *"ssh_exit=0"* ]]
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bats tests/lock-fanout.bats`
Expected: the 4 new tests FAIL (`provision_host` not implemented, and the
old `make_ssh_stub` — before your replacement — didn't log per-call
history). The 9 pre-existing tests may also need re-verification since
`make_ssh_stub` changed shape — the pre-existing `REMOTE_CMD=` assertions
in older tests must be updated to the new `CMD=` log format in this same
step (see Step 3 for the exact replacements), otherwise those tests will
also fail after the stub replacement — that's expected and intentional at
this point, not a new bug.

Update the pre-existing tests' assertions from `TARGET=...` / `REMOTE_CMD=...`
(two separate lines) to the new single-line `TARGET=... CMD=...` format,
e.g. change:

```bash
  grep -q '^TARGET=adminuser@asiago.local$' "$SSH_LOG"
```

to:

```bash
  grep -q 'TARGET=adminuser@asiago.local CMD=' "$SSH_LOG"
```

Apply the equivalent transform to every pre-existing test that greps
`SSH_LOG` for `TARGET=` or `REMOTE_CMD=` (there are several — search the
file for both strings and update each). The final
`"remote command is lock-guard's absolute path, not a bare pmset call"`
test's assertion becomes:

```bash
  grep -q 'CMD=\$HOME/.local/bin/lock-guard' "$SSH_LOG"
```

This test also needs `STUB_SSH_CHECKSUM_HOST`/`STUB_SSH_CHECKSUM_VALUE` set
to a matching checksum (same pattern as
"successful provisioning still invokes lock-guard normally afterward"
above) so provisioning succeeds and falls through to the lock-guard call —
otherwise, after Step 3's implementation, this test would instead exercise
the bare-`pmset`-fallback path and its old assertion would fail for the
right reason but the wrong test.

- [ ] **Step 3: Implement `provision_host` in `bin/lock-fanout`**

Add near the top of the file, alongside the other variable declarations:

```bash
local_lock_guard="$script_dir/lock-guard"
shasum_cmd="${LOCK_SYNC_SHASUM:-/usr/bin/shasum}"
```

Add the `provision_host` function, before `fanout_host`:

```bash
# Ensures $host has a current copy of lock-guard at ~/.local/bin/lock-guard,
# pushing it over SSH if missing or stale, without requiring the client to
# ever clone this repo (see docs/plans/2026-08-12-lock-guard-remote-
# provisioning-design.md — clients have zero footprint by design).
# Returns 0 if the client now has (or already had) a current lock-guard.
# Returns 1 if the checksum check or push itself failed (client
# unreachable, etc) — callers fall back to bare pmset in that case rather
# than attempting a lock-guard call that would fail the same way.
provision_host() {
  local host="$1" user="$2" local_sha remote_sha rc=0

  local_sha="$("$shasum_cmd" -a 256 "$local_lock_guard" | awk '{print $1}')"

  remote_sha="$("$ssh_cmd" -n -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=accept-new \
    "$user@$host" 'shasum -a 256 ~/.local/bin/lock-guard 2>/dev/null' 2>/dev/null)" || rc=$?
  if ((rc != 0)); then
    return 1
  fi
  remote_sha="${remote_sha%% *}"

  if [[ "$remote_sha" == "$local_sha" ]]; then
    return 0
  fi

  "$ssh_cmd" -o BatchMode=yes \
    -o ConnectTimeout=5 \
    -o StrictHostKeyChecking=accept-new \
    "$user@$host" 'mkdir -p ~/.local/bin && cat > ~/.local/bin/lock-guard && chmod +x ~/.local/bin/lock-guard' \
    <"$local_lock_guard" >/dev/null 2>&1 || rc=$?
  if ((rc != 0)); then
    return 1
  fi
  return 0
}
```

Note: the push call intentionally omits `-n` (unlike every other ssh call
in this file) because it needs to read `bin/lock-guard`'s content from
stdin (`<"$local_lock_guard"`) rather than from `/dev/null` — this is safe
here because `provision_host` is called once per host inside `fanout_host`,
not inside a `while read` loop over stdin the way `main`'s host-list
iteration is, so there's no risk of it consuming a shared stdin stream (see
the existing `-n` comment in `fanout_host` for why that risk exists
elsewhere in this file).

Update `fanout_host`:

```bash
fanout_host() {
  local host="$1" override user rc=0
  override=$(lookup_user "$host")
  user="${override:-$default_user}"

  if provision_host "$host" "$user"; then
    # `-n` redirects ssh's stdin from /dev/null. Required because ssh otherwise
    # reads from the caller's stdin, and in `main`'s `while read <<< "$clients"`
    # loop that means ssh consumes the remaining hosts, so only the first
    # iteration runs.
    "$ssh_cmd" -n -o BatchMode=yes \
      -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=accept-new \
      "$user@$host" "\$HOME/.local/bin/lock-guard" >/dev/null 2>&1 || rc=$?
    log "client=$host user=$user ssh_exit=$rc"
  else
    log "client=$host user=$user warn=provision-failed"
    "$ssh_cmd" -n -o BatchMode=yes \
      -o ConnectTimeout=5 \
      -o StrictHostKeyChecking=accept-new \
      "$user@$host" pmset displaysleepnow >/dev/null 2>&1 || rc=$?
    log "client=$host user=$user ssh_exit=$rc"
  fi
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bats tests/lock-fanout.bats`
Expected: all tests PASS (4 new + 9 pre-existing with updated assertions =
13 total in this file).

- [ ] **Step 5: Run the full suite**

Run: `bats tests/`
Expected: all tests across the whole project PASS (no regressions in
`lock-guard.bats`, `install.bats`, etc — this task only touches
`lock-fanout` and its own tests, but confirm nothing else depended on the
exact prior SSH stub log format, which shouldn't be the case since
`SSH_LOG`/`make_ssh_stub` are local to `tests/lock-fanout.bats`).

- [ ] **Step 6: shellcheck**

Run: `shellcheck -S info bin/lock-fanout`
Expected: no findings. Fix any and re-run (no `# shellcheck disable`
directives).

- [ ] **Step 7: Commit**

```bash
git add bin/lock-fanout tests/lock-fanout.bats
git commit -m "feat: lock-fanout provisions lock-guard on clients via SSH push, no client-side clone required"
```

---

## Self-review checklist

- Spec coverage: checksum check (shasum), conditional push (cat > over
  SSH, chmod +x, mkdir -p for first-time clients), fallback to bare pmset
  on provisioning failure with a `warn=provision-failed` log line — all
  covered by Task 1's tests.
- No placeholders: the implementation and every test are literal, runnable
  code.
- Scope: `bin/lock-guard` itself is unchanged; only the delivery mechanism
  (`bin/lock-fanout`) changes. Matches the repo owner's explicit
  instruction that clients never clone this repo.
- Non-goal check: push-only, lock-triggered, no new persistent client-side
  process, no bidirectional signaling back to the controller beyond the
  existing SSH-exit-code/checksum-response pattern `lock-fanout` already
  relies on for `lock-guard`/`pmset` calls today.
