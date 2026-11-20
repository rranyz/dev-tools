#!/usr/bin/env bash
# tests/test-orchestrator.sh: tests for lib/orchestrator.sh, scripts/install-all.sh and
# scripts/install-menu.sh.
#
# Makes no system changes. The scripts run against stub modules (WSL_DEVTOOLS_MODULES_DIR)
# that only record how they were called and exit with a chosen code. A fake "sudo" first
# on PATH records any use. Logs go to a temporary LOG_DIR. Interactive runs use a
# pseudo-terminal from util-linux "script". The script tests run only on Ubuntu 24.04
# under WSL2 (the environment checks are real) and are skipped elsewhere.
#
# Usage: bash tests/test-orchestrator.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"

# shellcheck source=helpers.sh
source "${TESTS_DIR}/helpers.sh"
# shellcheck source=../lib/common.sh
source "${PROJECT_ROOT}/lib/common.sh"
# shellcheck source=../lib/system.sh
source "${PROJECT_ROOT}/lib/system.sh"
# shellcheck source=../lib/orchestrator.sh
source "${PROJECT_ROOT}/lib/orchestrator.sh"
load_project_config

INSTALL_ALL="${PROJECT_ROOT}/scripts/install-all.sh"
INSTALL_MENU="${PROJECT_ROOT}/scripts/install-menu.sh"

echo "Registry"
assert_equals "11 modules" "11" "${#MODULE_ORDER[@]}"
all_described=1
for name in "${MODULE_ORDER[@]}"; do
    [[ -n "${MODULE_LABEL[$name]:-}" && -n "${MODULE_KIND[$name]:-}" && -n "${MODULE_DEPS[$name]+set}" ]] || all_described=0
    [[ -f "${PROJECT_ROOT}/modules/install-${name}.sh" ]] || all_described=0
done
assert_equals "every module has a label, kind, deps entry and a real module file" "1" "$all_described"
deps_before=1
for i in "${!MODULE_ORDER[@]}"; do
    for dep in ${MODULE_DEPS[${MODULE_ORDER[$i]}]}; do
        for j in "${!MODULE_ORDER[@]}"; do
            [[ "${MODULE_ORDER[$j]}" == "$dep" ]] && (( j >= i )) && deps_before=0
        done
    done
done
assert_equals "every dependency comes before its module" "1" "$deps_before"
assert_equals "optional tools are not in the core shortcut" "" \
    "$(for n in "${CORE_SELECTION[@]}"; do [[ "${MODULE_KIND[$n]}" == optional ]] && echo "$n"; done)"
assert_equals "sort_modules: registry order, no duplicates" "base php composer" \
    "$(sort_modules composer php base php | tr '\n' ' ' | sed 's/ $//')"
assert_equals "exclusive_conflicts: mariadb + mysql" "mariadb mysql" "$(exclusive_conflicts base mysql mariadb)"
assert_equals "exclusive_conflicts: one database is fine" "" "$(exclusive_conflicts base mariadb)"
assert_fail "nodejs does not use sudo"        module_uses_sudo nodejs
assert_ok   "php uses sudo"                  module_uses_sudo php
assert_ok   "php needs systemd"              module_needs_systemd php
assert_fail "composer does not need systemd" module_needs_systemd composer
assert_equals "format_duration 75" "1m15s" "$(format_duration 75)"
assert_equals "format_duration 9" "9s" "$(format_duration 9)"
assert_equals "result_text 2" "already installed" "$(result_text 2)"
assert_equals "result_text 7" "failed (exit 7)" "$(result_text 7)"
assert_equals "result_text 0 in a dry run" "planned (dry run)" "$(DRY_RUN=1 result_text 0)"

read_os_release >/dev/null 2>&1
if [[ "$(detect_wsl_version)" != "2" ]] || ! is_supported_ubuntu || (( EUID == 0 )); then
    skip "script tests need Ubuntu ${SUPPORTED_UBUNTU_VERSION} on WSL2, as a normal user"
    finish
    exit $?
fi

# ---------------------------------------------------------------------------
# Fixtures: stub modules, fake sudo, temporary logs
# ---------------------------------------------------------------------------

