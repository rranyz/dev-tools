# shellcheck shell=bash
# lib/common.sh: shared helpers for wsl-devtools.
#
# Source this file; do not execute it:
#     source "/path/to/wsl-devtools/lib/common.sh"
#
# Sourcing it defines variables and functions only. It does not change shell
# options; scripts opt in to strict mode by calling enable_strict_mode.

# Guard against being sourced twice.
if [[ -n "${WSL_DEVTOOLS_COMMON_LOADED:-}" ]]; then
    return 0
fi
WSL_DEVTOOLS_COMMON_LOADED=1

# ---------------------------------------------------------------------------
# Paths and settings
# ---------------------------------------------------------------------------

WSL_DEVTOOLS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="${WSL_DEVTOOLS_CONFIG_DIR:-${WSL_DEVTOOLS_ROOT}/config}"   # override for tests
LOG_DIR="${LOG_DIR:-${WSL_DEVTOOLS_ROOT}/logs}"
LOG_FILE="${LOG_FILE:-}"   # empty: messages go to the terminal only
DRY_RUN="${DRY_RUN:-0}"    # 1: run() prints commands instead of executing them

COLOR_RESET=$'\e[0m'
COLOR_BOLD=$'\e[1m'
COLOR_BLUE=$'\e[34m'
COLOR_GREEN=$'\e[32m'
COLOR_YELLOW=$'\e[33m'
COLOR_RED=$'\e[31m'

# ---------------------------------------------------------------------------
# Messages and logging
# ---------------------------------------------------------------------------

# Append one line to LOG_FILE when logging to a file is enabled.
_log_to_file() {
    local level="$1" message="$2"
    if [[ -n "${LOG_FILE}" ]]; then
        printf '%s [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$level" "$message" >>"${LOG_FILE}"
    fi
}

# Print a message to file descriptor 1 or 2, in colour when that is a terminal.
_log() {
    local level="$1" color="$2" fd="$3"
    shift 3
    local message="$*"

    if [[ -t "$fd" && -z "${NO_COLOR:-}" ]]; then
        printf '%s[%s]%s %s\n' "$color" "$level" "$COLOR_RESET" "$message" >&"$fd"
    else
        printf '[%s] %s\n' "$level" "$message" >&"$fd"
    fi
    _log_to_file "$level" "$message"
}

log_info()    { _log "INFO" "$COLOR_BLUE" 1 "$@"; }
log_success() { _log "OK" "$COLOR_GREEN" 1 "$@"; }
log_warn()    { _log "WARN" "$COLOR_YELLOW" 2 "$@"; }
log_error()   { _log "ERROR" "$COLOR_RED" 2 "$@"; }

# Print a section header, e.g. log_step "Checking PHP".
log_step() {
    local title="$*"
    if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
        printf '\n%s==> %s%s\n' "$COLOR_BOLD" "$title" "$COLOR_RESET"
    else
        printf '\n==> %s\n' "$title"
    fi
    _log_to_file "STEP" "$title"
}

# Print an error and exit. Usage: die "message" [exit_code]
die() {
    log_error "$1"
    exit "${2:-1}"
}

# Start writing messages to logs/<name>-YYYYmmdd-HHMMSS.log as well.
# Usage: log_init [name]
log_init() {
    local name="${1:-wsl-devtools}"

    if [[ ! "$name" =~ ^[A-Za-z0-9._-]+$ ]]; then
        log_error "log_init: invalid log name '${name}'"
        return 2
    fi
    mkdir -p "${LOG_DIR}"
    LOG_FILE="${LOG_DIR}/${name}-$(date '+%Y%m%d-%H%M%S').log"
    : >"${LOG_FILE}"
    log_info "Logging to ${LOG_FILE}"
}

# ---------------------------------------------------------------------------
# Error handling
# ---------------------------------------------------------------------------

# Turn on strict mode in the calling script:
#   -e  exit when a command fails      -u  error on unset variables
#   -o pipefail  a pipeline fails if any part fails
#   -E  the ERR trap also fires inside functions
# Call it at the top of entry scripts, right after sourcing this file.
enable_strict_mode() {
    set -Eeuo pipefail
    trap '_on_error "$?" "${BASH_SOURCE[0]:-unknown}" "${LINENO}" "${BASH_COMMAND}"' ERR
}

