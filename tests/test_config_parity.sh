#!/bin/bash
###############################################################################
# Static guard against config-rewrite heredocs dropping a parameter.
###############################################################################
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DAEMON="$REPO_ROOT/fan-control.sh"
WORK_DIR=$(mktemp -d)

trap 'rm -rf "$WORK_DIR"' EXIT

fail() {
    printf 'FAIL: %s\n' "$1" >&2
    exit 1
}

assert_eq() {
    local actual="$1"
    local expected="$2"
    local message="$3"

    # Trim whitespace: some wc(1) implementations (e.g. macOS/BSD) pad -l
    # output with leading spaces.
    actual="${actual//[[:space:]]/}"
    expected="${expected//[[:space:]]/}"

    [[ "$actual" == "$expected" ]] || fail "${message}: expected ${expected}, got ${actual}"
}

assert_same_set() {
    local left="$1"
    local right="$2"
    local description="$3"

    if ! cmp -s "$left" "$right"; then
        printf 'FAIL: %s differ\n' "$description" >&2
        diff -u "$left" "$right" >&2 || true
        exit 1
    fi
}

for block in 1 2 3; do
    : >"$WORK_DIR/heredoc-${block}"
done

awk '
    /<<-DEFAULTS/ {
        block = 1
        in_heredoc = 1
        next
    }
    /<<-CONFIG/ {
        block++
        in_heredoc = 1
        next
    }
    in_heredoc && /^(DEFAULTS|CONFIG)$/ {
        in_heredoc = 0
        next
    }
    in_heredoc && /^[A-Z][A-Z0-9_]*=/ {
        parameter = $0
        sub(/=.*/, "", parameter)
        print block, parameter
    }
' "$DAEMON" | while read -r block parameter; do
    printf '%s\n' "$parameter" >>"$WORK_DIR/heredoc-${block}"
done

for block in 1 2 3; do
    sort -u "$WORK_DIR/heredoc-${block}" >"$WORK_DIR/heredoc-${block}.sorted"
done

sed -n 's/^DEFAULT_\([A-Z][A-Z0-9_]*\)=.*/\1/p' "$DAEMON" | sort -u >"$WORK_DIR/defaults.sorted"
sed -n 's/^[[:space:]]*check_param "\([A-Z][A-Z0-9_]*\)".*/\1/p' "$DAEMON" | sort -u >"$WORK_DIR/check-params.sorted"

# The expected count is derived from the DEFAULT_* declarations rather than
# hardcoded, so this guard keeps working as parameters are added/removed -
# what it actually protects against is the three rewrite paths (and the
# check_param self-healing list) silently drifting apart from each other.
expected_count="$(wc -l <"$WORK_DIR/defaults.sorted")"

for block in 1 2 3; do
    assert_eq "$(wc -l <"$WORK_DIR/heredoc-${block}.sorted")" "$expected_count" \
        "heredoc ${block} parameter count"
done

assert_eq "$(wc -l <"$WORK_DIR/check-params.sorted")" "$expected_count" "check_param declaration count"
assert_same_set "$WORK_DIR/heredoc-1.sorted" "$WORK_DIR/heredoc-2.sorted" \
    "initial and migration config parameter sets"
assert_same_set "$WORK_DIR/heredoc-1.sorted" "$WORK_DIR/heredoc-3.sorted" \
    "initial and corrected-values config parameter sets"
assert_same_set "$WORK_DIR/heredoc-1.sorted" "$WORK_DIR/defaults.sorted" \
    "config heredocs and DEFAULT declarations"
assert_same_set "$WORK_DIR/heredoc-1.sorted" "$WORK_DIR/check-params.sorted" \
    "config heredocs and check_param declarations"

printf '✓ All %s config parameters are present in every rewrite path\n' "${expected_count//[[:space:]]/}"
