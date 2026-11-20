#!/usr/bin/env bash
# modules/install-postgresql.sh: PostgreSQL from Ubuntu's archive (PostgreSQL 16 on 24.04).
#
# Usage: install-postgresql.sh status|install|verify|guide
#   status   packages, clusters, services, listeners, listen_addresses (read-only)
#   install  install if missing and nothing conflicts (asks first), verify
#   verify   clusters online, local-only listeners, pg_isready; with sudo also
#            "SELECT version()" and a read-only check of listen_addresses and pg_hba rules
#   guide    safe initial configuration: per-project roles, backups, service commands
#
# Existing clusters, data (/var/lib/postgresql) and configuration (/etc/postgresql) are never
# changed. Ubuntu's defaults are kept: listen on localhost, "postgres" logs in by peer
# authentication (sudo -u postgres psql), no passwords are set.
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

PG_PORT="5432"
PG_DATA_ROOT="/var/lib/postgresql"
PG_ETC_ROOT="/etc/postgresql"
PG_SOCKET_DIR="/var/run/postgresql"
POSTGRESQL_PACKAGE_LIST=()

usage() {
    printf 'Usage: %s status|install|verify|guide\n' "$(basename "$0")"
}

# Installed PostgreSQL server packages (postgresql-16, postgresql-17, ...), one per line.
pg_server_packages() {
    # shellcheck disable=SC2016 # dpkg-query fields
    # dpkg-query exits 1 when nothing matches, which just means "none".
    { dpkg-query -W -f='${Package} ${db:Status-Abbrev}\n' 'postgresql-*' 2>/dev/null || true; } |
        awk '$1 ~ /^postgresql-[0-9]+$/ && substr($2, 2, 1) !~ /[nc]/ {print $1}'
}

# Clusters as "version name port status data_directory", one per line.
pg_clusters() {
    command_exists pg_lsclusters || return 0
    pg_lsclusters --no-header 2>/dev/null | awk '{print $1, $2, $3, $4, $6}' || true
}

# True when a directory exists and has any entry.
dir_has_content() {
    [[ -d "$1" ]] && [[ -n "$(ls -A -- "$1" 2>/dev/null)" ]]
}

