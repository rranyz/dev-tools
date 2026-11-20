# shellcheck shell=bash
# lib/orchestrator.sh: module registry and helpers shared by scripts/install-all.sh and
# scripts/install-menu.sh.
#
# Requires lib/common.sh. The orchestrators never install anything themselves: they run
# modules/install-<name>.sh as child processes and read the exit code (architecture.md §3).

if [[ -n "${WSL_DEVTOOLS_ORCHESTRATOR_LOADED:-}" ]]; then
    return 0
fi
WSL_DEVTOOLS_ORCHESTRATOR_LOADED=1

# Where the modules live. Tests point this at stub modules.
MODULES_DIR="${WSL_DEVTOOLS_MODULES_DIR:-${WSL_DEVTOOLS_ROOT}/modules}"

# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

# Installation order (architecture.md §6). A module's dependencies always come before it.
MODULE_ORDER=(base nginx php composer nodejs mariadb mysql redis postgresql mailpit docker)

declare -A MODULE_LABEL=(
    [base]="System preparation (curl wget zip unzip git)"
    [nginx]="Nginx"
    [php]="PHP + PHP-FPM + Xdebug"
    [composer]="Composer"
    [nodejs]="Node.js LTS via official NVM"
    [mariadb]="MariaDB"
    [mysql]="MySQL 8.0 (end-of-life upstream)"
    [redis]="Redis"
    [postgresql]="PostgreSQL 16"
    [mailpit]="Mailpit (local mail catcher)"
    [docker]="Docker Engine"
)

# shellcheck disable=SC2034 # used by scripts/install-all.sh
declare -A MODULE_KIND=(
    [base]=core [nginx]=core [php]=core [composer]=core [nodejs]=core
    [mariadb]=core [mysql]=core
    [redis]=optional [postgresql]=optional [mailpit]=optional [docker]=optional
)

# Space-separated. When a dependency was selected and did not end 0 or 2, the module is not run.
# shellcheck disable=SC2034 # used by scripts/install-all.sh
declare -A MODULE_DEPS=(
    [base]=""
    [nginx]="base" [php]="base" [composer]="php" [nodejs]="base"
    [mariadb]="base" [mysql]="base"
    [redis]="base" [postgresql]="base" [mailpit]="base" [docker]="base"
)

# Modules whose install manages a systemd service.
SYSTEMD_MODULES=(nginx php mariadb mysql redis postgresql mailpit docker)

# Modules that never use sudo (NVM is per user).
NO_SUDO_MODULES=(nodejs)

# The "core" shortcut in install-all.sh. The database is chosen separately (one of two).
# shellcheck disable=SC2034 # used by scripts/install-all.sh
CORE_SELECTION=(base nginx php composer nodejs)

# Pairs that cannot be installed together (architecture.md §9).
EXCLUSIVE_PAIRS=("mariadb mysql")

# Checks shared by both orchestrators, run before anything else (no log file yet).
# - DRY_RUN must be empty, 0 or 1. Anything else (e.g. "yes", "true") would silently mean a
#   real run, because only "1" means dry run.
# - The modules directory can be overridden for tests (WSL_DEVTOOLS_MODULES_DIR); say so,
#   because it changes which scripts run.
# Returns 3 when DRY_RUN is invalid.
check_orchestrator_env() {
    if ! is_valid_dry_run; then
        log_error "DRY_RUN='${DRY_RUN}' is not valid. Use DRY_RUN=1 for a dry run, or leave it unset."
        return 3
    fi
    if [[ -n "${WSL_DEVTOOLS_MODULES_DIR:-}" ]]; then
        log_warn "WSL_DEVTOOLS_MODULES_DIR is set: running modules from ${MODULES_DIR}, not ${WSL_DEVTOOLS_ROOT}/modules."
    fi
}

# Start the run log (logs/<name>-<timestamp>.log) and export LOG_FILE so the modules write
# their messages into the same file. Returns 1 with one clear message when that is not possible.
start_orchestrator_log() {
    if ! log_init "$1" >/dev/null 2>&1 || [[ ! -w "${LOG_FILE}" ]]; then
        LOG_FILE=""
        log_error "Cannot write a log file in ${LOG_DIR}. Check that the directory exists and is writable by $(id -un)."
        return 1
    fi
    export LOG_FILE
}

is_known_module() {
    is_one_of "${1:-}" "${MODULE_ORDER[@]}"
}

module_needs_systemd() {
    is_one_of "${1:-}" "${SYSTEMD_MODULES[@]}"
}

module_uses_sudo() {
    ! is_one_of "${1:-}" "${NO_SUDO_MODULES[@]}"
}

# Path of a module script. Usage: module_script php
module_script() {
    printf '%s/install-%s.sh' "$MODULES_DIR" "$1"
}

# Print the given module names in registry order, without duplicates.
sort_modules() {
    local name
    for name in "${MODULE_ORDER[@]}"; do
        is_one_of "$name" "$@" && echo "$name"
    done
    return 0
}

# Print one line per excluded pair found in the list, e.g. "mariadb mysql".
exclusive_conflicts() {
    local pair first second
    for pair in "${EXCLUSIVE_PAIRS[@]}"; do
        read -r first second <<<"$pair"
        if is_one_of "$first" "$@" && is_one_of "$second" "$@"; then
            echo "$pair"
        fi
    done
    return 0
}

