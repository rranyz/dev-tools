#!/usr/bin/env bash
# scripts/install-menu.sh: interactive main menu of the toolkit.
#
# Usage: install-menu.sh
#
# Every choice runs a module action (modules/install-<name>.sh <action>) as a child process,
# then shows how it ended and returns to the menu. PHP and Node.js open their own module
# menus. This script installs nothing itself.
#
# Ctrl+C while an action runs stops that action and returns to the menu; Ctrl+C at a menu
# prompt leaves the menu.
# Exit codes: 0 normal exit (menu option or end of input), 130 Ctrl+C at a menu prompt.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/system.sh
source "${SCRIPT_DIR}/../lib/system.sh"
# shellcheck source=../lib/orchestrator.sh
source "${SCRIPT_DIR}/../lib/orchestrator.sh"

# Main menu entries in display order: a module name, or a special entry.
MENU_ITEMS=(base nginx php composer nodejs mysql mariadb redis docker mailpit postgresql status exit)

declare -A MENU_TITLE=(
    [base]="System preparation"
    [nginx]="Nginx"
    [php]="PHP"
    [composer]="Composer"
    [nodejs]="Node.js and NVM"
    [mysql]="MySQL"
    [mariadb]="MariaDB"
    [redis]="Redis"
    [docker]="Docker"
    [mailpit]="Mailpit"
    [postgresql]="PostgreSQL"
    [status]="Installation status"
    [exit]="Exit"
)

# Module actions offered in each submenu, after status / install / verify.
declare -A MODULE_EXTRAS=(
    [base]="check-system"
    [mysql]="guide"
    [mariadb]="guide"
    [postgresql]="guide"
    [mailpit]="test php-mail guide"
    [docker]="test-run"
)

# Modules that have their own interactive menu ("install-<name>.sh menu").
OWN_MENU_MODULES=(php nodejs)

action_label() {
    case "$1" in
        status) echo "Show status" ;;
        install) echo "Install" ;;
        verify) echo "Verify" ;;
        guide) echo "Show the setup guide" ;;
        test) echo "Send a test email" ;;
        php-mail) echo "Route PHP mail() to Mailpit" ;;
        test-run) echo "Run Docker's hello-world test container" ;;
        check-system) echo "Check system requirements (read-only)" ;;
        *) echo "$1" ;;
    esac
}

# ---------------------------------------------------------------------------
# Input
# ---------------------------------------------------------------------------

# Read a menu choice into MENU_CHOICE. At end of input (Ctrl+D) exits 0. Ctrl+C at a
# prompt exits 130 through the trap set in main.
MENU_CHOICE=""
read_choice() {
    local prompt="$1"
    if ! read -r -p "$prompt" MENU_CHOICE; then
        printf '\n'
        log_info "End of input. Leaving the menu."
        exit 0
    fi
    MENU_CHOICE="${MENU_CHOICE//[[:space:]]/}"
}

