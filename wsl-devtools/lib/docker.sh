# shellcheck shell=bash
# lib/docker.sh: read-only Docker detection for modules/install-docker.sh.
#
# Requires lib/common.sh and lib/packages.sh. Nothing here changes the system.
#
# Three situations are told apart:
#   - Docker Desktop's WSL integration: Docker runs in Docker Desktop's own VM and this distro
#     only gets a docker CLI and socket under /mnt/wsl. A second daemon here would conflict.
#   - Another engine installed in this distro (Ubuntu's docker.io, a snap, podman-docker, ...).
#   - Docker Engine from Docker's repository (docker-ce), which this toolkit installs.
# Paths are prefixed with DOCKER_FS_ROOT so tests can use a fixture tree.

if [[ -n "${WSL_DEVTOOLS_DOCKER_LOADED:-}" ]]; then
    return 0
fi
WSL_DEVTOOLS_DOCKER_LOADED=1

DOCKER_FS_ROOT="${DOCKER_FS_ROOT:-}"   # override for tests
DOCKER_KEYRING="/etc/apt/keyrings/docker.asc"
# shellcheck disable=SC2034 # used by modules/install-docker.sh
DOCKER_SOURCES_FILE="/etc/apt/sources.list.d/docker.sources"
DOCKER_DAEMON_JSON="/etc/docker/daemon.json"
DOCKER_SOCKET="/var/run/docker.sock"
# shellcheck disable=SC2034 # used by modules/install-docker.sh
DOCKER_SOURCE_PATTERN='download\.docker\.com/linux/ubuntu'
# Packages that conflict with Docker's packages or provide another Docker engine.
# containerd.io (from Docker) conflicts with Ubuntu's containerd and runc.
DOCKER_CONFLICTING_PACKAGES="docker.io docker-engine podman-docker containerd runc moby-engine moby-cli"

# Path of the docker CLI on PATH, or nothing. Tests override this.
docker_cli_path() {
    command -v docker 2>/dev/null || true
}

# Path of Windows' docker.exe on PATH (Docker Desktop installed on Windows), or nothing.
docker_exe_path() {
    command -v docker.exe 2>/dev/null || true
}

# Print why Docker Desktop's WSL integration is considered active, or nothing.
docker_desktop_integration() {
    local root="$DOCKER_FS_ROOT" dir cli target
    for dir in "${root}/mnt/wsl/docker-desktop" "${root}/mnt/wsl/docker-desktop-data" \
        "${root}/mnt/wsl/docker-desktop-bind-mounts"; do
        if [[ -d "$dir" ]]; then
            echo "${dir#"$root"} exists"
            return 0
        fi
    done
    cli="$(docker_cli_path)"
    if [[ -n "$cli" ]]; then
        target="$(readlink -f -- "$cli" 2>/dev/null || echo "$cli")"
        if [[ "$target" == */mnt/wsl/docker-desktop* ]]; then
            echo "the docker command (${cli}) belongs to Docker Desktop (${target})"
            return 0
        fi
    fi
    if [[ -L "${root}${DOCKER_SOCKET}" ]]; then
        target="$(readlink -- "${root}${DOCKER_SOCKET}")"
        if [[ "$target" == /mnt/wsl/* ]]; then
            echo "${DOCKER_SOCKET} points to Docker Desktop (${target})"
            return 0
        fi
    fi
}

# Installed packages that conflict with Docker's repository packages, one per line.
docker_conflicting_packages() {
    local pkg
    for pkg in $DOCKER_CONFLICTING_PACKAGES; do
        if is_package_installed "$pkg"; then
            echo "$pkg"
        fi
    done
    # A snap called docker is another engine as well.
    if command_exists snap && snap list docker >/dev/null 2>&1; then
        echo "snap:docker"
    fi
}

# Print the fingerprint of the first (primary) key in an OpenPGP key file.
key_fingerprint() {
    local file="$1" home rc=0 output
    # A throwaway GnuPG home, so nothing is written to ~/.gnupg.
    home="$(mktemp -d)"
    output="$(GNUPGHOME="$home" gpg --batch --show-keys --with-colons --fingerprint "$file" 2>/dev/null)" || rc=$?
    rm -rf -- "$home"
    (( rc == 0 )) || return 1
    awk -F: '$1 == "fpr" {print $10; exit}' <<<"$output"
}

# The deb822 apt source for Docker's repository.
# Usage: docker_sources_text <codename> <architecture>
docker_sources_text() {
    printf '%s\n' \
        "# Managed by wsl-devtools: created by modules/install-docker.sh" \
        "Types: deb" \
        "URIs: ${DOCKER_APT_URL}" \
        "Suites: $1" \
        "Components: stable" \
        "Architectures: $2" \
        "Signed-By: ${DOCKER_KEYRING}"
}

# The daemon.json the toolkit writes when none exists.
docker_daemon_json_text() {
    printf '{\n  "ip": "%s"\n}\n' "$DOCKER_DEFAULT_BIND_IP"
}

# Print the "ip" value of a daemon.json, or nothing.
docker_daemon_ip() {
    local file="${1:-${DOCKER_FS_ROOT}${DOCKER_DAEMON_JSON}}"
    [[ -r "$file" ]] || return 0
    grep -oE '"ip"[[:space:]]*:[[:space:]]*"[^"]*"' "$file" | head -n 1 | sed 's/.*"\([^"]*\)"$/\1/' || true
}

# True when the user is listed in the docker group (it may not be active in this session yet).
user_in_docker_group() {
    local members
    members="$(getent group docker | cut -d: -f4)" || return 1
    [[ ",${members}," == *",${1:-$(id -un)},"* ]]
}

# True when this shell session already has the docker group.
session_has_docker_group() {
    [[ " $(id -nG) " == *" docker "* ]]
}
