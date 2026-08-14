#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# bats injects BATS_TEST_DIRNAME; pre-declare for shellcheck SC2154.
: "${BATS_TEST_DIRNAME:=}"

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../bin/lock-fanout"
  TMPDIR="$(mktemp -d)"
  STUB_DIR="$TMPDIR/stub"
  mkdir -p "$STUB_DIR"
  PATH="$STUB_DIR:$PATH"
  export LOCK_SYNC_LIST_CLIENTS="$STUB_DIR/list-clients-stub"
  export LOCK_SYNC_CONFIG="$TMPDIR/no-such-config"
  SSH_LOG="$TMPDIR/ssh.log"
  export SSH_LOG
  export LOCK_SYNC_SSH="$STUB_DIR/ssh"
  # Pin the "local host" identity used by the self-exclusion check to a
  # fixed, non-matching value by default, so existing tests (none of whose
  # client lists are meant to collide with the real test-runner's hostname)
  # don't accidentally skip a host because the CI/dev machine happens to be
  # named the same as a fixture client. Tests targeting self-exclusion
  # override this to a hostname that does match one of their fixture hosts.
  make_hostname_stub "no-such-controller-host"
}

# Stub for hostname -s; echoes the given short name.
make_hostname_stub() {
  local short_name="$1"
  cat >"$STUB_DIR/hostname-stub" <<EOF
#!/bin/bash
echo "$short_name"
EOF
  chmod +x "$STUB_DIR/hostname-stub"
  export LOCK_SYNC_HOSTNAME="$STUB_DIR/hostname-stub"
}

teardown() {
  rm -rf "$TMPDIR"
}

# Stub for list-clients; takes newline-separated host list as first arg.
make_list_clients_stub() {
  local hosts="$1"
  {
    printf '#!/bin/bash\n'
    printf 'cat <<EOF\n'
    printf '%s\n' "$hosts"
    printf 'EOF\n'
  } >"$LOCK_SYNC_LIST_CLIENTS"
  chmod +x "$LOCK_SYNC_LIST_CLIENTS"
}

# Stub for ssh; records EVERY distinct remote command invocation to SSH_LOG
# as "TARGET=<user@host> CMD=<remote command or stdin-marker>", one line per
# ssh call (not just the last, since provisioning now makes multiple calls
# per client). Exits with code from arg-match. By default exits 0; set
# STUB_SSH_FAIL_HOST to have all calls targeting that host exit 255.
# STUB_SSH_CHECKSUM_HOST/STUB_SSH_CHECKSUM_VALUE let a test script a
# specific shasum stdout for a specific host's checksum-check call.
# STUB_SSH_CHECKSUM_ALL_MATCH, when set, answers every host's shasum call
# with the real local lock-guard checksum, so multi-host tests can exercise
# the steady-state "already current, no push" path for every client at once.
# STUB_SSH_CHECKSUM_EXIT_HOST/STUB_SSH_CHECKSUM_EXIT let a test force the
# stub's shasum-call exit code for a specific host, independent of stdout —
# used to simulate the real remote `shasum ... || true` behavior post-fix
# (exit 0, empty stdout, for a missing remote file) as well as the pre-fix
# buggy behavior (exit 1, empty stdout) that this test file's bug-fix test
# reproduces and confirms is no longer what bin/lock-fanout's own remote
# command string produces.
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
    *)
      if [[ -n "$target" ]]; then
        if [[ -n "$remote_cmd" ]]; then
          remote_cmd="$remote_cmd $a"
        else
          remote_cmd="$a"
        fi
      fi
      ;;
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
if [[ -n "${STUB_SSH_CHECKSUM_ALL_MATCH:-}" && "$remote_cmd" == *shasum* ]]; then
  echo "${STUB_SSH_CHECKSUM_ALL_MATCH}  lock-guard"
