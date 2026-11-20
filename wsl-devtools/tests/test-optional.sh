#!/usr/bin/env bash
# tests/test-optional.sh: tests for the optional modules (Redis, PostgreSQL, Mailpit, Docker),
# lib/docker.sh and the shared helpers they use.
#
# Makes no system changes. Helpers are tested with fixture files and directories. Module tests
# put a fake "sudo" first on PATH that records any use, and run without a terminal, so every
# confirmation is answered "no". Module tests need Ubuntu 24.04 on WSL2 with systemd. The
# Docker signing-key check needs the network and is skipped without it.
#
# Usage: bash tests/test-optional.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"

# shellcheck source=helpers.sh
source "${TESTS_DIR}/helpers.sh"
# The modules are sourced for their helper functions; main only runs when executed.
# shellcheck source=../modules/install-mailpit.sh
source "${PROJECT_ROOT}/modules/install-mailpit.sh"
# shellcheck source=../modules/install-postgresql.sh
source "${PROJECT_ROOT}/modules/install-postgresql.sh"
# shellcheck source=../lib/docker.sh
source "${PROJECT_ROOT}/lib/docker.sh"
load_project_config

echo "Shared helpers"
mkdir -p "${TMP_DIR}/mirror"
printf 'payload\n' >"${TMP_DIR}/mirror/file.bin"
payload_sum="$(sha256_of "${TMP_DIR}/mirror/file.bin")"
assert_ok   "download_checked: matching checksum"  download_checked "file://${TMP_DIR}/mirror/file.bin" "${TMP_DIR}/dl1" "$payload_sum"
assert_ok   "download_checked: file written"       cmp -s "${TMP_DIR}/mirror/file.bin" "${TMP_DIR}/dl1"
assert_fail "download_checked: wrong checksum"     download_checked "file://${TMP_DIR}/mirror/file.bin" "${TMP_DIR}/dl2" "$(printf '0%.0s' {1..64})"
assert_fail "download_checked: missing file"       download_checked "file://${TMP_DIR}/mirror/nope" "${TMP_DIR}/dl3" "$payload_sum"
assert_ok   "127.0.0.1:6379 is loopback"            is_loopback_listener 127.0.0.1:6379
assert_fail "0.0.0.0:6379 is not loopback"          is_loopback_listener 0.0.0.0:6379
free_port=""
for candidate in 59997 59998 59999; do
    if [[ -z "$(port_listen_addresses "$candidate")" ]]; then free_port="$candidate"; break; fi
done
if [[ -n "$free_port" ]]; then
    assert_equals "a free port has no listeners" "" "$(port_listen_addresses "$free_port")"
    assert_ok "report_port_listeners on a free port -> 0" report_port_listeners "$free_port"
fi

echo "Docker detection (fixture paths)"
fx="${TMP_DIR}/docker-fs"
mkdir -p "$fx"
DOCKER_FS_ROOT="$fx"
FAKE_DOCKER_CLI=""
FAKE_DOCKER_EXE=""
docker_cli_path() { printf '%s' "$FAKE_DOCKER_CLI"; }
docker_exe_path() { printf '%s' "$FAKE_DOCKER_EXE"; }
assert_equals "empty system -> no integration" "" "$(docker_desktop_integration)"
mkdir -p "$fx/mnt/wsl/docker-desktop"
assert_ok "/mnt/wsl/docker-desktop -> integration" grep -q 'docker-desktop exists' <<<"$(docker_desktop_integration)"
rmdir "$fx/mnt/wsl/docker-desktop"
mkdir -p "$fx/var/run"
ln -s /mnt/wsl/docker-desktop/shared-sockets/guest-services/docker.proxy.sock "$fx/var/run/docker.sock"
assert_ok "socket symlink into /mnt/wsl -> integration" grep -q 'points to Docker Desktop' <<<"$(docker_desktop_integration)"
rm "$fx/var/run/docker.sock"
mkdir -p "${TMP_DIR}/elsewhere/mnt/wsl/docker-desktop/cli-tools/usr/bin" "${TMP_DIR}/bin"
touch "${TMP_DIR}/elsewhere/mnt/wsl/docker-desktop/cli-tools/usr/bin/docker"
ln -s "${TMP_DIR}/elsewhere/mnt/wsl/docker-desktop/cli-tools/usr/bin/docker" "${TMP_DIR}/bin/docker"
FAKE_DOCKER_CLI="${TMP_DIR}/bin/docker"
assert_ok "docker CLI from Docker Desktop -> integration" grep -q 'belongs to Docker Desktop' <<<"$(docker_desktop_integration)"
FAKE_DOCKER_CLI="/usr/bin/docker"
assert_equals "a normal docker CLI -> no integration" "" "$(docker_desktop_integration)"
FAKE_DOCKER_CLI=""

