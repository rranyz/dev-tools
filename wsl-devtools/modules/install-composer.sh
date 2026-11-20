#!/usr/bin/env bash
# modules/install-composer.sh: Composer, the PHP package manager.
#
# Usage: install-composer.sh status|install|verify
#   status   where Composer is and which version (read-only)
#   install  official installer: download, check its SHA-384 signature, install to
#            COMPOSER_INSTALL_DIR (asks first)
#   verify   composer --version, and Composer run with each installed managed PHP version
#
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
# shellcheck source=../lib/php.sh
source "${MODULE_DIR}/../lib/php.sh"

COMPOSER_TMP_DIR=""

usage() {
    printf 'Usage: %s status|install|verify\n' "$(basename "$0")"
}

cleanup() {
    if [[ -n "$COMPOSER_TMP_DIR" ]]; then
        rm -rf -- "$COMPOSER_TMP_DIR"
    fi
}

# Composer's first output line, run without Xdebug.
composer_version_line() {
    local output
    output="$(XDEBUG_MODE=off "$@" --version 2>&1)" || return 1
    printf '%s' "${output%%$'\n'*}"
}

composer_status() {
    local path
    log_step "Composer: status"
    if ! path="$(command -v composer)"; then
        log_info "composer: not installed"
        return 0
    fi
    log_info "composer: ${path}"
    log_info "version: $(composer_version_line composer || echo "does not run")"
    log_info "runs with the default 'php': $(php_cli_default || true)"
}

composer_verify() {
    local path line version failed=0
    local -a versions
    log_step "Composer: verify"
    if ! path="$(command -v composer)"; then
        log_error "composer: not found on PATH"
        return 1
    fi
    if line="$(composer_version_line composer)"; then
        log_success "composer: ${line} (${path})"
    else
        log_error "composer at ${path} does not run"
        failed=1
    fi
    mapfile -t versions < <(php_managed_installed_versions)
    for version in "${versions[@]}"; do
        if line="$(composer_version_line "/usr/bin/php${version}" "$path")"; then
            log_success "works with PHP ${version}: ${line}"
        else
            log_error "does not run with PHP ${version}"
            failed=1
        fi
    done
    return "$failed"
}

composer_install() {
    local expected actual installer

    preflight || exit 3
    if command_exists composer; then
        log_success "Composer is already installed at $(command -v composer). Nothing to do."
        composer_verify || exit 1
        exit 2
    fi
    if ! command_exists php; then
        log_error "No 'php' command found. Install PHP first: modules/install-php.sh install 8.4"
        exit 3
    fi
    require_commands curl sha384sum || exit 3

    log_step "Installing Composer"
    log_info "Source: ${COMPOSER_INSTALLER_URL} (signature: ${COMPOSER_SIGNATURE_URL})"
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] Would download the installer, check its SHA-384 signature,"
        log_info "[dry-run] run it with $(php_cli_default), and install to ${COMPOSER_INSTALL_DIR}/composer."
        return 0
    fi
    if ! confirm "Download Composer's official installer, check its signature and install ${COMPOSER_INSTALL_DIR}/composer?"; then
        log_warn "Cancelled. Nothing was changed."
        exit 4
    fi

    COMPOSER_TMP_DIR="$(mktemp -d)"
    trap cleanup EXIT
    installer="${COMPOSER_TMP_DIR}/composer-setup.php"

    if ! curl -fsSL --max-time 60 -o "$installer" "$COMPOSER_INSTALLER_URL"; then
        log_error "Downloading the installer failed."
        exit 1
    fi
    if ! expected="$(curl -fsSL --max-time 30 "$COMPOSER_SIGNATURE_URL")"; then
        log_error "Downloading the installer signature failed."
        exit 1
    fi
    actual="$(sha384sum "$installer")"
    actual="${actual%% *}"
    if [[ ! "$expected" =~ ^[0-9a-f]{96}$ || "$actual" != "$expected" ]]; then
        log_error "Installer signature mismatch: the download is corrupt or was changed. Nothing was installed."
        exit 1
    fi
    log_success "Installer signature verified (SHA-384)."

    # Run the installer as the normal user; only the final copy needs sudo.
    if ! XDEBUG_MODE=off php "$installer" --quiet --install-dir="$COMPOSER_TMP_DIR" --filename=composer; then
        log_error "The Composer installer failed. See its messages above."
        exit 1
    fi
    require_sudo || exit 3
    run sudo install -m 0755 "${COMPOSER_TMP_DIR}/composer" "${COMPOSER_INSTALL_DIR}/composer" || exit 1

    composer_verify || exit 1
    log_success "Composer installed."
}

main() {
    enable_strict_mode
    load_project_config || exit 3

    case "${1:-}" in
        status) composer_status ;;
        verify) composer_verify || exit 1 ;;
        install) composer_install ;;
        *)
            usage
            exit 3
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