# ERR trap handler: report where and what failed. Strict mode then exits.
_on_error() {
    local exit_code="$1" file="$2" line="$3" command="$4"
    file="${file#"${WSL_DEVTOOLS_ROOT}"/}"
    log_error "Command failed (exit ${exit_code}) at ${file}:${line}: ${command}"
}

# ---------------------------------------------------------------------------
# Running commands
# ---------------------------------------------------------------------------

# Quote a command so it can be shown exactly as it would run.
_format_command() {
    local formatted
    printf -v formatted '%q ' "$@"
    printf '%s' "${formatted% }"
}

# Show and run a command that changes the system. With DRY_RUN=1 the command is
# only shown. Returns the command's exit status.
# Usage: run sudo apt-get install -y nginx
run() {
    if (( $# == 0 )); then
        log_error "run: no command given"
        return 2
    fi
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] $(_format_command "$@")"
        return 0
    fi
    log_info "Running: $(_format_command "$@")"
    "$@"
}

# Describe a module exit code (see docs/architecture.md, module contract).
exit_code_meaning() {
    case "${1:-}" in
        0) echo "done" ;;
        2) echo "nothing to do" ;;
        3) echo "not possible: a requirement is not met" ;;
        4) echo "cancelled" ;;
        *) echo "failed (exit ${1:-?})" ;;
    esac
}

# ---------------------------------------------------------------------------
# Downloads
# ---------------------------------------------------------------------------

# Print a file's SHA-256 (hex).
sha256_of() {
    local sum
    sum="$(sha256sum "$1")" || return 1
    echo "${sum%% *}"
}

