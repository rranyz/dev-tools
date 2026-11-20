#!/usr/bin/env bash
# tests/test-system.sh: tests for lib/system.sh, lib/packages.sh, modules/install-base.sh
# and scripts/check-system.sh.
#
# Makes no system changes. Detection is tested with fixture files. Module tests put a
# fake "sudo" first on PATH that records any real use, and use fixture configs whose
# packages are already installed or do not exist, so nothing is ever installed.
# Module and live tests run only on Ubuntu 24.04 under WSL2 and are skipped elsewhere.
#
# Usage: bash tests/test-system.sh

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
load_project_config

FAKE_PACKAGE="wsl-devtools-no-such-pkg"

# Write a fixture file and print its path. Usage: fixture name line...
fixture() {
    local file="${TMP_DIR}/$1"
    shift
    printf '%s\n' "$@" >"$file"
    printf '%s' "$file"
}

echo "WSL2 detection"
assert_equals "WSL2 kernel -> 2" "2" \
    "$(detect_wsl_version "$(fixture wsl2 6.6.87.2-microsoft-standard-WSL2)")"
assert_equals "WSL1 kernel -> 1" "1" \
    "$(detect_wsl_version "$(fixture wsl1 4.4.0-19041-Microsoft)")"
assert_equals "custom WSL kernel -> unknown" "unknown" \
    "$(detect_wsl_version "$(fixture wsl-custom 5.15.0-microsoft-custom)")"
assert_equals "regular Linux kernel -> not WSL" "" \
    "$(detect_wsl_version "$(fixture linux 6.8.0-45-generic)")"
assert_equals "missing kernel file -> not WSL" "" \
    "$(detect_wsl_version "${TMP_DIR}/no-such-file")"

echo "Ubuntu version detection"
ubuntu_2404="$(fixture ubuntu-2404 'PRETTY_NAME="Ubuntu 24.04.5 LTS"' 'NAME="Ubuntu"' \
    'VERSION_ID="24.04"' 'VERSION_CODENAME=noble' 'ID=ubuntu' 'ID_LIKE=debian')"
ubuntu_2204="$(fixture ubuntu-2204 'PRETTY_NAME="Ubuntu 22.04.4 LTS"' 'VERSION_ID="22.04"' \
    'VERSION_CODENAME=jammy' 'ID=ubuntu')"
debian_12="$(fixture debian-12 'PRETTY_NAME="Debian GNU/Linux 12 (bookworm)"' 'VERSION_ID="12"' \
    'VERSION_CODENAME=bookworm' 'ID=debian')"

read_os_release "$ubuntu_2404"
assert_equals "24.04: OS_ID" "ubuntu" "$OS_ID"
assert_equals "24.04: OS_VERSION_ID" "24.04" "$OS_VERSION_ID"
assert_equals "24.04: OS_CODENAME" "noble" "$OS_CODENAME"
assert_equals "24.04: OS_PRETTY_NAME" "Ubuntu 24.04.5 LTS" "$OS_PRETTY_NAME"
assert_ok   "24.04 is supported"                  is_supported_ubuntu
read_os_release "$ubuntu_2204"
assert_ok   "22.04 is Ubuntu"                     is_ubuntu
assert_fail "22.04 is not supported"              is_supported_ubuntu
read_os_release "$debian_12"
assert_fail "Debian is not Ubuntu"                is_ubuntu
assert_fail "Debian is not supported"             is_supported_ubuntu
assert_fail "missing os-release file fails"       read_os_release "${TMP_DIR}/no-such-file"
assert_equals "missing os-release clears OS_ID" "" "$OS_ID"

echo "systemd detection"
assert_ok   "PID 1 'systemd' -> systemd"          is_systemd_pid1 "$(fixture comm-systemd systemd)"
assert_fail "PID 1 'init' -> no systemd"          is_systemd_pid1 "$(fixture comm-init init)"
assert_fail "unreadable PID 1 name -> no systemd" is_systemd_pid1 "${TMP_DIR}/no-such-file"
assert_ok   "state running is usable"             is_usable_systemd_state running
assert_ok   "state degraded is usable"            is_usable_systemd_state degraded
assert_ok   "state starting is usable"            is_usable_systemd_state starting
assert_fail "state offline is not usable"         is_usable_systemd_state offline
assert_fail "state unknown is not usable"         is_usable_systemd_state unknown
assert_fail "empty state is not usable"           is_usable_systemd_state ""