# ---------------------------------------------------------------------------
# Running modules
# ---------------------------------------------------------------------------

# Ctrl+C handling. Two modes, because bash restarts "read" after a trap handler returns:
#  - at prompts: orch_trap_exit_on_int; Ctrl+C prints ORCH_INT_MESSAGE and exits 130.
#  - while a module runs: orch_trap_flag_on_int; the module (same terminal) receives SIGINT
#    and stops, bash finishes waiting for it, and the trap only sets ORCH_INTERRUPTED, so the
#    caller can report it and decide what to do next.
ORCH_INTERRUPTED=0
ORCH_INT_MESSAGE="Interrupted."
orch_on_interrupt() {
    ORCH_INTERRUPTED=1
}
_orch_exit_interrupted() {
    printf '\n'
    log_warn "$ORCH_INT_MESSAGE"
    exit 130
}
orch_trap_exit_on_int() {
    trap _orch_exit_interrupted INT
}
orch_trap_flag_on_int() {
    trap orch_on_interrupt INT
}

LAST_MODULE_RC=0
LAST_MODULE_SECONDS=0

# Run one module action as a child process. Records LAST_MODULE_RC and LAST_MODULE_SECONDS.
# Always returns 0, so strict mode does not stop the caller; read LAST_MODULE_RC instead.
# Usage: run_module php install 8.4
run_module() {
    local name="$1" script start rc=0
    shift
    script="$(module_script "$name")"
    if [[ ! -f "$script" ]]; then
        log_error "Module not found: ${script}"
        LAST_MODULE_RC=1
        LAST_MODULE_SECONDS=0
        return 0
    fi
    start=$SECONDS
    bash "$script" "$@" || rc=$?
    LAST_MODULE_RC=$rc
    LAST_MODULE_SECONDS=$((SECONDS - start))
    return 0
}

# Short result text for an exit code, as shown in summaries.
result_text() {
    case "${1:-}" in
        0) if [[ "${DRY_RUN:-0}" == "1" ]]; then echo "planned (dry run)"; else echo "installed and verified"; fi ;;
        2) echo "already installed" ;;
        3) echo "blocked: requirement not met" ;;
        4) echo "cancelled" ;;
        130) echo "interrupted" ;;
        *) echo "failed (exit ${1:-?})" ;;
    esac
}

# 10 -> "10s", 75 -> "1m15s"
format_duration() {
    local seconds="${1:-0}"
    if (( seconds >= 60 )); then
        printf '%dm%02ds' $((seconds / 60)) $((seconds % 60))
    else
        printf '%ds' "$seconds"
    fi
}

# Shown after an install was interrupted: apt/dpkg may have been stopped half-way.
explain_interrupted_install() {
    log_warn "If apt or dpkg was interrupted, finish its work with: sudo dpkg --configure -a"
    log_warn "(The toolkit does not run this for you.) Rerunning the module is safe."
}

# ---------------------------------------------------------------------------
# Status and verification across modules
# ---------------------------------------------------------------------------

# Show every module's own status report (read-only).
status_all() {
    local name
    for name in "${MODULE_ORDER[@]}"; do
        (( ORCH_INTERRUPTED == 0 )) || return 0
        printf '\n'
        log_step "Status: ${MODULE_LABEL[$name]}"
        run_module "$name" status
        if (( LAST_MODULE_RC != 0 )); then
            log_warn "${name} status ended with: $(exit_code_meaning "$LAST_MODULE_RC")"
        fi
    done
}

# Read-only verify of the given modules. The modules' own output goes to LOG_FILE (or is
# dropped when there is none); the screen shows one PASS/FAIL line per module.
# Arguments are "name" or "name:arg1,arg2" (e.g. "php:8.4,7.4").
# Sets VERIFY_FAILED to the number of failures.
VERIFY_FAILED=0
verify_modules() {
    local entry name args_text output="/dev/null" status script
    local -a args
    VERIFY_FAILED=0
    [[ -n "${LOG_FILE:-}" ]] && output="$LOG_FILE"

    log_info "Some checks use sudo (for example nginx -t); you may be asked for your password."
    printf '\n  %-12s %-6s %s\n' "Module" "Result" "Details"
    for entry in "$@"; do
        (( ORCH_INTERRUPTED == 0 )) || return 0
        name="${entry%%:*}"
        args=()
        if [[ "$entry" == *:* ]]; then
            args_text="${entry#*:}"
            IFS=',' read -r -a args <<<"$args_text"
        fi
        printf '\n==> verify %s %s\n' "$name" "${args[*]}" >>"$output"
        # LOG_FILE is cleared for the child: its whole output is appended to the log below.
        LOG_FILE="" run_module "$name" verify "${args[@]}" >>"$output" 2>&1
        if (( LAST_MODULE_RC == 0 )); then
            status="PASS"
            printf '  %-12s %-6s %s\n' "$name" "$status" "$(format_duration "$LAST_MODULE_SECONDS")"
        else
            status="FAIL"
            VERIFY_FAILED=$((VERIFY_FAILED + 1))
            script="$(module_script "$name")"
            script="${script#"${WSL_DEVTOOLS_ROOT}"/}"
            printf '  %-12s %-6s %s\n' "$name" "$status" \
                "details: bash ${script} verify${args[*]:+ ${args[*]}}"
        fi
        _log_to_file "VERIFY" "${name}: ${status}"
    done
}