fi
if [[ -n "${STUB_SSH_CHECKSUM_HOST:-}" && "$target" == *"$STUB_SSH_CHECKSUM_HOST"* && "$remote_cmd" == *shasum* ]]; then
  echo "${STUB_SSH_CHECKSUM_VALUE:-}"
fi
if [[ -n "${STUB_SSH_CHECKSUM_EXIT_HOST:-}" && "$target" == *"$STUB_SSH_CHECKSUM_EXIT_HOST"* && "$remote_cmd" == *shasum* ]]; then
  exit "${STUB_SSH_CHECKSUM_EXIT:-0}"
fi
exit 0
STUBEOF
  chmod +x "$STUB_DIR/ssh"
}

@test "zero clients logs warn=no-clients and exits 0" {
  make_list_clients_stub ""
  make_ssh_stub

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == *"warn=no-clients"* ]]
  [ ! -s "$SSH_LOG" ]
}

@test "three clients all succeed logs three ssh_exit=0 lines in order" {
  make_list_clients_stub "asiago.local
tilsit.local
mimolette.local"
  local_sha=$(shasum -a 256 "$BATS_TEST_DIRNAME/../bin/lock-guard" | awk '{print $1}')
  export STUB_SSH_CHECKSUM_ALL_MATCH="$local_sha"
  make_ssh_stub

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[0]}" == *"client=asiago.local"* ]]
  [[ "${lines[0]}" == *"ssh_exit=0"* ]]
  [[ "${lines[1]}" == *"client=tilsit.local"* ]]
  [[ "${lines[1]}" == *"ssh_exit=0"* ]]
  [[ "${lines[2]}" == *"client=mimolette.local"* ]]
  [[ "${lines[2]}" == *"ssh_exit=0"* ]]
  # Steady state: every checksum already matches, so no push (cat/chmod/mv)
  # should have been attempted for any client — this is the case this test
  # exists to cover, distinct from the dedicated push tests below.
  run grep -q 'CMD=.*cat >' "$SSH_LOG"
  [ "$status" -ne 0 ]
}

@test "one of three ssh failures still exits 0 with mixed log lines" {
  make_list_clients_stub "asiago.local
tilsit.local
mimolette.local"
  export STUB_SSH_FAIL_HOST="tilsit.local"
  make_ssh_stub

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 4 ]
  [[ "${lines[0]}" == *"client=asiago.local"* ]]
  [[ "${lines[0]}" == *"ssh_exit=0"* ]]
  [[ "${lines[1]}" == *"client=tilsit.local"* ]]
  [[ "${lines[1]}" == *"warn=provision-failed"* ]]
  [[ "${lines[2]}" == *"client=tilsit.local"* ]]
  [[ "${lines[2]}" == *"ssh_exit=255"* ]]
  [[ "${lines[3]}" == *"client=mimolette.local"* ]]
  [[ "${lines[3]}" == *"ssh_exit=0"* ]]
}

@test "host with config override uses override user in ssh target" {
  make_list_clients_stub "asiago.local"
  cat >"$TMPDIR/config" <<'EOF'
asiago.local    adminuser
EOF
  export LOCK_SYNC_CONFIG="$TMPDIR/config"
  make_ssh_stub

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'TARGET=adminuser@asiago.local CMD=' "$SSH_LOG"
  [[ "${lines[0]}" == *"user=adminuser"* ]]
}

@test "missing config file uses default USER in ssh target" {
  make_list_clients_stub "asiago.local"
  export USER=localuser
  # LOCK_SYNC_CONFIG already points at nonexistent path from setup
  make_ssh_stub

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'TARGET=localuser@asiago.local CMD=' "$SSH_LOG"
  [[ "${lines[0]}" == *"user=localuser"* ]]
}

@test "list-clients failure logs error and exits 0" {
  cat >"$LOCK_SYNC_LIST_CLIENTS" <<'EOF'
#!/bin/bash
echo "something went wrong" >&2
exit 1
EOF
  chmod +x "$LOCK_SYNC_LIST_CLIENTS"
  make_ssh_stub

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == *"error=list-clients"* ]]
  [[ "${lines[0]}" == *"rc=1"* ]]
  [ ! -s "$SSH_LOG" ]
}

