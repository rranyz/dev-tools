# shellcheck shell=bash
# lib/php.sh: PHP helpers (versions, packages, FPM, CLI default, Xdebug settings).
#
# Requires lib/common.sh, lib/system.sh, lib/packages.sh and lib/services.sh.
# Nothing here removes a PHP version or changes the CLI default on its own;
# php_set_cli_default is only called after the user confirms.

if [[ -n "${WSL_DEVTOOLS_PHP_LOADED:-}" ]]; then
    return 0
fi
WSL_DEVTOOLS_PHP_LOADED=1

PHP_ETC_DIR="${PHP_ETC_DIR:-/etc/php}"   # override for tests
PHP_XDEBUG_DROPIN_NAME="99-wsl-devtools-xdebug.ini"
PHP_PPA_SOURCE_PATTERN='ppa\.launchpad(content)?\.net/ondrej/php'

# ---------------------------------------------------------------------------
# Versions and packages
# ---------------------------------------------------------------------------

# Print every installed PHP CLI version (X.Y), managed by the toolkit or not.
php_installed_versions() {
    local bin version
    for bin in /usr/bin/php[0-9]*; do
        version="${bin##*/php}"
        if [[ -x "$bin" && "$version" =~ ^[0-9]+\.[0-9]+$ ]]; then
            printf '%s\n' "$version"
        fi
    done
}

# Print the installed versions that are listed in PHP_VERSIONS.
php_managed_installed_versions() {
    local version
    while IFS= read -r version; do
        if is_supported_php_version "$version"; then
            printf '%s\n' "$version"
        fi
    done < <(php_installed_versions)
}

is_php_installed() {
    [[ -x "/usr/bin/php${1:-}" ]]
}

# True for versions listed in PHP_EOL_VERSIONS.
is_eol_php_version() {
    local -a eol
    read -r -a eol <<<"${PHP_EOL_VERSIONS:-}"
    is_one_of "${1:-}" "${eol[@]}"
}

# Print the extension suffixes for a version: PHP_EXTENSIONS plus PHP<XY>_EXTRA_EXTENSIONS.
php_extensions_for_version() {
    local version="$1" extra_var ext
    local -a common extras
    extra_var="PHP${version//./}_EXTRA_EXTENSIONS"
    read -r -a common <<<"${PHP_EXTENSIONS:-}"
    read -r -a extras <<<"${!extra_var:-}"
    for ext in "${common[@]}" "${extras[@]}"; do
        printf '%s\n' "$ext"
    done
}

# Print the apt packages for a version, e.g. php8.4-cli php8.4-fpm ...
php_packages_for_version() {
    local version="$1" ext
    while IFS= read -r ext; do
        printf 'php%s-%s\n' "$version" "$ext"
    done < <(php_extensions_for_version "$version")
}

# Print the PHP module name ("php -m") for an extension package suffix.
# Prints nothing for packages that are not modules (cli, fpm).
php_module_name() {
    case "$1" in
        cli | fpm) ;;
        mysql) echo "mysqli" ;;
        *) echo "$1" ;;
    esac
}

is_php_ppa_configured() {
    apt_source_configured "$PHP_PPA_SOURCE_PATTERN" "${1:-/etc/apt}"
}

# ---------------------------------------------------------------------------
# PHP-FPM
# ---------------------------------------------------------------------------

php_fpm_service() {
    printf 'php%s-fpm' "$1"
}

php_fpm_socket() {
    printf '/run/php/php%s-fpm.sock' "$1"
}

# Validate a version's FPM configuration (needs root).
php_fpm_config_test() {
    if ! run sudo "php-fpm$1" -t; then
        log_error "php-fpm$1 -t failed. PHP-FPM $1 was not reloaded."
        return 1
    fi
}

# Reload FPM gracefully, only after its configuration test passes.
php_fpm_reload() {
    php_fpm_config_test "$1" || return 1
    service_reload "$(php_fpm_service "$1")"
}

# ---------------------------------------------------------------------------
# CLI default (update-alternatives)
# ---------------------------------------------------------------------------

# Print the binary the "php" command runs, e.g. /usr/bin/php8.4. Empty if none.
php_cli_default() {
    readlink -f /usr/bin/php 2>/dev/null || true
}

# Print "auto" or "manual" for the php alternative. Empty if there is none.
php_cli_mode() {
    local query
    query="$(update-alternatives --query php 2>/dev/null)" || return 0
    awk '/^Status:/ {print $2}' <<<"$query"
}

# Point php, phar and phar.phar at one version. Call only after the user confirmed.
php_set_cli_default() {
    local version="$1" name target

    if ! is_php_installed "$version"; then
        log_error "PHP ${version} is not installed."
        return 1
    fi
    require_sudo || return 1
    for name in php phar phar.phar; do
        target="/usr/bin/${name}${version}"
        if [[ -x "$target" ]] && update-alternatives --query "$name" >/dev/null 2>&1; then
            run sudo update-alternatives --set "$name" "$target" || return 1
        fi
    done
}

# ---------------------------------------------------------------------------
# Xdebug settings
# ---------------------------------------------------------------------------