STUB_DIR="${TMP_DIR}/modules"
FAKEBIN="${TMP_DIR}/fakebin"
CALLS="${TMP_DIR}/calls"          # "<module> <action> [args]" per call
ENVLOG="${TMP_DIR}/env"           # "<module> <action> DRY_RUN=<v> LOG_FILE=<set|>" per call
SUDO_LOG="${TMP_DIR}/sudo-calls"
mkdir -p "$STUB_DIR" "$FAKEBIN" "${TMP_DIR}/logs"

for name in "${MODULE_ORDER[@]}"; do
    cat >"${STUB_DIR}/install-${name}.sh" <<EOF
#!/usr/bin/env bash
echo "${name} \$*" >>"${CALLS}"
echo "${name} \${1:-} DRY_RUN=\${DRY_RUN:-} LOG_FILE=\${LOG_FILE:+set}" >>"${ENVLOG}"
sleep_file="${STUB_DIR}/sleep-${name}-\${1:-}"
[[ -f "\$sleep_file" ]] && sleep "\$(<"\$sleep_file")"
rc_file="${STUB_DIR}/rc-${name}-\${1:-}"
[[ -f "\$rc_file" ]] && exit "\$(<"\$rc_file")"
exit 0
EOF
done

# Fake sudo: "sudo -n true" succeeds (sudo is "ready"), every call is recorded, nothing runs.
printf '#!/usr/bin/env bash\necho "sudo $*" >>"%s"\nexit 0\n' "$SUDO_LOG" >"${FAKEBIN}/sudo"
chmod +x "${FAKEBIN}/sudo"

export WSL_DEVTOOLS_MODULES_DIR="$STUB_DIR"
export LOG_DIR="${TMP_DIR}/logs"
export NO_COLOR=1
export PATH="${FAKEBIN}:${PATH}"
unset DRY_RUN LOG_FILE