# True when MENU_CHOICE is a whole number from 1 to max.
choice_in_range() {
    local max="$1"
    is_integer "$MENU_CHOICE" && (( ${#MENU_CHOICE} <= 3 )) &&
        (( 10#$MENU_CHOICE >= 1 && 10#$MENU_CHOICE <= max ))
}

# ---------------------------------------------------------------------------
# Running actions
# ---------------------------------------------------------------------------

# Run one action and report how it ended. Ctrl+C stops only that action.
menu_action() {
    local name="$1" action="$2" rc=0
    shift 2
    ORCH_INTERRUPTED=0
    orch_trap_flag_on_int
    if [[ "$action" == "check-system" ]]; then
        bash "${WSL_DEVTOOLS_ROOT}/scripts/check-system.sh" || rc=$?
        LAST_MODULE_RC=$rc
    else
        run_module "$name" "$action" "$@"
    fi
    orch_trap_exit_on_int
    if (( ORCH_INTERRUPTED == 1 || LAST_MODULE_RC == 130 )); then
        ORCH_INTERRUPTED=0
        log_warn "Interrupted. Back to the menu."
        [[ "$action" == "install" || "$action" == "php-mail" ]] && explain_interrupted_install
        return 0
    fi
    _log_to_file "RESULT" "${name} ${action}: exit ${LAST_MODULE_RC}"
    # Leaving the PHP or Node.js menu is not a result worth showing.
    if [[ "$action" != "menu" ]]; then
        log_info "Result: $(exit_code_meaning "$LAST_MODULE_RC")"
    fi
}

module_submenu() {
    local name="$1" i
    local -a actions extras
    read -r -a extras <<<"${MODULE_EXTRAS[$name]:-}"
    actions=(status install verify "${extras[@]}")

    while true; do
        printf '\n%s\n' "${MENU_TITLE[$name]}: ${MODULE_LABEL[$name]}"
        for i in "${!actions[@]}"; do
            printf '  %d) %s\n' $((i + 1)) "$(action_label "${actions[$i]}")"
        done
        printf '  %d) Back to main menu\n' $(( ${#actions[@]} + 1 ))
        read_choice "Choose 1-$(( ${#actions[@]} + 1 )): "
        if ! choice_in_range $(( ${#actions[@]} + 1 )); then
            log_warn "Please enter a number from 1 to $(( ${#actions[@]} + 1 ))."
            continue
        fi
        (( 10#$MENU_CHOICE <= ${#actions[@]} )) || return 0
        menu_action "$name" "${actions[$((10#$MENU_CHOICE - 1))]}"
    done
}

status_submenu() {
    while true; do
        printf '\nInstallation status\n'
        printf '  1) Status of every module (read-only)\n'
        printf '  2) Verify every module (read-only, PASS/FAIL table)\n'
        printf '  3) Back to main menu\n'
        read_choice "Choose 1-3: "
        ORCH_INTERRUPTED=0
        orch_trap_flag_on_int
        case "$MENU_CHOICE" in
            1) status_all ;;
            2)
                verify_modules "${MODULE_ORDER[@]}"
                log_info "Modules that are not installed show FAIL. Full output: ${LOG_FILE}"
                ;;
            3) orch_trap_exit_on_int; return 0 ;;
            *) log_warn "Please enter a number from 1 to 3." ;;
        esac
        orch_trap_exit_on_int
        if (( ORCH_INTERRUPTED == 1 )); then
            ORCH_INTERRUPTED=0
            log_warn "Interrupted. Back to the menu."
        fi
    done
}

open_item() {
    local item="$1"
    case "$item" in
        status) status_submenu ;;
        exit)
            log_info "Goodbye."
            exit 0
            ;;
        *)
            if is_one_of "$item" "${OWN_MENU_MODULES[@]}"; then
                menu_action "$item" menu
            else
                module_submenu "$item"
            fi
            ;;
    esac
}

main_menu() {
    local i count=${#MENU_ITEMS[@]}
    while true; do
        printf '\nWSL2 web development toolkit: main menu\n'
        for i in "${!MENU_ITEMS[@]}"; do
            printf '  %2d) %s\n' $((i + 1)) "${MENU_TITLE[${MENU_ITEMS[$i]}]}"
        done
        read_choice "Choose 1-${count}: "
        if ! choice_in_range "$count"; then
            log_warn "Please enter a number from 1 to ${count}."
            continue
        fi
        open_item "${MENU_ITEMS[$((10#$MENU_CHOICE - 1))]}"
    done
}

main() {
    enable_strict_mode
    ORCH_INT_MESSAGE="Interrupted. Leaving the menu."
    orch_trap_exit_on_int
    load_project_config || exit 3
    if (( $# > 0 )); then
        printf 'Usage: %s   (interactive menu, no arguments)\n' "$(basename "$0")"
        [[ "$1" == "-h" || "$1" == "--help" ]] && exit 0
        exit 3
    fi
    check_orchestrator_env || exit 3
    require_not_root || exit 3
    export DRY_RUN
    start_orchestrator_log install-menu || exit 1

    log_step "WSL2 web development toolkit"
    log_info "Target: Ubuntu ${SUPPORTED_UBUNTU_VERSION} on WSL2 with systemd. Toolkit: ${WSL_DEVTOOLS_ROOT}"
    log_info "Log file: ${LOG_FILE}"
    [[ "${DRY_RUN:-0}" == "1" ]] && log_info "DRY RUN: modules only show their plans."
    log_info "Each module checks the system and asks before changing anything."
    main_menu
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
