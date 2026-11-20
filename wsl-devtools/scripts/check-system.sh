#!/usr/bin/env bash
# scripts/check-system.sh: read-only report on whether this system is ready for the toolkit.
#
# Usage: check-system.sh
# Exit codes: 0 ready, 3 one or more requirements not met. Changes nothing.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/system.sh
source "${SCRIPT_DIR}/../lib/system.sh"
# shellcheck source=../lib/packages.sh
source "${SCRIPT_DIR}/../lib/packages.sh"

main() {
    local problems=0 check busy

    enable_strict_mode
    load_project_config || exit 3

    log_step "System requirements"
    for check in check_not_root check_os check_wsl2 check_systemd check_sudo check_apt; do
        "$check" || problems=$((problems + 1))
    done

    busy="$(apt_busy_process)"
    if [[ -n "$busy" ]]; then
        log_warn "apt/dpkg is running right now (${busy//$'\n'/, }). Installs will wait up to ${APT_LOCK_TIMEOUT_SECONDS}s for it."
    fi

    "${WSL_DEVTOOLS_ROOT}/modules/install-base.sh" status

    log_step "Result"
    if (( problems > 0 )); then
        log_error "${problems} requirement(s) not met. See the messages above."
        exit 3
    fi
    log_success "This system meets the toolkit's requirements."
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
