#!/usr/bin/env bash
# modules/install-php.sh: PHP versions from Ondřej Surý's PPA, PHP-FPM, Xdebug, CLI default.
#
# Usage: install-php.sh                      interactive menu (in a terminal)
#        install-php.sh status               PPA, installed versions, FPM, Xdebug, CLI default
#        install-php.sh install <ver>...     e.g. "install 8.4" or "install 8.4 7.4"
#        install-php.sh verify [ver]...      CLI, extensions, FPM service/socket, php-fpm -t
#        install-php.sh set-default <ver>    make <ver> the "php" command (asks first)
#        install-php.sh xdebug [ver]...      install/configure/show Xdebug
#        install-php.sh site [list|create]   Nginx sites per PHP-FPM version (scripts/nginx-site.sh)
#
# Never removes a PHP version and never changes the CLI default without confirmation.
# Exit codes: 0 ok, 1 failed, 2 already installed / nothing to do, 3 precondition not met,
#             4 cancelled.

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${MODULE_DIR}/../lib/common.sh"
# shellcheck source=../lib/system.sh
source "${MODULE_DIR}/../lib/system.sh"
# shellcheck source=../lib/packages.sh
source "${MODULE_DIR}/../lib/packages.sh"
# shellcheck source=../lib/services.sh
source "${MODULE_DIR}/../lib/services.sh"
# shellcheck source=../lib/php.sh
source "${MODULE_DIR}/../lib/php.sh"

SELF="${MODULE_DIR}/install-php.sh"