reset_calls() {
    rm -f "$CALLS" "$ENVLOG" "$SUDO_LOG" "${STUB_DIR}"/rc-* "${STUB_DIR}"/sleep-* "${TMP_DIR}/logs"/*
    touch "$CALLS" "$ENVLOG" "$SUDO_LOG"
}
set_rc() { echo "$3" >"${STUB_DIR}/rc-$1-$2"; }
set_sleep() { echo "$3" >"${STUB_DIR}/sleep-$1-$2"; }   # the stub sleeps N seconds in that action
calls() { tr '\n' ';' <"$CALLS"; }

OUT="${TMP_DIR}/out"
RC=0
# Run without a terminal: run_plain <args...>
run_plain() {
    RC=0
    bash "$INSTALL_ALL" "$@" </dev/null >"$OUT" 2>&1 || RC=$?
}
# Run in a pseudo-terminal with the given input: run_pty "<input>" <command...>
run_pty() {
    local input="$1"
    shift
    RC=0
    printf '%b' "$input" | timeout 60 script -qec "$(printf '%q ' "$@")" /dev/null >"$OUT" 2>&1 || RC=$?
    sed -i 's/\r$//' "$OUT"
}
# Like run_pty, but types the input in timed steps: run_pty_steps "<cmd>" data delay [data delay]...
# Each data string is typed, then the given number of seconds pass. "\003" is Ctrl+C.
run_pty_steps() {
    local cmd="$1"
    shift
    RC=0
    {
        while (( $# >= 2 )); do
            printf '%b' "$1"
            sleep "$2"
            shift 2
        done
    } | timeout 60 script -qec "$cmd" /dev/null >"$OUT" 2>&1 || RC=$?
    sed -i 's/\r$//' "$OUT"
}
out_has() { grep -qF -- "$1" "$OUT"; }

# ---------------------------------------------------------------------------
# install-all.sh: argument validation (nothing runs, no log file)
# ---------------------------------------------------------------------------

echo "install-all: validation"
reset_calls
run_plain --modules foo
assert_equals "unknown module -> 3" "3" "$RC"
run_plain --modules mariadb,mysql
assert_equals "mariadb + mysql -> 3" "3" "$RC"
assert_ok "mariadb + mysql explained" out_has "cannot be installed together"
run_plain --modules php --php 9.9
assert_equals "unsupported PHP version -> 3" "3" "$RC"
run_plain --modules redis --php 8.4
assert_equals "--php without the php module -> 3" "3" "$RC"
run_plain --no-such-option
assert_equals "unknown option -> 3" "3" "$RC"
run_plain --modules 18446744073709551619
assert_equals "a number that would wrap around (2^64+3) -> 3, not php" "3" "$RC"
DRY_RUN=yes run_plain --modules base
assert_equals "DRY_RUN=yes is refused -> 3" "3" "$RC"
assert_ok "invalid DRY_RUN explained" out_has "DRY_RUN='yes' is not valid"
run_plain --php 9.9
assert_equals "invalid --php without --modules -> 3 before any prompt" "3" "$RC"
assert_ok "modules override is announced" out_has "WSL_DEVTOOLS_MODULES_DIR is set"
assert_equals "no module ran during validation" "" "$(calls)"
assert_equals "no log file was created during validation" "0" "$(find "${TMP_DIR}/logs" -type f | wc -l)"
run_plain
assert_equals "no terminal and no --modules -> 4" "4" "$RC"
run_plain --modules core
assert_equals "no terminal to confirm -> 4" "4" "$RC"
assert_equals "nothing ran without confirmation" "" "$(calls)"
assert_equals "sudo was not used before confirmation" "" "$(grep -v -- '-n true' "$SUDO_LOG")"
run_plain --help
assert_equals "--help -> 0" "0" "$RC"
LOG_DIR=/proc/wsl-devtools-no-such-dir run_plain --modules base
assert_equals "log directory not writable -> 1" "1" "$RC"
assert_ok "log problem explained" out_has "Cannot write a log file in /proc/wsl-devtools-no-such-dir"

# ---------------------------------------------------------------------------
# install-all.sh: order, dependencies, results (dry run: no confirmation needed)
# ---------------------------------------------------------------------------

echo "install-all: order and dependencies (DRY_RUN=1)"
reset_calls
DRY_RUN=1 run_plain --modules composer,php,base,base --php both
assert_equals "dry run -> 0" "0" "$RC"
assert_equals "registry order, each module once, PHP versions passed" \
    "base install;php install 8.4 7.4;composer install;" "$(calls)"
assert_equals "DRY_RUN and LOG_FILE reach the modules" "3" "$(grep -c 'install DRY_RUN=1 LOG_FILE=set' "$ENVLOG")"
assert_equals "no verify pass in a dry run" "" "$(grep ' verify' "$CALLS")"
assert_equals "no real sudo -v in a dry run" "" "$(grep -- '-v' "$SUDO_LOG")"
assert_ok "dry run result message" out_has "Dry run finished"
assert_equals "one log file written" "1" "$(find "${TMP_DIR}/logs" -name 'install-all-*.log' | wc -l)"

reset_calls
set_rc base install 1
DRY_RUN=1 run_plain --modules base,nginx,php,composer,redis
assert_equals "base fails -> 1" "1" "$RC"
assert_equals "only base ran" "base install;" "$(calls)"
assert_equals "dependents marked not run" "4" "$(grep -c 'not run: needs' "$OUT")"
assert_ok "composer: transitive skip" out_has "composer     not run: needs php"

reset_calls
set_rc php install 3
DRY_RUN=1 run_plain --modules base,php,composer,nodejs,mariadb
assert_equals "php blocked -> 3" "3" "$RC"
assert_equals "only composer is skipped" "base install;php install 8.4;nodejs install;mariadb install;" "$(calls)"
assert_ok "php shown as blocked" out_has "php          blocked: requirement not met"

reset_calls
set_rc base install 2
set_rc php install 4
DRY_RUN=1 run_plain --modules base,nginx,php,composer
assert_equals "already installed satisfies, cancel skips dependents -> 3" "3" "$RC"
assert_equals "nginx and php ran after base (2), composer skipped" "base install;nginx install;php install 8.4;" "$(calls)"

reset_calls
set_rc redis install 7
DRY_RUN=1 run_plain --modules redis,mailpit
assert_equals "unexpected exit code -> 1" "1" "$RC"
assert_ok "unexpected code shown" out_has "failed (exit 7)"
assert_equals "independent module still ran" "redis install;mailpit install;" "$(calls)"

echo "install-all: no systemd"
# shellcheck disable=SC2016 # stub script text: its variables expand when the stub runs
printf '#!/usr/bin/env bash\n[[ "$1" == is-system-running ]] && { echo offline; exit 1; }\nexit 1\n' >"${FAKEBIN}/systemctl"
chmod +x "${FAKEBIN}/systemctl"
reset_calls
DRY_RUN=1 run_plain --modules nginx
assert_equals "a systemd module without systemd -> 3" "3" "$RC"
assert_ok "explained" out_has "needs systemd"
DRY_RUN=1 run_plain --modules nodejs,composer
assert_equals "non-service modules still run -> 0" "0" "$RC"
assert_equals "they ran" "composer install;nodejs install;" "$(calls)"
rm -f "${FAKEBIN}/systemctl"

# ---------------------------------------------------------------------------
# install-all.sh: interactive (pseudo-terminal)
# ---------------------------------------------------------------------------

if ! command -v script >/dev/null 2>&1; then
    skip "interactive tests need util-linux 'script'"
else
    echo "install-all: interactive"
    reset_calls
    run_pty 'y\n' bash "$INSTALL_ALL" --modules base,nodejs
    assert_equals "confirmed run -> 0" "0" "$RC"
    assert_equals "install then verify" "base install;nodejs install;base verify;nodejs verify;" "$(calls)"
    assert_equals "sudo -v asked once" "1" "$(grep -c 'sudo -v' "$SUDO_LOG")"
    assert_equals "verify runs without LOG_FILE (output appended to the log)" "2" \
        "$(grep -c 'verify DRY_RUN=0 LOG_FILE=$' "$ENVLOG")"
    assert_ok "PASS table" out_has "base         PASS"

    reset_calls
    run_pty 'y\n' bash "$INSTALL_ALL" --modules nodejs
    assert_equals "nodejs alone -> 0" "0" "$RC"
    assert_equals "nodejs alone: no sudo -v" "0" "$(grep -c 'sudo -v' "$SUDO_LOG")"

    reset_calls
    set_rc base verify 1
    run_pty 'y\n' bash "$INSTALL_ALL" --modules base
    assert_equals "failed verification -> 1" "1" "$RC"
    assert_ok "FAIL shown" out_has "base         FAIL"

    reset_calls
    set_rc php install 3
    run_pty 'y\n' bash "$INSTALL_ALL" --modules php,composer
    assert_equals "verify skipped for blocked modules" "php install 8.4;" "$(calls)"

    reset_calls
    run_pty 'n\n' bash "$INSTALL_ALL" --modules base
    assert_equals "answered no -> 4" "4" "$RC"
    assert_equals "answered no: nothing ran" "" "$(calls)"

    reset_calls
    run_pty '\n99\nmariadb mysql\nfoo\n1 5\ny\n' bash "$INSTALL_ALL"
    assert_equals "interactive selection -> 0" "0" "$RC"
    assert_equals "invalid answers re-asked, then base + nodejs" \
        "base install;nodejs install;base verify;nodejs verify;" "$(calls)"
    assert_ok "empty answer re-asked" out_has "Select at least one module"
    assert_ok "out-of-range number re-asked" out_has "Unknown module '99'"
    assert_ok "module list shown" out_has "Docker Engine"

    reset_calls
    run_pty 'php\n7\n3\ny\n' bash "$INSTALL_ALL"
    assert_equals "PHP version prompt: invalid, then both" "php install 8.4 7.4;php verify 8.4 7.4;" "$(calls)"
    assert_ok "PHP 7.4 EOL warning" out_has "end-of-life"

    reset_calls
    run_pty 'q\n' bash "$INSTALL_ALL"
    assert_equals "q at the selection -> 4" "4" "$RC"

    echo "Ctrl+C (pseudo-terminal, timed input)"
    reset_calls
    set_sleep php install 20
    run_pty_steps "bash $(printf '%q' "$INSTALL_ALL") --modules base,php,composer,nodejs" 'y\n' 3 '\003' 3
    assert_equals "Ctrl+C during a module -> 130" "130" "$RC"
    assert_equals "nothing runs after the interrupted module" "base install;php install 8.4;" "$(calls)"
    assert_ok "module shown as interrupted" out_has "php          interrupted"
    assert_ok "later modules: not run" out_has "composer     not run: interrupted"
    assert_ok "dpkg hint shown" out_has "sudo dpkg --configure -a"

    reset_calls
    run_pty_steps "bash $(printf '%q' "$INSTALL_ALL")" '' 2 '\003' 2
    assert_equals "Ctrl+C before the run -> 130" "130" "$RC"
    assert_ok "nothing changed message" out_has "Interrupted. Nothing was changed."
    assert_equals "Ctrl+C before the run: nothing ran" "" "$(calls)"

    reset_calls
    set_sleep redis status 20
    run_pty_steps "bash $(printf '%q' "$INSTALL_MENU")" '8\n1\n' 2 '\003' 2 '4\n13\n' 2
    assert_equals "menu: Ctrl+C during an action, then Exit -> 0" "0" "$RC"
    assert_ok "menu returns after Ctrl+C" out_has "Interrupted. Back to the menu."

    reset_calls
    run_pty_steps "bash $(printf '%q' "$INSTALL_MENU")" '' 2 '\003' 2
    assert_equals "menu: Ctrl+C at the prompt -> 130" "130" "$RC"
    assert_ok "menu leaves on Ctrl+C at a prompt" out_has "Interrupted. Leaving the menu."
fi

# ---------------------------------------------------------------------------
# install-menu.sh (piped input; module confirmations would answer no)
# ---------------------------------------------------------------------------

echo "install-menu"
run_menu() {
    RC=0
    printf '%b' "$1" | bash "$INSTALL_MENU" >"$OUT" 2>&1 || RC=$?
}

reset_calls
run_menu '0\n99\nx\n\n13\n'
assert_equals "invalid choices, then Exit -> 0" "0" "$RC"
assert_equals "four invalid choices re-asked" "4" "$(grep -c 'Please enter a number from 1 to 13' "$OUT")"
assert_equals "nothing ran" "" "$(calls)"
assert_ok "13 menu entries" out_has "13) Exit"

run_menu ''
assert_equals "end of input -> 0" "0" "$RC"

run_menu '1\n9\n'
assert_equals "end of input inside a submenu -> 0" "0" "$RC"
assert_ok "submenu validates input" out_has "Please enter a number from 1 to 5"

reset_calls
run_menu '8\n1\n3\n4\n13\n'
assert_equals "Redis: status, verify, back, exit" "redis status;redis verify;" "$(calls)"

reset_calls
run_menu '3\n5\n13\n'
assert_equals "PHP and Node.js open their own menus" "php menu;nodejs menu;" "$(calls)"

reset_calls
run_menu '10\n5\n7\n9\n4\n5\n13\n'
assert_equals "Mailpit php-mail, Docker test-run" "mailpit php-mail;docker test-run;" "$(calls)"

reset_calls
run_menu '6\n4\n5\n7\n4\n5\n13\n'
assert_equals "MySQL and MariaDB guides" "mysql guide;mariadb guide;" "$(calls)"

reset_calls
set_rc nginx install 3
run_menu '2\n2\n4\n13\n'
assert_equals "install from a submenu" "nginx install;" "$(calls)"
assert_ok "result shown" out_has "Result: not possible: a requirement is not met"

reset_calls
run_menu '12\n1\n2\n3\n13\n'
assert_equals "status of all modules" "11" "$(grep -c ' status$' "$CALLS")"
assert_equals "verify of all modules" "11" "$(grep -c ' verify$' "$CALLS")"
assert_ok "verify table shown" out_has "docker       PASS"

assert_equals "menu: DRY_RUN=yes is refused" "3" "$(DRY_RUN=yes bash "$INSTALL_MENU" </dev/null >/dev/null 2>&1; echo $?)"
run_menu '3\n13\n'
assert_fail "no result line after the PHP menu" out_has "Result:"
assert_equals "arguments are refused" "3" "$(bash "$INSTALL_MENU" extra </dev/null >/dev/null 2>&1; echo $?)"

finish
