#!/usr/bin/env bash
# modules/install-redis.sh: Redis from Ubuntu's archive.
#
# Usage: install-redis.sh status|install|verify
#   status   package, service, listeners on the Redis port, ping (read-only)
#   install  install if missing and the port is free (asks first), start, verify
#   verify   service, local-only listeners, redis-cli ping, server version
#
# Ubuntu's defaults are kept: bind 127.0.0.1 -::1, protected-mode yes, no password.
# /etc/redis/redis.conf is never edited.
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

REDIS_UNIT="redis-server"
REDIS_PORT="6379"
REDIS_PACKAGE_LIST=()

usage() {
    printf 'Usage: %s status|install|verify\n' "$(basename "$0")"
}

# Print redis-cli's answer to PING on 127.0.0.1, or nothing when it does not answer.
redis_ping() {
    command_exists redis-cli || return 0
    # A server with a password answers "NOAUTH ..."; that still proves it is running.
    timeout 5 redis-cli -h 127.0.0.1 -p "$REDIS_PORT" ping 2>&1 | head -n 1 || true
}

redis_status() {
    log_step "Redis: status"
    if ! is_package_installed redis-server; then
        log_info "redis-server: not installed"
    else
        log_info "redis-server: installed ($(package_version redis-server))"
        log_info "service ${REDIS_UNIT}: $(service_state "$REDIS_UNIT"), $(service_is_enabled "$REDIS_UNIT" && echo "starts at boot" || echo "does not start at boot")"
        log_info "redis-cli ping: $(redis_ping | sed 's/^$/no answer/')"
    fi
    report_port_listeners "$REDIS_PORT" || true
}

redis_verify() {
    local failed=0 answer version
    log_step "Redis: verify"
    if ! is_package_installed redis-server; then
        log_error "redis-server is not installed."
        return 1
    fi
    log_success "redis-server: $(package_version redis-server)"
    if service_is_active "$REDIS_UNIT"; then
        log_success "service ${REDIS_UNIT}: active"
    else
        log_error "service ${REDIS_UNIT}: $(service_state "$REDIS_UNIT"). Start it with: sudo systemctl start ${REDIS_UNIT}"
        failed=1
    fi
    if ! service_is_enabled "$REDIS_UNIT"; then
        log_warn "service ${REDIS_UNIT} does not start at boot. Enable it with: sudo systemctl enable ${REDIS_UNIT}"
    fi
    if [[ -z "$(port_listen_addresses "$REDIS_PORT")" ]]; then
        log_error "nothing listens on port ${REDIS_PORT}"
        failed=1
    elif ! report_port_listeners "$REDIS_PORT"; then
        log_warn "Keep 'bind 127.0.0.1 -::1' in /etc/redis/redis.conf unless other machines must connect. Not changed by the toolkit."
    fi

    answer="$(redis_ping)"
    case "$answer" in
        PONG)
            log_success "redis-cli -h 127.0.0.1 ping -> PONG"
            version="$(timeout 5 redis-cli -h 127.0.0.1 -p "$REDIS_PORT" INFO server 2>/dev/null |
                awk -F: '/^redis_version:/ {gsub(/\r/, "", $2); print $2}')" || version=""
            log_success "Redis server version: ${version:-unknown}"
            ;;
        NOAUTH*)
            log_success "Redis answers on 127.0.0.1:${REDIS_PORT} (a password is set: ${answer})"
            ;;
        *)
            log_error "Redis does not answer on 127.0.0.1:${REDIS_PORT}${answer:+: ${answer}}"
            failed=1
            ;;
    esac
    return "$failed"
}

redis_install() {
    local -a missing
    local rc=0 listeners pkg

    preflight --needs-systemd || exit 3
    mapfile -t missing < <(missing_packages "${REDIS_PACKAGE_LIST[@]}")
    if (( ${#missing[@]} == 0 )); then
        log_success "Redis is already installed. Nothing to do."
        redis_verify || exit 1
        exit 2
    fi

    listeners="$(port_listen_addresses "$REDIS_PORT" | tr '\n' ' ')"
    if [[ -n "$listeners" ]]; then
        log_error "Port ${REDIS_PORT} is already in use (${listeners% }), probably by another Redis or a container."
        log_error "Stop that program first (see: sudo ss -ltnp). The toolkit does not stop it. Nothing was changed."
        exit 3
    fi

    log_step "Redis: install plan"
    for pkg in "${missing[@]}"; do
        log_info "  ${pkg}  $(package_candidate "$pkg" || true)"
    done
    log_info "Service ${REDIS_UNIT} is started and enabled at boot, with Ubuntu's defaults:"
    log_info "listening on 127.0.0.1 and ::1 only, protected mode on, no password. No configuration file is changed."
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] Would run: sudo apt-get update; sudo apt-get install -y ${missing[*]}; then start ${REDIS_UNIT} and verify."
        return 0
    fi
    if ! confirm "Install ${missing[*]}?"; then
        log_warn "Cancelled. Nothing was changed."
        exit 4
    fi
    install_missing_packages "${missing[@]}" || rc=$?
    (( rc == 0 )) || exit "$rc"
    if ! service_is_active "$REDIS_UNIT"; then
        service_enable_now "$REDIS_UNIT" || exit 1
    fi
    redis_verify || exit 1
    log_success "Redis installed. Connect from PHP/Laravel with REDIS_HOST=127.0.0.1 REDIS_PORT=${REDIS_PORT}."
}

main() {
    enable_strict_mode
    load_project_config || exit 3
    read -r -a REDIS_PACKAGE_LIST <<<"${REDIS_PACKAGES:-}"
    if (( ${#REDIS_PACKAGE_LIST[@]} == 0 )); then
        die "REDIS_PACKAGES is empty in ${CONFIG_DIR}/packages.conf" 3
    fi

    case "${1:-}" in
        status) redis_status ;;
        verify) redis_verify || exit 1 ;;
        install) redis_install ;;
        *)
            usage
            exit 3
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