@test "config with comments and blanks parses override correctly" {
  make_list_clients_stub "asiago.local
tilsit.local"
  cat >"$TMPDIR/config" <<'EOF'
# lock-sync config

# <host>        <user>

asiago.local    admin

# tilsit.local  intentionally has no override
EOF
  export LOCK_SYNC_CONFIG="$TMPDIR/config"
  export USER=defaultuser
  make_ssh_stub

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == *"client=asiago.local"* ]]
  [[ "${lines[0]}" == *"user=admin"* ]]
  [[ "${lines[1]}" == *"client=tilsit.local"* ]]
  [[ "${lines[1]}" == *"user=defaultuser"* ]]
  grep -q 'TARGET=admin@asiago.local CMD=' "$SSH_LOG"
  grep -q 'TARGET=defaultuser@tilsit.local CMD=' "$SSH_LOG"
}

@test "LOCK_SYNC_SSH selects the ssh binary, bypassing PATH wrappers" {
  make_list_clients_stub "asiago.local"
  # A distinct ssh stub outside STUB_DIR so PATH lookup cannot find it.
  cat >"$TMPDIR/custom-ssh" <<EOF
#!/bin/bash
printf 'custom ssh ran\n' >"$TMPDIR/custom-ssh.marker"
exit 0
EOF
  chmod +x "$TMPDIR/custom-ssh"
  export LOCK_SYNC_SSH="$TMPDIR/custom-ssh"

  # A PATH-located ssh stub that should NOT be invoked.
  make_ssh_stub

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ -f "$TMPDIR/custom-ssh.marker" ]
  [ ! -s "$SSH_LOG" ]
}

@test "remote command is lock-guard's absolute path, not a bare pmset call" {
  make_list_clients_stub "asiago.local"
  local_sha=$(shasum -a 256 "$BATS_TEST_DIRNAME/../bin/lock-guard" | awk '{print $1}')
  export STUB_SSH_CHECKSUM_HOST="asiago.local"
  export STUB_SSH_CHECKSUM_VALUE="$local_sha  lock-guard"
  make_ssh_stub

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  grep -q 'CMD=\$HOME/.local/bin/lock-guard' "$SSH_LOG"
}

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
  grep -q "TARGET=.*asiago.local CMD=.*mv -f" "$SSH_LOG"

  # Verify the push actually carried lock-guard's real content, not just a
  # cat>-shaped command. The ssh stub captures stdin verbatim (embedded
  # newlines and all) after a "STDIN=" marker, so the distinctive string
  # lands on its own line within the captured block rather than on the
  # "STDIN=" line itself — confirm the marker is present, then confirm a
  # string that's only in bin/lock-guard shows up somewhere after it.
  grep -q 'STDIN=' "$SSH_LOG"
  awk '/STDIN=/{found=1} found' "$SSH_LOG" | grep -q 'action=suppress'
}

@test "provisioning: brand-new client with no remote lock-guard gets provisioned (push, not pmset fallback)" {
  # Reproduces the exact bug scenario: a genuinely new client's remote
  # `shasum ~/.local/bin/lock-guard` finds no file. Post-fix, bin/lock-fanout's
  # own remote command string ends in `|| true`, so a real client's ssh call
  # would exit 0 with empty stdout in this situation — simulate exactly that
  # via the stub (exit 0, no STUB_SSH_CHECKSUM_VALUE set, so stdout is empty)
  # and confirm the client gets provisioned rather than falling back to pmset.
  make_list_clients_stub "asiago.local"
  export STUB_SSH_CHECKSUM_EXIT_HOST="asiago.local"
  export STUB_SSH_CHECKSUM_EXIT=0
  make_ssh_stub

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" != *"warn=provision-failed"* ]]
  grep -q 'TARGET=.*asiago.local CMD=.*shasum' "$SSH_LOG"
  grep -q 'TARGET=.*asiago.local CMD=.*cat >' "$SSH_LOG"
  grep -q "TARGET=.*asiago.local CMD=.*chmod +x" "$SSH_LOG"
  grep -q "TARGET=.*asiago.local CMD=.*mv -f" "$SSH_LOG"

  run grep -q 'CMD=.*pmset displaysleepnow' "$SSH_LOG"
  [ "$status" -ne 0 ]
}