usage() {
    printf 'Usage: %s [status | install <ver>... | verify [ver]... | set-default <ver> | xdebug [ver]... | site [list|create] | menu]\n' \
        "$(basename "$0")"
    printf 'Supported versions: %s\n' "${PHP_VERSIONS:-}"
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------

php_status() {
    local version label pkg_version upstream socket_state xdebug_state modules
    local -a versions

    log_step "PHP: status"
    if is_php_ppa_configured; then
        log_info "PPA ${PHP_PPA}: configured"
    else
        log_info "PPA ${PHP_PPA}: not configured"
    fi

    mapfile -t versions < <(php_installed_versions)
    if (( ${#versions[@]} == 0 )); then
        log_info "No PHP version is installed."
    fi
    for version in "${versions[@]}"; do
        label="managed"
        is_supported_php_version "$version" || label="not managed by this toolkit"
        pkg_version="-"
        upstream="-"
        if is_package_installed "php${version}-cli"; then
            pkg_version="$(package_version "php${version}-cli")"
            upstream="$(upstream_version "$pkg_version")"
        fi
        socket_state="no socket"
        [[ -S "$(php_fpm_socket "$version")" ]] && socket_state="socket ok"
        modules="$(XDEBUG_MODE=off "/usr/bin/php${version}" -m 2>/dev/null)" || modules=""
        xdebug_state="Xdebug not loaded"
        grep -qix xdebug <<<"$modules" && xdebug_state="Xdebug loaded"
        log_info "PHP ${version} (${label}): package ${pkg_version} (upstream ${upstream}), FPM $(service_state "$(php_fpm_service "$version")"), ${socket_state}, ${xdebug_state}"
    done
    log_info "CLI default: $(php_cli_default || true) (alternative mode: $(php_cli_mode))"
}

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------

# Verify one version. $2 = 1 when root-only checks (php-fpm -t) may run.
php_verify_version() {
    local version="$1" use_sudo="$2" bin="/usr/bin/php$1" output modules ext name failed=0
    local -a missing=() loaded=()

    log_step "PHP ${version}: verify"
    if [[ ! -x "$bin" ]]; then
        log_error "php${version} is not installed."
        return 1
    fi
    if ! output="$(XDEBUG_MODE=off "$bin" -r 'echo PHP_VERSION;' 2>&1)"; then
        log_error "php${version} does not run: ${output}"
        return 1
    fi
    log_success "php${version} CLI: PHP ${output}"

    modules="$(XDEBUG_MODE=off "$bin" -m 2>/dev/null)" || modules=""
    while IFS= read -r ext; do
        name="$(php_module_name "$ext")"
        [[ -n "$name" ]] || continue
        if grep -qix -- "$name" <<<"$modules"; then loaded+=("$name"); else missing+=("$name"); fi
    done < <(php_extensions_for_version "$version")
    if (( ${#missing[@]} > 0 )); then
        log_error "php${version} extensions missing: ${missing[*]}"
        failed=1
    else
        log_success "php${version} extensions loaded: ${loaded[*]}"
    fi

    if service_is_active "$(php_fpm_service "$version")"; then
        log_success "service $(php_fpm_service "$version"): active"
    else
        log_error "service $(php_fpm_service "$version"): $(service_state "$(php_fpm_service "$version")")"
        failed=1
    fi
    if [[ -S "$(php_fpm_socket "$version")" ]]; then
        log_success "FPM socket: $(php_fpm_socket "$version")"
    else
        log_error "FPM socket missing: $(php_fpm_socket "$version")"
        failed=1
    fi
    if (( use_sudo )); then
        php_fpm_config_test "$version" || failed=1
    else
        log_warn "php-fpm${version} -t skipped: it needs sudo. Run this in a terminal to include it."
    fi
    return "$failed"
}

# Verify the given versions, or every installed managed version.
php_verify() {
    local -a versions=("$@")
    local version use_sudo=0 failed=0

    if (( ${#versions[@]} == 0 )); then
        mapfile -t versions < <(php_managed_installed_versions)
    fi
    if (( ${#versions[@]} == 0 )); then
        log_error "No PHP version from '${PHP_VERSIONS}' is installed."
        return 1
    fi
    can_use_sudo_now && use_sudo=1
    for version in "${versions[@]}"; do
        php_verify_version "$version" "$use_sudo" || failed=1
    done
    return "$failed"
}

# ---------------------------------------------------------------------------
# install
# ---------------------------------------------------------------------------

# Warn about an end-of-life version and ask to continue. Returns 1 if the user says no.
confirm_eol_version() {
    log_warn "PHP $1 is end-of-life: it gets no upstream security fixes (PHP 7.4 ended on 28 November 2022)."
    log_warn "Install it only for legacy projects that still need it. Keep it off public networks."
    [[ "${DRY_RUN:-0}" == "1" ]] && return 0
    confirm "Install end-of-life PHP $1 anyway?"
}

# Add the PPA when it is missing (after confirmation). Returns 0, 1, 3 or 4.
ensure_php_ppa() {
    local -a prerequisites missing
    local rc=0

    if is_php_ppa_configured; then
        log_success "PPA ${PHP_PPA}: already configured."
        return 0
    fi
    log_info "PPA ${PHP_PPA}: not configured yet."
    if ! curl -fsSI --max-time 20 "${PHP_PPA_URL}/dists/${OS_CODENAME}/Release" >/dev/null; then
        log_error "The PPA has no packages for Ubuntu ${OS_CODENAME}, or it cannot be reached (${PHP_PPA_URL})."
        return 3
    fi
    log_success "The PPA publishes packages for Ubuntu ${OS_CODENAME}."
    if [[ "${DRY_RUN:-0}" != "1" ]] &&
        ! confirm "Add the apt source ppa:${PHP_PPA} (Ondřej Surý's PHP packages)?"; then
        return 4
    fi

    read -r -a prerequisites <<<"${APT_PREREQUISITE_PACKAGES:-}"
    mapfile -t missing < <(missing_packages "${prerequisites[@]}")
    if (( ${#missing[@]} > 0 )); then
        install_missing_packages "${missing[@]}" || rc=$?
        (( rc == 0 )) || return "$rc"
    fi
    require_sudo || return 3
    run sudo add-apt-repository -y -n "ppa:${PHP_PPA}" || return 1
    apt_update || return 1
}

# Explain how the PHP 7.4 package version relates to upstream 7.4.33.
explain_php74_version() {
    local version upstream
    version="$(package_candidate php7.4-cli)"
    if [[ -z "$version" ]]; then
        log_info "The exact PHP 7.4 package version is known after the PPA is added."
        return 0
    fi
    upstream="$(upstream_version "$version")"
    if [[ "$upstream" == "${PHP74_UPSTREAM_VERSION:-}" ]]; then
        log_info "PHP 7.4 package ${version}: upstream PHP ${upstream} with the PPA's own patch revision (${version##*-})."
        log_info "It is not a pristine upstream ${PHP74_UPSTREAM_VERSION} build."
    else
        log_warn "PHP 7.4 package ${version} is upstream ${upstream}, not ${PHP74_UPSTREAM_VERSION:-?}."
    fi
}

php_install() {
    local -a versions=("$@") missing=() packages=() version_missing=()
    local version pkg previous_default rc=0

    if (( ${#versions[@]} == 0 )); then
        log_error "Name at least one version to install: ${PHP_VERSIONS}"
        exit 3
    fi
    for version in "${versions[@]}"; do
        if ! is_supported_php_version "$version"; then
            log_error "PHP '${version}' is not supported by this toolkit. Supported: ${PHP_VERSIONS}."
            exit 3
        fi
    done

    preflight --needs-systemd || exit 3
    if ! command_exists curl; then
        log_error "curl is missing. Run modules/install-base.sh install first."
        exit 3
    fi

    for version in "${versions[@]}"; do
        if is_eol_php_version "$version" && ! confirm_eol_version "$version"; then
            log_warn "Cancelled. Nothing was changed."
            exit 4
        fi
    done

    log_step "PHP: package source"
    ensure_php_ppa || rc=$?
    (( rc == 0 )) || exit "$rc"

    for version in "${versions[@]}"; do
        mapfile -t packages < <(php_packages_for_version "$version")
        mapfile -t version_missing < <(missing_packages "${packages[@]}")
        missing+=("${version_missing[@]}")
    done
    if (( ${#missing[@]} == 0 )); then
        log_success "PHP ${versions[*]}: all packages are already installed. Nothing to do."
        php_verify "${versions[@]}" || exit 1
        exit 2
    fi

    log_step "PHP: install plan"
    for pkg in "${missing[@]}"; do
        log_info "  ${pkg}  $(package_candidate "$pkg" || true)"
    done
    is_one_of 7.4 "${versions[@]}" && explain_php74_version
    log_info "Xdebug settings (start_with_request=${XDEBUG_START_WITH_REQUEST}) are added only where no xdebug.* settings exist."
    log_info "Existing PHP versions and the default 'php' command are not changed."

    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] Would run: sudo apt-get update; sudo apt-get install -y ${missing[*]}"
        log_info "[dry-run] Then: start php<ver>-fpm if needed, add Xdebug settings, verify."
        return 0
    fi
    if ! confirm "Install ${#missing[@]} package(s) for PHP ${versions[*]}?"; then
        log_warn "Cancelled. Nothing was changed."
        exit 4
    fi

    previous_default="$(php_cli_default)"
    install_missing_packages "${missing[@]}" || rc=$?
    (( rc == 0 )) || exit "$rc"
    restore_cli_default "$previous_default"

    for version in "${versions[@]}"; do
        if ! service_is_active "$(php_fpm_service "$version")"; then
            service_enable_now "$(php_fpm_service "$version")" || exit 1
        fi
        configure_xdebug "$version" || exit 1
    done
    php_verify "${versions[@]}" || exit 1
    log_success "PHP ${versions[*]} installed."
}

# apt may repoint /usr/bin/php when a version is installed. Put back the user's choice.
restore_cli_default() {
    local previous="$1" current previous_version
    current="$(php_cli_default)"
    [[ -n "$previous" && "$current" != "$previous" ]] || return 0
    previous_version="${previous##*/php}"
    log_warn "Installing changed the 'php' command from ${previous} to ${current}."
    if is_valid_version "$previous_version" && php_set_cli_default "$previous_version"; then
        log_success "Restored the 'php' command to ${previous}."
    else
        log_warn "Could not restore it automatically. Use: $(basename "$0") set-default <version>"
    fi
}

# ---------------------------------------------------------------------------
# set-default
# ---------------------------------------------------------------------------

php_set_default() {
    local version="${1:-}"
    local -a installed
    mapfile -t installed < <(php_installed_versions)

    if ! is_valid_version "$version" || ! is_php_installed "$version"; then
        log_error "PHP '${version}' is not installed. Installed versions: ${installed[*]:-none}"
        exit 3
    fi
    log_info "Current 'php' command: $(php_cli_default) (alternative mode: $(php_cli_mode))"
    if [[ "$(php_cli_default)" == "/usr/bin/php${version}" ]]; then
        log_success "PHP ${version} is already the default. Nothing to do."
        exit 2
    fi
    preflight || exit 3
    if [[ "${DRY_RUN:-0}" != "1" ]] &&
        ! confirm "Make PHP ${version} the default 'php' (and phar) command? This affects every tool and project that runs 'php'."; then
        log_warn "Cancelled. The default was not changed."
        exit 4
    fi
    php_set_cli_default "$version" || exit 1
    [[ "${DRY_RUN:-0}" == "1" ]] && return 0
    log_success "'php' now runs PHP $(XDEBUG_MODE=off php -r 'echo PHP_VERSION;')"
}

# ---------------------------------------------------------------------------
# xdebug
# ---------------------------------------------------------------------------

php_xdebug() {
    local -a versions=("$@") missing=() needs_settings=() sapis
    local version rc=0 failed=0

    if (( ${#versions[@]} == 0 )); then
        mapfile -t versions < <(php_managed_installed_versions)
    fi
    if (( ${#versions[@]} == 0 )); then
        log_error "No PHP version from '${PHP_VERSIONS}' is installed. Install PHP first."
        exit 3
    fi
    for version in "${versions[@]}"; do
        if ! is_php_installed "$version"; then
            log_error "PHP ${version} is not installed."
            exit 3
        fi
    done

    preflight --needs-systemd || exit 3
    for version in "${versions[@]}"; do
        is_package_installed "php${version}-xdebug" || missing+=("php${version}-xdebug")
        mapfile -t sapis < <(xdebug_sapis_needing_settings "$version")
        (( ${#sapis[@]} > 0 )) && needs_settings+=("${version} (${sapis[*]})")
    done

    if (( ${#missing[@]} + ${#needs_settings[@]} > 0 )); then
        log_step "Xdebug: changes"
        (( ${#missing[@]} > 0 )) && log_info "Install: ${missing[*]}"
        (( ${#needs_settings[@]} > 0 )) && log_info "Add toolkit settings (start_with_request=${XDEBUG_START_WITH_REQUEST}) for: ${needs_settings[*]}"
        if [[ "${DRY_RUN:-0}" == "1" ]]; then
            log_info "[dry-run] Nothing changed."
            return 0
        fi
        if ! confirm "Apply these Xdebug changes? PHP-FPM is reloaded if its settings change."; then
            log_warn "Cancelled. Nothing was changed."
            exit 4
        fi
        if (( ${#missing[@]} > 0 )); then
            install_missing_packages "${missing[@]}" || rc=$?
            (( rc == 0 )) || exit "$rc"
        fi
        for version in "${versions[@]}"; do
            configure_xdebug "$version" || exit 1
        done
    fi

    log_step "Xdebug: verify"
    for version in "${versions[@]}"; do
        xdebug_show "$version" || failed=1
    done
    (( failed == 0 )) || exit 1
    log_info "Where start_with_request is 'trigger': debug a request with ?XDEBUG_TRIGGER=1 (or the XDEBUG_TRIGGER cookie), and the CLI with XDEBUG_TRIGGER=1 php script.php"
}

# ---------------------------------------------------------------------------
# menu
# ---------------------------------------------------------------------------

# Run an action of this module as a child process and report how it ended.
menu_run() {
    local rc=0
    bash "$SELF" "$@" || rc=$?
    log_info "Result: $(exit_code_meaning "$rc")"
}

php_menu() {
    local choice version
    while true; do
        printf '\nPHP menu\n'
        printf '  1) Install PHP 7.4 (end-of-life)\n'
        printf '  2) Install PHP 8.4\n'
        printf '  3) Install both\n'
        printf '  4) Switch default PHP CLI version\n'
        printf '  5) Configure Nginx PHP-FPM (sites)\n'
        printf '  6) Install or verify Xdebug\n'
        printf '  7) Check installed PHP versions\n'
        printf '  8) Back to main menu\n'
        read -r -p "Choose 1-8: " choice || return 0
        case "$choice" in
            1) menu_run install 7.4 ;;
            2) menu_run install 8.4 ;;
            3) menu_run install 8.4 7.4 ;;
            4)
                read -r -p "Make which version the default? Installed: $(php_installed_versions | tr '\n' ' '): " version || continue
                menu_run set-default "$version"
                ;;
            5)
                read -r -p "l) list sites  c) create a site: " choice || continue
                case "$choice" in
                    l | L) menu_run site list ;;
                    c | C) menu_run site create ;;
                    *) log_warn "Please enter l or c." ;;
                esac
                ;;
            6) menu_run xdebug ;;
            7) menu_run status ;;
            8) return 0 ;;
            *) log_warn "Please enter a number from 1 to 8." ;;
        esac
    done
}

main() {
    local action

    enable_strict_mode
    load_project_config || exit 3

    action="${1:-}"
    if (( $# > 0 )); then
        shift
    fi
    if [[ -z "$action" ]]; then
        if [[ -t 0 ]]; then
            action="menu"
        else
            usage
            exit 3
        fi
    fi

    case "$action" in
        status) php_status ;;
        install) php_install "$@" ;;
        verify) php_verify "$@" || exit 1 ;;
        set-default) php_set_default "${1:-}" ;;
        xdebug) php_xdebug "$@" ;;
        site) exec bash "${WSL_DEVTOOLS_ROOT}/scripts/nginx-site.sh" "${@:-create}" ;;
        menu) php_menu ;;
        *)
            usage
            exit 3
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
