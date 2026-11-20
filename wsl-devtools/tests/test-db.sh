#!/usr/bin/env bash
# tests/test-db.sh: tests for lib/database.sh and the MariaDB/MySQL modules.
#
# Makes no system changes. Detection is tested with fixture dpkg output and fixture
# directories. The SQL security report runs against a temporary MariaDB server started as
# the current user in a temporary directory (no networking, own socket), when the MariaDB
# server binaries are present. Module tests put a fake "sudo" first on PATH that records any
# use and run without a terminal. Module tests need Ubuntu 24.04 on WSL2 with systemd.
#
# Usage: bash tests/test-db.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"

# shellcheck source=helpers.sh
source "${TESTS_DIR}/helpers.sh"
# shellcheck source=../lib/common.sh
source "${PROJECT_ROOT}/lib/common.sh"
# shellcheck source=../lib/system.sh
source "${PROJECT_ROOT}/lib/system.sh"
# shellcheck source=../lib/packages.sh
source "${PROJECT_ROOT}/lib/packages.sh"
# shellcheck source=../lib/services.sh
source "${PROJECT_ROOT}/lib/services.sh"
# shellcheck source=../lib/database.sh
source "${PROJECT_ROOT}/lib/database.sh"
load_project_config

echo "Flavour metadata"
assert_equals "MariaDB unit" "mariadb" "$(db_meta mariadb unit)"
assert_equals "MySQL unit" "mysql" "$(db_meta mysql unit)"
assert_equals "MariaDB ports" "3306" "$(db_meta mariadb ports)"
assert_equals "MySQL ports (with X Protocol)" "3306 33060" "$(db_meta mysql ports)"
assert_equals "MariaDB admin tool" "mariadb-admin" "$(db_meta mariadb admin)"
assert_equals "MySQL client" "mysql" "$(db_meta mysql client)"
assert_equals "MariaDB secure-installation tool" "mariadb-secure-installation" "$(db_meta mariadb secure)"
assert_equals "MariaDB packages from config" "mariadb-server mariadb-client" "$(db_meta mariadb packages)"
assert_equals "MySQL packages from config" "mysql-server mysql-client" "$(db_meta mysql packages)"
assert_equals "other flavour of mariadb" "mysql" "$(db_other_flavour mariadb)"
assert_equals "other flavour of mysql" "mariadb" "$(db_other_flavour mysql)"
assert_fail "unknown flavour is refused"           is_db_flavour postgres
assert_fail "unknown key is refused"               db_meta mariadb nothing

echo "Installed flavour (fixture dpkg output)"
DPKG_FIXTURE=""
_db_dpkg_list() { printf '%s' "$DPKG_FIXTURE"; }
DPKG_FIXTURE=$'mariadb-server ii \nmariadb-client ii \nmariadb-server-core ii \nmysql-common ii \nmysql-server un \n'
assert_equals "MariaDB only" "mariadb" "$(db_installed_flavour)"
assert_equals "MariaDB packages listed" "mariadb-server mariadb-client mariadb-server-core" \
    "$(db_installed_packages mariadb | tr '\n' ' ' | sed 's/ $//')"
DPKG_FIXTURE=$'mysql-server ii \nmysql-server-8.0 ii \nmysql-client-core-8.0 ii \nmysql-common ii \nmariadb-common ii \n'
assert_equals "MySQL only (shared mariadb-common ignored)" "mysql" "$(db_installed_flavour)"
DPKG_FIXTURE=$'mysql-common ii \nmariadb-common ii \ngalera-4 ii \n'
assert_equals "only shared packages -> none" "none" "$(db_installed_flavour)"
DPKG_FIXTURE=$'mariadb-client ii \nmysql-server iF \n'
assert_equals "half-configured package counts -> both" "both" "$(db_installed_flavour)"
DPKG_FIXTURE=$'mariadb-server rc \nmariadb-server-core rc \nmysql-common ii \n'
assert_equals "removed with config files left -> none" "none" "$(db_installed_flavour)"
assert_equals "config-files leftovers listed" "mariadb-server mariadb-server-core" \
    "$(db_installed_packages mariadb config-files | tr '\n' ' ' | sed 's/ $//')"
DPKG_FIXTURE=$'mariadb-client-core ii \n'
assert_equals "a MariaDB client alone counts (it conflicts with MySQL's client)" "mariadb" "$(db_installed_flavour)"
DPKG_FIXTURE=""
assert_equals "nothing -> none" "none" "$(db_installed_flavour)"
unset -f _db_dpkg_list
# Restore the real function definition.
unset WSL_DEVTOOLS_DATABASE_LOADED
# shellcheck source=../lib/database.sh
source "${PROJECT_ROOT}/lib/database.sh"