FIXTURE_PACKAGES=""
is_package_installed() { [[ " ${FIXTURE_PACKAGES} " == *" ${1:-} "* ]]; }
command_exists_real="$(declare -f command_exists)"
command_exists() { [[ "${1:-}" != "snap" ]] && command -v "${1:-}" >/dev/null 2>&1; }
assert_equals "no conflicting packages" "" "$(docker_conflicting_packages)"
FIXTURE_PACKAGES="docker.io"
assert_equals "Ubuntu's docker.io conflicts" "docker.io" "$(docker_conflicting_packages)"
FIXTURE_PACKAGES="containerd runc"
assert_equals "Ubuntu's containerd and runc conflict" "containerd runc" "$(docker_conflicting_packages | tr '\n' ' ' | sed 's/ $//')"
FIXTURE_PACKAGES="docker-ce docker-ce-cli containerd.io"
assert_equals "Docker's own packages do not count as conflicts" "" "$(docker_conflicting_packages)"
unset -f is_package_installed
eval "$command_exists_real"
unset WSL_DEVTOOLS_PACKAGES_LOADED
# shellcheck source=../lib/packages.sh
source "${PROJECT_ROOT}/lib/packages.sh"

sources_text="$(docker_sources_text noble amd64)"
assert_ok "apt source uses the keyring"   grep -qx "Signed-By: ${DOCKER_KEYRING}" <<<"$sources_text"
assert_ok "apt source suite noble"        grep -qx "Suites: noble" <<<"$sources_text"
assert_ok "apt source URL from config"    grep -qx "URIs: ${DOCKER_APT_URL}" <<<"$sources_text"
docker_daemon_json_text >"${TMP_DIR}/daemon.json"
assert_ok "daemon.json is valid JSON"     python3 -I -c 'import json,sys; json.load(open(sys.argv[1]))' "${TMP_DIR}/daemon.json"
assert_equals "daemon.json ip" "127.0.0.1" "$(docker_daemon_ip "${TMP_DIR}/daemon.json")"
printf '{\n  "log-driver": "json-file",\n  "ip" : "0.0.0.0"\n}\n' >"${TMP_DIR}/daemon-other.json"
assert_equals "existing daemon.json ip is read" "0.0.0.0" "$(docker_daemon_ip "${TMP_DIR}/daemon-other.json")"
printf '{ "log-driver": "json-file" }\n' >"${TMP_DIR}/daemon-none.json"
assert_equals "daemon.json without ip" "" "$(docker_daemon_ip "${TMP_DIR}/daemon-none.json")"
printf 'not a key\n' >"${TMP_DIR}/not-a-key.asc"
assert_equals "a non-key file has no fingerprint" "" "$(key_fingerprint "${TMP_DIR}/not-a-key.asc" 2>/dev/null)"
if curl -fsSL --max-time 20 -o "${TMP_DIR}/docker.asc" "${DOCKER_APT_URL}/gpg" 2>/dev/null; then
    assert_equals "Docker's published key has the pinned fingerprint" "$DOCKER_GPG_FINGERPRINT" \
        "$(key_fingerprint "${TMP_DIR}/docker.asc")"
else
    skip "Docker key check (download.docker.com not reachable)"
fi
DOCKER_FS_ROOT=""
unset -f docker_cli_path docker_exe_path
unset WSL_DEVTOOLS_DOCKER_LOADED
# shellcheck source=../lib/docker.sh
source "${PROJECT_ROOT}/lib/docker.sh"

