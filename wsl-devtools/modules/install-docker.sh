#!/usr/bin/env bash
# modules/install-docker.sh: Docker Engine inside Ubuntu, from Docker's official apt repository.
#
# Usage: install-docker.sh status|install|verify|test-run
#   status    Docker Desktop integration, other engines, Docker Engine, services, daemon.json,
#             docker group (read-only)
#   install   explain the approach, then (asks first) add Docker's signed apt repository,
#             install Docker Engine, make published ports default to 127.0.0.1 when no
#             daemon.json exists, start it, and offer the docker group (asked separately)
#   verify    packages, services, socket, server version, daemon.json, group
#   test-run  run the hello-world container (asks first: it downloads from Docker Hub)
#
# Never installs a second daemon next to Docker Desktop's WSL integration or another engine,
# never removes packages, never changes an existing daemon.json or apt source.
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
# shellcheck source=../lib/docker.sh
source "${MODULE_DIR}/../lib/docker.sh"

DOCKER_PACKAGE_LIST=()
DOCKER_TMP_DIR=""

usage() {
    printf 'Usage: %s status|install|verify|test-run\n' "$(basename "$0")"
}

cleanup() {
    if [[ -n "$DOCKER_TMP_DIR" ]]; then
        rm -rf -- "$DOCKER_TMP_DIR"
    fi
}

docker_engine_installed() {
    [[ -z "$(missing_packages "${DOCKER_PACKAGE_LIST[@]}")" ]]
}

# Print how to run docker commands now: "docker" when this session can use the socket,
# "sudo docker" when sudo can be used, or nothing.
docker_command() {
    if [[ -S "$DOCKER_SOCKET" && -w "$DOCKER_SOCKET" && -r "$DOCKER_SOCKET" ]]; then
        echo "docker"
    elif can_use_sudo_now; then
        echo "sudo docker"
    fi
}

# ---------------------------------------------------------------------------
# status / verify
# ---------------------------------------------------------------------------

docker_status() {
    local reason exe conflicts ip
    log_step "Docker: status"
    reason="$(docker_desktop_integration)"
    if [[ -n "$reason" ]]; then
        log_info "Docker Desktop WSL integration: active (${reason})"
    else
        log_info "Docker Desktop WSL integration: not detected"
    fi
    exe="$(docker_exe_path)"
    [[ -n "$exe" ]] && log_info "Docker Desktop for Windows: docker.exe found at ${exe}"
    conflicts="$(docker_conflicting_packages | tr '\n' ' ')"
    [[ -n "$conflicts" ]] && log_info "Other Docker/container packages installed: ${conflicts% }"
    if docker_engine_installed; then
        log_info "Docker Engine (docker-ce): installed ($(package_version docker-ce))"
        log_info "service docker: $(service_state docker), $(service_is_enabled docker && echo "starts at boot" || echo "does not start at boot"); containerd: $(service_state containerd)"
    else
        log_info "Docker Engine (docker-ce): not installed (missing: $(missing_packages "${DOCKER_PACKAGE_LIST[@]}" | tr '\n' ' ' | sed 's/ $//'))"
    fi
    if apt_source_configured "$DOCKER_SOURCE_PATTERN"; then
        log_info "apt source for ${DOCKER_APT_URL}: configured"
    fi
    if [[ -e "$DOCKER_DAEMON_JSON" ]]; then
        ip="$(docker_daemon_ip)"
        log_info "${DOCKER_DAEMON_JSON}: present (default bind address for published ports: ${ip:-not set, all interfaces})"
    fi
    if getent group docker >/dev/null; then
        if session_has_docker_group; then
            log_info "docker group: $(id -un) is a member (active in this shell)"
        elif user_in_docker_group; then
            log_info "docker group: $(id -un) is a member, active in new shells only"
        else
            log_info "docker group: $(id -un) is not a member (docker commands need sudo)"
        fi
    fi
}

