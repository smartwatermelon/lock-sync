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

# --- db.json display-name resolution -------------------------------------
# Synergy strips characters (e.g. hyphens) out of the screen name it writes to
# synergy.conf, so the conf alone cannot reproduce the real .local hostname.
# The real display name lives in the sibling db.json, joinable on the last 8
# hex of its `id` field. These tests cover that resolution and its fallback.
# db.json is read from <dir of conf>/db.json, overridable via LOCK_SYNC_DB.

@test "db.json resolves a hyphenless screen back to its display name" {
  # Regression: Synergy wrote 'arichmac-3181d4b4'; the real host is arich-mac.
  conf="$TMPDIR/conf"
  cat >"$conf" <<'EOF'
section: screens
	arichmac-3181d4b4:
		alt = alt
end
EOF
  cat >"$TMPDIR/db.json" <<'EOF'
{"version":1,"data":{"computers":[
  {"id":"c62aa4f29f078b74d81a30b352495a06a68b16f85a98ec7247c51f033181d4b4",
   "name":"arich-mac","hostname":"arich-mac"}
]}}
EOF
  run "$SCRIPT" "$conf"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "arich-mac.local" ]
}

@test "db.json name wins over the suffix-stripped conf label" {
  # Heuristic alone would yield 'foobar'; db.json says the name is foo-bar-baz.
  conf="$TMPDIR/conf"
  cat >"$conf" <<'EOF'
section: screens
	foobar-aabbccdd:
		alt = alt
end
EOF
  cat >"$TMPDIR/db.json" <<'EOF'
{"version":1,"data":{"computers":[
  {"id":"deadbeefaabbccdd","name":"foo-bar-baz","hostname":"whatever"}
]}}
EOF
  run "$SCRIPT" "$conf"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "foo-bar-baz.local" ]
}

@test "db.json display names are lowercased" {
  conf="$TMPDIR/conf"
  cat >"$conf" <<'EOF'
section: screens
	node-11223344:
		alt = alt
end
EOF
  cat >"$TMPDIR/db.json" <<'EOF'
{"version":1,"data":{"computers":[
  {"id":"feed11223344","name":"Big-NODE","hostname":"Big-NODE"}
]}}
EOF
  run "$SCRIPT" "$conf"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "big-node.local" ]
}

@test "multiple screens each resolve from db.json in conf order" {
  conf="$TMPDIR/conf"
  cat >"$conf" <<'EOF'
section: screens
	arichmac-3181d4b4:
		alt = alt
	otherbox-99887766:
		alt = alt
end
EOF
  cat >"$TMPDIR/db.json" <<'EOF'
{"version":1,"data":{"computers":[
  {"id":"aaaa3181d4b4","name":"arich-mac","hostname":"arich-mac"},
  {"id":"bbbb99887766","name":"other-box","hostname":"other-box"}
]}}
EOF
  run "$SCRIPT" "$conf"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "arich-mac.local" ]
  [ "${lines[1]}" = "other-box.local" ]
}

@test "screen whose suffix is absent from db.json falls back to the heuristic" {
  conf="$TMPDIR/conf"
  cat >"$conf" <<'EOF'
section: screens
	arichmac-3181d4b4:
		alt = alt
	stale-12345678:
		alt = alt
end
EOF
  # db.json knows arichmac but not the stale screen.
  cat >"$TMPDIR/db.json" <<'EOF'
{"version":1,"data":{"computers":[
  {"id":"aaaa3181d4b4","name":"arich-mac","hostname":"arich-mac"}
]}}
EOF
  run "$SCRIPT" "$conf"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 2 ]
  [ "${lines[0]}" = "arich-mac.local" ]
  [ "${lines[1]}" = "stale.local" ]
}

@test "malformed db.json falls back to the heuristic with exit 0" {
  conf="$TMPDIR/conf"
  cat >"$conf" <<'EOF'
section: screens
	arichmac-3181d4b4:
		alt = alt
end
EOF
  printf 'not json {{{\n' >"$TMPDIR/db.json"
  run "$SCRIPT" "$conf"
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 1 ]
  [ "${lines[0]}" = "arichmac.local" ]
}

@test "LOCK_SYNC_DB overrides the db.json location" {
  conf="$TMPDIR/conf"
  cat >"$conf" <<'EOF'
section: screens
	arichmac-3181d4b4:
		alt = alt
end
EOF
  db="$TMPDIR/elsewhere/db.json"
  mkdir -p "$TMPDIR/elsewhere"
  cat >"$db" <<'EOF'
{"version":1,"data":{"computers":[
  {"id":"aaaa3181d4b4","name":"arich-mac","hostname":"arich-mac"}
]}}
EOF
  run env LOCK_SYNC_DB="$db" "$SCRIPT" "$conf"
  [ "$status" -eq 0 ]
  [ "${lines[0]}" = "arich-mac.local" ]
}
