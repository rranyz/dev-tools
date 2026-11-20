# shellcheck shell=bash
# lib/database.sh: shared logic for the MariaDB and MySQL modules.
#
# Requires lib/common.sh, lib/system.sh, lib/packages.sh and lib/services.sh.
#
# The two flavours, "mariadb" and "mysql", are mutually exclusive (docs/architecture.md §9):
# Ubuntu's packages conflict, and both use port 3306, /run/mysqld/mysqld.sock, /etc/mysql
# and /var/lib/mysql. Installing one never removes the other, existing data is never reused,
# moved or deleted, and nothing here changes a password or an authentication setting.
#
# Installed software is detected by dpkg package names only: on a MariaDB system
# /usr/bin/mysql and mysql.service exist too (as MariaDB's compatibility names).

if [[ -n "${WSL_DEVTOOLS_DATABASE_LOADED:-}" ]]; then
    return 0
fi
WSL_DEVTOOLS_DATABASE_LOADED=1

DB_SOCKET="/run/mysqld/mysqld.sock"
DB_DATADIR="/var/lib/mysql"
DB_ETC="/etc/mysql"
DB_PORT="3306"
MYSQLX_PORT="33060"   # MySQL's X Protocol

# ---------------------------------------------------------------------------
# Flavour metadata
# ---------------------------------------------------------------------------

is_db_flavour() {
    is_one_of "${1:-}" mariadb mysql
}

db_other_flavour() {
    if [[ "$1" == "mariadb" ]]; then echo "mysql"; else echo "mariadb"; fi
}

# Usage: db_meta <flavour> <key>
# Keys: label unit server client admin dump secure ports packages
db_meta() {
    case "${1:-}:${2:-}" in
        mariadb:label) echo "MariaDB" ;;
        mysql:label) echo "MySQL" ;;
        mariadb:unit) echo "mariadb" ;;
        mysql:unit) echo "mysql" ;;
        mariadb:server) echo "mariadb-server" ;;
        mysql:server) echo "mysql-server" ;;
        mariadb:client) echo "mariadb" ;;
        mysql:client) echo "mysql" ;;
        mariadb:admin) echo "mariadb-admin" ;;
        mysql:admin) echo "mysqladmin" ;;
        mariadb:dump) echo "mariadb-dump" ;;
        mysql:dump) echo "mysqldump" ;;
        mariadb:secure) echo "mariadb-secure-installation" ;;
        mysql:secure) echo "mysql_secure_installation" ;;
        mariadb:ports) echo "$DB_PORT" ;;
        mysql:ports) echo "$DB_PORT $MYSQLX_PORT" ;;
        mariadb:packages) echo "${MARIADB_PACKAGES:-}" ;;
        mysql:packages) echo "${MYSQL_PACKAGES:-}" ;;
        *)
            log_error "db_meta: unknown flavour or key '${1:-}:${2:-}'"
            return 2
            ;;
    esac
}

# ---------------------------------------------------------------------------
# Detection (read-only)
# ---------------------------------------------------------------------------

# Package names that belong to a flavour (extended regex). The shared mysql-common and
# mariadb-common, and galera-4 (which does not conflict with MySQL), are not counted.
_db_package_pattern() {
    case "$1" in
        mariadb) echo '^mariadb-(server|client|plugin|backup)' ;;
        mysql) echo '^mysql-(server|client)' ;;
    esac
}

# dpkg's view of database packages: "<name> <status abbreviation>" per line, e.g.
# "mariadb-server ii". Tests override this function with fixture output.
_db_dpkg_list() {
    # shellcheck disable=SC2016 # ${...} are dpkg-query fields
    # dpkg-query exits 1 when a pattern matches no known package, which just means "none".
    dpkg-query -W -f='${Package} ${db:Status-Abbrev}\n' 'mariadb-*' 'mysql-*' 2>/dev/null || true
}

# Print a flavour's packages in a dpkg state, one per line.
#   installed     (default) unpacked or installed, including half-configured
#   config-files  removed, but configuration files left behind ("rc")
# Usage: db_installed_packages <flavour> [installed|config-files]
db_installed_packages() {
    local flavour="$1" state="${2:-installed}" pattern
    pattern="$(_db_package_pattern "$flavour")"
    [[ -n "$pattern" ]] || return 2
    case "$state" in
        installed)
            # Second letter of the status: n = not installed, c = config files only.
            _db_dpkg_list | awk -v p="$pattern" '$1 ~ p && substr($2, 2, 1) !~ /[nc]/ {print $1}'
            ;;
        config-files)
            _db_dpkg_list | awk -v p="$pattern" '$1 ~ p && substr($2, 2, 1) == "c" {print $1}'
            ;;
        *) return 2 ;;
    esac
}