echo "Missing dependencies"
mkdir -p "${TMP_DIR}/empty-bin"
check_apt_with_empty_path() { local PATH="${TMP_DIR}/empty-bin"; check_apt; }
sudo_status_with_empty_path() { local PATH="${TMP_DIR}/empty-bin"; sudo_status; }
assert_fail "check_apt fails when apt tools are missing" check_apt_with_empty_path
assert_equals "sudo_status is 'missing' without sudo" "missing" "$(sudo_status_with_empty_path)"
assert_ok   "is_package_installed bash"           is_package_installed bash
assert_fail "is_package_installed fake package"   is_package_installed "$FAKE_PACKAGE"
assert_equals "missing_packages lists only the missing one" "$FAKE_PACKAGE" \
    "$(missing_packages bash "$FAKE_PACKAGE")"
assert_equals "no apt candidate for the fake package" "" "$(package_candidate "$FAKE_PACKAGE")"
assert_ok   "apt candidate exists for bash"       test -n "$(package_candidate bash)"
assert_equals "installing an installed package removes nothing" "" "$(apt_would_remove bash)"

echo "Base module (fake sudo, fixture configs)"
read_os_release >/dev/null 2>&1
if [[ "$(detect_wsl_version)" != "2" ]] || ! is_supported_ubuntu; then
    skip "module tests need Ubuntu ${SUPPORTED_UBUNTU_VERSION} on WSL2"
else
    # Fake sudo: "sudo -n ..." fails as if a password were needed; any other use is recorded.
    mkdir -p "${TMP_DIR}/fakebin"
    SUDO_MARKER="${TMP_DIR}/sudo-was-called"
    # shellcheck disable=SC2016 # stub script text: its variables expand when the stub runs
    printf '#!/usr/bin/env bash\n[[ "${1:-}" == "-n" ]] && exit 1\ntouch "%s"\nexit 1\n' \
        "$SUDO_MARKER" >"${TMP_DIR}/fakebin/sudo"
    chmod +x "${TMP_DIR}/fakebin/sudo"

    make_config_dir() {
        local dir="${TMP_DIR}/$1"
        mkdir -p "$dir"
        cp "${PROJECT_ROOT}/config/versions.conf" "$dir/"
        printf 'BASE_PACKAGES="%s"\n' "$2" >"$dir/packages.conf"
        printf '%s' "$dir"
    }
    installed_config="$(make_config_dir cfg-installed "bash coreutils")"
    missing_config="$(make_config_dir cfg-missing "bash ${FAKE_PACKAGE}")"

    # Run the module with a config dir; stdin is not a terminal, so confirm() answers no.
    run_module() {
        local config_dir="$1"
        shift
        env WSL_DEVTOOLS_CONFIG_DIR="$config_dir" DRY_RUN="${DRY_RUN:-0}" \
            PATH="${TMP_DIR}/fakebin:${PATH}" \
            "${PROJECT_ROOT}/modules/install-base.sh" "$@" </dev/null >/dev/null 2>&1
    }

    run_module "$installed_config" install
    assert_equals "already installed -> install exits 2" "2" "$?"
    run_module "$installed_config" verify
    assert_equals "already installed -> verify exits 0" "0" "$?"
    DRY_RUN=1 run_module "$missing_config" install
    assert_equals "unavailable package (dry run) -> install exits 3" "3" "$?"
    run_module "$missing_config" install
    assert_equals "missing package, no terminal to confirm -> install exits 4" "4" "$?"
    run_module "$missing_config" verify
    assert_equals "missing package -> verify exits 1" "1" "$?"
    run_module "$installed_config" not-an-action
    assert_equals "unknown action -> exits 3" "3" "$?"
    assert_fail "sudo was never used for a real change" test -e "$SUDO_MARKER"
fi

echo "Live read-only checks on this machine"
if [[ "$(detect_wsl_version)" != "2" ]] || ! is_supported_ubuntu; then
    skip "live checks need Ubuntu ${SUPPORTED_UBUNTU_VERSION} on WSL2"
else
    assert_ok "scripts/check-system.sh exits 0"   "${PROJECT_ROOT}/scripts/check-system.sh"
    assert_ok "install-base.sh status exits 0"    "${PROJECT_ROOT}/modules/install-base.sh" status
fi

finish
