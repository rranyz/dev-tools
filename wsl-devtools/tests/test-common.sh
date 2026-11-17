#!/usr/bin/env bash
# tests/test-common.sh: tests for lib/common.sh.
#
# Makes no system changes: it only creates and removes a temporary directory.
# Usage: bash tests/test-common.sh
# Exit status: 0 if all tests pass, 1 otherwise.

# No "set -e" here: every assertion should run even after a failure.
set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
TMP_DIR="$(mktemp -d)"
trap 'rm -rf "${TMP_DIR}"' EXIT

# shellcheck source=../lib/common.sh
source "${PROJECT_ROOT}/lib/common.sh"

PASSED=0
FAILED=0

pass() { PASSED=$((PASSED + 1)); printf '  ok    %s\n' "$1"; }
fail() { FAILED=$((FAILED + 1)); printf '  FAIL  %s\n' "$1"; }

# assert_ok "description" command args...   -> command must succeed
assert_ok() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then pass "$description"; else fail "$description"; fi
}

# assert_fail "description" command args... -> command must fail
assert_fail() {
    local description="$1"
    shift
    if "$@" >/dev/null 2>&1; then fail "$description"; else pass "$description"; fi
}

# Write a temporary config file with the given lines.
make_config() {
    local file="${TMP_DIR}/$1"
    shift
    printf '%s\n' "$@" >"$file"
    printf '%s' "$file"
}

echo "Validation"
assert_ok   "is_integer 42"                    is_integer 42
assert_fail "is_integer empty"                 is_integer ""
assert_fail "is_integer -1"                    is_integer -1
assert_fail "is_integer 4a"                    is_integer 4a
assert_ok   "is_valid_port 80"                 is_valid_port 80
assert_ok   "is_valid_port 65535"              is_valid_port 65535
assert_fail "is_valid_port 0"                  is_valid_port 0
assert_fail "is_valid_port 65536"              is_valid_port 65536
assert_fail "is_valid_port 123456"             is_valid_port 123456
assert_fail "is_valid_port abc"                is_valid_port abc
assert_ok   "is_valid_version 8.4"             is_valid_version 8.4
assert_fail "is_valid_version 8"               is_valid_version 8
assert_fail "is_valid_version 8.4.1"           is_valid_version 8.4.1
assert_fail "is_valid_version 8.x"             is_valid_version 8.x
assert_ok   "is_valid_domain myapp.test"       is_valid_domain myapp.test
assert_ok   "is_valid_domain api.myapp.test"   is_valid_domain api.myapp.test
assert_fail "is_valid_domain localhost"        is_valid_domain localhost
assert_fail "is_valid_domain MyApp.test"       is_valid_domain MyApp.test
assert_fail "is_valid_domain -bad.test"        is_valid_domain -bad.test
assert_fail "is_valid_domain bad_name.test"    is_valid_domain bad_name.test
assert_fail "is_valid_domain a..test"          is_valid_domain a..test
assert_fail "is_valid_domain 'a.test; rm'"     is_valid_domain "a.test; rm"
assert_ok   "is_one_of b a b c"                is_one_of b a b c
assert_fail "is_one_of d a b c"                is_one_of d a b c
assert_fail "is_supported_php_version before config is loaded" is_supported_php_version 8.4

echo "Command checks"
assert_ok   "command_exists bash"              command_exists bash
assert_fail "command_exists missing command"   command_exists wsl-devtools-no-such-command
assert_ok   "require_commands bash cat"        require_commands bash cat
assert_fail "require_commands with a missing command" require_commands bash wsl-devtools-no-such-command

echo "Configuration"
assert_ok   "load_config versions.conf"        load_config "${CONFIG_DIR}/versions.conf"
assert_ok   "load_config packages.conf"        load_config "${CONFIG_DIR}/packages.conf"
assert_ok   "NVM_VERSION is set"               test -n "${NVM_VERSION:-}"
assert_ok   "BASE_PACKAGES is set"             test -n "${BASE_PACKAGES:-}"
assert_ok   "is_supported_php_version 8.4"     is_supported_php_version 8.4
assert_ok   "is_supported_php_version 7.4"     is_supported_php_version 7.4
assert_fail "is_supported_php_version 8.2"     is_supported_php_version 8.2
assert_fail "load_config missing file"         load_config "${TMP_DIR}/missing.conf"
assert_fail "load_config without argument"     load_config

good_config="$(make_config good.conf '# comment' '' 'GOOD_VALUE="hello world"')"
assert_ok   "load_config accepts comments, blanks, assignments" load_config "$good_config"
assert_ok   "loaded value is correct"          test "${GOOD_VALUE:-}" = "hello world"

# These files must be refused before anything in them runs; the marker files prove it.
# shellcheck disable=SC2016  # the $ and backticks must stay literal
subst_config="$(make_config subst.conf "BAD=\"\$(touch ${TMP_DIR}/ran-subst)\"")"
# shellcheck disable=SC2016
backtick_config="$(make_config backtick.conf "BAD=\"\`touch ${TMP_DIR}/ran-backtick\`\"")"
command_config="$(make_config command.conf "touch ${TMP_DIR}/ran-command")"
lowercase_config="$(make_config lowercase.conf 'bad="value"')"
unquoted_config="$(make_config unquoted.conf 'BAD=value')"
crlf_config="${TMP_DIR}/crlf.conf"
printf 'GOOD="x"\r\n' >"$crlf_config"

assert_fail "load_config refuses \$(...)"      load_config "$subst_config"
assert_fail "load_config refuses backticks"    load_config "$backtick_config"
assert_fail "load_config refuses bare commands" load_config "$command_config"
assert_fail "load_config refuses lowercase names" load_config "$lowercase_config"
assert_fail "load_config refuses unquoted values" load_config "$unquoted_config"
assert_fail "load_config refuses CRLF line endings" load_config "$crlf_config"
assert_fail "refused configs ran nothing"      compgen -G "${TMP_DIR}/ran-*"

echo "Running commands"
DRY_RUN=1 run touch "${TMP_DIR}/dry-run-marker" >/dev/null
assert_fail "DRY_RUN=1 does not execute"       test -e "${TMP_DIR}/dry-run-marker"
assert_ok   "run true succeeds"                run true
assert_fail "run false fails"                  run false
assert_fail "run with no command fails"        run

echo "Confirmation"
assert_fail "confirm without a terminal answers no" confirm "Proceed?" </dev/null

echo "Logging"
(
    LOG_DIR="${TMP_DIR}/logs"
    log_init test-run >/dev/null
    log_warn "written to the log" 2>/dev/null
    grep -q "\[WARN\] written to the log" "${LOG_FILE}"
)
if (( $? == 0 )); then pass "log_init writes messages to a log file"; else fail "log_init writes messages to a log file"; fi
assert_fail "log_init refuses an unsafe name"  log_init "../escape"

echo "Error handling"
strict_output="$(bash -c 'source "$1"; enable_strict_mode; false; echo reached' _ "${PROJECT_ROOT}/lib/common.sh" 2>&1)"
strict_status=$?
assert_ok   "strict mode stops on failure"     test "$strict_status" -ne 0
assert_fail "strict mode skips later commands" grep -q reached <<<"$strict_output"
assert_ok   "ERR trap reports the failed command" grep -q "Command failed (exit 1)" <<<"$strict_output"
(die "test" 3) 2>/dev/null
die_status=$?
assert_ok   "die exits with the given code"    test "$die_status" -eq 3

echo
echo "Passed: ${PASSED}  Failed: ${FAILED}"
(( FAILED == 0 ))
