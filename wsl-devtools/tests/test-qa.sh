#!/usr/bin/env bash
# tests/test-qa.sh: cross-module failure scenarios with mocks (Phase 8).
#
#   - systemd unavailable: a fake "systemctl" reports "offline";
#   - missing dependencies: a PATH built from the real tools minus curl, git, php or composer;
#   - failed package installations: a fake "sudo" that fails "apt-get update" or
#     "apt-get install", the removal guard, an unavailable package, an install that did not
#     really happen;
#   - an invalid DRY_RUN value in every entry script.
#
# Makes no system changes. The fake "sudo" first on PATH records every call and never runs
# anything, so no apt command, service change or file write as root can happen. Read-only
# commands (apt-get -s, apt-cache, dpkg-query) run for real. Interactive answers go through a
# pseudo-terminal (util-linux "script"). Runs only on Ubuntu 24.04 under WSL2.
#
# Usage: bash tests/test-qa.sh

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
    skip "QA scenarios need Ubuntu ${SUPPORTED_UBUNTU_VERSION} on WSL2, as a normal user"
    finish
    exit $?
fi
if ! command -v script >/dev/null 2>&1; then
    skip "QA scenarios need util-linux 'script' for the pseudo-terminal"
    finish
    exit $?
fi

MODULES="${PROJECT_ROOT}/modules"
FAKEBIN="${TMP_DIR}/fakebin"
SUDO_LOG="${TMP_DIR}/sudo-calls"
SUDO_MODE="${TMP_DIR}/sudo-mode"     # ok | update-fail | install-fail
OUT="${TMP_DIR}/out"
RC=0
mkdir -p "$FAKEBIN" "${TMP_DIR}/logs" "${TMP_DIR}/home"

# Fake sudo: records every call and never runs the command.
#   sudo -n ...            -> 0 (sudo looks usable without a password)
#   sudo -v                -> 0
#   ... apt-get update     -> 100 when the mode is update-fail
#   ... apt-get install    -> 100 when the mode is install-fail
cat >"${FAKEBIN}/sudo" <<EOF
#!/usr/bin/env bash
echo "sudo \$*" >>"${SUDO_LOG}"
mode="\$(cat "${SUDO_MODE}" 2>/dev/null || echo ok)"
case " \$* " in
    *" apt-get update "*) [[ "\$mode" == update-fail ]] && exit 100 ;;
    *" apt-get install "*) [[ "\$mode" == install-fail ]] && exit 100 ;;
esac
exit 0
EOF
chmod +x "${FAKEBIN}/sudo"

export LOG_DIR="${TMP_DIR}/logs"
export NO_COLOR=1
unset DRY_RUN LOG_FILE

reset() {
    rm -f "$SUDO_LOG" "${TMP_DIR}/logs"/*
    touch "$SUDO_LOG"
    echo ok >"$SUDO_MODE"
}
# sudo calls other than the harmless "sudo -n true" check.
real_sudo_calls() { grep -v '^sudo -n true$' "$SUDO_LOG" | tr '\n' ';'; }
out_has() { grep -qF -- "$1" "$OUT"; }

# run_with_path <PATH> <command...>   no terminal; sets RC, output in OUT
run_with_path() {
    local path="$1"
    shift
    RC=0
    env PATH="$path" HOME="${TMP_DIR}/home" "$@" </dev/null >"$OUT" 2>&1 || RC=$?
}
STD_PATH="${FAKEBIN}:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"

# A PATH with every real tool except the named ones (symlinks in a temporary directory).
# Usage: path_without curl git  -> prints the PATH
path_without() {
    local dir src entry name
    dir="${TMP_DIR}/path-without-$(IFS=-; echo "$*")"
    if [[ ! -d "$dir" ]]; then
        mkdir -p "$dir"
        for src in /usr/local/sbin /usr/local/bin /usr/sbin /usr/bin /sbin /bin; do
            [[ -d "$src" && ! -L "$src" ]] || continue
            for entry in "$src"/*; do
                name="${entry##*/}"
                [[ -x "$entry" && ! -e "${dir}/${name}" ]] || continue
                is_one_of "$name" "$@" && continue
                ln -s "$entry" "${dir}/${name}"
            done
        done
    fi
    printf '%s:%s' "$FAKEBIN" "$dir"
}

# ---------------------------------------------------------------------------
# systemd unavailable
# ---------------------------------------------------------------------------

