#!/usr/bin/env bash
# tests/test-web.sh: tests for lib/php.sh, lib/nginx.sh, the Nginx/PHP/Composer modules
# and scripts/nginx-site.sh.
#
# Makes no system changes. Helpers are tested with fixture directories. Module tests put a
# fake "sudo" first on PATH that records any real use, and run without a terminal, so every
# confirmation is answered "no". Module and live tests need Ubuntu 24.04 on WSL2.
#
# Usage: bash tests/test-web.sh

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
# shellcheck source=../lib/nginx.sh
source "${PROJECT_ROOT}/lib/nginx.sh"
# shellcheck source=../lib/php.sh
source "${PROJECT_ROOT}/lib/php.sh"
load_project_config

echo "Package versions"
assert_equals "upstream of 1:7.4.33-31+ubuntu24.04.1+deb.sury.org+1" "7.4.33" \
    "$(upstream_version '1:7.4.33-31+ubuntu24.04.1+deb.sury.org+1')"
assert_equals "upstream of 8.4.27-1+ubuntu24.04.1+deb.sury.org+1" "8.4.27" \
    "$(upstream_version '8.4.27-1+ubuntu24.04.1+deb.sury.org+1')"
assert_equals "upstream of 1.24.0-2ubuntu7.19" "1.24.0" "$(upstream_version '1.24.0-2ubuntu7.19')"
assert_equals "upstream of 1:3.1.6-1+ubuntu24.04.1" "3.1.6" "$(upstream_version '1:3.1.6-1+ubuntu24.04.1')"

echo "PPA detection"
apt_with_ppa="${TMP_DIR}/apt-ppa"
apt_with_list="${TMP_DIR}/apt-list"
apt_commented="${TMP_DIR}/apt-commented"
apt_empty="${TMP_DIR}/apt-empty"
mkdir -p "$apt_with_ppa/sources.list.d" "$apt_with_list/sources.list.d" \
    "$apt_commented/sources.list.d" "$apt_empty/sources.list.d"
printf 'Types: deb\nURIs: https://ppa.launchpadcontent.net/ondrej/php/ubuntu/\nSuites: noble\n' \
    >"$apt_with_ppa/sources.list.d/ondrej-ubuntu-php-noble.sources"
printf 'deb http://ppa.launchpad.net/ondrej/php/ubuntu noble main\n' \
    >"$apt_with_list/sources.list.d/ondrej-php.list"
printf '# deb http://ppa.launchpad.net/ondrej/php/ubuntu noble main\n' \
    >"$apt_commented/sources.list.d/ondrej-php.list"
assert_ok   "deb822 .sources file is detected"       is_php_ppa_configured "$apt_with_ppa"
assert_ok   "one-line .list file is detected"         is_php_ppa_configured "$apt_with_list"
assert_fail "commented-out entry is ignored"          is_php_ppa_configured "$apt_commented"
assert_fail "no sources -> not configured"            is_php_ppa_configured "$apt_empty"

echo "PHP packages and sockets"
php74_packages="$(php_packages_for_version 7.4 | tr '\n' ' ')"
php84_packages="$(php_packages_for_version 8.4 | tr '\n' ' ')"
assert_ok   "7.4 packages include php7.4-json"        grep -q 'php7.4-json' <<<"$php74_packages"
assert_ok   "7.4 packages include php7.4-xdebug"      grep -q 'php7.4-xdebug' <<<"$php74_packages"
assert_fail "8.4 packages have no json package"       grep -q 'php8.4-json' <<<"$php84_packages"
assert_equals "8.4 has 12 packages" "12" "$(php_packages_for_version 8.4 | wc -l | tr -d ' ')"
assert_equals "module name for mysql" "mysqli" "$(php_module_name mysql)"
assert_equals "no module name for fpm" "" "$(php_module_name fpm)"
assert_equals "FPM socket path" "/run/php/php8.4-fpm.sock" "$(php_fpm_socket 8.4)"
assert_equals "FPM service name" "php7.4-fpm" "$(php_fpm_service 7.4)"
assert_ok   "7.4 is end-of-life"                      is_eol_php_version 7.4
assert_fail "8.4 is not end-of-life"                  is_eol_php_version 8.4

