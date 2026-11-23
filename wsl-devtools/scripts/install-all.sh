#!/usr/bin/env bash
# scripts/install-all.sh: install a selected set of tools in dependency order.
#
# Usage: install-all.sh [--modules a,b,c] [--php 8.4|7.4|both] [--dry-run] [--help]
#
# Without --modules it shows the available modules and asks which to install. Nothing is
# preselected: optional tools and the database are installed only when you choose them.
# All installation logic lives in modules/install-<name>.sh; this script runs them as child
# processes, in order, and each module still asks its own questions before changing anything.
#
# Exit codes: 0 everything installed or already installed, and verified; 1 a module or a
# verification failed; 3 a module was blocked, cancelled or not run (and nothing failed), or the
# system is not supported; 4 cancelled before anything ran; 130 interrupted (Ctrl+C).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/system.sh
source "${SCRIPT_DIR}/../lib/system.sh"
# shellcheck source=../lib/orchestrator.sh
source "${SCRIPT_DIR}/../lib/orchestrator.sh"

SELECTED=()          # module names in run order
PHP_SELECTION=()     # PHP versions passed to "install-php.sh install"
SYSTEMD_OK=1
OPT_MODULES=""
OPT_PHP=""
declare -A RESULT_RC=() RESULT_NOTE=() RESULT_TIME=()

usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Installs the tools you select, in dependency order, then verifies them.

Options:
  --modules LIST   comma-separated modules; skips the selection prompt.
                   Modules: ${MODULE_ORDER[*]}
                   "core" means: ${CORE_SELECTION[*]}
  --php VERSIONS   PHP versions for the php module: 8.4 (default), 7.4 or both
  --dry-run        show what would be done; change nothing (same as DRY_RUN=1)
  -h, --help       show this help

Examples:
  $(basename "$0")
  $(basename "$0") --modules core,mariadb --php 8.4
  $(basename "$0") --modules redis,mailpit
  DRY_RUN=1 $(basename "$0") --modules php --php both
EOF
}

parse_args() {
    while (( $# > 0 )); do
        case "$1" in
            --modules)
                [[ -n "${2:-}" ]] || { log_error "--modules needs a list, e.g. --modules core,mariadb"; exit 3; }
                OPT_MODULES="$2"
                shift 2
                ;;
            --php)
                [[ -n "${2:-}" ]] || { log_error "--php needs 8.4, 7.4 or both"; exit 3; }
                OPT_PHP="$2"
                shift 2
                ;;
            --dry-run)
                DRY_RUN=1
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                usage
                exit 3
                ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# 1-2. Project information and environment checks
# ---------------------------------------------------------------------------

show_project_info() {
    log_step "WSL2 web development toolkit: install selected tools"
    log_info "Toolkit:  ${WSL_DEVTOOLS_ROOT}"
    log_info "Target:   Ubuntu ${SUPPORTED_UBUNTU_VERSION} (${SUPPORTED_UBUNTU_CODENAME}) on WSL2 with systemd"
    log_info "Log file: ${LOG_FILE}"
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_info "Mode:     DRY RUN: modules only show their plans; nothing is changed"
    fi
}

# Stops (exit 3) unless the basic requirements are met. Without systemd, the modules that
# manage services become unavailable; the others can still be installed.
check_environment() {
    log_step "Environment checks"
    if ! { check_not_root && check_os && check_wsl2 && check_apt && check_sudo; }; then
        log_error "This system does not meet the toolkit's requirements. Nothing was changed."
        exit 3
    fi
    if ! check_systemd; then
        SYSTEMD_OK=0
        log_warn "Modules that manage services are unavailable: ${SYSTEMD_MODULES[*]}"
    fi
}

module_available() {
    (( SYSTEMD_OK == 1 )) || ! module_needs_systemd "$1"
}

# ---------------------------------------------------------------------------
# 3-4. Module list and selection
# ---------------------------------------------------------------------------

show_modules() {
    local i name note
    log_step "Available modules"
    for i in "${!MODULE_ORDER[@]}"; do
        name="${MODULE_ORDER[$i]}"
        note="${MODULE_KIND[$name]}"
        [[ -n "${MODULE_DEPS[$name]}" ]] && note+=", needs ${MODULE_DEPS[$name]}"
        module_available "$name" || note+=", UNAVAILABLE: no systemd"
        printf '  %2d) %-10s %-46s [%s]\n' $((i + 1)) "$name" "${MODULE_LABEL[$name]}" "$note"
    done
    printf '\n  MariaDB and MySQL cannot be installed together. Already-installed tools are\n'
    printf '  detected by each module and skipped. Current state: scripts/install-menu.sh -> status.\n'
}

