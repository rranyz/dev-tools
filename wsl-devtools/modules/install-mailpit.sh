#!/usr/bin/env bash
# modules/install-mailpit.sh: Mailpit, a local email testing server (pinned GitHub release).
#
# Usage: install-mailpit.sh status|install|verify|test|php-mail|guide
#   status    binary and version, systemd unit, listeners (read-only)
#   install   download the pinned release (SHA-256 checked), install the binary and a
#             toolkit systemd unit bound to localhost, start it, verify (asks first)
#   verify    service, local-only listeners, web API, SMTP greeting
#   test      send one test message through SMTP and check that it arrived
#   php-mail  opt-in: route PHP mail() of the managed PHP versions to Mailpit with a toolkit
#             drop-in, only where no sendmail_path is set yet (asks first)
#   guide     web UI, SMTP settings for applications, service commands
#
# Never overwrites an existing Mailpit binary or a mailpit.service it did not create.
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

MAILPIT_BIN="${MAILPIT_BIN:-/usr/local/bin/mailpit}"                        # override for tests
MAILPIT_UNIT="mailpit"
MAILPIT_UNIT_FILE="${MAILPIT_UNIT_FILE:-/etc/systemd/system/mailpit.service}" # override for tests
MAILPIT_UNIT_TEMPLATE="${WSL_DEVTOOLS_ROOT}/templates/mailpit.service.tpl"
MAILPIT_MARKER="# Managed by wsl-devtools"
MAILPIT_PHP_DROPIN_NAME="99-wsl-devtools-mailpit.ini"
MAILPIT_TMP_DIR=""

usage() {
    printf 'Usage: %s status|install|verify|test|php-mail|guide\n' "$(basename "$0")"
}

cleanup() {
    if [[ -n "$MAILPIT_TMP_DIR" ]]; then
        rm -rf -- "$MAILPIT_TMP_DIR"
    fi
}

# ---------------------------------------------------------------------------
# Helpers (read-only)
# ---------------------------------------------------------------------------

mailpit_smtp_port() { echo "${MAILPIT_SMTP_ADDRESS##*:}"; }
mailpit_ui_port() { echo "${MAILPIT_UI_ADDRESS##*:}"; }

# The configured addresses must be loopback address:port pairs; the toolkit never binds
# Mailpit beyond this machine.
mailpit_config_ok() {
    local address
    for address in "${MAILPIT_SMTP_ADDRESS:-}" "${MAILPIT_UI_ADDRESS:-}"; do
        if ! is_loopback_listener "$address" || ! is_valid_port "${address##*:}"; then
            log_error "config/versions.conf: '${address}' must be a localhost address with a port, e.g. 127.0.0.1:1025."
            return 1
        fi
    done
    if ! is_release_tag "${MAILPIT_VERSION:-}" || [[ ! "${MAILPIT_SHA256:-}" =~ ^[0-9a-f]{64}$ ]]; then
        log_error "config/versions.conf: MAILPIT_VERSION must look like v1.33.1 and MAILPIT_SHA256 must be 64 hex characters."
        return 1
    fi
}