@test "provisioning: pre-fix buggy behavior (remote shasum exit 1) correctly falls back to pmset" {
  # Documents the OLD buggy remote command's behavior for contrast: if the
  # remote checksum call exits 1 (as bin/lock-fanout's remote command did
  # before the `|| true` fix, for a missing file), provision_host cannot
  # distinguish that from a genuine ssh failure and correctly returns 1 —
  # this is why the fix had to change the remote command itself rather than
  # provision_host's exit-code handling.
  make_list_clients_stub "asiago.local"
  export STUB_SSH_CHECKSUM_EXIT_HOST="asiago.local"
  export STUB_SSH_CHECKSUM_EXIT=1
  make_ssh_stub

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"warn=provision-failed"* ]]
  grep -q 'TARGET=.*asiago.local CMD=.*pmset displaysleepnow' "$SSH_LOG"

  run grep -q 'CMD=.*cat >' "$SSH_LOG"
  [ "$status" -ne 0 ]
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
  [[ "${lines[0]}" == *"client=asiago.local"* ]]
  [[ "${lines[0]}" == *"warn=provision-failed"* ]]

  run grep -q 'CMD=.*\$HOME/.local/bin/lock-guard' "$SSH_LOG"
  [ "$status" -ne 0 ]
}

@test "missing local lock-guard fails provisioning fast and falls back to pmset, without any ssh call" {
  # local_lock_guard is derived from the script's own directory
  # ($script_dir/lock-guard, via BASH_SOURCE), so to exercise the
  # missing-file guard we run a copy of lock-fanout from an isolated bin/
  # fixture dir that deliberately omits lock-guard, rather than touching
  # the real bin/lock-guard in this repo.
  FIXTURE_BIN="$TMPDIR/fixture-bin"
  mkdir -p "$FIXTURE_BIN"
  cp "$BATS_TEST_DIRNAME/../bin/lock-fanout" "$FIXTURE_BIN/lock-fanout"
  # No lock-guard copied into $FIXTURE_BIN — that's the point of this test.

  make_list_clients_stub "asiago.local"
  make_ssh_stub

  run "$FIXTURE_BIN/lock-fanout"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"client=asiago.local"* ]]
  [[ "${lines[0]}" == *"warn=provision-failed"* ]]

  # No shasum/cat/chmod ssh calls should have been attempted at all — the
  # guard must return before any ssh invocation, not just before the push.
  run grep -q 'CMD=.*shasum' "$SSH_LOG"
  [ "$status" -ne 0 ]
  grep -q 'TARGET=.*asiago.local CMD=.*pmset displaysleepnow' "$SSH_LOG"
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

# --- Issue #27: self-exclusion ---

@test "self-exclusion: client list including the local hostname is filtered out of fan-out, others unaffected" {
  make_list_clients_stub "asiago.local
tilsit.local
mimolette.local"
  make_hostname_stub "asiago"
  local_sha=$(shasum -a 256 "$BATS_TEST_DIRNAME/../bin/lock-guard" | awk '{print $1}')
  export STUB_SSH_CHECKSUM_ALL_MATCH="$local_sha"
  make_ssh_stub

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [[ "${lines[0]}" == *"client=asiago.local"* ]]
  [[ "${lines[0]}" == *"warn=skip-self"* ]]
  [[ "${lines[1]}" == *"client=tilsit.local"* ]]
  [[ "${lines[1]}" == *"ssh_exit=0"* ]]
  [[ "${lines[2]}" == *"client=mimolette.local"* ]]
  [[ "${lines[2]}" == *"ssh_exit=0"* ]]

  # No ssh call should ever target asiago.local — the skip happens before
  # any ssh invocation, not just before the final lock-guard call.
  run grep -q 'TARGET=.*asiago.local' "$SSH_LOG"
  [ "$status" -ne 0 ]
  grep -q 'TARGET=.*tilsit.local' "$SSH_LOG"
  grep -q 'TARGET=.*mimolette.local' "$SSH_LOG"
}