# Print the active listen_addresses line of each cluster's postgresql.conf.
pg_listen_settings() {
    local conf value
    for conf in "${PG_ETC_ROOT}"/*/*/postgresql.conf; do
        [[ -r "$conf" ]] || continue
        value="$(sed -n "s/^[[:space:]]*listen_addresses[[:space:]]*=[[:space:]]*\([^#]*\).*/\1/p" "$conf" | tail -n 1)"
        printf '%s: %s\n' "${conf#"${PG_ETC_ROOT}"/}" "${value:-not set (default: localhost)}"
    done
}

pg_status() {
    local line pkg version name port state data
    local -a servers clusters
    log_step "PostgreSQL: status"
    mapfile -t servers < <(pg_server_packages)
    if (( ${#servers[@]} == 0 )); then
        log_info "PostgreSQL server: not installed"
    else
        for pkg in "${servers[@]}"; do
            log_info "${pkg}: installed ($(package_version "$pkg"))"
        done
    fi
    mapfile -t clusters < <(pg_clusters)
    for line in "${clusters[@]}"; do
        read -r version name port state data <<<"$line"
        log_info "cluster ${version}/${name}: port ${port}, ${state}, data ${data}, service postgresql@${version}-${name}: $(service_state "postgresql@${version}-${name}")"
    done
    while IFS= read -r line; do
        [[ -n "$line" ]] && log_info "listen_addresses in ${line}"
    done < <(pg_listen_settings)
    report_port_listeners "$PG_PORT" || true
    if (( ${#servers[@]} == 0 )) && { dir_has_content "$PG_DATA_ROOT" || dir_has_content "$PG_ETC_ROOT"; }; then
        log_warn "${PG_DATA_ROOT} or ${PG_ETC_ROOT} has content but no server package is installed (left from an earlier install?)."
    fi
}

# Run one read-only SQL statement as the postgres superuser (peer authentication through sudo).
pg_sql() {
    local port="$1" sql="$2"
    # cd / so psql does not warn that postgres cannot read the current directory.
    (cd / && sudo -u postgres psql -X -A -t -q -p "$port" -c "$sql")
}

# Read-only security report for one cluster port. Findings are warnings; nothing is changed.
pg_security_report() {
    local port="$1" value rules line
    if value="$(pg_sql "$port" "SHOW listen_addresses")"; then
        case "$value" in
            localhost | 127.0.0.1 | '127.0.0.1,::1' | '::1,127.0.0.1') log_success "listen_addresses = '${value}' (this machine only)" ;;
            *) log_warn "listen_addresses = '${value}': PostgreSQL may accept connections from other machines (not changed)." ;;
        esac
    else
        log_warn "Could not read listen_addresses."
    fi
    if rules="$(pg_sql "$port" "SELECT line_number || ': ' || type || ' ' || array_to_string(database, ',') || ' ' || array_to_string(user_name, ',') || ' ' || address FROM pg_hba_file_rules WHERE type LIKE 'host%' AND address IS NOT NULL AND address NOT IN ('127.0.0.1', '::1', 'localhost', 'samehost')")"; then
        if [[ -z "$rules" ]]; then
            log_success "pg_hba.conf: TCP rules only for local addresses"
        else
            while IFS= read -r line; do
                log_warn "pg_hba.conf line ${line} allows non-local addresses (not changed)."
            done <<<"$rules"
        fi
    else
        log_warn "Could not read pg_hba_file_rules."
    fi
}

pg_verify() {
    local failed=0 line version name port state data unit result
    local -a clusters
    log_step "PostgreSQL: verify"
    if ! is_package_installed postgresql; then
        log_error "postgresql is not installed."
        return 1
    fi
    log_success "postgresql: $(package_version postgresql)"
    mapfile -t clusters < <(pg_clusters)
    if (( ${#clusters[@]} == 0 )); then
        log_error "No PostgreSQL cluster exists (pg_lsclusters is empty)."
        return 1
    fi
    for line in "${clusters[@]}"; do
        read -r version name port state data <<<"$line"
        unit="postgresql@${version}-${name}"
        if [[ "$state" == online* ]]; then
            log_success "cluster ${version}/${name}: online on port ${port} (data ${data})"
        else
            log_error "cluster ${version}/${name}: ${state}. Start it with: sudo systemctl start ${unit}"
            failed=1
        fi
        if ! service_is_enabled "$unit" && ! service_is_enabled postgresql; then
            log_warn "${unit} does not start at boot. Enable it with: sudo systemctl enable postgresql"
        fi
        if ! report_port_listeners "$port" "port ${port}"; then
            log_warn "Keep listen_addresses = 'localhost' unless other machines must connect. Not changed by the toolkit."
        fi
        if pg_isready -q -h "$PG_SOCKET_DIR" -p "$port" -t 5; then
            log_success "accepts connections on the socket (${PG_SOCKET_DIR}, pg_isready)"
        else
            log_error "does not accept connections on ${PG_SOCKET_DIR} port ${port}"
            failed=1
        fi
        if pg_isready -q -h 127.0.0.1 -p "$port" -t 5; then
            log_success "accepts connections on 127.0.0.1:${port} (pg_isready)"
        else
            log_error "does not accept connections on 127.0.0.1:${port}"
            failed=1
        fi
        if ! can_use_sudo_now; then
            log_warn "The SQL check and security report were skipped: they need sudo (sudo -u postgres psql). Run this in a terminal to include them."
            continue
        fi
        if result="$(pg_sql "$port" "SELECT version()")"; then
            log_success "SQL as postgres over the socket: ${result%% on *}"
            log_step "PostgreSQL ${version}/${name}: security check (read-only)"
            pg_security_report "$port"
        else
            log_error "SELECT version() as postgres failed."
            failed=1
        fi
    done
    return "$failed"
}

pg_install() {
    local -a missing servers
    local rc=0 listeners pkg

    preflight --needs-systemd || exit 3
    mapfile -t missing < <(missing_packages "${POSTGRESQL_PACKAGE_LIST[@]}")
    if (( ${#missing[@]} == 0 )); then
        log_success "PostgreSQL is already installed. Nothing to do."
        pg_verify || exit 1
        exit 2
    fi

    log_step "PostgreSQL: checks before installing"
    mapfile -t servers < <(pg_server_packages)
    if (( ${#servers[@]} > 0 )) && ! is_package_installed postgresql; then
        log_error "Another PostgreSQL server is installed: ${servers[*]}."
        log_error "Installing Ubuntu's postgresql would add a second cluster on another port next to it. Nothing was changed."
        log_info "Keep using the existing server (pg_lsclusters), or ask before mixing versions."
        exit 3
    fi
    if (( ${#servers[@]} == 0 )); then
        if dir_has_content "$PG_DATA_ROOT" || dir_has_content "$PG_ETC_ROOT"; then
            log_error "${PG_DATA_ROOT} or ${PG_ETC_ROOT} already has content, but no PostgreSQL server package is installed."
            log_error "It is probably left from an earlier install. The toolkit never reuses, moves or deletes it. Nothing was changed."
            exit 3
        fi
        listeners="$(port_listen_addresses "$PG_PORT" | tr '\n' ' ')"
        if [[ -n "$listeners" ]]; then
            log_error "Port ${PG_PORT} is already in use (${listeners% }), probably by another PostgreSQL or a container."
            log_error "Stop that program first (see: sudo ss -ltnp). The toolkit does not stop it. Nothing was changed."
            exit 3
        fi
    fi
    log_success "No conflicting PostgreSQL, no leftover data, port ${PG_PORT} free."

    log_step "PostgreSQL: install plan"
    for pkg in "${missing[@]}"; do
        log_info "  ${pkg}  $(package_candidate "$pkg" || true)"
    done
    log_info "Ubuntu creates the cluster 16/main (data in ${PG_DATA_ROOT}/16/main) listening on localhost:${PG_PORT}."
    log_info "The 'postgres' superuser logs in with 'sudo -u postgres psql' (peer authentication). No password is set."
    log_info "No configuration file is changed."
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] Would run: sudo apt-get update; sudo apt-get install -y ${missing[*]}; then verify."
        return 0
    fi
    if ! confirm "Install ${missing[*]}?"; then
        log_warn "Cancelled. Nothing was changed."
        exit 4
    fi
    install_missing_packages "${missing[@]}" || rc=$?
    (( rc == 0 )) || exit "$rc"
    if ! service_is_active postgresql; then
        service_enable_now postgresql || exit 1
    fi
    pg_verify || exit 1
    log_success "PostgreSQL installed. Next steps: $(basename "$0") guide"
}

pg_guide() {
    cat <<EOF
PostgreSQL: safe initial configuration (nothing below is run by the toolkit)

Administration
  sudo -u postgres psql
      The "postgres" superuser logs in by peer authentication: no password, only for
      users who can use sudo. Keep it that way.

One role and one database per project
  sudo -u postgres createuser --pwprompt myapp
  sudo -u postgres createdb --owner=myapp myapp
  psql -h 127.0.0.1 -U myapp myapp        (TCP with a password, as applications connect)
  Application settings (for example Laravel's .env):
      DB_CONNECTION=pgsql  DB_HOST=127.0.0.1  DB_PORT=${PG_PORT}
      DB_DATABASE=myapp    DB_USERNAME=myapp  DB_PASSWORD=...
  PHP needs the pgsql extension, which the toolkit does not install by default:
      sudo apt install php8.4-pgsql        (and/or php7.4-pgsql)

Network
  Keep listen_addresses = 'localhost' (Ubuntu's default) and pg_hba.conf host rules for
  127.0.0.1/32 and ::1/128 only. Windows programs reach it as localhost:${PG_PORT} through
  WSL's localhost forwarding.

Service
  pg_lsclusters                       sudo systemctl start|stop|restart postgresql
  systemctl status postgresql@16-main journalctl -u postgresql@16-main --since today

Backups
  sudo -u postgres pg_dump --format=custom myapp > myapp.dump
  sudo -u postgres pg_restore --dbname=myapp --clean myapp.dump
  sudo -u postgres pg_dumpall > all-databases.sql
EOF
}

main() {
    enable_strict_mode
    load_project_config || exit 3
    read -r -a POSTGRESQL_PACKAGE_LIST <<<"${POSTGRESQL_PACKAGES:-}"
    if (( ${#POSTGRESQL_PACKAGE_LIST[@]} == 0 )); then
        die "POSTGRESQL_PACKAGES is empty in ${CONFIG_DIR}/packages.conf" 3
    fi

    case "${1:-}" in
        status) pg_status ;;
        verify) pg_verify || exit 1 ;;
        install) pg_install ;;
        guide) pg_guide ;;
        *)
            usage
            exit 3
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