docker_verify() {
    local failed=0 cmd version ip
    log_step "Docker: verify"
    if ! docker_engine_installed; then
        log_error "Docker Engine is not installed (missing: $(missing_packages "${DOCKER_PACKAGE_LIST[@]}" | tr '\n' ' ' | sed 's/ $//'))."
        return 1
    fi
    log_success "docker-ce: $(package_version docker-ce)"
    local unit
    for unit in docker containerd; do
        if service_is_active "$unit"; then
            log_success "service ${unit}: active"
        else
            log_error "service ${unit}: $(service_state "$unit"). Start it with: sudo systemctl start ${unit}"
            failed=1
        fi
        service_is_enabled "$unit" || log_warn "service ${unit} does not start at boot. Enable it with: sudo systemctl enable ${unit}"
    done
    if [[ -S "$DOCKER_SOCKET" ]]; then
        log_success "socket: ${DOCKER_SOCKET}"
    else
        log_error "socket missing: ${DOCKER_SOCKET}"
        failed=1
    fi
    cmd="$(docker_command)"
    if [[ -z "$cmd" ]]; then
        log_warn "Server check skipped: this shell cannot use the docker socket and sudo cannot ask for a password here."
    else
        # shellcheck disable=SC2086 # cmd is "docker" or "sudo docker"
        if version="$($cmd info --format '{{.ServerVersion}}' 2>/dev/null)" && [[ -n "$version" ]]; then
            log_success "Docker server ${version} answers (${cmd} info)"
        else
            log_error "The Docker server does not answer (${cmd} info)."
            failed=1
        fi
    fi
    ip="$(docker_daemon_ip)"
    if [[ "$ip" == "$DOCKER_DEFAULT_BIND_IP" ]]; then
        log_success "published ports default to ${ip} (${DOCKER_DAEMON_JSON})"
    else
        log_info "published ports default to ${ip:-all interfaces}. Publish locally with: docker run -p 127.0.0.1:8080:80 ..."
    fi
    if session_has_docker_group; then
        log_success "docker group active in this shell: docker works without sudo"
    elif user_in_docker_group; then
        log_info "You are in the docker group; it takes effect in new shells (close all WSL terminals first)."
    else
        log_info "You are not in the docker group: use 'sudo docker ...'."
    fi
    return "$failed"
}

# ---------------------------------------------------------------------------
# install
# ---------------------------------------------------------------------------

# Exit 3 when Docker Desktop's integration or another engine is present.
docker_refuse_conflicts() {
    local reason conflicts
    reason="$(docker_desktop_integration)"
    if [[ -n "$reason" ]]; then
        log_error "Docker Desktop's WSL integration is active: ${reason}."
        log_error "Installing Docker Engine here would add a second daemon: two Docker hosts with their own images"
        log_error "and containers, a docker CLI and socket that point to one or the other, and confusing port bindings."
        log_info "Keep using Docker Desktop. To use Docker Engine here instead, first turn off the integration for this"
        log_info "distro in Docker Desktop (Settings > Resources > WSL integration) and reopen the terminal. Nothing was changed."
        exit 3
    fi
    conflicts="$(docker_conflicting_packages | tr '\n' ' ')"
    if [[ -n "$conflicts" ]]; then
        log_error "Other Docker or container packages are installed: ${conflicts% }."
        log_error "Docker's packages conflict with them, and the toolkit never removes packages. Nothing was changed."
        log_info "Keep using the installed engine, or remove those packages yourself (after saving any images and"
        log_info "containers you need), then rerun."
        exit 3
    fi
}

docker_explain_plan() {
    local -a missing
    local pkg
    mapfile -t missing < <(missing_packages "${DOCKER_PACKAGE_LIST[@]}")
    log_step "Docker: installation approach"
    log_info "Docker Engine runs inside this Ubuntu distro, as a systemd service (docker, containerd)."
    log_info "Source: Docker's official apt repository ${DOCKER_APT_URL} (suite ${OS_CODENAME}, stable)."
    log_info "Its signing key is downloaded and must have the fingerprint ${DOCKER_GPG_FINGERPRINT}."
    log_info "New files:"
    if [[ -e "$DOCKER_KEYRING" ]]; then
        log_info "  ${DOCKER_KEYRING} exists: kept if it is the same key, otherwise the install stops"
    else
        log_info "  ${DOCKER_KEYRING} (the signing key)"
    fi
    if apt_source_configured "$DOCKER_SOURCE_PATTERN"; then
        log_info "  apt source: already configured, kept as it is"
    else
        log_info "  ${DOCKER_SOURCES_FILE} (the apt source)"
    fi
    if [[ -e "$DOCKER_DAEMON_JSON" ]]; then
        log_info "  ${DOCKER_DAEMON_JSON} exists and is not changed (published ports: $(docker_daemon_ip | sed 's/^$/all interfaces/'))"
    else
        log_info "  ${DOCKER_DAEMON_JSON} with {\"ip\": \"${DOCKER_DEFAULT_BIND_IP}\"}: 'docker run -p 8080:80' then listens on"
        log_info "  ${DOCKER_DEFAULT_BIND_IP}:8080 only; publish elsewhere explicitly with -p 0.0.0.0:8080:80"
    fi
    log_info "Packages:"
    for pkg in "${missing[@]}"; do
        log_info "  ${pkg}"
    done
    log_info "Afterwards you are asked separately whether to join the docker group."
    log_info "WSL: Windows reaches published ports as localhost:<port> through WSL's localhost forwarding."
    log_info "Docker manages its own iptables/nftables rules for containers."
}

