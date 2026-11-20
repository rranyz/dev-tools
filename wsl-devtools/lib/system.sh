# shellcheck shell=bash
# lib/system.sh: read-only detection of the environment.
#
# Requires lib/common.sh to be sourced first. Nothing in this file changes the
# system. The only command that can prompt is require_sudo (sudo -v).
#
# Detection functions accept an optional file path so tests can use fixtures.

if [[ -n "${WSL_DEVTOOLS_SYSTEM_LOADED:-}" ]]; then
    return 0
fi
WSL_DEVTOOLS_SYSTEM_LOADED=1

OS_ID=""
OS_VERSION_ID=""
OS_CODENAME=""
OS_PRETTY_NAME=""

# ---------------------------------------------------------------------------
# Ubuntu
# ---------------------------------------------------------------------------

# Parse /etc/os-release (without sourcing it) into OS_ID, OS_VERSION_ID,
# OS_CODENAME and OS_PRETTY_NAME. Usage: read_os_release [file]
# SC2120: the file argument is for test fixtures. SC2034: OS_CODENAME is used by the modules.
# shellcheck disable=SC2120,SC2034
read_os_release() {
    local file="${1:-/etc/os-release}" key value

    OS_ID="" OS_VERSION_ID="" OS_CODENAME="" OS_PRETTY_NAME=""
    if [[ ! -r "$file" ]]; then
        log_error "Cannot read ${file}; unable to identify the Linux distribution."
        return 1
    fi
    while IFS='=' read -r key value || [[ -n "$key" ]]; do
        value="${value%\"}"
        value="${value#\"}"
        case "$key" in
            ID) OS_ID="$value" ;;
            VERSION_ID) OS_VERSION_ID="$value" ;;
            VERSION_CODENAME) OS_CODENAME="$value" ;;
            PRETTY_NAME) OS_PRETTY_NAME="$value" ;;
        esac
    done <"$file"
}

is_ubuntu() {
    [[ "$OS_ID" == "ubuntu" ]]
}

# True for the release in SUPPORTED_UBUNTU_VERSION (config/versions.conf).
is_supported_ubuntu() {
    is_ubuntu && [[ -n "${SUPPORTED_UBUNTU_VERSION:-}" && "$OS_VERSION_ID" == "$SUPPORTED_UBUNTU_VERSION" ]]
}

# ---------------------------------------------------------------------------
# WSL
# ---------------------------------------------------------------------------

# Print "2" for WSL2, "1" for WSL1, "unknown" for a WSL kernel whose version
# cannot be told, and nothing when not running under WSL.
#   WSL2 kernels: 6.6.87.2-microsoft-standard-WSL2
#   WSL1 (no real kernel): 4.4.0-19041-Microsoft
# Usage: detect_wsl_version [osrelease_file]
# shellcheck disable=SC2120 # the file argument is for test fixtures
detect_wsl_version() {
    local file="${1:-/proc/sys/kernel/osrelease}" release

    [[ -r "$file" ]] || return 0
    release="$(<"$file")"
    if [[ "$release" == *WSL2* ]]; then
        echo "2"
    elif [[ "$release" == *-Microsoft ]]; then
        echo "1"
    elif [[ "${release,,}" == *microsoft* ]]; then
        echo "unknown"
    fi
}

# ---------------------------------------------------------------------------
# systemd
# ---------------------------------------------------------------------------

# True when PID 1 is systemd. Usage: is_systemd_pid1 [comm_file]
# shellcheck disable=SC2120 # the file argument is for test fixtures
is_systemd_pid1() {
    local file="${1:-/proc/1/comm}"
    [[ -r "$file" && "$(<"$file")" == "systemd" ]]
}

# Print the overall systemd state (running, degraded, offline, ...).
systemd_state() {
    command_exists systemctl || return 1
    # is-system-running exits non-zero for "degraded" and others; only its output matters here.
    systemctl is-system-running 2>/dev/null || true
}

# "degraded" means some units failed (common under WSL for desktop units); services still work.
is_usable_systemd_state() {
    is_one_of "${1:-}" running degraded starting initializing
}

_explain_systemd_setup() {
    log_info "Service operations are stopped. This toolkit does not change WSL settings."
    log_info "To enable systemd yourself: add these lines to /etc/wsl.conf"
    log_info "    [boot]"
    log_info "    systemd=true"
    log_info "then run 'wsl.exe --shutdown' in Windows PowerShell and reopen Ubuntu."
}

# ---------------------------------------------------------------------------
# sudo
# ---------------------------------------------------------------------------

# Print one of: ready (sudo works now without a password), password (the user may
# use sudo and will be asked for a password), denied, missing. Never prompts.
sudo_status() {
    local groups

    if ! command_exists sudo; then
        echo "missing"
        return 0
    fi
    # -n: never prompt. Failure only means a password would be needed.
    if sudo -n true 2>/dev/null; then
        echo "ready"
        return 0
    fi
    groups=" $(id -nG) "
    if [[ "$groups" == *" sudo "* || "$groups" == *" admin "* ]]; then
        echo "password"
    else
        echo "denied"
    fi
}

# True when a sudo command can run now: sudo needs no password, or there is a
# terminal to ask for one. Read-only "verify" actions use this to skip root-only
# checks (like "nginx -t") in unattended runs instead of hanging on a prompt.
can_use_sudo_now() {
    local status
    status="$(sudo_status)"
    [[ "$status" == "ready" || ( "$status" == "password" && -t 0 ) ]]
}

