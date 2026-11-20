#!/usr/bin/env bash
# tests/test-live.sh: read-only health and repeat-run checks of what is installed (Phase 8).
#
# 1. Takes a snapshot of the system state the toolkit could touch: config trees (metadata and
#    checksums of readable files), ~/.bashrc, ~/.nvm, the php alternative, installed packages,
#    service states and /usr/local/bin.
# 2. Runs every module's status, verify and install twice without a terminal (install must stop
#    with 2 "already installed", 3 "not possible" or 4 "needs confirmation"), plus install-all
#    and the menu.
# 3. Runs the live checks: systemctl, php -v per version, the php alternative, composer, nvm/node/
#    npm in a new shell, Nginx fastcgi_pass sockets vs PHP-FPM, nginx -t / php-fpm -t (only when
#    sudo needs no password), databases and Node.js switching.
# 4. Takes the snapshot again: it must be identical.
#
# Checks apply only to what is installed, so this also runs in a fresh distro after installs.
# Real sudo is only used as "sudo -n" (never prompts). Note: Composer runs "sudo -K", so the
# composer check ends a cached sudo session.
#
# Usage: bash tests/test-live.sh

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
# shellcheck source=../lib/php.sh
source "${PROJECT_ROOT}/lib/php.sh"
load_project_config

read_os_release >/dev/null 2>&1
if [[ "$(detect_wsl_version)" != "2" ]] || ! is_supported_ubuntu || (( EUID == 0 )); then
    skip "live checks need Ubuntu ${SUPPORTED_UBUNTU_VERSION} on WSL2, as a normal user"
    finish
    exit $?
fi

export LOG_DIR="${TMP_DIR}/logs"
export NO_COLOR=1
unset DRY_RUN LOG_FILE
mkdir -p "$LOG_DIR"
MODULES="${PROJECT_ROOT}/modules"
OUT="${TMP_DIR}/out"
UNITS=(nginx php7.4-fpm php8.2-fpm php8.4-fpm mariadb mysql redis-server postgresql mailpit docker containerd)

# ---------------------------------------------------------------------------
# Snapshot
# ---------------------------------------------------------------------------

snapshot() {
    local dir unit
    for dir in /etc/nginx /etc/php /etc/mysql /etc/apt/sources.list.d /etc/apt/keyrings \
        /etc/redis /etc/postgresql /etc/docker /usr/local/bin; do
        [[ -e "$dir" ]] || continue
        # Metadata for every file (also root-only ones), checksums for readable files.
        find "$dir" -printf '%p %s %T@ %m %u %l\n' 2>/dev/null | sort
        find "$dir" -type f -readable -print0 2>/dev/null | sort -z | xargs -0 -r sha256sum 2>/dev/null
    done
    ls -l /etc/systemd/system/mailpit.service 2>/dev/null
    sha256sum "${HOME}/.bashrc" 2>/dev/null
    git -C "${HOME}/.nvm" rev-parse HEAD 2>/dev/null
    cat "${HOME}/.nvm/alias/default" 2>/dev/null
    ls "${HOME}/.nvm/versions/node" 2>/dev/null
    update-alternatives --query php 2>/dev/null
    dpkg-query -W -f '${Package} ${Version} ${Status}\n' 2>/dev/null
    for unit in "${UNITS[@]}"; do
        printf '%s %s %s\n' "$unit" "$(systemctl is-active "$unit" 2>/dev/null)" "$(systemctl is-enabled "$unit" 2>/dev/null)"
    done
}

echo "Snapshot before"
snapshot >"${TMP_DIR}/snapshot-before"
pass "snapshot taken ($(wc -l <"${TMP_DIR}/snapshot-before") lines)"

# ---------------------------------------------------------------------------
# Every module, twice, no terminal
# ---------------------------------------------------------------------------

run_noterm() {
    RC=0
    "$@" </dev/null >"$OUT" 2>&1 || RC=$?
}