# Print mariadb, mysql, both or none.
db_installed_flavour() {
    local mariadb mysql
    mariadb="$(db_installed_packages mariadb)"
    mysql="$(db_installed_packages mysql)"
    if [[ -n "$mariadb" && -n "$mysql" ]]; then
        echo "both"
    elif [[ -n "$mariadb" ]]; then
        echo "mariadb"
    elif [[ -n "$mysql" ]]; then
        echo "mysql"
    else
        echo "none"
    fi
}

# Print the state of the data directory: missing, empty, has-data or unreadable.
# MySQL creates it with mode 700, so a normal user often cannot look inside.
# shellcheck disable=SC2120 # the directory argument is for test fixtures
db_datadir_state() {
    local dir="${1:-$DB_DATADIR}" entries
    if [[ ! -e "$dir" ]]; then
        echo "missing"
    elif [[ ! -d "$dir" || ! -r "$dir" || ! -x "$dir" ]]; then
        echo "unreadable"
    elif ! entries="$(ls -A -- "$dir" 2>/dev/null)"; then
        echo "unreadable"
    elif [[ -z "$entries" ]]; then
        echo "empty"
    else
        echo "has-data"
    fi
}

# Where /etc/mysql/my.cnf points (the my.cnf alternative), or nothing.
db_mycnf_target() {
    update-alternatives --query my.cnf 2>/dev/null | awk '/^Value:/ {print $2}' || true
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------

# "<n> packages, version <v>: name name ..." for messages. The version is the first
# package's (they share one version within a flavour).
_db_package_summary() {
    local version
    version="$(package_version "$1" 2>/dev/null)" || version="?"
    echo "$# package(s), version ${version}: $*"
}

# Log the listeners of each port. Returns 1 when a port is bound beyond loopback.
_db_report_ports() {
    local flavour="$1" port exposed=0
    for port in $(db_meta "$flavour" ports); do
        report_port_listeners "$port" || exposed=1
    done
    return "$exposed"
}

db_status() {
    local flavour="$1" label other other_label unit
    local -a own other_installed leftovers
    label="$(db_meta "$flavour" label)"
    other="$(db_other_flavour "$flavour")"
    other_label="$(db_meta "$other" label)"
    unit="$(db_meta "$flavour" unit)"

    log_step "${label}: status"
    mapfile -t own < <(db_installed_packages "$flavour")
    mapfile -t other_installed < <(db_installed_packages "$other")
    if (( ${#own[@]} == 0 )); then
        log_info "${label}: not installed"
    else
        log_info "${label} packages: $(_db_package_summary "${own[@]}")"
        # Only ask systemd about the unit when this flavour is installed: on a MariaDB
        # system "mysql" is an alias of mariadb.service.
        log_info "service ${unit}: $(service_state "$unit"), $(service_is_enabled "$unit" && echo "starts at boot" || echo "does not start at boot")"
    fi
    if (( ${#other_installed[@]} > 0 )); then
        log_info "${other_label} is installed: $(_db_package_summary "${other_installed[@]}")"
        log_info "Only one of MariaDB and MySQL can be installed (see docs/architecture.md §9)."
    fi
    mapfile -t leftovers < <(db_installed_packages "$other" config-files; db_installed_packages "$flavour" config-files)
    if (( ${#leftovers[@]} > 0 )); then
        log_warn "Removed packages left configuration files in ${DB_ETC}: ${leftovers[*]}"
    fi
    _db_report_ports "$flavour" || true
    if [[ -S "$DB_SOCKET" ]]; then
        log_info "socket ${DB_SOCKET}: present"
    else
        log_info "socket ${DB_SOCKET}: not present"
    fi
    log_info "data directory ${DB_DATADIR}: $(db_datadir_state)"
    log_info "my.cnf points to: $(db_mycnf_target | sed 's/^$/(not set)/')"
}

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------

# Run one read-only SQL statement as the database root user, over the socket, with sudo.
# Root logs in by socket authentication, so no password is involved. Tests override this.
db_sql() {
    local flavour="$1" sql="$2"
    sudo "$(db_meta "$flavour" client)" --protocol=socket -N -B -e "$sql"
}

# True when the server answers. "ping" exits 0 even when it answers "Access denied" (no
# credentials are given), and 1 when nothing answers; its messages are not needed.
db_ping() {
    local admin="$1"
    shift
    "$admin" --connect-timeout=5 "$@" ping >/dev/null 2>&1
}

# Read-only security report. Findings are warnings with advice; nothing is changed.
db_security_report() {
    local flavour="$1" client hosts host definition count
    client="$(db_meta "$flavour" client)"

    log_step "$(db_meta "$flavour" label): security check (read-only)"
    if ! hosts="$(db_sql "$flavour" "SELECT host FROM mysql.user WHERE user = 'root'")"; then
        log_warn "Could not read the account list as root (sudo ${client}). Skipped."
        return 0
    fi
    while IFS= read -r host; do
        [[ -n "$host" ]] || continue
        # SHOW CREATE USER includes password hashes, so it is only classified, never printed.
        definition="$(db_sql "$flavour" "SHOW CREATE USER 'root'@'${host//\'/\'\'}'")" || definition=""
        if [[ "$definition" == *unix_socket* || "$definition" == *auth_socket* ]]; then
            log_success "root@${host}: socket login (sudo ${client}), no password needed"
        else
            log_info "root@${host}: password login. The toolkit does not change it."
        fi
        if ! is_one_of "$host" localhost 127.0.0.1 ::1; then
            log_warn "root@${host} can log in from other machines. For local development root should be local only (not changed)."
        fi
    done <<<"$hosts"

    count="$(db_sql "$flavour" "SELECT COUNT(*) FROM mysql.user WHERE user = ''")" || count=""
    if [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )); then
        log_warn "${count} anonymous account(s) exist. Remove them yourself if not needed: DROP USER ''@'<host>';"
    elif [[ "$count" == "0" ]]; then
        log_success "no anonymous accounts"
    fi
    count="$(db_sql "$flavour" "SELECT COUNT(*) FROM information_schema.schemata WHERE schema_name = 'test'")" || count=""
    if [[ "$count" =~ ^[0-9]+$ ]] && (( count > 0 )); then
        log_warn "A 'test' database exists, which any account may be able to use. Drop it yourself if not needed."
    elif [[ "$count" == "0" ]]; then
        log_success "no 'test' database"
    fi
}

# Returns 0 when the server is installed, running and answering.
db_verify() {
    local flavour="$1" label server unit admin client version failed=0
    label="$(db_meta "$flavour" label)"
    server="$(db_meta "$flavour" server)"
    unit="$(db_meta "$flavour" unit)"
    admin="$(db_meta "$flavour" admin)"
    client="$(db_meta "$flavour" client)"

    log_step "${label}: verify"
    if ! is_package_installed "$server"; then
        log_error "${server} is not installed."
        return 1
    fi
    log_success "${server}: $(package_version "$server")"

    if service_is_active "$unit"; then
        log_success "service ${unit}: active"
    else
        log_error "service ${unit}: $(service_state "$unit"). Start it with: sudo systemctl start ${unit}"
        failed=1
    fi
    if service_is_enabled "$unit"; then
        log_success "service ${unit}: starts at boot"
    else
        log_warn "service ${unit} does not start at boot. Enable it with: sudo systemctl enable ${unit}"
    fi
    if [[ -S "$DB_SOCKET" ]]; then
        log_success "socket: ${DB_SOCKET}"
    else
        log_error "socket missing: ${DB_SOCKET}"
        failed=1
    fi
    if [[ -z "$(port_listen_addresses "$DB_PORT")" ]]; then
        log_error "nothing listens on port ${DB_PORT}"
        failed=1
    elif ! _db_report_ports "$flavour"; then
        log_warn "Keep bind-address = 127.0.0.1 unless other machines must connect. Not changed by the toolkit."
    fi

    if ! command_exists "$admin"; then
        log_error "${admin} not found."
        return 1
    fi
    if db_ping "$admin" --protocol=socket; then
        log_success "server answers on the socket (${admin} ping)"
    else
        log_error "server does not answer on ${DB_SOCKET}"
        failed=1
    fi
    if db_ping "$admin" --protocol=tcp --host=127.0.0.1 --port="$DB_PORT"; then
        log_success "server answers on 127.0.0.1:${DB_PORT} (${admin} ping)"
    else
        log_error "server does not answer on 127.0.0.1:${DB_PORT}"
        failed=1
    fi

    if ! can_use_sudo_now; then
        log_warn "The SQL check and security report were skipped: they need sudo (sudo ${client}). Run this in a terminal to include them."
        return "$failed"
    fi
    if version="$(db_sql "$flavour" "SELECT VERSION()")"; then
        log_success "SQL as root over the socket: SELECT VERSION() -> ${version}"
        db_security_report "$flavour"
    else
        log_error "SELECT VERSION() as root (sudo ${client}) failed."
        failed=1
    fi
    return "$failed"
}

# ---------------------------------------------------------------------------
# install
# ---------------------------------------------------------------------------

# Exit 3 with an explanation when the other flavour is installed.
_db_refuse_other_flavour() {
    local flavour="$1" other label other_label
    local -a other_installed
    other="$(db_other_flavour "$flavour")"
    label="$(db_meta "$flavour" label)"
    other_label="$(db_meta "$other" label)"
    mapfile -t other_installed < <(db_installed_packages "$other")
    (( ${#other_installed[@]} == 0 )) && return 0

    log_error "${other_label} is installed: $(_db_package_summary "${other_installed[@]}")"
    log_error "${label} and ${other_label} cannot be installed together from Ubuntu's packages: apt would remove ${other_label},"
    log_error "and both use port ${DB_PORT}, ${DB_SOCKET}, ${DB_ETC} and ${DB_DATADIR}. Nothing was changed."
    log_info "Alternatives:"
    log_info "  - keep ${other_label} (modules/install-${other}.sh status);"
    log_info "  - run ${label} in a container on 127.0.0.1:3307 (Docker Engine: modules/install-docker.sh);"
    log_info "  - use a separate WSL distro for projects that need ${label}."
    log_info "Switching servers is a manual step that needs your approval: see modules/install-${flavour}.sh guide"
    exit 3
}

# Exit 3 when the data directory holds data that no installed server owns.
_db_refuse_leftover_data() {
    local state
    state="$(db_datadir_state)"
    case "$state" in
        missing | empty) return 0 ;;
        unreadable)
            log_error "${DB_DATADIR} exists but cannot be inspected without root, and no database server package is installed."
            ;;
        *)
            log_error "${DB_DATADIR} contains data, but no database server package is installed."
            ;;
    esac
    log_error "It is probably left over from an earlier installation. The toolkit never reuses, moves or deletes database data."
    log_error "Back it up and move it away yourself if it is not needed (for example: sudo mv ${DB_DATADIR} ${DB_DATADIR}.old), then rerun."
    exit 3
}

# Exit 3 when another program already listens on the server's ports.
_db_refuse_busy_ports() {
    local flavour="$1" port listeners busy=0
    for port in $(db_meta "$flavour" ports); do
        listeners="$(port_listen_addresses "$port" | tr '\n' ' ')"
        if [[ -n "$listeners" ]]; then
            log_error "Port ${port} is already in use (${listeners% }), probably by another database or a container."
            busy=1
        fi
    done
    if (( busy )); then
        log_error "Stop that program first (see: sudo ss -ltnp). The toolkit does not stop it. Nothing was changed."
        exit 3
    fi
}

db_install() {
    local flavour="$1" label unit client server pkg rc=0
    local -a packages missing leftovers

    label="$(db_meta "$flavour" label)"
    unit="$(db_meta "$flavour" unit)"
    client="$(db_meta "$flavour" client)"
    server="$(db_meta "$flavour" server)"
    read -r -a packages <<<"$(db_meta "$flavour" packages)"

    preflight --needs-systemd || exit 3

    mapfile -t missing < <(missing_packages "${packages[@]}")
    if (( ${#missing[@]} == 0 )); then
        log_success "${label} is already installed. Nothing to do."
        db_verify "$flavour" || exit 1
        exit 2
    fi

    log_step "${label}: checks before installing"
    _db_refuse_other_flavour "$flavour"
    if ! is_package_installed "$server"; then
        _db_refuse_leftover_data
        _db_refuse_busy_ports "$flavour"
    fi
    mapfile -t leftovers < <(db_installed_packages "$(db_other_flavour "$flavour")" config-files)
    if (( ${#leftovers[@]} > 0 )); then
        log_warn "Removed packages left configuration files in ${DB_ETC}: ${leftovers[*]}. They are not changed."
    fi
    log_success "No conflicting database server, no leftover data, ports free."

    # Flavour-specific warning and confirmation (install-mysql.sh defines one).
    if declare -F db_extra_confirm >/dev/null && ! db_extra_confirm; then
        log_warn "Cancelled. Nothing was changed."
        exit 4
    fi

    log_step "${label}: install plan"
    for pkg in "${missing[@]}"; do
        log_info "  ${pkg}  $(package_candidate "$pkg" || true)"
    done
    log_info "Service ${unit} is started and enabled at boot. Ubuntu's default config binds it to 127.0.0.1."
    log_info "The database root user logs in with 'sudo ${client}' (socket authentication). No password is set."
    log_info "Existing configuration files are not changed."
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] Would run: sudo apt-get update; sudo apt-get install -y ${missing[*]}; then start ${unit} and verify."
        return 0
    fi
    if ! confirm "Install ${#missing[@]} package(s) for ${label}?"; then
        log_warn "Cancelled. Nothing was changed."
        exit 4
    fi

    install_missing_packages "${missing[@]}" || rc=$?
    (( rc == 0 )) || exit "$rc"
    if ! service_is_active "$unit"; then
        service_enable_now "$unit" || exit 1
    fi
    db_verify "$flavour" || exit 1
    log_success "${label} installed."
    log_info "Next steps (database users, backups, service commands): modules/install-${flavour}.sh guide"
}

# ---------------------------------------------------------------------------
# guide
# ---------------------------------------------------------------------------

db_guide() {
    local flavour="$1" label unit client dump secure other
    label="$(db_meta "$flavour" label)"
    secure="$(db_meta "$flavour" secure)"
    unit="$(db_meta "$flavour" unit)"
    client="$(db_meta "$flavour" client)"
    dump="$(db_meta "$flavour" dump)"
    other="$(db_other_flavour "$flavour")"

    cat <<EOF
${label}: safe initial configuration (nothing below is run by the toolkit)

Administration
  sudo ${client}
      The database root user logs in through the Unix socket: no password, only for
      users who can use sudo. Keep it that way.
  Do not set a root password, and skip the root-password step of
  ${secure}: with socket login it fails or changes how root logs in.

One database and one user per project
  sudo ${client} <<'SQL'
  CREATE DATABASE myapp CHARACTER SET utf8mb4 COLLATE utf8mb4_unicode_ci;
  CREATE USER 'myapp'@'localhost' IDENTIFIED BY 'choose-a-password';
  GRANT ALL PRIVILEGES ON myapp.* TO 'myapp'@'localhost';
  SQL
  Application settings (for example Laravel's .env):
      DB_HOST=localhost   uses the socket ${DB_SOCKET}
      DB_HOST=127.0.0.1   uses TCP port ${DB_PORT}; if the login is refused, also create
                          'myapp'@'127.0.0.1' with the same password and grant
      DB_PORT=${DB_PORT}  DB_DATABASE=myapp  DB_USERNAME=myapp

Network
  Keep bind-address = 127.0.0.1 (Ubuntu's default). Windows programs reach it as
  localhost:${DB_PORT} through WSL's localhost forwarding. Do not bind 0.0.0.0 unless
  other machines must connect.

Service
  systemctl status ${unit}            sudo systemctl start|stop|restart ${unit}
  systemctl is-enabled ${unit}        journalctl -u ${unit} --since today

Backups
  sudo ${dump} --all-databases --single-transaction --routines --events > all-databases.sql
  sudo ${dump} myapp > myapp.sql      restore: sudo ${client} myapp < myapp.sql

Switching to $(db_meta "${other}" label) (manual, needs your approval; the toolkit never does it)
  1. Back up every database (above) and keep the dump outside ${DB_DATADIR}.
  2. sudo systemctl stop ${unit}; remove the ${label} packages with apt.
  3. sudo mv ${DB_DATADIR} ${DB_DATADIR}.${flavour}-backup
  4. modules/install-${other}.sh install, then import the dump.
EOF
}

# ---------------------------------------------------------------------------
# Entry point for the modules
# ---------------------------------------------------------------------------

db_usage() {
    printf 'Usage: install-%s.sh status|install|verify|guide\n' "$1"
    printf '  status   packages, service, ports, socket, data directory (read-only)\n'
    printf '  install  install if missing and nothing conflicts (asks first), start, verify\n'
    printf '  verify   service, socket, ports, ping; with sudo also SQL and a security report\n'
    printf '  guide    safe initial configuration: users, backups, service commands\n'
}

# Usage: db_main <flavour> <action>
db_main() {
    local flavour="$1"
    shift
    enable_strict_mode
    load_project_config || exit 3
    if ! is_db_flavour "$flavour" || [[ -z "$(db_meta "$flavour" packages)" ]]; then
        die "No package list for '${flavour}' in ${CONFIG_DIR}/packages.conf" 3
    fi

    case "${1:-}" in
        status) db_status "$flavour" ;;
        install) db_install "$flavour" ;;
        verify) db_verify "$flavour" || exit 1 ;;
        guide) db_guide "$flavour" ;;
        *)
            db_usage "$flavour"
            exit 3
            ;;
    esac
}