echo "Xdebug settings detection"
etc_php="${TMP_DIR}/etc-php"
mkdir -p "$etc_php/8.4/cli/conf.d" "$etc_php/8.4/fpm/conf.d" "$etc_php/7.4/cli/conf.d" "$etc_php/7.4/fpm/conf.d"
printf 'zend_extension=xdebug.so\n' >"$etc_php/8.4/cli/conf.d/20-xdebug.ini"
printf 'zend_extension=xdebug.so\n' >"$etc_php/8.4/fpm/conf.d/20-xdebug.ini"
printf 'xdebug.mode = debug\n' >"$etc_php/8.4/fpm/conf.d/99-xdebug-debug.ini"
printf ';xdebug.mode = debug\n' >"$etc_php/7.4/cli/conf.d/30-commented.ini"
printf 'xdebug.mode = debug\n' >"$etc_php/7.4/fpm/conf.d/${PHP_XDEBUG_DROPIN_NAME}"
PHP_ETC_DIR="$etc_php"
assert_equals "zend_extension only -> no settings" "" "$(xdebug_foreign_settings 8.4 cli)"
assert_equals "foreign xdebug.mode is found" "$etc_php/8.4/fpm/conf.d/99-xdebug-debug.ini" \
    "$(xdebug_foreign_settings 8.4 fpm)"
assert_equals "commented setting is ignored" "" "$(xdebug_foreign_settings 7.4 cli)"
assert_equals "toolkit's own file is not 'foreign'" "" "$(xdebug_foreign_settings 7.4 fpm)"
assert_equals "8.4 needs toolkit settings for cli only" "cli" \
    "$(xdebug_sapis_needing_settings 8.4 | tr '\n' ' ' | sed 's/ $//')"
assert_equals "7.4 needs toolkit settings for cli only" "cli" \
    "$(xdebug_sapis_needing_settings 7.4 | tr '\n' ' ' | sed 's/ $//')"
PHP_ETC_DIR="/etc/php"
assert_ok   "drop-in uses trigger mode"               grep -q 'start_with_request = trigger' <<<"$(xdebug_dropin_content)"
assert_ok   "drop-in is marked as managed"            grep -q 'Managed by wsl-devtools' <<<"$(xdebug_dropin_content)"

echo "Nginx site configuration"
site_config="$(render_site_config myapp.test /var/www/myapp/public /run/php/php7.4-fpm.sock)"
assert_ok   "server_name is filled in"                grep -q 'server_name myapp.test;' <<<"$site_config"
assert_ok   "root is filled in"                       grep -q 'root /var/www/myapp/public;' <<<"$site_config"
assert_ok   "PHP 7.4 socket is used"                  grep -q 'fastcgi_pass unix:/run/php/php7.4-fpm.sock;' <<<"$site_config"
assert_ok   "listens like Ubuntu's default site"      grep -qx '    listen 80;' <<<"$site_config"
assert_fail "no placeholders are left"                grep -q '{{' <<<"$site_config"
assert_ok   "is_safe_path /var/www/app/public"        is_safe_path /var/www/app/public
assert_fail "is_safe_path relative path"              is_safe_path www/app
assert_fail "is_safe_path with a space"               is_safe_path "/var/www/my app"
assert_fail "is_safe_path with ;"                     is_safe_path "/var/www/app;rm"
assert_fail "is_safe_path with .."                    is_safe_path /var/www/../etc

nginx_fixture="${TMP_DIR}/nginx"
mkdir -p "$nginx_fixture/sites-available" "$nginx_fixture/sites-enabled" "$nginx_fixture/conf.d"
printf 'server {\n    listen 80;\n    server_name shop.test www.shop.test;  # comment\n}\n' \
    >"$nginx_fixture/sites-available/shop"
ln -s "$nginx_fixture/sites-available/shop" "$nginx_fixture/sites-enabled/shop"
printf 'server { server_name api.test; }\n' >"$nginx_fixture/conf.d/api.conf"
NGINX_DIR="$nginx_fixture"
assert_ok   "existing site file is detected"      nginx_site_exists shop
assert_fail "unknown site name is free"           nginx_site_exists blog.test
assert_ok   "server_name in sites-enabled is in use" nginx_server_name_in_use www.shop.test
assert_ok   "server_name in conf.d is in use"     nginx_server_name_in_use api.test
assert_fail "similar name is not a match"         nginx_server_name_in_use shop.testing
assert_fail "unused server_name is free"          nginx_server_name_in_use blog.test
assert_equals "site summary" "shop.test www.shop.test|-|" \
    "$(nginx_site_summary "$nginx_fixture/sites-enabled/shop")"
NGINX_DIR="/etc/nginx"

echo "Modules (fake sudo, no terminal)"
read_os_release >/dev/null 2>&1
if [[ "$(detect_wsl_version)" != "2" ]] || ! is_supported_ubuntu; then
    skip "module tests need Ubuntu ${SUPPORTED_UBUNTU_VERSION} on WSL2"