# Download the signing key and install it, after checking its fingerprint.
docker_install_key() {
    local key="${DOCKER_TMP_DIR}/docker.asc" fingerprint
    if ! curl -fsSL --max-time 60 -o "$key" "${DOCKER_APT_URL}/gpg"; then
        log_error "Downloading ${DOCKER_APT_URL}/gpg failed."
        return 1
    fi
    fingerprint="$(key_fingerprint "$key")" || fingerprint=""
    if [[ "$fingerprint" != "$DOCKER_GPG_FINGERPRINT" ]]; then
        log_error "The downloaded key has fingerprint '${fingerprint:-unreadable}', expected ${DOCKER_GPG_FINGERPRINT}. Nothing was installed."
        return 1
    fi
    log_success "Signing key fingerprint verified: ${fingerprint}"
    if [[ -e "$DOCKER_KEYRING" ]]; then
        if cmp -s "$key" "$DOCKER_KEYRING"; then
            log_success "${DOCKER_KEYRING} already holds this key."
            return 0
        fi
        log_error "${DOCKER_KEYRING} exists with different content. It is not overwritten; check it yourself."
        return 3
    fi
    run sudo install -d -m 0755 "$(dirname "$DOCKER_KEYRING")" || return 1
    run sudo install -m 0644 -o root -g root "$key" "$DOCKER_KEYRING"
}

docker_install_source() {
    local file="${DOCKER_TMP_DIR}/docker.sources"
    if apt_source_configured "$DOCKER_SOURCE_PATTERN"; then
        log_success "apt source for ${DOCKER_APT_URL} already configured. Kept as it is."
        return 0
    fi
    if [[ -e "$DOCKER_SOURCES_FILE" ]]; then
        log_error "${DOCKER_SOURCES_FILE} exists but does not point to ${DOCKER_APT_URL}. It is not overwritten."
        return 3
    fi
    docker_sources_text "$OS_CODENAME" "$(dpkg --print-architecture)" >"$file"
    run sudo install -m 0644 -o root -g root "$file" "$DOCKER_SOURCES_FILE"
}

docker_install_daemon_json() {
    local file="${DOCKER_TMP_DIR}/daemon.json"
    [[ -e "$DOCKER_DAEMON_JSON" ]] && return 0
    docker_daemon_json_text >"$file"
    run sudo install -d -m 0755 "$(dirname "$DOCKER_DAEMON_JSON")" || return 1
    run sudo install -m 0644 -o root -g root "$file" "$DOCKER_DAEMON_JSON"
}

docker_offer_group() {
    local user
    user="$(id -un)"
    if user_in_docker_group "$user"; then
        log_success "${user} is already in the docker group."
        return 0
    fi
    log_step "Docker: run docker without sudo?"
    log_warn "Members of the docker group control the Docker daemon, which runs as root: this is equivalent to"
    log_warn "root access on this distro. Without it, use 'sudo docker ...'."
    if ! confirm "Add ${user} to the docker group?"; then
        log_info "Not added. You can do it later with: sudo usermod -aG docker ${user}"
        return 0
    fi
    run sudo usermod -aG docker "$user" || return 1
    log_success "${user} added to the docker group. It takes effect in new shells:"
    log_info "close all WSL terminals (or run 'wsl.exe --terminate <distro>' in Windows), then reopen Ubuntu."
}

