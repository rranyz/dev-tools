# shellcheck shell=bash
# lib/packages.sh: dpkg/apt helpers.
#
# Requires lib/common.sh. Only apt_update and apt_install change the system, and
# both go through run(), so DRY_RUN=1 shows the commands without running them.

if [[ -n "${WSL_DEVTOOLS_PACKAGES_LOADED:-}" ]]; then
    return 0
fi
WSL_DEVTOOLS_PACKAGES_LOADED=1

APT_LOCK_TIMEOUT_SECONDS=120

# True when the package is fully installed.
is_package_installed() {
    # shellcheck disable=SC2016  # ${Status} is a dpkg-query field, not a shell variable
    [[ "$(dpkg-query -W -f='${Status}' -- "${1:-}" 2>/dev/null)" == "install ok installed" ]]
}

# Print the installed version of an installed package.
package_version() {
    # shellcheck disable=SC2016
    dpkg-query -W -f='${Version}' -- "$1"
}

# Print the packages from the list that are not installed, one per line.
missing_packages() {
    local pkg
    for pkg in "$@"; do
        is_package_installed "$pkg" || printf '%s\n' "$pkg"
    done
}

# Print the version apt would install, or nothing if the package is unavailable.
package_candidate() {
    local candidate
    candidate="$(apt-cache policy -- "${1:-}" | awk '/^  Candidate:/ {print $2}')"
    if [[ "$candidate" == "(none)" ]]; then
        candidate=""
    fi
    printf '%s' "$candidate"
}

# Refresh the package lists. This never upgrades installed packages.
apt_update() {
    log_info "Refreshing package lists (apt-get update). No installed package is upgraded."
    run sudo apt-get update --error-on=any -o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT_SECONDS}"
}

# Print the packages apt would remove to install the given ones (simulation, no root needed).
apt_would_remove() {
    apt-get -s install -- "$@" | awk '/^Remv / {print $2}'
}

# Strip the epoch and Debian revision from a package version:
#   1:7.4.33-31+ubuntu24.04.1+deb.sury.org+1  ->  7.4.33
upstream_version() {
    local version="${1:-}"
    version="${version#*:}"
    printf '%s' "${version%-*}"
}

# True if any apt source line mentions the pattern (extended regex).
# Usage: apt_source_configured 'ppa\.launchpad(content)?\.net/ondrej/php' [apt_dir]
apt_source_configured() {
    local pattern="$1" apt_dir="${2:-/etc/apt}" file content
    local -a files=()

    for file in "${apt_dir}/sources.list" "${apt_dir}/sources.list.d"/*.list \
        "${apt_dir}/sources.list.d"/*.sources; do
        [[ -f "$file" ]] && files+=("$file")
    done
    (( ${#files[@]} > 0 )) || return 1
    # Ignore commented-out lines. Read everything first: "grep -q" in a pipe can
    # stop early and make the pipeline fail under pipefail.
    content="$(grep -hvE '^[[:space:]]*#' -- "${files[@]}")" || return 1
    grep -qE -- "$pattern" <<<"$content"
}

# Install packages, refusing if apt would remove anything.
# NEEDRESTART_MODE=l: list services needing a restart instead of restarting them.
apt_install() {
    local removals

    if ! removals="$(apt_would_remove "$@")"; then
        log_error "apt cannot plan the installation of: $*. See the messages above."
        return 1
    fi
    if [[ -n "$removals" ]]; then
        log_error "Installing $* would remove: ${removals//$'\n'/ }. Nothing was changed."
        return 1
    fi
    if ! run sudo env DEBIAN_FRONTEND=noninteractive NEEDRESTART_MODE=l \
        apt-get install -y -o "DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT_SECONDS}" -- "$@"; then
        log_error "apt-get install failed for: $*. See apt's messages above. Running the install again is safe."
        return 1
    fi
}

# The shared install sequence for modules, after the user has confirmed:
# sudo -> refresh package lists -> check every package is available -> install.
# Returns 0 ok, 1 apt failed, 3 a package is not available from the apt sources.
install_missing_packages() {
    local -a unavailable=()
    local pkg

    require_sudo || return 3
    if ! apt_update; then
        log_error "Refreshing package lists failed. Check the network and the apt sources named above, then run this again."
        return 1
    fi
    for pkg in "$@"; do
        [[ -n "$(package_candidate "$pkg")" ]] || unavailable+=("$pkg")
    done
    if (( ${#unavailable[@]} > 0 )); then
        log_error "Not available from the configured apt sources: ${unavailable[*]}"
        return 3
    fi
    apt_install "$@" || return 1
}