# Turn a list of numbers / names / "core" into module names (sets PARSED_MODULES).
# Prints a message and returns 1 for invalid input.
PARSED_MODULES=()
parse_selection() {
    local text="$1" token name conflict
    local -a tokens names=()

    read -r -a tokens <<<"${text//,/ }"
    if (( ${#tokens[@]} == 0 )); then
        log_warn "Select at least one module."
        return 1
    fi
    for token in "${tokens[@]}"; do
        token="${token,,}"
        if [[ "$token" == "core" ]]; then
            names+=("${CORE_SELECTION[@]}")
        # At most 3 digits: longer numbers would wrap around in bash arithmetic.
        elif is_integer "$token" && (( ${#token} <= 3 )) &&
            (( 10#$token >= 1 && 10#$token <= ${#MODULE_ORDER[@]} )); then
            names+=("${MODULE_ORDER[$((10#$token - 1))]}")
        elif is_known_module "$token"; then
            names+=("$token")
        else
            log_warn "Unknown module '${token}'. Use numbers 1-${#MODULE_ORDER[@]}, module names or 'core'."
            return 1
        fi
    done
    for name in "${names[@]}"; do
        if ! module_available "$name"; then
            log_warn "${name} needs systemd, which is not usable here (see the environment checks)."
            return 1
        fi
    done
    conflict="$(exclusive_conflicts "${names[@]}")"
    if [[ -n "$conflict" ]]; then
        log_warn "${conflict/ / and } cannot be installed together. Choose one of them."
        return 1
    fi
    mapfile -t PARSED_MODULES < <(sort_modules "${names[@]}")
}

# Sets PHP_SELECTION from 8.4 / 7.4 / both / 8.4,7.4. Returns 1 for invalid input.
parse_php_selection() {
    local text="${1,,}" version
    local -a requested supported

    [[ "$text" == "both" ]] && text="${PHP_VERSIONS}"
    read -r -a requested <<<"${text//,/ }"
    if (( ${#requested[@]} == 0 )); then
        log_warn "Name a PHP version: ${PHP_VERSIONS} or both."
        return 1
    fi
    for version in "${requested[@]}"; do
        if ! is_supported_php_version "$version"; then
            log_warn "PHP '${version}' is not supported. Choose from: ${PHP_VERSIONS} or both."
            return 1
        fi
    done
    # Keep the order of PHP_VERSIONS and drop duplicates.
    PHP_SELECTION=()
    read -r -a supported <<<"${PHP_VERSIONS}"
    for version in "${supported[@]}"; do
        if is_one_of "$version" "${requested[@]}"; then
            PHP_SELECTION+=("$version")
        fi
    done
}

ask_modules() {
    local answer
    if [[ ! -t 0 ]]; then
        log_error "No interactive terminal to ask which tools to install. Use --modules, e.g. --modules core,mariadb"
        exit 4
    fi
    while true; do
        printf '\nEnter numbers or names separated by spaces (e.g. "1 2 3 4 5 6" or "core mariadb"), or q to quit.\n'
        read -r -p "Install which modules? " answer || exit_no_answer
        [[ "${answer,,}" == "q" ]] && { log_warn "Cancelled. Nothing was changed."; exit 4; }
        parse_selection "$answer" && break
    done
    SELECTED=("${PARSED_MODULES[@]}")
}

ask_php_versions() {
    local answer
    while true; do
        printf '\nPHP versions: 1) 8.4 (recommended)  2) 7.4 (end-of-life, legacy projects only)  3) both\n'
        read -r -p "Choose 1-3 [1]: " answer || exit_no_answer
        case "$answer" in
            "" | 1) PHP_SELECTION=(8.4); return 0 ;;
            2) PHP_SELECTION=(7.4); return 0 ;;
            3) parse_php_selection both && return 0 ;;
            *) log_warn "Please enter 1, 2 or 3." ;;
        esac
    done
}

select_modules() {
    if [[ -n "$OPT_MODULES" ]]; then
        parse_selection "$OPT_MODULES" || exit 3
        SELECTED=("${PARSED_MODULES[@]}")
    else
        ask_modules
    fi

    if is_one_of php "${SELECTED[@]}"; then
        if [[ -n "$OPT_PHP" ]]; then
            parse_php_selection "$OPT_PHP" || exit 3
        elif [[ -n "$OPT_MODULES" ]]; then
            PHP_SELECTION=(8.4)
        else
            ask_php_versions
        fi
    elif [[ -n "$OPT_PHP" ]]; then
        log_error "--php was given, but the php module is not selected."
        exit 3
    fi
}

# ---------------------------------------------------------------------------
# 5-7. Plan and run
# ---------------------------------------------------------------------------

module_args() {
    if [[ "$1" == "php" ]]; then
        echo "${PHP_SELECTION[*]}"
    fi
    return 0
}

show_plan() {
    local i name deps args
    log_step "Plan"
    for i in "${!SELECTED[@]}"; do
        name="${SELECTED[$i]}"
        deps="${MODULE_DEPS[$name]}"
        args="$(module_args "$name")"
        printf '  %d. %-10s %s%s%s\n' $((i + 1)) "$name" "${MODULE_LABEL[$name]}" \
            "${args:+ (versions: ${args})}" "${deps:+, after ${deps}}"
    done
    if is_one_of 7.4 "${PHP_SELECTION[@]}"; then
        log_warn "PHP 7.4 is end-of-life (no upstream security fixes). Use it only for legacy projects."
    fi
    log_info "Each module checks what is already installed and asks before changing anything."
    log_info "Not done automatically: Nginx sites, the default PHP CLI, Mailpit's php-mail, Docker's test-run."
}

# True when any selected module uses sudo; then the password is asked once, up front.
selection_uses_sudo() {
    local name
    for name in "${SELECTED[@]}"; do
        module_uses_sudo "$name" && return 0
    done
    return 1
}

# The first selected dependency that did not end 0 or 2, if any.
failed_dependency() {
    local dep
    local -a deps
    read -r -a deps <<<"${MODULE_DEPS[$1]}"
    for dep in "${deps[@]}"; do
        if [[ -n "${RESULT_RC[$dep]+set}" ]] && ! is_one_of "${RESULT_RC[$dep]}" 0 2; then
            echo "$dep"
            return 0
        fi
    done
    return 0
}

run_selected() {
    local i name dep total=${#SELECTED[@]}
    local -a args

    for i in "${!SELECTED[@]}"; do
        name="${SELECTED[$i]}"
        if (( ORCH_INTERRUPTED == 1 )); then
            RESULT_RC[$name]="-"
            RESULT_NOTE[$name]="not run: interrupted"
            continue
        fi
        dep="$(failed_dependency "$name")"
        if [[ -n "$dep" ]]; then
            log_step "[$((i + 1))/${total}] ${MODULE_LABEL[$name]}: not run"
            log_warn "Skipped because ${dep} did not complete."
            RESULT_RC[$name]="-"
            RESULT_NOTE[$name]="not run: needs ${dep}"
            continue
        fi

        log_step "[$((i + 1))/${total}] ${MODULE_LABEL[$name]}"
        read -r -a args <<<"$(module_args "$name")"
        run_module "$name" install "${args[@]}"
        RESULT_RC[$name]=$LAST_MODULE_RC
        RESULT_TIME[$name]=$(format_duration "$LAST_MODULE_SECONDS")
        if (( ORCH_INTERRUPTED == 1 || LAST_MODULE_RC == 130 )); then
            ORCH_INTERRUPTED=1
            RESULT_RC[$name]=130
            log_warn "${name}: interrupted."
            explain_interrupted_install
        fi
        RESULT_NOTE[$name]="$(result_text "${RESULT_RC[$name]}")"
        _log_to_file "RESULT" "${name}: ${RESULT_NOTE[$name]} (exit ${RESULT_RC[$name]})"
    done
}

# ---------------------------------------------------------------------------
# 8-10. Summary, verification, next steps
# ---------------------------------------------------------------------------

print_summary() {
    local name
    log_step "Summary"
    printf '  %-12s %-36s %s\n' "Module" "Result" "Time"
    for name in "${SELECTED[@]}"; do
        printf '  %-12s %-36s %s\n' "$name" "${RESULT_NOTE[$name]}" "${RESULT_TIME[$name]:--}"
        _log_to_file "SUMMARY" "${name}: ${RESULT_NOTE[$name]}"
    done
}

run_verification() {
    local name
    local -a entries=()
    for name in "${SELECTED[@]}"; do
        is_one_of "${RESULT_RC[$name]}" 0 2 || continue
        if [[ "$name" == "php" ]]; then
            entries+=("php:$(IFS=,; echo "${PHP_SELECTION[*]}")")
        else
            entries+=("$name")
        fi
    done
    log_step "Verification"
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_info "Skipped in a dry run."
        return 0
    fi
    if (( ${#entries[@]} == 0 )); then
        log_info "No module completed, so there is nothing to verify."
        return 0
    fi
    verify_modules "${entries[@]}"
    log_info "Full verification output is in ${LOG_FILE}"
}

show_next_steps() {
    local -a steps=()
    if is_one_of nginx "${SELECTED[@]}" || is_one_of php "${SELECTED[@]}"; then
        steps+=("Create a site:              scripts/nginx-site.sh create <domain> <root> <php-version>")
    fi
    if is_one_of php "${SELECTED[@]}"; then
        steps+=("Change the default PHP CLI: modules/install-php.sh set-default <version>")
    fi
    if is_one_of nodejs "${SELECTED[@]}"; then
        steps+=("Node.js:                    open a new terminal, then: nvm --version; node --version")
    fi
    if is_one_of mailpit "${SELECTED[@]}"; then
        steps+=("PHP mail() to Mailpit:      modules/install-mailpit.sh php-mail")
    fi
    if is_one_of docker "${SELECTED[@]}"; then
        steps+=("Test Docker:                modules/install-docker.sh test-run")
    fi
    (( ${#steps[@]} > 0 )) || return 0
    log_step "Next steps (optional, not done automatically)"
    printf '  %s\n' "${steps[@]}"
}

final_exit_code() {
    local name rc incomplete=0
    (( ORCH_INTERRUPTED == 0 )) || { echo 130; return 0; }
    for name in "${SELECTED[@]}"; do
        rc="${RESULT_RC[$name]}"
        case "$rc" in
            0 | 2) ;;
            3 | 4 | -) incomplete=1 ;;
            *) echo 1; return 0 ;;
        esac
    done
    (( VERIFY_FAILED == 0 )) || { echo 1; return 0; }
    (( incomplete == 0 )) && echo 0 || echo 3
}

# End of input at a prompt (Ctrl+D): nothing has run yet.
exit_no_answer() {
    printf '\n'
    log_warn "No answer. Cancelled; nothing was changed."
    exit 4
}

main() {
    local rc

    enable_strict_mode
    ORCH_INT_MESSAGE="Interrupted. Nothing was changed."
    orch_trap_exit_on_int
    load_project_config || exit 3
    parse_args "$@"
    # Validate everything that needs no system access before anything else, even a log file.
    check_orchestrator_env || exit 3
    export DRY_RUN
    if [[ -n "$OPT_PHP" ]]; then
        parse_php_selection "$OPT_PHP" || exit 3
    fi
    if [[ -n "$OPT_MODULES" ]]; then
        select_modules
    fi
    require_not_root || exit 3

    start_orchestrator_log install-all || exit 1
    show_project_info
    check_environment
    if [[ -z "$OPT_MODULES" ]]; then
        show_modules
        select_modules
    else
        parse_selection "$OPT_MODULES" || exit 3   # again: systemd may be unusable
    fi
    show_plan

    if [[ "${DRY_RUN:-0}" != "1" ]]; then
        if ! confirm "Start installing these ${#SELECTED[@]} module(s)?"; then
            log_warn "Cancelled. Nothing was changed."
            exit 4
        fi
    fi
    if selection_uses_sudo; then
        require_sudo || exit 3
    fi

    # From here on, Ctrl+C stops the running module; the summary is still printed.
    orch_trap_flag_on_int
    run_selected
    print_summary
    if (( ORCH_INTERRUPTED == 0 )); then
        run_verification
        show_next_steps
    fi

    rc="$(final_exit_code)"
    log_step "Result"
    case "$rc" in
        0)
            if [[ "${DRY_RUN:-0}" == "1" ]]; then
                log_success "Dry run finished. Nothing was changed."
            else
                log_success "All selected modules are installed and verified."
            fi
            ;;
        1) log_error "Something failed. See the summary above and ${LOG_FILE}." ;;
        3) log_warn "Some modules were blocked, cancelled or not run. Fix the cause and rerun; installed modules are skipped." ;;
        130) log_warn "Interrupted. Rerun to continue; installed modules are skipped." ;;
    esac
    log_info "Log: ${LOG_FILE}"
    exit "$rc"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