@test "self-exclusion: hostname comparison is case-insensitive" {
  make_list_clients_stub "asiago.local"
  make_hostname_stub "ASIAGO"
  make_ssh_stub

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [[ "${lines[0]}" == *"client=asiago.local"* ]]
  [[ "${lines[0]}" == *"warn=skip-self"* ]]
  [ ! -s "$SSH_LOG" ]
}

@test "self-exclusion: no client matches local hostname, all clients proceed normally" {
  make_list_clients_stub "tilsit.local
mimolette.local"
  make_hostname_stub "asiago"
  local_sha=$(shasum -a 256 "$BATS_TEST_DIRNAME/../bin/lock-guard" | awk '{print $1}')
  export STUB_SSH_CHECKSUM_ALL_MATCH="$local_sha"
  make_ssh_stub

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [[ "${lines[0]}" == *"client=tilsit.local"* ]]
  [[ "${lines[0]}" == *"ssh_exit=0"* ]]
  [[ "${lines[1]}" == *"client=mimolette.local"* ]]
  [[ "${lines[1]}" == *"ssh_exit=0"* ]]

  run grep -q 'warn=skip-self' <<<"$output"
  [ "$status" -ne 0 ]
}

# --- Issue #28: ssh stub multi-arg remote-command capture ---

@test "ssh stub regression: multiple trailing positional args after user@host are all captured, not just the last" {
  make_ssh_stub
  "$STUB_DIR/ssh" -o BatchMode=yes user@host.local "pmset" "displaysleepnow" "extra-arg" >/dev/null
  grep -q 'TARGET=user@host.local CMD=pmset displaysleepnow extra-arg' "$SSH_LOG"
}

# --- Issue #29: provision-failed reason distinction ---

@test "provision-failed reason: ssh failure during checksum check logs reason=ssh-failed and the ssh exit code" {
  make_list_clients_stub "asiago.local"
  export STUB_SSH_FAIL_HOST="asiago.local"
  make_ssh_stub

  run "$SCRIPT"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"client=asiago.local"* ]]
  [[ "${lines[0]}" == *"warn=provision-failed"* ]]
  [[ "${lines[0]}" == *"reason=ssh-failed"* ]]
  [[ "${lines[0]}" == *"ssh_exit=255"* ]]
}

@test "provision-failed reason: missing local lock-guard logs reason=missing-local-lock-guard with no ssh_exit field" {
  FIXTURE_BIN="$TMPDIR/fixture-bin"
  mkdir -p "$FIXTURE_BIN"
  cp "$BATS_TEST_DIRNAME/../bin/lock-fanout" "$FIXTURE_BIN/lock-fanout"
  # No lock-guard copied into $FIXTURE_BIN — that's the point of this test.

  make_list_clients_stub "asiago.local"
  make_ssh_stub

  run "$FIXTURE_BIN/lock-fanout"
  [ "$status" -eq 0 ]
  [[ "${lines[0]}" == *"client=asiago.local"* ]]
  [[ "${lines[0]}" == *"warn=provision-failed"* ]]
  [[ "${lines[0]}" == *"reason=missing-local-lock-guard"* ]]
  # No ssh_exit field on the provision-failed line itself: no ssh call ever
  # happened for the checksum/push step in this guard-clause case, so there
  # is no real ssh exit code to report here (distinct from the fallback
  # pmset line immediately after, which does have its own ssh_exit=).
  [[ "${lines[0]}" != *"ssh_exit="* ]]
}