echo "systemd unavailable (fake systemctl reports 'offline')"
NOSYSTEMD_BIN="${TMP_DIR}/nosystemd-bin"
mkdir -p "$NOSYSTEMD_BIN"
cat >"${NOSYSTEMD_BIN}/systemctl" <<'EOF'
#!/usr/bin/env bash
[[ "${1:-}" == "is-system-running" ]] && { echo offline; exit 1; }
exit 3
EOF
chmod +x "${NOSYSTEMD_BIN}/systemctl"
NOSYSTEMD_PATH="${NOSYSTEMD_BIN}:${STD_PATH}"

for module in nginx redis postgresql mailpit docker mariadb mysql; do
    reset
    run_with_path "$NOSYSTEMD_PATH" bash "${MODULES}/install-${module}.sh" install
    assert_equals "${module} install without systemd -> 3" "3" "$RC"
    assert_ok "${module}: systemd problem explained" out_has "systemd"
    DRY_RUN=1 run_with_path "$NOSYSTEMD_PATH" bash "${MODULES}/install-${module}.sh" install
    assert_equals "${module} DRY_RUN=1 install without systemd -> 3" "3" "$RC"
    assert_equals "${module}: no sudo used" "" "$(real_sudo_calls)"
done
reset
run_with_path "$NOSYSTEMD_PATH" bash "${MODULES}/install-php.sh" install 8.4
assert_equals "php install 8.4 without systemd -> 3" "3" "$RC"
run_with_path "$NOSYSTEMD_PATH" bash "${MODULES}/install-php.sh" xdebug
assert_equals "php xdebug without systemd -> 3" "3" "$RC"
assert_ok "how to enable systemd is explained (not done)" out_has "wsl.conf"