# Ask for the sudo password now, right before a real change.
require_sudo() {
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] sudo -v"
        return 0
    fi
    log_info "Administrator rights are needed. You may be asked for your password."
    if ! sudo -v; then
        log_error "Could not get sudo rights."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# APT
# ---------------------------------------------------------------------------

# Print running apt/dpkg processes (pid and name), if any. Informational only.
# Matches the real unattended-upgrade run (/usr/bin/unattended-upgrade), not the
# always-running unattended-upgrade-shutdown helper.
apt_busy_process() {
    command_exists pgrep || return 0
    # pgrep exits 1 when nothing matches, which is the normal case.
    pgrep -l -x 'apt|apt-get|dpkg' || true
    pgrep -l -f '/usr/bin/unattended-upgrade( |$)' || true
}

# ---------------------------------------------------------------------------
# Network
# ---------------------------------------------------------------------------

# Print listening TCP sockets on a port (empty when the port is free).
port_listeners() {
    # ss fails only when it cannot read socket information; an empty answer means "free".
    ss -Hltn "sport = :$1" 2>/dev/null || true
}

# Print the local addresses listening on a TCP port, one per line (e.g. 127.0.0.1:3306).
port_listen_addresses() {
    port_listeners "$1" | awk '{print $4}'
}

# True for a listener address on the loopback interface: 127.x.x.x, [::1], localhost.
# Usage: is_loopback_listener 127.0.0.1:3306
is_loopback_listener() {
    local address="${1%:*}"
    address="${address#[}"
    address="${address%]}"
    address="${address%%\%*}"   # drop an interface suffix such as %lo
    [[ "$address" == 127.* || "$address" == "::1" || "$address" == "localhost" ]]
}

# Log every listener of a port as local-only or not. Returns 1 when one is not loopback.
# Usage: report_port_listeners <port> [label]
report_port_listeners() {
    local port="$1" label="${2:-port $1}" address exposed=0
    local -a addresses
    mapfile -t addresses < <(port_listen_addresses "$port")
    if (( ${#addresses[@]} == 0 )); then
        log_info "${label}: nothing listening"
        return 0
    fi
    for address in "${addresses[@]}"; do
        if is_loopback_listener "$address"; then
            log_info "${label}: listening on ${address} (this machine only)"
        else
            log_warn "${label}: listening on ${address}, which is not limited to this machine."
            exposed=1
        fi
    done
    return "$exposed"
}

# ---------------------------------------------------------------------------
# Checks: each logs its result and returns 0 (ok) or 1 (problem)
# ---------------------------------------------------------------------------

check_not_root() {
    require_not_root
}

check_os() {
    read_os_release || return 1
    if ! is_ubuntu; then
        log_error "OS: ${OS_PRETTY_NAME:-${OS_ID:-unknown}}. This toolkit supports Ubuntu only."
        return 1
    fi
    if ! is_supported_ubuntu; then
        log_error "OS: ${OS_PRETTY_NAME}. Supported: Ubuntu ${SUPPORTED_UBUNTU_VERSION:-?} (${SUPPORTED_UBUNTU_CODENAME:-?}) only."
        return 1
    fi
    log_success "OS: ${OS_PRETTY_NAME}"
}

check_wsl2() {
    local version
    version="$(detect_wsl_version)"
    case "$version" in
        2)
            log_success "WSL: WSL2"
            ;;
        1)
            log_error "WSL: WSL1. This toolkit needs WSL2. Convert from Windows with 'wsl.exe --set-version <distro> 2' (not done by this toolkit)."
            return 1
            ;;
        unknown)
            log_error "WSL: version unclear (kernel $(uname -r)). Expected a kernel name containing 'WSL2'."
            return 1
            ;;
        *)
            log_error "WSL: not detected. This toolkit targets Ubuntu on WSL2."
            return 1
            ;;
    esac
}

check_apt() {
    require_commands apt-get apt-cache dpkg dpkg-query || return 1
    log_success "APT: available"
}

check_sudo() {
    case "$(sudo_status)" in
        ready) log_success "sudo: available" ;;
        password) log_success "sudo: available (your password will be asked when needed)" ;;
        missing)
            log_error "sudo: not installed."
            return 1
            ;;
        *)
            log_error "sudo: user '$(id -un)' is not in the sudo group."
            return 1
            ;;
    esac
}

check_systemd() {
    local state

    if ! is_systemd_pid1; then
        log_error "systemd: not running as PID 1 (PID 1 is '$(cat /proc/1/comm 2>/dev/null || echo unknown)')."
        _explain_systemd_setup
        return 1
    fi
    if ! command_exists systemctl; then
        log_error "systemd: systemctl command not found."
        return 1
    fi
    state="$(systemd_state)"
    if ! is_usable_systemd_state "$state"; then
        log_error "systemd: systemctl reports '${state:-no answer}'."
        _explain_systemd_setup
        return 1
    fi
    if [[ "$state" == "degraded" ]]; then
        log_success "systemd: running (degraded: some units failed, see 'systemctl --failed'; this does not block the toolkit)"
    else
        log_success "systemd: ${state}"
    fi
}

# Run the checks every module needs, stopping at the first problem.
# Returns 3 (precondition not met) on failure.
# Usage: preflight [--needs-systemd]
preflight() {
    log_step "Checking the system"
    if ! { check_not_root && check_os && check_wsl2 && check_apt && check_sudo; }; then
        return 3
    fi
    if [[ "${1:-}" == "--needs-systemd" ]]; then
        check_systemd || return 3
    fi
}
