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