xdebug_dropin_path() {
    printf '%s/%s/%s/conf.d/%s' "$PHP_ETC_DIR" "$1" "$2" "$PHP_XDEBUG_DROPIN_NAME"
}

# Print ini files (php.ini or conf.d/*.ini) of a version and SAPI that already set
# xdebug.* options, excluding the toolkit's own file.
# Usage: xdebug_foreign_settings 8.4 cli
xdebug_foreign_settings() {
    local dir="${PHP_ETC_DIR}/$1/$2" file
    for file in "${dir}/php.ini" "${dir}/conf.d"/*.ini; do
        [[ -f "$file" && "${file##*/}" != "$PHP_XDEBUG_DROPIN_NAME" ]] || continue
        if grep -qE '^[[:space:]]*xdebug\.[a-z_]+[[:space:]]*=' "$file"; then
            printf '%s\n' "$file"
        fi
    done
}

# Print the SAPIs (cli, fpm) of a version that would get the toolkit's Xdebug file:
# the SAPI exists, has no toolkit file yet and no other xdebug.* settings.
xdebug_sapis_needing_settings() {
    local version="$1" sapi
    for sapi in cli fpm; do
        [[ -d "${PHP_ETC_DIR}/${version}/${sapi}/conf.d" ]] || continue
        [[ -e "$(xdebug_dropin_path "$version" "$sapi")" ]] && continue
        [[ -n "$(xdebug_foreign_settings "$version" "$sapi")" ]] && continue
        printf '%s\n' "$sapi"
    done
}

xdebug_dropin_content() {
    printf '%s\n' \
        "; Managed by wsl-devtools (modules/install-php.sh). Safe to edit or remove." \
        "; With start_with_request = trigger, a debug session starts only when the" \
        "; XDEBUG_TRIGGER cookie, GET/POST parameter or environment variable is set," \
        "; for example: XDEBUG_TRIGGER=1 php script.php" \
        "xdebug.mode = debug" \
        "xdebug.start_with_request = ${XDEBUG_START_WITH_REQUEST:-trigger}" \
        "xdebug.client_host = ${XDEBUG_CLIENT_HOST:-127.0.0.1}" \
        "xdebug.client_port = ${XDEBUG_CLIENT_PORT:-9003}"
}

# Write the toolkit's Xdebug file where it is needed, and report SAPIs that keep
# their existing settings. Reloads FPM (after php-fpm -t) when its file was added.
configure_xdebug() {
    local version="$1" sapi dropin foreign tmp fpm_changed=0
    local -a needed

    mapfile -t needed < <(xdebug_sapis_needing_settings "$version")
    for sapi in cli fpm; do
        [[ -d "${PHP_ETC_DIR}/${version}/${sapi}/conf.d" ]] || continue
        if is_one_of "$sapi" "${needed[@]}"; then
            dropin="$(xdebug_dropin_path "$version" "$sapi")"
            tmp="$(mktemp)"
            xdebug_dropin_content >"$tmp"
            if ! run sudo install -m 0644 "$tmp" "$dropin"; then
                rm -f "$tmp"
                return 1
            fi
            rm -f "$tmp"
            log_success "Xdebug ${version} ${sapi}: settings written to ${dropin}"
            [[ "$sapi" == "fpm" ]] && fpm_changed=1
        elif [[ -e "$(xdebug_dropin_path "$version" "$sapi")" ]]; then
            log_info "Xdebug ${version} ${sapi}: toolkit settings already present."
        else
            foreign="$(xdebug_foreign_settings "$version" "$sapi")"
            log_info "Xdebug ${version} ${sapi}: keeping existing settings in ${foreign//$'\n'/, }"
        fi
    done
    if (( fpm_changed )); then
        php_fpm_reload "$version" || return 1
    fi
}

# Show whether Xdebug is loaded for the CLI and its effective settings.
xdebug_show() {
    local version="$1" bin="/usr/bin/php$1" modules values sapi files
    modules="$(XDEBUG_MODE=off "$bin" -m 2>/dev/null)" || modules=""
    if ! grep -qix xdebug <<<"$modules"; then
        log_warn "Xdebug ${version}: not loaded in the CLI."
        return 1
    fi
    # XDEBUG_MODE=off stops Xdebug from connecting; ini_get still shows the configured values.
    values="$(XDEBUG_MODE=off "$bin" -r 'echo ini_get("xdebug.mode"), " | start_with_request=", ini_get("xdebug.start_with_request"), " | client ", ini_get("xdebug.client_host"), ":", ini_get("xdebug.client_port");' 2>/dev/null)" || values="unknown"
    log_success "Xdebug ${version} CLI: mode=${values}"
    for sapi in cli fpm; do
        files="$(xdebug_foreign_settings "$version" "$sapi")"
        [[ -e "$(xdebug_dropin_path "$version" "$sapi")" ]] && files+=$'\n'"$(xdebug_dropin_path "$version" "$sapi")"
        files="${files#$'\n'}"
        log_info "Xdebug ${version} ${sapi} settings from: ${files:-built-in defaults}"
    done
}