docker_install() {
    local -a prerequisites prerequisites_missing missing
    local rc=0 unit

    preflight --needs-systemd || exit 3
    read_os_release || exit 3

    if docker_engine_installed; then
        log_success "Docker Engine is already installed. Nothing to do."
        docker_verify || exit 1
        exit 2
    fi
    log_step "Docker: checks before installing"
    docker_refuse_conflicts
    if [[ -n "$(docker_exe_path)" ]]; then
        log_warn "docker.exe was found: Docker Desktop is installed on Windows, with its WSL integration off for this distro."
        log_warn "If you later turn that integration on, it will clash with Docker Engine installed here."
    fi
    log_success "No Docker Desktop integration and no other engine in this distro."

    docker_explain_plan
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] Nothing changed. No network access was made."
        return 0
    fi
    if ! confirm "Install Docker Engine this way?"; then
        log_warn "Cancelled. Nothing was changed."
        exit 4
    fi

    DOCKER_TMP_DIR="$(mktemp -d)"
    trap cleanup EXIT
    read -r -a prerequisites <<<"${APT_PREREQUISITE_PACKAGES:-}"
    mapfile -t prerequisites_missing < <(missing_packages "${prerequisites[@]}")
    if (( ${#prerequisites_missing[@]} > 0 )); then
        install_missing_packages "${prerequisites_missing[@]}" || rc=$?
        (( rc == 0 )) || exit "$rc"
    fi
    require_sudo || exit 3
    docker_install_key || exit $?
    docker_install_source || exit $?
    docker_install_daemon_json || exit 1
    mapfile -t missing < <(missing_packages "${DOCKER_PACKAGE_LIST[@]}")
    install_missing_packages "${missing[@]}" || rc=$?
    (( rc == 0 )) || exit "$rc"
    for unit in containerd docker; do
        if ! service_is_active "$unit"; then
            service_enable_now "$unit" || exit 1
        fi
    done
    docker_offer_group || exit 1
    docker_verify || exit 1
    log_success "Docker Engine installed. Try: $(basename "$0") test-run"
}

docker_test_run() {
    local cmd output
    if ! docker_engine_installed || ! service_is_active docker; then
        log_error "Docker Engine is not installed or not running. Install it first: $(basename "$0") install"
        exit 3
    fi
    cmd="$(docker_command)"
    if [[ -z "$cmd" ]]; then
        log_error "This shell cannot use the docker socket and sudo cannot ask for a password here. Run this in a terminal."
        exit 3
    fi
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] Would run: ${cmd} run --rm hello-world"
        return 0
    fi
    if ! confirm "Download the hello-world image from Docker Hub and run it once (${cmd} run --rm hello-world)?"; then
        log_warn "Cancelled."
        exit 4
    fi
    # shellcheck disable=SC2086 # cmd is "docker" or "sudo docker"
    if output="$($cmd run --rm hello-world 2>&1)" && grep -q 'Hello from Docker!' <<<"$output"; then
        log_success "hello-world ran: containers work."
    else
        log_error "hello-world did not run:"
        printf '%s\n' "$output" | sed 's/^/    /'
        exit 1
    fi
}

main() {
    enable_strict_mode
    load_project_config || exit 3
    read -r -a DOCKER_PACKAGE_LIST <<<"${DOCKER_PACKAGES:-}"
    if (( ${#DOCKER_PACKAGE_LIST[@]} == 0 )); then
        die "DOCKER_PACKAGES is empty in ${CONFIG_DIR}/packages.conf" 3
    fi
    if [[ ! "${DOCKER_GPG_FINGERPRINT:-}" =~ ^[0-9A-F]{40}$ ]] || ! is_loopback_listener "${DOCKER_DEFAULT_BIND_IP:-}:0"; then
        die "config/versions.conf: DOCKER_GPG_FINGERPRINT must be 40 uppercase hex characters and DOCKER_DEFAULT_BIND_IP a loopback address." 3
    fi

    case "${1:-}" in
        status) docker_status ;;
        verify) docker_verify || exit 1 ;;
        install) docker_install ;;
        test-run) docker_test_run ;;
        *)
            usage
            exit 3
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