mapfile -t php_versions < <(php_installed_versions)
if (( ${#php_versions[@]} > 0 )); then
    mkdir -p "${TMP_DIR}/www"
    run_with_path "$NOSYSTEMD_PATH" bash "${PROJECT_ROOT}/scripts/nginx-site.sh" \
        create qa-nosystemd.test "${TMP_DIR}/www" "${php_versions[0]}"
    assert_equals "nginx-site create without systemd -> 3" "3" "$RC"
else
    skip "nginx-site create without systemd: no PHP installed"
fi
run_with_path "$NOSYSTEMD_PATH" bash "${PROJECT_ROOT}/scripts/install-all.sh" --modules nginx
assert_equals "install-all --modules nginx without systemd -> 3" "3" "$RC"
run_with_path "$NOSYSTEMD_PATH" bash "${MODULES}/install-base.sh" status
assert_equals "base status still works without systemd" "0" "$RC"
run_with_path "$NOSYSTEMD_PATH" bash "${MODULES}/install-nginx.sh" status
assert_equals "nginx status still works without systemd" "0" "$RC"
run_with_path "$NOSYSTEMD_PATH" bash "${PROJECT_ROOT}/scripts/check-system.sh"
assert_equals "check-system reports the problem -> 3" "3" "$RC"
assert_equals "no sudo used in any systemd scenario" "" "$(real_sudo_calls)"

# ---------------------------------------------------------------------------
# Missing dependencies
# ---------------------------------------------------------------------------

echo "Missing dependencies (PATH without a tool)"
reset
run_with_path "$(path_without curl)" bash "${MODULES}/install-php.sh" install 8.4
assert_equals "php install without curl -> 3" "3" "$RC"
assert_ok "missing curl explained" out_has "curl is missing"

run_with_path "$(path_without git)" bash "${MODULES}/install-nodejs.sh" install
assert_equals "nodejs install without git -> 3" "3" "$RC"
assert_ok "missing git named" out_has "git"

run_with_path "$(path_without curl)" bash "${MODULES}/install-base.sh" verify
assert_equals "base verify without the curl command -> 1" "1" "$RC"
assert_ok "verify names the broken command" out_has "curl: package is installed but the command does not run"

run_with_path "$(path_without composer php)" bash "${MODULES}/install-composer.sh" install
assert_equals "composer install without php -> 3" "3" "$RC"

run_with_path "$(path_without sha256sum)" bash "${MODULES}/install-nodejs.sh" install-nvm
assert_equals "NVM install without sha256sum -> 3" "3" "$RC"
assert_equals "no sudo used with missing dependencies" "" "$(real_sudo_calls)"

# ---------------------------------------------------------------------------
# Failed package installations (answer "y" in a pseudo-terminal)
# ---------------------------------------------------------------------------

echo "Failed package installations (fake sudo, nothing is installed)"
# A config dir whose BASE_PACKAGES is the given list.
make_config() {
    local dir="${TMP_DIR}/cfg-$1"
    mkdir -p "$dir"
    cp "${PROJECT_ROOT}/config/versions.conf" "$dir/"
    printf 'BASE_PACKAGES="%s"\nAPT_PREREQUISITE_PACKAGES="ca-certificates"\n' "$2" >"$dir/packages.conf"
    printf '%s' "$dir"
}
# base_install_answering_yes <config_dir>
base_install_answering_yes() {
    RC=0
    printf 'y\n' | timeout 120 script -qec \
        "env WSL_DEVTOOLS_CONFIG_DIR=$(printf '%q' "$1") PATH=$(printf '%q' "$STD_PATH") bash $(printf '%q' "${MODULES}/install-base.sh") install" \
        /dev/null >"$OUT" 2>&1 || RC=$?
}

TEST_PACKAGE="sl"   # small, not installed, has a candidate in Ubuntu's archive
if is_package_installed "$TEST_PACKAGE" || [[ -z "$(package_candidate "$TEST_PACKAGE")" ]]; then
    skip "failed-install tests need '${TEST_PACKAGE}' uninstalled with an apt candidate"
else
    cfg="$(make_config sl "$TEST_PACKAGE")"

    reset
    echo update-fail >"$SUDO_MODE"
    base_install_answering_yes "$cfg"
    assert_equals "apt-get update fails -> 1" "1" "$RC"
    assert_ok "update failure explained" out_has "Refreshing package lists failed"
    assert_fail "nothing installed after a failed update" grep -q 'apt-get install' "$SUDO_LOG"

    reset
    echo install-fail >"$SUDO_MODE"
    base_install_answering_yes "$cfg"
    assert_equals "apt-get install fails -> 1" "1" "$RC"
    assert_ok "install failure explained" out_has "apt-get install failed for: ${TEST_PACKAGE}"
    assert_ok "only the missing package was requested, with the lock timeout" grep -q "apt-get install -y .* -- ${TEST_PACKAGE}" "$SUDO_LOG"
    assert_ok "services are not auto-restarted (NEEDRESTART_MODE=l)" grep -q 'NEEDRESTART_MODE=l' "$SUDO_LOG"

    reset
    base_install_answering_yes "$cfg"
    assert_equals "apt reports success but the package is missing -> verify fails, 1" "1" "$RC"
    assert_ok "verify catches it" out_has "${TEST_PACKAGE}: package is not installed"
fi

if is_package_installed mariadb-server && [[ -n "$(apt_would_remove mysql-server)" ]]; then
    reset
    base_install_answering_yes "$(make_config guard mysql-server)"
    assert_equals "removal guard: an install that would remove packages -> 1" "1" "$RC"
    assert_ok "removal guard explains what would be removed" out_has "would remove"
    assert_fail "removal guard: apt-get install never called" grep -q 'apt-get install' "$SUDO_LOG"
else
    skip "removal guard test needs MariaDB installed (mysql-server would remove it)"
fi

reset
base_install_answering_yes "$(make_config unavailable wsl-devtools-no-such-pkg)"
assert_equals "an unavailable package -> 3" "3" "$RC"
assert_ok "unavailable package named" out_has "Not available from the configured apt sources"

reset
RC=0
printf 'n\n' | timeout 60 script -qec \
    "env WSL_DEVTOOLS_CONFIG_DIR=$(printf '%q' "$(make_config no wsl-devtools-no-such-pkg)") PATH=$(printf '%q' "$STD_PATH") bash $(printf '%q' "${MODULES}/install-base.sh") install" \
    /dev/null >"$OUT" 2>&1 || RC=$?
assert_equals "answering n -> 4" "4" "${RC:-0}"
assert_equals "answering n: no sudo" "" "$(real_sudo_calls)"

# ---------------------------------------------------------------------------
# Invalid DRY_RUN in every entry script
# ---------------------------------------------------------------------------

echo "Invalid DRY_RUN is refused everywhere"
reset
for script_path in "${MODULES}"/install-*.sh "${PROJECT_ROOT}/scripts/check-system.sh" \
    "${PROJECT_ROOT}/scripts/nginx-site.sh" "${PROJECT_ROOT}/scripts/install-all.sh" \
    "${PROJECT_ROOT}/scripts/install-menu.sh"; do
    action=install
    case "$script_path" in
        */check-system.sh | */install-menu.sh) action="" ;;
        */nginx-site.sh) action=list ;;
        */install-all.sh) action="--modules base" ;;
    esac
    # shellcheck disable=SC2086 # action is one word or "--modules base"
    DRY_RUN=yes run_with_path "$STD_PATH" bash "$script_path" $action
    assert_equals "DRY_RUN=yes: $(basename "$script_path") -> 3" "3" "$RC"
done
assert_equals "no sudo used with an invalid DRY_RUN" "" "$(real_sudo_calls)"

finish
