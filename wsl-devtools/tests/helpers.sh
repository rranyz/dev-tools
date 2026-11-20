# shellcheck shell=bash
# tests/helpers.sh: small assertion helpers shared by the test scripts.
#
# Source it from a test script. It creates TMP_DIR and removes it on exit.

PASSED=0
FAILED=0
SKIPPED=0
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

pass() { PASSED=$((PASSED + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '  FAIL  %s\n' "$1"; }
skip() { SKIPPED=$((SKIPPED + 1)); printf '  skip  %s\n' "$1"; }

# assert_ok "description" command args...    the command must succeed
assert_ok() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then pass "$description"; else fail "$description"; fi
}

# assert_fail "description" command args...  the command must fail
assert_fail() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then fail "$description"; else pass "$description"; fi
}

# assert_equals "description" expected actual
assert_equals() {
    if [[ "$2" == "$3" ]]; then
        pass "$1"
    else
        fail "$1 (expected '$2', got '$3')"
    fi
}

# Print the summary; returns non-zero when any test failed.
finish() {
    echo
    echo "Passed: ${PASSED}  Failed: ${FAILED}  Skipped: ${SKIPPED}"
    (( FAILED == 0 ))
}