is_release_tag() {
    [[ "${1:-}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# Print the installed binary's version (v1.33.1), or nothing.
mailpit_installed_version() {
    [[ -x "$MAILPIT_BIN" ]] || return 0
    # "mailpit version" prints the version among other text; only the tag is taken.
    { "$MAILPIT_BIN" version 2>/dev/null || true; } | grep -oE 'v[0-9]+\.[0-9]+\.[0-9]+' | head -n 1 || true
}

# True when the unit file exists and was written by the toolkit.
mailpit_unit_is_ours() {
    [[ -f "$MAILPIT_UNIT_FILE" ]] && head -n 1 "$MAILPIT_UNIT_FILE" | grep -qF "$MAILPIT_MARKER"
}

# Print the unit file for the configured binary, version and addresses.
render_mailpit_unit() {
    local unit
    unit="$(<"$MAILPIT_UNIT_TEMPLATE")"
    unit="${unit//\{\{CREATED\}\}/$(date '+%Y-%m-%d')}"
    unit="${unit//\{\{VERSION\}\}/$MAILPIT_VERSION}"
    unit="${unit//\{\{BINARY\}\}/$MAILPIT_BIN}"
    unit="${unit//\{\{SMTP_ADDRESS\}\}/$MAILPIT_SMTP_ADDRESS}"
    unit="${unit//\{\{UI_ADDRESS\}\}/$MAILPIT_UI_ADDRESS}"
    printf '%s\n' "$unit"
}

# Mailpit's /api/v1/info JSON, or nothing when the API does not answer.
mailpit_api_info() {
    curl -fsS --max-time 5 "http://${MAILPIT_UI_ADDRESS}/api/v1/info" 2>/dev/null || true
}

# Print a value from flat JSON: a string ("Version":"v1.33.1") or a number ("Messages":3).
json_value() {
    local json="$1" key="$2"
    grep -oE "\"${key}\":(\"[^\"]*\"|[0-9]+)" <<<"$json" | head -n 1 | cut -d: -f2- | tr -d '"' || true
}

# Print the first line the SMTP server sends (its greeting), or nothing.
smtp_greeting() {
    local host="${MAILPIT_SMTP_ADDRESS%:*}" port line=""
    port="$(mailpit_smtp_port)"
    # Bash's /dev/tcp opens a TCP connection; the greeting arrives without sending anything.
    (
        exec 3<>"/dev/tcp/${host}/${port}" || exit 0
        IFS= read -r -t 5 line <&3 || true
        printf 'QUIT\r\n' >&3 || true
        printf '%s\n' "${line%$'\r'}"
    ) 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# status / verify
# ---------------------------------------------------------------------------

mailpit_status() {
    local version
    log_step "Mailpit: status"
    if [[ -x "$MAILPIT_BIN" ]]; then
        version="$(mailpit_installed_version)"
        log_info "binary ${MAILPIT_BIN}: ${version:-unknown version} (pinned ${MAILPIT_VERSION})"
    else
        log_info "binary ${MAILPIT_BIN}: not installed (pinned ${MAILPIT_VERSION})"
    fi
    if mailpit_unit_is_ours; then
        log_info "unit ${MAILPIT_UNIT_FILE}: created by the toolkit; service $(service_state "$MAILPIT_UNIT"), $(service_is_enabled "$MAILPIT_UNIT" && echo "starts at boot" || echo "does not start at boot")"
    elif [[ -e "$MAILPIT_UNIT_FILE" ]]; then
        log_info "unit ${MAILPIT_UNIT_FILE}: exists, not created by the toolkit"
    else
        log_info "unit ${MAILPIT_UNIT_FILE}: not present"
    fi
    report_port_listeners "$(mailpit_smtp_port)" "SMTP port $(mailpit_smtp_port)" || true
    report_port_listeners "$(mailpit_ui_port)" "web port $(mailpit_ui_port)" || true
}

mailpit_verify() {
    local failed=0 port info version greeting
    log_step "Mailpit: verify"
    if [[ ! -x "$MAILPIT_BIN" ]]; then
        log_error "${MAILPIT_BIN} is not installed."
        return 1
    fi
    log_success "binary: ${MAILPIT_BIN} $(mailpit_installed_version)"
    if service_is_active "$MAILPIT_UNIT"; then
        log_success "service ${MAILPIT_UNIT}: active"
    else
        log_error "service ${MAILPIT_UNIT}: $(service_state "$MAILPIT_UNIT"). Start it with: sudo systemctl start ${MAILPIT_UNIT}"
        failed=1
    fi
    if ! service_is_enabled "$MAILPIT_UNIT"; then
        log_warn "service ${MAILPIT_UNIT} does not start at boot. Enable it with: sudo systemctl enable ${MAILPIT_UNIT}"
    fi
    for port in "$(mailpit_smtp_port)" "$(mailpit_ui_port)"; do
        if [[ -z "$(port_listen_addresses "$port")" ]]; then
            log_error "nothing listens on port ${port}"
            failed=1
        elif ! report_port_listeners "$port"; then
            log_warn "Mailpit should listen on localhost only. Check ${MAILPIT_UNIT_FILE}."
        fi
    done
    info="$(mailpit_api_info)"
    version="$(json_value "$info" Version)"
    if [[ -n "$version" ]]; then
        log_success "web UI and API answer: http://${MAILPIT_UI_ADDRESS}/ (Mailpit ${version}, $(json_value "$info" Messages) message(s))"
    else
        log_error "the web API does not answer on http://${MAILPIT_UI_ADDRESS}/api/v1/info"
        failed=1
    fi
    greeting="$(smtp_greeting)"
    if [[ "$greeting" == 220* ]]; then
        log_success "SMTP answers on ${MAILPIT_SMTP_ADDRESS}: ${greeting}"
    else
        log_error "SMTP does not answer on ${MAILPIT_SMTP_ADDRESS}${greeting:+ (got: ${greeting})}"
        failed=1
    fi
    return "$failed"
}

# ---------------------------------------------------------------------------
# install
# ---------------------------------------------------------------------------

mailpit_install() {
    local arch version port listeners busy=0 tarball unit_file

    preflight --needs-systemd || exit 3
    mailpit_config_ok || exit 3
    arch="$(dpkg --print-architecture)"
    if [[ "$arch" != "amd64" ]]; then
        log_error "This machine is ${arch}. The toolkit pins only the linux-amd64 Mailpit release."
        exit 3
    fi

    version="$(mailpit_installed_version)"
    if [[ -x "$MAILPIT_BIN" ]] && mailpit_unit_is_ours && [[ "$version" == "$MAILPIT_VERSION" ]]; then
        log_success "Mailpit ${version} is already installed. Nothing to do."
        mailpit_verify || exit 1
        exit 2
    fi

    log_step "Mailpit: checks before installing"
    if [[ -e "$MAILPIT_BIN" ]]; then
        log_error "${MAILPIT_BIN} already exists (${version:-unknown version}; pinned ${MAILPIT_VERSION}). It is not overwritten."
        log_error "Use it as it is, or move it away yourself and rerun. Nothing was changed."
        exit 3
    fi
    if [[ -e "$MAILPIT_UNIT_FILE" ]] && ! mailpit_unit_is_ours; then
        log_error "${MAILPIT_UNIT_FILE} exists and was not created by the toolkit. It is not overwritten. Nothing was changed."
        exit 3
    fi
    for port in "$(mailpit_smtp_port)" "$(mailpit_ui_port)"; do
        listeners="$(port_listen_addresses "$port" | tr '\n' ' ')"
        if [[ -n "$listeners" ]]; then
            log_error "Port ${port} is already in use (${listeners% })."
            busy=1
        fi
    done
    if (( busy )); then
        log_error "Stop that program first (see: sudo ss -ltnp). The toolkit does not stop it. Nothing was changed."
        exit 3
    fi
    log_success "No other Mailpit, ports $(mailpit_smtp_port) and $(mailpit_ui_port) free."

    log_step "Mailpit: install plan"
    log_info "Download: ${MAILPIT_DOWNLOAD_URL}/${MAILPIT_VERSION}/mailpit-linux-amd64.tar.gz (SHA-256 checked)"
    log_info "Install:  ${MAILPIT_BIN}, and the systemd unit ${MAILPIT_UNIT_FILE} (new file)"
    log_info "Service:  SMTP on ${MAILPIT_SMTP_ADDRESS}, web UI on http://${MAILPIT_UI_ADDRESS}/ (this machine only),"
    log_info "          runs as a temporary system user (DynamicUser), messages in /var/lib/mailpit."
    log_info "PHP is not changed. To route PHP mail() to Mailpit later: $(basename "$0") php-mail"
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] Would download and check the release, install the binary and unit, enable --now ${MAILPIT_UNIT}, verify."
        return 0
    fi
    if ! confirm "Install Mailpit ${MAILPIT_VERSION}?"; then
        log_warn "Cancelled. Nothing was changed."
        exit 4
    fi

    MAILPIT_TMP_DIR="$(mktemp -d)"
    trap cleanup EXIT
    tarball="${MAILPIT_TMP_DIR}/mailpit.tar.gz"
    download_checked "${MAILPIT_DOWNLOAD_URL}/${MAILPIT_VERSION}/mailpit-linux-amd64.tar.gz" \
        "$tarball" "$MAILPIT_SHA256" || exit 1
    log_success "Release checksum verified (SHA-256)."
    if ! tar -xzf "$tarball" -C "$MAILPIT_TMP_DIR" mailpit; then
        log_error "The release archive does not contain the mailpit binary."
        exit 1
    fi
    unit_file="${MAILPIT_TMP_DIR}/mailpit.service"
    render_mailpit_unit >"$unit_file"

    require_sudo || exit 3
    run sudo install -m 0755 -o root -g root "${MAILPIT_TMP_DIR}/mailpit" "$MAILPIT_BIN" || exit 1
    run sudo install -m 0644 -o root -g root "$unit_file" "$MAILPIT_UNIT_FILE" || exit 1
    service_daemon_reload || exit 1
    service_enable_now "$MAILPIT_UNIT" || exit 1
    # Give Mailpit a moment to open its ports before checking.
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        [[ -n "$(mailpit_api_info)" ]] && break
        sleep 0.5
    done
    mailpit_verify || exit 1
    log_success "Mailpit installed. Web UI: http://localhost:$(mailpit_ui_port)/  Next: $(basename "$0") test"
}

# ---------------------------------------------------------------------------
# test
# ---------------------------------------------------------------------------

mailpit_test() {
    local before after subject
    if [[ ! -x "$MAILPIT_BIN" ]] || ! service_is_active "$MAILPIT_UNIT"; then
        log_error "Mailpit is not installed or not running. Install it first: $(basename "$0") install"
        exit 3
    fi
    log_step "Mailpit: send a test message"
    before="$(json_value "$(mailpit_api_info)" Messages)"
    subject="wsl-devtools test $(date '+%Y-%m-%d %H:%M:%S')"
    if ! printf 'From: wsl-devtools@localhost\nTo: test@localhost\nSubject: %s\n\nThis message was sent by install-mailpit.sh test.\n' "$subject" |
        "$MAILPIT_BIN" sendmail -S "$MAILPIT_SMTP_ADDRESS" test@localhost; then
        log_error "Sending through ${MAILPIT_SMTP_ADDRESS} failed."
        exit 1
    fi
    for _ in 1 2 3 4 5 6 7 8 9 10; do
        after="$(json_value "$(mailpit_api_info)" Messages)"
        [[ "$after" =~ ^[0-9]+$ && "$before" =~ ^[0-9]+$ ]] && (( after > before )) && break
        sleep 0.3
    done
    if [[ "$after" =~ ^[0-9]+$ && "$before" =~ ^[0-9]+$ ]] && (( after > before )); then
        log_success "Message '${subject}' arrived (${before} -> ${after} messages). See http://localhost:$(mailpit_ui_port)/"
    else
        log_error "The message did not show up in Mailpit (messages: ${before:-?} -> ${after:-?})."
        exit 1
    fi
}

# ---------------------------------------------------------------------------
# php-mail
# ---------------------------------------------------------------------------

mailpit_php_dropin_path() {
    printf '%s/%s/%s/conf.d/%s' "$PHP_ETC_DIR" "$1" "$2" "$MAILPIT_PHP_DROPIN_NAME"
}

mailpit_sendmail_path_value() {
    printf '%s sendmail -S %s' "$MAILPIT_BIN" "$MAILPIT_SMTP_ADDRESS"
}

# Print "file:line" for every active sendmail_path setting of a version and SAPI, excluding
# the toolkit's own drop-in. Usage: php_sendmail_path_settings 8.4 fpm
php_sendmail_path_settings() {
    local dir="${PHP_ETC_DIR}/$1/$2" file
    for file in "${dir}/php.ini" "${dir}/conf.d"/*.ini; do
        [[ -f "$file" && "${file##*/}" != "$MAILPIT_PHP_DROPIN_NAME" ]] || continue
        grep -nE '^[[:space:]]*sendmail_path[[:space:]]*=' "$file" | sed "s|^|${file}:|" | cut -d: -f1,2 || true
    done
}

mailpit_php_dropin_text() {
    printf '; %s: created by modules/install-mailpit.sh php-mail\n' "${MAILPIT_MARKER#\# }"
    printf '; PHP mail() hands messages to Mailpit (web UI: http://%s/). Remove this file to undo.\n' "$MAILPIT_UI_ADDRESS"
    printf 'sendmail_path = "%s"\n' "$(mailpit_sendmail_path_value)"
}

mailpit_php_mail() {
    local version sapi dropin foreign value tmp target failed=0
    local -a versions targets=() fpm_versions=()

    if [[ ! -x "$MAILPIT_BIN" ]]; then
        log_error "Mailpit is not installed. Install it first: $(basename "$0") install"
        exit 3
    fi
    mapfile -t versions < <(php_managed_installed_versions)
    if (( ${#versions[@]} == 0 )); then
        log_error "No PHP version from '${PHP_VERSIONS:-}' is installed. Install PHP first: modules/install-php.sh"
        exit 3
    fi

    log_step "PHP mail() -> Mailpit: plan"
    for version in "${versions[@]}"; do
        for sapi in cli fpm; do
            [[ -d "${PHP_ETC_DIR}/${version}/${sapi}/conf.d" ]] || continue
            dropin="$(mailpit_php_dropin_path "$version" "$sapi")"
            if [[ -f "$dropin" ]]; then
                log_success "PHP ${version} ${sapi}: already uses Mailpit (${dropin})"
                continue
            fi
            foreign="$(php_sendmail_path_settings "$version" "$sapi" | tr '\n' ' ')"
            if [[ -n "$foreign" ]]; then
                log_info "PHP ${version} ${sapi}: sendmail_path is already set in ${foreign% }. Kept as it is."
                continue
            fi
            log_info "PHP ${version} ${sapi}: add ${dropin}"
            targets+=("${version}:${sapi}")
        done
    done
    if (( ${#targets[@]} == 0 )); then
        log_success "Nothing to do."
        exit 2
    fi
    log_info "Each file contains: sendmail_path = \"$(mailpit_sendmail_path_value)\""
    log_info "PHP-FPM is reloaded (after php-fpm -t) where its settings change."
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] Nothing changed."
        return 0
    fi
    if ! confirm "Route PHP mail() to Mailpit for: ${targets[*]}?"; then
        log_warn "Cancelled. Nothing was changed."
        exit 4
    fi

    require_sudo || exit 3
    tmp="$(mktemp)"
    mailpit_php_dropin_text >"$tmp"
    for target in "${targets[@]}"; do
        version="${target%%:*}"
        sapi="${target##*:}"
        run sudo install -m 0644 -o root -g root "$tmp" "$(mailpit_php_dropin_path "$version" "$sapi")" || failed=1
        if [[ "$sapi" == "fpm" ]] && ! is_one_of "$version" "${fpm_versions[@]}"; then
            fpm_versions+=("$version")
        fi
    done
    rm -f -- "$tmp"
    for version in "${fpm_versions[@]}"; do
        if ! php_fpm_reload "$version"; then
            log_error "PHP-FPM ${version} rejected the change; removing the new file."
            run sudo rm -f -- "$(mailpit_php_dropin_path "$version" fpm)"
            failed=1
        fi
    done
    for version in "${versions[@]}"; do
        is_one_of "${version}:cli" "${targets[@]}" || continue
        value="$("/usr/bin/php${version}" -r 'echo ini_get("sendmail_path");' 2>/dev/null)" || value=""
        if [[ "$value" == "$(mailpit_sendmail_path_value)" ]]; then
            log_success "php${version} CLI: sendmail_path = ${value}"
        else
            log_error "php${version} CLI: sendmail_path is '${value}', expected '$(mailpit_sendmail_path_value)'"
            failed=1
        fi
    done
    (( failed == 0 )) || exit 1
    log_success "PHP mail() now goes to Mailpit. Try: php -r 'mail(\"test@localhost\", \"Hello\", \"From PHP\");'"
}

# ---------------------------------------------------------------------------
# guide
# ---------------------------------------------------------------------------

mailpit_guide() {
    cat <<EOF
Mailpit: catching outgoing email during development (nothing below is run by the toolkit)

Ports (this machine only)
  SMTP     ${MAILPIT_SMTP_ADDRESS}   applications send mail here; no login, no TLS
  Web UI   http://${MAILPIT_UI_ADDRESS}/   read the captured messages; also from Windows as
           http://localhost:$(mailpit_ui_port)/ through WSL's localhost forwarding
  API      http://${MAILPIT_UI_ADDRESS}/api/v1/   (interactive documentation at that address)

Application settings (for example Laravel's .env)
  MAIL_MAILER=smtp  MAIL_HOST=127.0.0.1  MAIL_PORT=$(mailpit_smtp_port)
  MAIL_USERNAME=null  MAIL_PASSWORD=null  MAIL_ENCRYPTION=null

PHP mail()
  $(basename "$0") php-mail adds this line for each managed PHP version (cli and fpm),
  only where no sendmail_path is set yet:
      sendmail_path = "$(mailpit_sendmail_path_value)"
  Undo by deleting ${MAILPIT_PHP_DROPIN_NAME} in /etc/php/<version>/{cli,fpm}/conf.d/
  and reloading php<version>-fpm.

Service
  systemctl status ${MAILPIT_UNIT}     sudo systemctl start|stop|restart ${MAILPIT_UNIT}
  journalctl -u ${MAILPIT_UNIT} --since today
  Messages are stored in /var/lib/mailpit/mailpit.db; delete them in the web UI.

Updating
  Change MAILPIT_VERSION and MAILPIT_SHA256 in config/versions.conf. The toolkit does not
  replace an installed binary itself.
EOF
}

main() {
    enable_strict_mode
    load_project_config || exit 3

    case "${1:-}" in
        status) mailpit_status ;;
        verify) mailpit_verify || exit 1 ;;
        install) mailpit_install ;;
        test) mailpit_test ;;
        php-mail) mailpit_php_mail ;;
        guide) mailpit_guide ;;
        *)
            usage
            exit 3
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
