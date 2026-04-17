# Slice (a) — `list-clients` design

Date: 2026-04-17
Status: approved, ready to implement

## Purpose

First implementation slice of lock-sync. A pure parser: read a Synergy
`synergy.conf`, emit the hostnames of every screen in `section: screens`,
transformed into `.local` form suitable for SSH.

No side effects beyond printing. No network. No dependency on the rest of the
tool. Trivially testable.

## Contract

**File:** `bin/list-clients`

**Usage:**

```text
bin/list-clients [path]
```

- No arg → reads `~/Library/Preferences/Synergy/synergy.conf`.
- Arg → reads that file (used by tests and debugging).

**Output (stdout):** one hostname per line, `<short>.local`, in the order they
appear in the `section: screens` block. Empty screens section → zero lines on
stdout and exit 0.

```text
asiago.local
tilsit.local
mimolette.local
```

**Exit codes:**

- `0` — success, list printed (list may be empty).
- `1` — conf file not found or not readable.
- `2` — malformed conf (`section: screens` not closed with `end`).

**stderr:** only error messages. Silent on success.

**Self-inclusion:** the script does NOT filter the current host out. Consumer
(slice (c)) pays for the harmless `ssh self pmset displaysleepnow` no-op
rather than slice (a) needing to know which machine is "self".

**Name-suffix rule:** names matching `<name>-<8 hex chars>$` have the suffix
stripped, then `.local` is appended. Names that do NOT match the pattern are
passed through unchanged with `.local` appended.

## Implementation

Bash wrapper for `[[ -r ]]` guard, awk for parsing.

```bash
#!/usr/bin/env bash
set -euo pipefail

conf="${1:-$HOME/Library/Preferences/Synergy/synergy.conf}"

if [[ ! -r "$conf" ]]; then
  printf 'list-clients: cannot read %s\n' "$conf" >&2
  exit 1
fi

awk '
  /^section: screens[[:space:]]*$/ { in_screens = 1; next }
  in_screens && /^end[[:space:]]*$/ { in_screens = 0; next }
  in_screens && /^\t[^ \t].*:[[:space:]]*$/ {
    name = $0
    sub(/^\t/, "", name)
    sub(/:[[:space:]]*$/, "", name)
    sub(/-[0-9a-fA-F]{8}$/, "", name)
    print name ".local"
  }
  END {
    if (in_screens) {
      print "list-clients: section: screens not closed" > "/dev/stderr"
      exit 2
    }
  }
' "$conf"
```

### Why this shape

- **awk over sed/grep pipelines:** state ("am I inside `section: screens`?")
  is natural in awk, ugly in sed.
- **`in_screens` guard:** prevents collisions with `section: links`, which
  also contains lines like `asiago-995cd2f5:` (link sources).
- **One-tab discrimination (`^\t[^ \t]`):** screen headers are indented one
  tab; properties under each screen are two tabs. Guarantees property lines
  cannot masquerade as screen headers.
- **Suffix strip is defensive:** the `-[0-9a-fA-F]{8}$` anchor matches the
  Synergy-generated ID at end-of-line only. Names without the suffix pass
  through unchanged.
- **`end` matcher tolerates trailing whitespace** (`[[:space:]]*$`) because
  Synergy's writer sometimes emits stray spaces.
- **Unterminated `section: screens` → exit 2** via the `END` block.

### Deliberately NOT handled (YAGNI)

- Comments (Synergy's format does not define them).
- Multiple `section: screens` blocks (not a real-world case).
- Reading from stdin (`-` arg).

## Tests

**Framework:** bats-core. Install locally with `brew install bats-core`;
CI installs via `apt-get`.

**Layout:**

```text
tests/
  list-clients.bats
  fixtures/
    synergy.conf          # one realistic multi-section sample
```

Test #1 uses the fixture file. Tests #2–#13 use inline heredocs for
self-documenting specs.

### Cases

Happy paths:

1. Three-screen realistic fixture → three `.local` hostnames, order preserved.
2. Single screen → one line.
3. Empty `section: screens` → empty output, exit 0.
4. Screen without `-<8hex>` suffix → passed through, `.local` appended.
5. Mixed suffix / no-suffix screens → each transformed correctly.
6. Trailing whitespace on `end` or screen header lines → still parsed.
7. Uppercase hex suffix (`-ABCDEF12`) → stripped.

Negative / anti-regression:

1. Internal hyphens (`my-mac-001`) → NOT stripped.
2. Entries in `section: links` matching the screen-header pattern → NOT emitted.
3. `section: options` entries with colons (e.g., `keystroke(F5) = ...`) → NOT emitted.
4. Double-tabbed property lines → NOT emitted.
5. Missing file → exit 1, stderr non-empty, stdout empty.
6. `section: screens` with no `end` before EOF → exit 2, stderr mentions "not closed".

## CI integration

Add a second job to `.github/workflows/ci.yml`. Install bats-core from source
into `$HOME/.local` (pinned tag), avoiding `npm install -g` which hits EACCES
on the GitHub-hosted runner and avoiding apt's older version:

```yaml
bats:
  runs-on: ubuntu-latest
  steps:
    - uses: actions/checkout@v4
    - name: Install and run bats
      run: |
        git clone --depth 1 --branch v1.10.0 https://github.com/bats-core/bats-core.git /tmp/bats
        /tmp/bats/install.sh "$HOME/.local"
        export PATH="$HOME/.local/bin:$PATH"
        bats tests/
```

## Implementation order (TDD)

1. Write all 13 bats tests.
2. Run `bats tests/` — confirm all 13 fail for the expected reason
   (script missing / wrong output).
3. Write `bin/list-clients`.
4. Run `bats tests/` — confirm all 13 green.
5. Update CLAUDE.md "Current state" paragraph (fold in, no separate commit).
6. Add bats job to `.github/workflows/ci.yml`.
7. Commit, push, PR.