# Download a URL to a file and check its SHA-256 before anyone uses it.
# Returns 1 (with a message) when the download fails or the checksum differs.
# Usage: download_checked <url> <destination> <expected-sha256>
download_checked() {
    local url="$1" destination="$2" expected="$3" actual
    if ! curl -fsSL --max-time 300 -o "$destination" "$url"; then
        log_error "Downloading ${url} failed."
        return 1
    fi
    actual="$(sha256_of "$destination")" || return 1
    if [[ "$actual" != "$expected" ]]; then
        log_error "Checksum mismatch for ${url}: expected ${expected}, got ${actual}. The file is not used."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# Command and dependency checks
# ---------------------------------------------------------------------------

# True if a command, function or builtin with this name is available.
command_exists() {
    command -v "${1:-}" >/dev/null 2>&1
}

# Check several commands at once and report every missing one.
# Usage: require_commands curl git || return 3
require_commands() {
    local missing=() cmd
    for cmd in "$@"; do
        command_exists "$cmd" || missing+=("$cmd")
    done
    if (( ${#missing[@]} > 0 )); then
        log_error "Missing required command(s): ${missing[*]}"
        return 1
    fi
}

# NVM is per-user, so the toolkit must run as the normal user and use sudo per command.
require_not_root() {
    if (( EUID == 0 )); then
        log_error "Do not run this as root or with sudo. Run it as your normal user; it asks for sudo when needed."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# User confirmation
# ---------------------------------------------------------------------------

# Ask a yes/no question. Returns 0 for yes, 1 for no. Empty input means no.
# Without an interactive terminal it answers no, so nothing risky runs unattended.
# Usage: if confirm "Install PHP 7.4?"; then ...; fi
confirm() {
    local question="$1" answer

    if [[ ! -t 0 ]]; then
        log_warn "No interactive terminal; answering 'no' to: ${question}"
        return 1
    fi
    while true; do
        read -r -p "${question} [y/N] " answer || return 1
        case "${answer,,}" in
            y | yes) _log_to_file "CONFIRM" "${question} -> yes"; return 0 ;;
            n | no | "") _log_to_file "CONFIRM" "${question} -> no"; return 1 ;;
            *) log_warn "Please answer y or n." ;;
        esac
    done
}

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

# Non-negative whole number, e.g. 0, 42.
is_integer() {
    [[ "${1:-}" =~ ^[0-9]+$ ]]
}

# TCP/UDP port number 1-65535.
is_valid_port() {
    local port="${1:-}"
    is_integer "$port" && (( ${#port} <= 5 )) && (( 10#$port >= 1 && 10#$port <= 65535 ))
}

# MAJOR.MINOR version, e.g. 8.4 or 7.4.
is_valid_version() {
    [[ "${1:-}" =~ ^[0-9]+\.[0-9]+$ ]]
}

# Lowercase domain name with at least one dot, e.g. myapp.test.
is_valid_domain() {
    local domain="${1:-}"
    local label='[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?'
    local pattern="^(${label}\\.)+${label}\$"
    (( ${#domain} <= 253 )) && [[ "$domain" =~ $pattern ]]
}

# Absolute path made only of letters, digits and . _ / -, with no ".." part.
# Used for paths written into config files, e.g. an Nginx document root.
is_safe_path() {
    local path="${1:-}"
    [[ "$path" =~ ^/[A-Za-z0-9._/-]+$ && "/${path}/" != *"/../"* ]]
}

# True if the first argument equals one of the others.
# Usage: is_one_of "$choice" install status verify
is_one_of() {
    local value="${1:-}" item
    shift
    for item in "$@"; do
        [[ "$item" == "$value" ]] && return 0
    done
    return 1
}

# True if the version is listed in PHP_VERSIONS (config/versions.conf).
is_supported_php_version() {
    local version="${1:-}"
    local -a versions

    if [[ -z "${PHP_VERSIONS:-}" ]]; then
        log_error "PHP_VERSIONS is not set; load config/versions.conf first."
        return 2
    fi
    read -r -a versions <<<"${PHP_VERSIONS}"
    is_valid_version "$version" && is_one_of "$version" "${versions[@]}"
}

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

_CONFIG_SKIP_PATTERN='^[[:space:]]*(#.*)?$'
_CONFIG_LINE_PATTERN='^[A-Z][A-Z0-9_]*="[^"$`\\]*"$'

# Source a config file only after checking every line is a plain assignment.
# This prevents a config file from running commands when it is loaded.
# Usage: load_config "${CONFIG_DIR}/versions.conf"
load_config() {
    local file="${1:-}" line line_number=0

    if [[ -z "$file" ]]; then
        log_error "load_config: no file given"
        return 2
    fi
    if [[ ! -f "$file" || ! -r "$file" ]]; then
        log_error "Config file not found or not readable: ${file}"
        return 1
    fi

    while IFS= read -r line || [[ -n "$line" ]]; do
        line_number=$((line_number + 1))
        if [[ "$line" == *$'\r' ]]; then
            log_error "${file}:${line_number} has Windows (CRLF) line endings. Fix with: sed -i 's/\\r\$//' '${file}'"
            return 1
        fi
        [[ "$line" =~ $_CONFIG_SKIP_PATTERN ]] && continue
        if [[ ! "$line" =~ $_CONFIG_LINE_PATTERN ]]; then
            log_error "Refusing to load ${file}: line ${line_number} is not a plain NAME=\"value\" assignment: ${line}"
            return 1
        fi
    done <"$file"

    # shellcheck source=/dev/null
    source "$file"
}

# True when DRY_RUN is unset, 0 or 1. Only "1" means a dry run, so a value like "yes" or
# "true" would silently mean a real run; every entry script refuses it instead.
is_valid_dry_run() {
    is_one_of "${DRY_RUN:-}" "" 0 1
}

# Load the project's standard config files from CONFIG_DIR. Every module and script calls
# this first, so it also refuses an invalid DRY_RUN before anything can run.
load_project_config() {
    if ! is_valid_dry_run; then
        log_error "DRY_RUN='${DRY_RUN}' is not valid. Use DRY_RUN=1 for a dry run, or leave it unset."
        return 3
    fi
    load_config "${CONFIG_DIR}/versions.conf" && load_config "${CONFIG_DIR}/packages.conf"
}
