#!/usr/bin/env bash
# modules/install-nginx.sh: the Nginx web server.
#
# Usage: install-nginx.sh status|install|verify
#   status   package, service and enabled sites (read-only)
#   install  install Nginx if missing (asks first), make sure the service runs, verify
#   verify   package, "nginx -t" (needs sudo), service, HTTP answer on 127.0.0.1
#
# Never writes or overwrites Nginx configuration. Sites are added with scripts/nginx-site.sh.
# Exit codes: 0 ok, 1 failed, 2 already installed, 3 precondition not met, 4 cancelled.

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${MODULE_DIR}/../lib/common.sh"
# shellcheck source=../lib/system.sh
source "${MODULE_DIR}/../lib/system.sh"
# shellcheck source=../lib/packages.sh
source "${MODULE_DIR}/../lib/packages.sh"
# shellcheck source=../lib/services.sh
source "${MODULE_DIR}/../lib/services.sh"
# shellcheck source=../lib/nginx.sh
source "${MODULE_DIR}/../lib/nginx.sh"

NGINX_PACKAGE_LIST=()

usage() {
    printf 'Usage: %s status|install|verify\n' "$(basename "$0")"
}

nginx_status() {
    local site enabled_sites=()
    log_step "Nginx: status"
    if ! is_package_installed nginx; then
        log_info "nginx: not installed"
        if [[ -n "$(port_listeners 80)" ]]; then
            log_warn "Port 80 is already in use by another program."
        fi
        return 0
    fi
    log_info "nginx: installed ($(package_version nginx))"
    log_info "service: $(service_state nginx), $(service_is_enabled nginx && echo "starts at boot" || echo "does not start at boot")"
    for site in "${NGINX_DIR}/sites-enabled"/*; do
        [[ -e "$site" ]] && enabled_sites+=("${site##*/}")
    done
    log_info "enabled sites (${#enabled_sites[@]}): ${enabled_sites[*]:-none}"
}

# Returns 0 when Nginx is installed, valid, running and answering.
nginx_verify() {
    local failed=0 code
    log_step "Nginx: verify"
    if ! is_package_installed nginx; then
        log_error "nginx: package is not installed"
        return 1
    fi
    log_success "nginx: installed ($(package_version nginx))"

    if can_use_sudo_now; then
        nginx_config_test || failed=1
    else
        log_warn "nginx -t skipped: it needs sudo. Run this in a terminal to include it."
    fi

    if service_is_active nginx; then
        log_success "service nginx: active"
    else
        log_error "service nginx: $(service_state nginx)"
        failed=1
    fi

    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 http://127.0.0.1/ || true)"
    if [[ "$code" =~ ^[1-5][0-9][0-9]$ ]]; then
        log_success "http://127.0.0.1/ answers (HTTP ${code})"
    else
        log_error "http://127.0.0.1/ does not answer"
        failed=1
    fi
    return "$failed"
}

nginx_install() {
    local -a missing
    local rc=0

    preflight --needs-systemd || exit 3

    mapfile -t missing < <(missing_packages "${NGINX_PACKAGE_LIST[@]}")
    if (( ${#missing[@]} == 0 )); then
        log_success "Nginx is already installed. Nothing to do."
        nginx_verify || exit 1
        exit 2
    fi

    if [[ -n "$(port_listeners 80)" ]]; then
        log_error "Port 80 is already in use by another program (see: sudo ss -ltnp 'sport = :80')."
        log_error "Nginx could not start. Stop that program first; this toolkit does not stop it."
        exit 3
    fi

    log_step "Installing Nginx"
    log_info "Missing: ${missing[*]}"
    if [[ "${DRY_RUN:-0}" != "1" ]] &&
        ! confirm "Install ${missing[*]}? Nginx starts on port 80 with Ubuntu's default site."; then
        log_warn "Cancelled. Nothing was changed."
        exit 4
    fi

    install_missing_packages "${missing[@]}" || rc=$?
    (( rc == 0 )) || exit "$rc"

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] Service start and verification skipped."
        return 0
    fi
    if ! service_is_active nginx; then
        service_enable_now nginx || exit 1
    fi
    nginx_verify || exit 1
    log_success "Nginx installed."
}

main() {
    enable_strict_mode
    load_project_config || exit 3
    read -r -a NGINX_PACKAGE_LIST <<<"${NGINX_PACKAGES:-}"
    if (( ${#NGINX_PACKAGE_LIST[@]} == 0 )); then
        die "NGINX_PACKAGES is empty in ${CONFIG_DIR}/packages.conf" 3
    fi

    case "${1:-}" in
        status) nginx_status ;;
        verify) nginx_verify || exit 1 ;;
        install) nginx_install ;;
        *)
            usage
            exit 3
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