echo "Data directory state"
mkdir -p "${TMP_DIR}/data-empty" "${TMP_DIR}/data-full/mysql" "${TMP_DIR}/data-locked"
touch "${TMP_DIR}/data-full/ibdata1"
chmod 000 "${TMP_DIR}/data-locked"
assert_equals "missing"    "missing"  "$(db_datadir_state "${TMP_DIR}/no-such-dir")"
assert_equals "empty"      "empty"    "$(db_datadir_state "${TMP_DIR}/data-empty")"
assert_equals "has data"   "has-data" "$(db_datadir_state "${TMP_DIR}/data-full")"
if (( EUID != 0 )); then
    assert_equals "unreadable (mode 000)" "unreadable" "$(db_datadir_state "${TMP_DIR}/data-locked")"
fi
chmod 755 "${TMP_DIR}/data-locked"
touch "${TMP_DIR}/data-file"
assert_equals "a file, not a directory" "unreadable" "$(db_datadir_state "${TMP_DIR}/data-file")"

echo "Listener addresses"
for address in 127.0.0.1:3306 127.0.0.53:3306 '[::1]:3306' '[::1%lo]:3306' localhost:3306; do
    assert_ok "${address} is loopback" is_loopback_listener "$address"
done
for address in 0.0.0.0:3306 '*:3306' '[::]:3306' 192.168.1.5:3306 '[fe80::1]:3306'; do
    assert_fail "${address} is not loopback" is_loopback_listener "$address"
done

echo "Security report (fixture SQL answers)"
SQL_ROOT_HOSTS=$'localhost'
SQL_ANON="0"
SQL_TEST="0"
db_sql() {
    case "$2" in
        *"FROM mysql.user WHERE user = 'root'"*) printf '%s\n' "$SQL_ROOT_HOSTS" ;;
        "SHOW CREATE USER 'root'@'localhost'") echo "CREATE USER root@localhost IDENTIFIED VIA unix_socket" ;;
        "SHOW CREATE USER 'root'@'%'") echo "CREATE USER root@% IDENTIFIED BY PASSWORD '*HASH'" ;;
        *"user = ''"*) echo "$SQL_ANON" ;;
        *"schema_name = 'test'"*) echo "$SQL_TEST" ;;
        *) return 1 ;;
    esac
}
report="$(db_security_report mariadb 2>&1)"
assert_ok   "clean server: socket login reported"   grep -q 'root@localhost: socket login' <<<"$report"
assert_fail "clean server: no warnings"             grep -q 'WARN' <<<"$report"
SQL_ROOT_HOSTS=$'localhost\n%'
SQL_ANON="2"
SQL_TEST="1"
report="$(db_security_report mariadb 2>&1)"
assert_ok   "remote root is warned about"           grep -q "root@% can log in from other machines" <<<"$report"
assert_ok   "anonymous accounts are warned about"   grep -q '2 anonymous account' <<<"$report"
assert_ok   "test database is warned about"         grep -q "'test' database exists" <<<"$report"
assert_fail "password hashes are never printed"     grep -q 'HASH' <<<"$report"
# shellcheck disable=SC2317 # stub, called indirectly by db_security_report
db_sql() { return 1; }
assert_ok   "an unreadable account list is only a warning" db_security_report mariadb
unset -f db_sql
unset WSL_DEVTOOLS_DATABASE_LOADED
# shellcheck source=../lib/database.sh
source "${PROJECT_ROOT}/lib/database.sh"

echo "Security report (temporary MariaDB server, real SQL)"
if ! command_exists mariadb-install-db || ! command_exists mariadbd || ! command_exists mariadb; then
    skip "MariaDB server binaries not installed"
elif (( EUID == 0 )); then
    skip "temporary server test does not run as root"
else
    # The data goes on tmpfs when possible: on WSL's virtual disk every fsync of the
    # bootstrap is slow (about 90 s in total), on tmpfs it takes under a second.
    if [[ -d /dev/shm && -w /dev/shm ]]; then
        tmp_db="$(mktemp -d -p /dev/shm wsl-devtools-test.XXXXXX)"
    else
        tmp_db="${TMP_DIR}/db"
    fi
    if mariadb-install-db --no-defaults --datadir="${tmp_db}" --auth-root-authentication-method=socket \
        --auth-root-socket-user="$(id -un)" >"${TMP_DIR}/install-db.log" 2>&1; then
        # A relative socket path inside the data directory keeps it short (sockets have a
        # path length limit). --skip-networking: no TCP port is opened.
        (cd "$tmp_db" && exec mariadbd --no-defaults --datadir=. --socket=s --skip-networking \
            --pid-file=p --log-error=e.log) &
        trap 'kill "$(cat "${tmp_db}/p" 2>/dev/null)" 2>/dev/null; sleep 1; rm -rf "${tmp_db}" "${TMP_DIR}"' EXIT
        for _ in $(seq 1 40); do [[ -S "${tmp_db}/s" ]] && break; sleep 0.25; done
        db_sql() { (cd "$tmp_db" && mariadb --no-defaults --socket=s -u "$(id -un)" -N -B -e "$2"); }
        assert_ok "temporary server answers SQL" db_sql mariadb "SELECT 1"
        # mariadb-install-db without Debian's setup creates anonymous accounts and a test database.
        report="$(db_security_report mariadb 2>&1)"
        assert_ok "real SQL: root@localhost uses socket login" grep -q 'root@localhost: socket login' <<<"$report"
        assert_ok "real SQL: anonymous accounts found"         grep -q 'anonymous account' <<<"$report"
        assert_ok "real SQL: test database found"              grep -q "'test' database exists" <<<"$report"
        db_sql mariadb "CREATE USER 'root'@'%' IDENTIFIED BY 'x'" >/dev/null 2>&1
        report="$(db_security_report mariadb 2>&1)"
        assert_ok "real SQL: remote root found"                grep -q 'root@% can log in from other machines' <<<"$report"
        unset -f db_sql
        unset WSL_DEVTOOLS_DATABASE_LOADED
        # shellcheck source=../lib/database.sh
        source "${PROJECT_ROOT}/lib/database.sh"
    else
        fail "mariadb-install-db failed: $(tail -n 3 "${TMP_DIR}/install-db.log" | tr '\n' ' ')"
        rm -rf "$tmp_db"
    fi