echo "Mailpit unit and helpers"
unit="$(render_mailpit_unit)"
assert_fail "no placeholders left"            grep -q '{{' <<<"$unit"
assert_ok   "managed header on line 1"        grep -q "^${MAILPIT_MARKER}" <<<"$(head -n 1 <<<"$unit")"
assert_ok   "SMTP bound to 127.0.0.1:1025"    grep -q -- '--smtp 127.0.0.1:1025' <<<"$unit"
assert_ok   "web UI bound to 127.0.0.1:8025"  grep -q -- '--listen 127.0.0.1:8025' <<<"$unit"
assert_ok   "runs as a dynamic user"          grep -qx 'DynamicUser=yes' <<<"$unit"
assert_ok   "no update check"                 grep -q -- '--disable-version-check' <<<"$unit"
assert_ok   "configured addresses accepted"   mailpit_config_ok
saved_smtp="$MAILPIT_SMTP_ADDRESS"
MAILPIT_SMTP_ADDRESS="0.0.0.0:1025"
assert_fail "a non-local SMTP address is refused" mailpit_config_ok
MAILPIT_SMTP_ADDRESS="127.0.0.1:99999"
assert_fail "an invalid port is refused"      mailpit_config_ok
MAILPIT_SMTP_ADDRESS="$saved_smtp"
printf '%s\n' "$unit" >"${TMP_DIR}/mailpit-ours.service"
printf '[Unit]\nDescription=someone else\n' >"${TMP_DIR}/mailpit-foreign.service"
MAILPIT_UNIT_FILE="${TMP_DIR}/mailpit-ours.service"
assert_ok   "toolkit unit is recognised"      mailpit_unit_is_ours
MAILPIT_UNIT_FILE="${TMP_DIR}/mailpit-foreign.service"
assert_fail "foreign unit is not ours"        mailpit_unit_is_ours
MAILPIT_UNIT_FILE="${TMP_DIR}/missing.service"
assert_fail "missing unit is not ours"        mailpit_unit_is_ours
info='{"Database":"/var/lib/mailpit/mailpit.db","Version":"v1.33.1","LatestVersion":"","Messages":12,"Unread":3}'
assert_equals "JSON string value"  "v1.33.1" "$(json_value "$info" Version)"
assert_equals "JSON number value"  "12"      "$(json_value "$info" Messages)"
assert_equals "missing JSON key"   ""        "$(json_value "$info" Nope)"

echo "PHP sendmail_path detection (fixture /etc/php)"
PHP_ETC_DIR="${TMP_DIR}/etc-php"
mkdir -p "$PHP_ETC_DIR/8.4/cli/conf.d" "$PHP_ETC_DIR/8.4/fpm/conf.d"
printf ';sendmail_path =\n' >"$PHP_ETC_DIR/8.4/cli/php.ini"
printf '[mail function]\nsendmail_path = /usr/sbin/sendmail -t -i\n' >"$PHP_ETC_DIR/8.4/fpm/php.ini"
printf 'sendmail_path = "x"\n' >"$PHP_ETC_DIR/8.4/cli/conf.d/${MAILPIT_PHP_DROPIN_NAME}"
assert_equals "commented line and own drop-in are ignored" "" "$(php_sendmail_path_settings 8.4 cli)"
assert_equals "an active setting is found with its line" "$PHP_ETC_DIR/8.4/fpm/php.ini:2" "$(php_sendmail_path_settings 8.4 fpm)"
assert_equals "drop-in path" "$PHP_ETC_DIR/8.4/fpm/conf.d/${MAILPIT_PHP_DROPIN_NAME}" "$(mailpit_php_dropin_path 8.4 fpm)"
assert_ok "drop-in sets sendmail_path to Mailpit" grep -qx "sendmail_path = \"${MAILPIT_BIN} sendmail -S 127.0.0.1:1025\"" <<<"$(mailpit_php_dropin_text)"
PHP_ETC_DIR="/etc/php"

