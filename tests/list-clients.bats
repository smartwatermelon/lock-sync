#!/usr/bin/env bats

bats_require_minimum_version 1.5.0

# bats injects BATS_TEST_DIRNAME; pre-declare for shellcheck SC2154.
: "${BATS_TEST_DIRNAME:=}"

setup() {
  SCRIPT="$BATS_TEST_DIRNAME/../bin/list-clients"
  FIXTURES="$BATS_TEST_DIRNAME/fixtures"
  TMPDIR="$(mktemp -d)"
}

teardown() {
  rm -rf "$TMPDIR"
}

@test "three-screen fixture emits short .local hostnames in conf order" {
  run "$SCRIPT" "$FIXTURES/synergy.conf"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = "brie.local" ]
  [ "${lines[1]}" = "camembert.local" ]
  [ "${lines[2]}" = "roquefort.local" ]
}

@test "single screen emits one line" {
  conf="$TMPDIR/conf"
  cat >"$conf" <<'EOF'
section: screens
	solo-12345678:
		alt = alt
end
EOF
  run "$SCRIPT" "$conf"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "solo.local" ]
}

@test "empty screens section emits nothing with exit 0" {
  conf="$TMPDIR/conf"
  cat >"$conf" <<'EOF'
section: screens
end
EOF
  run "$SCRIPT" "$conf"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "screen without hex suffix passes through with .local appended" {
  conf="$TMPDIR/conf"
  cat >"$conf" <<'EOF'
section: screens
	myscreen:
		alt = alt
end
EOF
  run "$SCRIPT" "$conf"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "myscreen.local" ]
}

@test "mixed suffix and no-suffix screens transform independently" {
  conf="$TMPDIR/conf"
  cat >"$conf" <<'EOF'
section: screens
	withsuffix-12345678:
		alt = alt
	nosuffix:
		alt = alt
end
EOF
  run "$SCRIPT" "$conf"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "withsuffix.local" ]
  [ "${lines[1]}" = "nosuffix.local" ]
}

@test "trailing whitespace tolerated on end and screen-header lines" {
  conf="$TMPDIR/conf"
  printf 'section: screens\n\tfoo-12345678:   \n\t\talt = alt\nend  \n' >"$conf"
  run "$SCRIPT" "$conf"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "foo.local" ]
}

@test "uppercase hex suffix stripped" {
  conf="$TMPDIR/conf"
  cat >"$conf" <<'EOF'
section: screens
	upper-ABCDEF12:
		alt = alt
end
EOF
  run "$SCRIPT" "$conf"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "upper.local" ]
}

@test "internal hyphens not followed by 8-hex suffix are preserved" {
  conf="$TMPDIR/conf"
  cat >"$conf" <<'EOF'
section: screens
	my-mac-001:
		alt = alt
end
EOF
  run "$SCRIPT" "$conf"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "my-mac-001.local" ]
}

@test "entries in section: links are not emitted" {
  conf="$TMPDIR/conf"
  cat >"$conf" <<'EOF'
section: screens
	real-12345678:
		alt = alt
end

section: links
	fake-87654321:
		up(0,100) = other-11223344(0,100)
end
EOF
  run "$SCRIPT" "$conf"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "real.local" ]
}

@test "screen-header-shaped lines in section: options are not emitted" {
  conf="$TMPDIR/conf"
  cat >"$conf" <<'EOF'
section: screens
	real-12345678:
		alt = alt
end

section: options
	faketrigger:
		heartbeat = 5000
end
EOF
  run "$SCRIPT" "$conf"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "real.local" ]
}

@test "double-tabbed property lines inside a screen are not emitted" {
  conf="$TMPDIR/conf"
  cat >"$conf" <<'EOF'
section: screens
	real-12345678:
		fakename:
		alt = alt
end
EOF
  run "$SCRIPT" "$conf"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "real.local" ]
}

@test "missing file exits 1 with error on stderr and no stdout" {
  run --separate-stderr "$SCRIPT" "$TMPDIR/does-not-exist.conf"
  [ "$status" -eq 1 ]
  [ -z "$stdout" ]
  [[ "$stderr" == *"does-not-exist.conf"* ]]
}

@test "unterminated section: screens exits 2 with error on stderr and no stdout" {
  conf="$TMPDIR/conf"
  cat >"$conf" <<'EOF'
section: screens
	real-12345678:
		alt = alt
EOF
  run --separate-stderr "$SCRIPT" "$conf"
  [ "$status" -eq 2 ]
  [ -z "$stdout" ]
  [[ "$stderr" == *"not closed"* ]]
}
