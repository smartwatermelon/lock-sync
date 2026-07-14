# `list-clients` db.json hostname resolution

Date: 2026-07-14
Status: approved, ready to implement

## Purpose

Fix a client that fails to lock because its derived hostname is wrong.

A Mac whose real `.local` name is `arich-mac.local` shows up in `synergy.conf`
as the screen `arichmac-3181d4b4` — Synergy dropped the internal hyphen when it
generated the screen name. `list-clients` strips the `-3181d4b4` instance
suffix and emits `arichmac.local`, which does not resolve. SSH to it fails, so
the machine never locks.

## Root cause (what is NOT the bug)

The suffix-strip regex `-[0-9a-fA-F]{8}$` in `bin/list-clients` is **not**
responsible. It only removes a trailing hyphen plus exactly eight hex
characters. A bare `arich-mac` does not match it (`-mac` is three characters
and `m` is not hex), so the regex cannot turn `arich-mac` into `arichmac`.

The hyphen is gone before `list-clients` ever runs. Synergy sanitizes the
host's name into a screen identifier and writes the hyphenless form to
`synergy.conf`. The information needed to reverse that — the real display name
— is not in `synergy.conf`. It lives in a sibling file, `db.json`:

```json
{
  "id": "c62aa4f29f078b74d81a30b352495a06a68b16f85a98ec7247c51f033181d4b4",
  "name": "arich-mac",
  "hostname": "arich-mac"
}
```

The last eight hex characters of `id` (`3181d4b4`) equal the suffix Synergy
appends to the screen name (`arichmac-3181d4b4`). That is the join key.

### Why `name`, not `hostname`

`db.json` carries both `name` (the user-facing display name) and `hostname`
(macOS's default network name). They diverge. On the current machine:

| conf suffix | db `name` | db `hostname`          | today's output |
| ----------- | --------- | ---------------------- | -------------- |
| 995cd2f5    | asiago    | ASIAGO.local           | asiago.local   |
| 7681d488    | MIMOLETTE | Andrews-Mac-mini.local | mimolette.local|
| cb476f5e    | TILSIT    | TILSIT                 | tilsit.local   |
| 3181d4b4    | arich-mac | arich-mac              | arichmac.local |

`mimolette` is a working client today at `mimolette.local`. Its `hostname`
field is `Andrews-Mac-mini.local` — resolving by `hostname` would break it.
Resolving by `name` reproduces every current output (case aside, and `.local`
resolution is case-insensitive) and additionally fixes `arich-mac`.

## Contract changes

`bin/list-clients` gains one input and no new output shape.

- **New input:** `db.json`, located at `${LOCK_SYNC_DB:-<dir of conf>/db.json}`.
  The `LOCK_SYNC_DB` override mirrors the existing `LOCK_SYNC_CONFIG` pattern
  and keeps tests isolated.
- **Output:** unchanged — one `<host>.local` per line, in `section: screens`
  order. Exit codes unchanged (`0` ok, `1` conf unreadable, `2` conf malformed).

`synergy.conf` remains the source of truth for *which* hosts to lock. `db.json`
only refines *what each host is named*.

## Resolution algorithm

1. Build a suffix→name map, once, only when `jq` is on PATH **and** `db.json`
   is readable:

   ```bash
   jq -r '.data[]? | select(.id and .name) | "\(.id[-8:])\t\(.name)"' "$db"
   ```

   Load into `declare -A dbname`. If `jq` is absent, `db.json` is missing, or
   `jq` exits non-zero (malformed JSON), the map stays empty.

2. The awk stage keeps its section parsing (including the "screens not closed"
   → exit 2 guard) but emits the **raw** screen label, e.g. `arichmac-3181d4b4`.

3. Bash resolves each label:
   - If it ends in `-<8 hex>` and that suffix is a key in `dbname`, use
     `dbname[suffix]`, lowercased.
   - Otherwise strip a trailing `-<8 hex>` (today's heuristic) and keep the rest.
   - Append `.local` unless the name already ends in `.local`.

Result: `arichmac-3181d4b4` → `arich-mac` → `arich-mac.local`. When no `db.json`
sits beside the conf, every screen takes the heuristic path — identical to
today.

## Why this shape

- **Fallback, never regression:** the resolver degrades to the current
  behavior when jq or `db.json` is unavailable, so machines without jq (or an
  older Synergy without `db.json`) are no worse off than today.
- **`jq` over hand-rolled JSON parsing:** `db.json` is minified; extracting
  fields with awk/grep is fragile against reordering. jq is already installed
  on the server Mac; `bin/install` should note it as a soft dependency.
- **Map built once, not per screen:** one `jq` invocation, then O(1) lookups.
- **Suffix as key:** the eight-hex tail is a truncated sha256; a collision is
  astronomically unlikely. First match wins; not worth guarding.

## Deliberately NOT handled (YAGNI)

- Resolving by `hostname` (breaks `mimolette`; see above).
- Mocking `jq` absence in tests — gated on `command -v jq`, so its absence is
  just the empty-map branch. Documented, not simulated.
- Rewriting hostnames via the per-client override config — that file maps
  `<host> <user>` and is the wrong layer for name repair.

## Tests

`tests/list-clients.bats`, same tmpdir pattern (write `conf` + sibling
`db.json`, run, assert).

Happy paths:

1. `db.json` maps a hyphenless screen back to its display name
   (`arichmac-3181d4b4` → `arich-mac.local`). Regression test for this bug.
2. db `name` wins over the stripped conf label.
3. Case normalization (`MIMOLETTE` → `mimolette.local`).
4. Multiple screens, mixed — each resolved from db.

Fallback / anti-regression:

5. Suffix present in conf but absent from `db.json` → heuristic for that screen,
   others still resolved from db.
6. `db.json` present but malformed (jq errors) → whole run falls back, exit 0.
7. No `db.json` sibling → heuristic. Already covered by the existing fixture
   tests, which must stay green **unmodified** — the real proof of
   non-regression.

## CI

The new tests need `jq`. GitHub-hosted `ubuntu-latest` ships jq, so no workflow
change is required; confirm during verification. If a future runner lacks it,
the tests that assert db resolution would fail (not fall back silently), which
is the desired signal.

## Implementation order (TDD)

1. Add the new bats tests.
2. Run `bats tests/` — confirm the new tests fail, existing ones pass.
3. Implement the resolver in `bin/list-clients`.
4. Run `bats tests/` — all green.
5. `shellcheck -S info bin/*` clean.
6. Run against the real conf — confirm `arich-mac.local`.
7. Update `CLAUDE.md` (db.json is now a key external input; note jq soft dep).
8. Commit, push, PR.