echo "PostgreSQL helpers (fixture /etc/postgresql)"
PG_ETC_ROOT="${TMP_DIR}/etc-postgresql"
mkdir -p "$PG_ETC_ROOT/16/main" "$PG_ETC_ROOT/15/other"
printf "#listen_addresses = 'localhost'\n" >"$PG_ETC_ROOT/16/main/postgresql.conf"
printf "listen_addresses = '*'        # all\n" >"$PG_ETC_ROOT/15/other/postgresql.conf"
settings="$(pg_listen_settings)"
assert_ok "commented setting -> default localhost" grep -q '^16/main/postgresql.conf: not set (default: localhost)$' <<<"$settings"
assert_ok "explicit setting is shown"              grep -q "^15/other/postgresql.conf: '\*'" <<<"$settings"
mkdir -p "${TMP_DIR}/pg-empty" "${TMP_DIR}/pg-full/16"
assert_fail "empty directory has no content"       dir_has_content "${TMP_DIR}/pg-empty"
assert_ok   "directory with a cluster has content" dir_has_content "${TMP_DIR}/pg-full"
assert_fail "missing directory has no content"     dir_has_content "${TMP_DIR}/pg-missing"
PG_ETC_ROOT="/etc/postgresql"

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
    for name in redis postgresql mailpit docker; do
        module="${PROJECT_ROOT}/modules/install-${name}.sh"
        expect_exit "install-${name} status -> 0"         0 "$module" status
        expect_exit "install-${name} unknown action -> 3" 3 "$module" bogus
        expect_exit "install-${name} no action -> 3"      3 "$module"
    done
    if ! is_package_installed redis-server && [[ -z "$(port_listen_addresses 6379)" ]]; then
        expect_exit "install-redis verify (not installed) -> 1"     1 "${PROJECT_ROOT}/modules/install-redis.sh" verify
        expect_exit "install-redis install (no terminal) -> 4"      4 "${PROJECT_ROOT}/modules/install-redis.sh" install
        DRY_RUN=1 expect_exit "DRY_RUN=1 install-redis install -> 0" 0 "${PROJECT_ROOT}/modules/install-redis.sh" install
    else
        skip "Redis is installed or port 6379 is busy: install-path tests skipped"
    fi
    if [[ -z "$(pg_server_packages)" ]] && [[ -z "$(port_listen_addresses 5432)" ]] &&
        ! dir_has_content /var/lib/postgresql && ! dir_has_content /etc/postgresql; then
        expect_exit "install-postgresql verify (not installed) -> 1"     1 "${PROJECT_ROOT}/modules/install-postgresql.sh" verify
        expect_exit "install-postgresql install (no terminal) -> 4"      4 "${PROJECT_ROOT}/modules/install-postgresql.sh" install
        DRY_RUN=1 expect_exit "DRY_RUN=1 install-postgresql install -> 0" 0 "${PROJECT_ROOT}/modules/install-postgresql.sh" install
        expect_exit "install-postgresql guide -> 0"                      0 "${PROJECT_ROOT}/modules/install-postgresql.sh" guide
    else
        skip "PostgreSQL is present: install-path tests skipped"
    fi
    if [[ ! -e /usr/local/bin/mailpit && ! -e /etc/systemd/system/mailpit.service ]] &&
        [[ -z "$(port_listen_addresses 1025)$(port_listen_addresses 8025)" ]]; then
        expect_exit "install-mailpit verify (not installed) -> 1"     1 "${PROJECT_ROOT}/modules/install-mailpit.sh" verify
        expect_exit "install-mailpit install (no terminal) -> 4"      4 "${PROJECT_ROOT}/modules/install-mailpit.sh" install
        DRY_RUN=1 expect_exit "DRY_RUN=1 install-mailpit install -> 0" 0 "${PROJECT_ROOT}/modules/install-mailpit.sh" install
        expect_exit "install-mailpit test (not installed) -> 3"       3 "${PROJECT_ROOT}/modules/install-mailpit.sh" test
        expect_exit "install-mailpit php-mail (not installed) -> 3"   3 "${PROJECT_ROOT}/modules/install-mailpit.sh" php-mail
        expect_exit "install-mailpit guide -> 0"                      0 "${PROJECT_ROOT}/modules/install-mailpit.sh" guide
    else
        skip "Mailpit is present: install-path tests skipped"
    fi
    if [[ -z "$(docker_desktop_integration)" && -z "$(docker_conflicting_packages)" ]] &&
        ! is_package_installed docker-ce; then
        expect_exit "install-docker verify (not installed) -> 1"     1 "${PROJECT_ROOT}/modules/install-docker.sh" verify
        expect_exit "install-docker install (no terminal) -> 4"      4 "${PROJECT_ROOT}/modules/install-docker.sh" install
        DRY_RUN=1 expect_exit "DRY_RUN=1 install-docker install -> 0" 0 "${PROJECT_ROOT}/modules/install-docker.sh" install
        expect_exit "install-docker test-run (not installed) -> 3"   3 "${PROJECT_ROOT}/modules/install-docker.sh" test-run
    else
        skip "Docker (or Docker Desktop) is present: install-path tests skipped"
    fi
    assert_fail "sudo was never used" test -e "$SUDO_MARKER"
    assert_fail "no Mailpit unit was written" test -e /etc/systemd/system/mailpit.service
    assert_fail "no Docker keyring was written" test -e /etc/apt/keyrings/docker.asc
fi

finish