echo "Every module twice without a terminal (status, verify, install)"
for round in 1 2; do
    for module in base nginx php composer nodejs mariadb mysql redis postgresql mailpit docker; do
        script_path="${MODULES}/install-${module}.sh"
        args=()
        [[ "$module" == "php" ]] && args=(8.4)

        run_noterm bash "$script_path" status
        assert_equals "round ${round}: ${module} status -> 0" "0" "$RC"
        run_noterm bash "$script_path" verify
        if is_one_of "$RC" 0 1; then pass "round ${round}: ${module} verify -> ${RC}"
        else fail "round ${round}: ${module} verify -> ${RC} (expected 0 or 1)"; fi
        echo "${module} verify ${RC}" >>"${TMP_DIR}/verify-round-${round}"
        run_noterm bash "$script_path" install "${args[@]}"
        if is_one_of "$RC" 2 3 4; then pass "round ${round}: ${module} install stops safely -> ${RC}"
        else fail "round ${round}: ${module} install -> ${RC} (expected 2, 3 or 4)"; fi
        echo "${module} install ${RC}" >>"${TMP_DIR}/install-round-${round}"
    done
done
assert_equals "verify results are the same in both rounds" \
    "$(cat "${TMP_DIR}/verify-round-1")" "$(cat "${TMP_DIR}/verify-round-2")"
assert_equals "install results are the same in both rounds" \
    "$(cat "${TMP_DIR}/install-round-1")" "$(cat "${TMP_DIR}/install-round-2")"

run_noterm bash "${PROJECT_ROOT}/scripts/install-all.sh" --modules core,mariadb
assert_equals "install-all without a terminal -> 4 (nothing runs)" "4" "$RC"
RC=0
printf '12\n1\n2\n3\n13\n' | bash "${PROJECT_ROOT}/scripts/install-menu.sh" >"$OUT" 2>&1 || RC=$?
assert_equals "menu: status and verify of every module, Exit -> 0" "0" "$RC"
run_noterm bash "${PROJECT_ROOT}/scripts/check-system.sh"
assert_equals "check-system -> 0" "0" "$RC"
run_noterm bash "${PROJECT_ROOT}/scripts/nginx-site.sh" list
assert_equals "nginx-site list -> 0" "0" "$RC"
DRY_RUN=1 run_noterm bash "${MODULES}/install-php.sh" install 8.4 7.4
if is_one_of "$RC" 0 2; then pass "PHP 8.4 + 7.4 side by side: dry-run plan -> ${RC}"
else fail "PHP 8.4 + 7.4 dry run -> ${RC}"; fi

# ---------------------------------------------------------------------------
# Live checks of what is installed
# ---------------------------------------------------------------------------

echo "Services"
for unit in nginx mariadb mysql redis-server postgresql mailpit docker; do
    if [[ "$(systemctl is-enabled "$unit" 2>/dev/null)" == "enabled" ]]; then
        assert_ok "systemctl is-active ${unit}" systemctl is-active --quiet "$unit"
    fi
done

