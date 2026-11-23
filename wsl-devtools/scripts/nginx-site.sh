#!/usr/bin/env bash
# scripts/nginx-site.sh: Nginx sites that use a chosen PHP-FPM version.
#
# Usage: nginx-site.sh list
#        nginx-site.sh create [domain] [document-root] [php-version]
#   Missing create arguments are asked for when run in a terminal.
#
# create only adds new files (sites-available/<domain> and its sites-enabled link).
# It refuses names or server_names that are already used, runs "nginx -t" before
# reloading, and removes only its own two new files if the test fails.
# Exit codes: 0 ok, 1 failed, 3 precondition not met, 4 cancelled.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${SCRIPT_DIR}/../lib/common.sh"
# shellcheck source=../lib/system.sh
source "${SCRIPT_DIR}/../lib/system.sh"
# shellcheck source=../lib/packages.sh
source "${SCRIPT_DIR}/../lib/packages.sh"
# shellcheck source=../lib/services.sh
source "${SCRIPT_DIR}/../lib/services.sh"
# shellcheck source=../lib/nginx.sh
source "${SCRIPT_DIR}/../lib/nginx.sh"
# shellcheck source=../lib/php.sh
source "${SCRIPT_DIR}/../lib/php.sh"

usage() {
    printf 'Usage: %s list | create [domain] [document-root] [php-version]\n' "$(basename "$0")"
}

# Ask for a value on the terminal and print the answer.
ask() {
    local answer
    read -r -p "$1" answer || return 1
    printf '%s' "$answer"
}

site_list() {
    local file names root socket version origin
    log_step "Nginx sites enabled in ${NGINX_DIR}/sites-enabled"
    if [[ ! -d "${NGINX_DIR}/sites-enabled" ]]; then
        log_warn "Nginx is not installed (no ${NGINX_DIR}/sites-enabled)."
        return 0
    fi
    for file in "${NGINX_DIR}/sites-enabled"/*; do
        [[ -e "$file" ]] || continue
        IFS='|' read -r names root socket <<<"$(nginx_site_summary "$file")"
        version="-"
        if [[ "$socket" =~ php([0-9]+\.[0-9]+)-fpm\.sock$ ]]; then
            version="${BASH_REMATCH[1]}"
        fi
        origin=""
        grep -q 'Managed by wsl-devtools' "$file" && origin="  [wsl-devtools]"
        printf '  %-26s server_name: %-28s PHP: %-4s root: %s%s\n' \
            "${file##*/}" "${names:--}" "$version" "$root" "$origin"
    done
}

# Explain why www-data cannot read the document root. Changes nothing.
explain_root_permissions() {
    log_error "The web server user www-data cannot read $1."
    log_error "On Ubuntu 24.04, home folders are private (mode 750) by default."
    log_error "Either place the project under /var/www, or allow access yourself,"
    log_error "for example: chmod o+x \$HOME (this toolkit does not change permissions)."
}

site_create() {
    local domain="${1:-}" root="${2:-}" version="${3:-}"
    local socket available enabled tmp

    if [[ -t 0 ]]; then
        [[ -n "$domain" ]] || domain="$(ask 'Domain (for example myapp.test): ')" || exit 4
        [[ -n "$root" ]] || root="$(ask 'Document root (absolute path, for example /var/www/myapp/public): ')" || exit 4
        [[ -n "$version" ]] || version="$(ask "PHP version (installed: $(php_installed_versions | tr '\n' ' ')): ")" || exit 4
    fi

    if ! is_valid_domain "$domain"; then
        log_error "Invalid domain '${domain}'. Use lowercase letters, digits, dots and hyphens, for example myapp.test."
        exit 3
    fi
    if ! is_safe_path "$root"; then
        log_error "Invalid document root '${root}'. Use an absolute path made of letters, digits, '.', '_', '-' and '/'."
        exit 3
    fi
    if [[ ! -d "$root" ]]; then
        log_error "Document root ${root} does not exist. Create it first."
        exit 3
    fi
    if ! is_valid_version "$version" || ! is_php_installed "$version"; then
        log_error "PHP '${version}' is not installed. Installed: $(php_installed_versions | tr '\n' ' ')"
        exit 3
    fi

    preflight --needs-systemd || exit 3
    if ! is_package_installed nginx; then
        log_error "Nginx is not installed. Run modules/install-nginx.sh install first."
        exit 3
    fi
    socket="$(php_fpm_socket "$version")"
    if ! service_is_active "$(php_fpm_service "$version")" || [[ ! -S "$socket" ]]; then
        log_error "PHP-FPM ${version} is not running (service $(php_fpm_service "$version"), socket ${socket})."
        exit 3
    fi
    if nginx_site_exists "$domain"; then
        log_error "A site named ${domain} already exists in ${NGINX_DIR}/sites-available or sites-enabled. It was not changed."
        exit 3
    fi
    if nginx_server_name_in_use "$domain"; then
        log_error "server_name ${domain} is already used by an enabled site. Nothing was changed."
        exit 3
    fi

    require_sudo || exit 3
    if ! sudo -u www-data test -r "$root" -a -x "$root"; then
        explain_root_permissions "$root"
        exit 3
    fi

    tmp="$(mktemp)"
    render_site_config "$domain" "$root" "$socket" >"$tmp"
    log_step "New site configuration"
    sed 's/^/    /' "$tmp"
    available="${NGINX_DIR}/sites-available/${domain}"
    enabled="${NGINX_DIR}/sites-enabled/${domain}"
    if [[ "${DRY_RUN:-0}" != "1" ]] &&
        ! confirm "Create ${available}, enable it and reload Nginx?"; then
        rm -f "$tmp"
        log_warn "Cancelled. Nothing was changed."
        exit 4
    fi

    if ! run sudo install -m 0644 "$tmp" "$available"; then
        rm -f "$tmp"
        exit 1
    fi
    rm -f "$tmp"
    if ! run sudo ln -s "$available" "$enabled"; then
        run sudo rm -f -- "$available"
        exit 1
    fi
    if ! nginx_config_test; then
        log_warn "Removing the two new site files so the running configuration stays as it was."
        run sudo rm -f -- "$enabled" "$available"
        exit 1
    fi
    service_reload nginx || exit 1

    log_success "Site ${domain} is enabled and uses PHP ${version} (${socket})."
    log_info "Test it from Ubuntu: curl -H 'Host: ${domain}' http://127.0.0.1/"
    log_info "To open it in a Windows browser, add this line to C:\\Windows\\System32\\drivers\\etc\\hosts"
    log_info "(edit as Administrator; this toolkit does not change Windows files):  127.0.0.1 ${domain}"
}

main() {
    enable_strict_mode
    load_project_config || exit 3

    case "${1:-}" in
        list) site_list ;;
        create)
            shift
            site_create "$@"
            ;;
        *)
            usage
            exit 3
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
