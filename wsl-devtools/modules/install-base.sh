#!/usr/bin/env bash
# modules/install-base.sh: basic command-line utilities (BASE_PACKAGES in config/packages.conf:
# curl, wget, zip, unzip, git).
#
# Usage: install-base.sh status|install|verify
#   status   show what is installed (read-only)
#   install  install missing utilities after confirmation, then verify
#   verify   check that each utility is installed and runs (read-only)
#
# Exit codes: 0 ok, 1 failed, 2 already installed (nothing to do),
#             3 precondition not met, 4 cancelled by the user.
# Set DRY_RUN=1 to show the commands that would change the system without running them.

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${MODULE_DIR}/../lib/common.sh"
# shellcheck source=../lib/system.sh
source "${MODULE_DIR}/../lib/system.sh"
# shellcheck source=../lib/packages.sh
source "${MODULE_DIR}/../lib/packages.sh"

BASE_PACKAGE_LIST=()

usage() {
    printf 'Usage: %s status|install|verify\n' "$(basename "$0")"
}

# Print the version output of a known utility (its first line is shown).
# Returns 2 for packages without a known command.
tool_version() {
    local output
    case "$1" in
        curl) curl --version ;;
        wget) wget --version ;;
        zip)
            # Line 1 of "zip -v" is a copyright notice; the version is on "This is Zip ...".
            output="$(zip -v)" || return 1
            grep -m 1 '^This is Zip' <<<"$output"
            ;;
        unzip) unzip -v ;;
        git) git --version ;;
        *) return 2 ;;
    esac
}

base_status() {
    local pkg
    log_step "Base utilities: status"
    for pkg in "${BASE_PACKAGE_LIST[@]}"; do
        if is_package_installed "$pkg"; then
            log_info "${pkg}: installed ($(package_version "$pkg"))"
        else
            log_info "${pkg}: not installed"
        fi
    done
}

# Returns 0 when every utility is installed and runs, 1 otherwise.
base_verify() {
    local pkg output failed=0
    log_step "Base utilities: verify"
    for pkg in "${BASE_PACKAGE_LIST[@]}"; do
        if ! is_package_installed "$pkg"; then
            log_error "${pkg}: package is not installed"
            failed=1
        elif output="$(tool_version "$pkg" 2>&1)"; then
            log_success "${pkg}: ${output%%$'\n'*}"
        elif (( $? == 2 )); then
            log_success "${pkg}: installed ($(package_version "$pkg"))"
        else
            log_error "${pkg}: package is installed but the command does not run"
            failed=1
        fi
    done
    return "$failed"
}

base_install() {
    local -a missing
    local rc=0

    preflight || exit 3

    mapfile -t missing < <(missing_packages "${BASE_PACKAGE_LIST[@]}")
    if (( ${#missing[@]} == 0 )); then
        log_success "All base utilities are already installed. Nothing to do."
        base_verify || exit 1
        exit 2
    fi

    log_step "Installing base utilities"
    log_info "Missing: ${missing[*]}"
    if [[ "${DRY_RUN:-0}" != "1" ]] &&
        ! confirm "Refresh apt package lists and install: ${missing[*]}? (Nothing else is upgraded)"; then
        log_warn "Cancelled. Nothing was changed."
        exit 4
    fi

    install_missing_packages "${missing[@]}" || rc=$?
    (( rc == 0 )) || exit "$rc"

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] Verification skipped because nothing was installed."
        return 0
    fi
    base_verify || exit 1
    log_success "Base utilities installed."
}

main() {
    enable_strict_mode
    load_project_config || exit 3
    read -r -a BASE_PACKAGE_LIST <<<"${BASE_PACKAGES:-}"
    if (( ${#BASE_PACKAGE_LIST[@]} == 0 )); then
        die "BASE_PACKAGES is empty in ${CONFIG_DIR}/packages.conf" 3
    fi

    case "${1:-}" in
        status) base_status ;;
        verify) base_verify || exit 1 ;;
        install) base_install ;;
        *)
            usage
            exit 3
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