echo "PHP"
mapfile -t php_versions < <(php_managed_installed_versions)
if (( ${#php_versions[@]} == 0 )); then
    skip "no managed PHP version installed"
fi
for version in "${php_versions[@]}"; do
    assert_ok "php${version} -v" env XDEBUG_MODE=off "php${version}" -v
    if is_package_installed "php${version}-fpm"; then
        assert_ok "php${version}-fpm is active" systemctl is-active --quiet "php${version}-fpm"
        assert_ok "socket /run/php/php${version}-fpm.sock exists" test -S "/run/php/php${version}-fpm.sock"
    fi
done
if command -v php >/dev/null 2>&1; then
    php_target="$(update-alternatives --query php 2>/dev/null | awk '/^Value:/ {print $2}')"
    assert_ok "the php alternative points to an existing program" test -x "$php_target"
    assert_equals "php -v matches the alternative (${php_target})" \
        "$(XDEBUG_MODE=off "$php_target" -r 'echo PHP_VERSION;')" "$(XDEBUG_MODE=off php -r 'echo PHP_VERSION;')"
fi

echo "Composer"
if command -v composer >/dev/null 2>&1; then
    run_noterm env XDEBUG_MODE=off composer --version --no-ansi
    assert_equals "composer --version -> 0" "0" "$RC"
    assert_ok "composer reports its version" grep -q '^Composer version' "$OUT"
else
    skip "composer not installed"
fi

echo "Nginx and PHP-FPM"
if is_package_installed nginx; then
    assert_ok "Nginx answers on http://localhost" curl -s -o /dev/null --max-time 5 http://localhost/
    sockets_ok=1
    while read -r socket; do
        [[ -n "$socket" ]] || continue
        if [[ ! -S "$socket" ]]; then
            sockets_ok=0
            fail "enabled site uses ${socket}, which does not exist"
        fi
    done < <(grep -hoE 'fastcgi_pass[[:space:]]+unix:[^;[:space:]]+' /etc/nginx/sites-enabled/* 2>/dev/null |
        sed 's/.*unix://' | sort -u)
    (( sockets_ok == 1 )) && pass "every fastcgi_pass socket in the enabled sites exists"
    if sudo -n true 2>/dev/null; then
        assert_ok "sudo nginx -t" sudo -n nginx -t
        for version in "${php_versions[@]}"; do
            is_package_installed "php${version}-fpm" &&
                assert_ok "sudo php-fpm${version} -t" sudo -n "php-fpm${version}" -t
        done
    else
        skip "nginx -t and php-fpm -t need your sudo password: run them yourself (testing.md §10)"
    fi
else
    skip "nginx not installed"
fi

echo "Node.js and NVM"
if [[ -s "${HOME}/.nvm/nvm.sh" ]]; then
    run_noterm env -i HOME="$HOME" TERM=dumb PATH=/usr/local/bin:/usr/bin:/bin \
        bash -ic 'command -v nvm && nvm --version && node --version && npm --version'
    assert_equals "new shell: command -v nvm, nvm/node/npm --version -> 0" "0" "$RC"
    assert_ok "node --version prints vX.Y.Z" grep -qE '^v[0-9]+\.' "$OUT"
    default_alias="$(cat "${HOME}/.nvm/alias/default" 2>/dev/null)"
    if [[ -n "$default_alias" ]]; then
        run_noterm bash "${MODULES}/install-nodejs.sh" use "$default_alias"
        assert_equals "use <default ${default_alias}> -> 0" "0" "$RC"
    fi
    run_noterm bash "${MODULES}/install-nodejs.sh" use 99
    assert_equals "use 99 (not installed) -> 3" "3" "$RC"
    other=""
    for node_dir in "${HOME}/.nvm/versions/node"/v*; do
        [[ -d "$node_dir" && "${node_dir##*/}" != "v${default_alias#v}"* ]] || continue
        other="${node_dir##*/}"
        break
    done
    if [[ -n "$other" ]]; then
        run_noterm bash "${MODULES}/install-nodejs.sh" set-default "$other"
        assert_equals "set-default ${other} without a terminal -> 4" "4" "$RC"
    fi
    assert_equals "default alias unchanged" "$default_alias" "$(cat "${HOME}/.nvm/alias/default" 2>/dev/null)"
else
    skip "NVM not installed"
fi

echo "Databases"
if is_package_installed mariadb-server || is_package_installed mysql-server; then
    admin=mariadb-admin
    is_package_installed mysql-server && admin=mysqladmin
    assert_ok "${admin} ping over the socket" "$admin" ping --silent
    loopback_only=1
    while read -r address; do
        [[ -n "$address" ]] || continue
        is_loopback_listener "$address" || loopback_only=0
    done < <(port_listen_addresses 3306)
    assert_equals "port 3306 listens on loopback only" "1" "$loopback_only"
    other_db=mysql
    is_package_installed mysql-server && other_db=mariadb
    run_noterm bash "${MODULES}/install-${other_db}.sh" install
    assert_equals "install-${other_db} next to the installed server -> 3" "3" "$RC"
else
    skip "no database server installed"
fi

# ---------------------------------------------------------------------------
# Nothing changed
# ---------------------------------------------------------------------------

echo "Snapshot after"
snapshot >"${TMP_DIR}/snapshot-after"
if diff -u "${TMP_DIR}/snapshot-before" "${TMP_DIR}/snapshot-after" >"${TMP_DIR}/snapshot.diff"; then
    pass "the system is unchanged after all runs"
else
    fail "the system changed:"
    head -40 "${TMP_DIR}/snapshot.diff"
fi

finish