else
    mkdir -p "${TMP_DIR}/fakebin"
    SUDO_MARKER="${TMP_DIR}/sudo-was-called"
    # Fake sudo: "sudo -n" fails as if a password were needed; "sudo -K" (which Composer runs
    # itself at startup to drop cached sudo rights) is ignored; any other use is recorded.
    # shellcheck disable=SC2016 # stub script text: its variables expand when the stub runs
    printf '#!/usr/bin/env bash\n[[ "${1:-}" == "-n" ]] && exit 1\n[[ "${1:-}" == "-K" ]] && exit 0\ntouch "%s"\nexit 1\n' \
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

    if is_package_installed nginx; then
        expect_exit "install-nginx install (installed) -> 2" 2 "${PROJECT_ROOT}/modules/install-nginx.sh" install
    else
        expect_exit "install-nginx install (not installed, no terminal) -> 4" 4 "${PROJECT_ROOT}/modules/install-nginx.sh" install
    fi
    expect_exit "install-nginx status -> 0"            0 "${PROJECT_ROOT}/modules/install-nginx.sh" status
    expect_exit "install-php install 8.2 (unsupported) -> 3" 3 "${PROJECT_ROOT}/modules/install-php.sh" install 8.2
    expect_exit "install-php install (no version) -> 3"     3 "${PROJECT_ROOT}/modules/install-php.sh" install
    expect_exit "install-php without terminal or action -> 3" 3 "${PROJECT_ROOT}/modules/install-php.sh"
    expect_exit "install-php install 7.4 (EOL, no terminal to confirm) -> 4" 4 "${PROJECT_ROOT}/modules/install-php.sh" install 7.4
    mapfile -t both_php_packages < <(php_packages_for_version 8.4; php_packages_for_version 7.4)
    DRY_RUN=1 expect_exit "DRY_RUN=1 install-php install 8.4 7.4 -> 0 or 2" \
        "$( [[ -z "$(missing_packages "${both_php_packages[@]}")" ]] && echo 2 || echo 0 )" \
        "${PROJECT_ROOT}/modules/install-php.sh" install 8.4 7.4
    expect_exit "install-php set-default 9.9 -> 3"     3 "${PROJECT_ROOT}/modules/install-php.sh" set-default 9.9
    current_default="$(php_cli_default)"
    other_version=""
    for version in $(php_installed_versions); do
        [[ "/usr/bin/php${version}" != "$current_default" ]] && other_version="$version" && break
    done
    if [[ -n "$other_version" ]]; then
        expect_exit "install-php set-default ${other_version} (no terminal to confirm) -> 4" 4 \
            "${PROJECT_ROOT}/modules/install-php.sh" set-default "$other_version"
    fi
    if [[ -n "$current_default" ]]; then
        expect_exit "install-php set-default <current> -> 2" 2 \
            "${PROJECT_ROOT}/modules/install-php.sh" set-default "${current_default##*/php}"
    fi
    assert_equals "CLI default unchanged" "$current_default" "$(php_cli_default)"
    expect_exit "install-php status -> 0"              0 "${PROJECT_ROOT}/modules/install-php.sh" status
    if command_exists composer; then
        expect_exit "install-composer install (installed) -> 2" 2 "${PROJECT_ROOT}/modules/install-composer.sh" install
        expect_exit "install-composer verify -> 0"     0 "${PROJECT_ROOT}/modules/install-composer.sh" verify
    fi
    expect_exit "nginx-site list -> 0"                 0 "${PROJECT_ROOT}/scripts/nginx-site.sh" list
    expect_exit "nginx-site create with invalid domain -> 3" 3 "${PROJECT_ROOT}/scripts/nginx-site.sh" create "Bad_Domain" /tmp 8.4
    expect_exit "nginx-site create with unsafe root -> 3" 3 "${PROJECT_ROOT}/scripts/nginx-site.sh" create new.test "/tmp/a b" 8.4
    expect_exit "nginx-site create with PHP 9.9 -> 3"  3 "${PROJECT_ROOT}/scripts/nginx-site.sh" create new.test /tmp 9.9
    existing_site=""
    for site in /etc/nginx/sites-enabled/*; do
        [[ -e "$site" && "${site##*/}" != "default" ]] && existing_site="${site##*/}" && break
    done
    if [[ -n "$existing_site" ]] && is_valid_domain "$existing_site" && is_php_installed 8.4; then
        expect_exit "nginx-site create over existing site '${existing_site}' -> 3" 3 \
            "${PROJECT_ROOT}/scripts/nginx-site.sh" create "$existing_site" /tmp 8.4
    fi
    assert_fail "sudo was never used for a real change" test -e "$SUDO_MARKER"
fi

finish