fi

echo "Modules (fake sudo, no terminal)"
read_os_release >/dev/null 2>&1
if [[ "$(detect_wsl_version)" != "2" ]] || ! is_supported_ubuntu || ! is_systemd_pid1; then
    skip "module tests need Ubuntu ${SUPPORTED_UBUNTU_VERSION} on WSL2 with systemd"
else
    mkdir -p "${TMP_DIR}/fakebin"
    SUDO_MARKER="${TMP_DIR}/sudo-was-called"
    # Fake sudo: "sudo -n" fails as if a password were needed; any other use is recorded.
    # shellcheck disable=SC2016 # stub script text: its variables expand when the stub runs
    printf '#!/usr/bin/env bash\n[[ "${1:-}" == "-n" ]] && exit 1\ntouch "%s"\nexit 1\n' \
        "$SUDO_MARKER" >"${TMP_DIR}/fakebin/sudo"
    chmod +x "${TMP_DIR}/fakebin/sudo"
    run_tool() {
        env DRY_RUN="${DRY_RUN:-0}" PATH="${TMP_DIR}/fakebin:${PATH}" "$@" </dev/null >/dev/null 2>&1
    }
    expect_exit() {
        local description="$1" expected="$2"
        shift 2
        run_tool "$@"
        assert_equals "$description" "$expected" "$?"
    }
    MARIADB_MODULE="${PROJECT_ROOT}/modules/install-mariadb.sh"
    MYSQL_MODULE="${PROJECT_ROOT}/modules/install-mysql.sh"
    flavour="$(db_installed_flavour)"
    mariadb_was_active="$(service_state mariadb)"

    for module in "$MARIADB_MODULE" "$MYSQL_MODULE"; do
        expect_exit "$(basename "$module") status -> 0"         0 "$module" status
        expect_exit "$(basename "$module") guide -> 0"          0 "$module" guide
        expect_exit "$(basename "$module") unknown action -> 3" 3 "$module" bogus
        expect_exit "$(basename "$module") no action -> 3"      3 "$module"
    done
    case "$flavour" in
        mariadb)
            expect_exit "install-mariadb install (installed) -> 2"   2 "$MARIADB_MODULE" install
            expect_exit "install-mariadb verify -> 0"                0 "$MARIADB_MODULE" verify
            expect_exit "install-mysql install (MariaDB present) -> 3" 3 "$MYSQL_MODULE" install
            DRY_RUN=1 expect_exit "DRY_RUN=1 install-mysql install -> 3" 3 "$MYSQL_MODULE" install
            expect_exit "install-mysql verify (not installed) -> 1"  1 "$MYSQL_MODULE" verify
            ;;
        mysql)
            expect_exit "install-mysql install (installed) -> 2"     2 "$MYSQL_MODULE" install
            expect_exit "install-mysql verify -> 0"                  0 "$MYSQL_MODULE" verify
            expect_exit "install-mariadb install (MySQL present) -> 3" 3 "$MARIADB_MODULE" install
            expect_exit "install-mariadb verify (not installed) -> 1" 1 "$MARIADB_MODULE" verify
            ;;
        none)
            expect_exit "install-mariadb install (no terminal) -> 4 or 3" \
                "$( [[ "$(db_datadir_state)" == missing || "$(db_datadir_state)" == empty ]] && echo 4 || echo 3 )" \
                "$MARIADB_MODULE" install
            expect_exit "install-mariadb verify (not installed) -> 1" 1 "$MARIADB_MODULE" verify
            ;;
        *)
            skip "both MariaDB and MySQL packages are installed; install tests skipped"
            ;;
    esac
    assert_fail "sudo was never used"                       test -e "$SUDO_MARKER"
    assert_equals "MariaDB service state unchanged" "$mariadb_was_active" "$(service_state mariadb)"
fi

finish
