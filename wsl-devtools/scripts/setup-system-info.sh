#!/usr/bin/env bash
# WSL / Ubuntu developer welcome dashboard
# Usage:
#   bash setup-system-info.sh          Show the dashboard
#   bash setup-system-info.sh --install
#   bash setup-system-info.sh --uninstall

set -u

APP_NAME="wsl-system-info"
INSTALL_DIR="${HOME}/.local/bin"
INSTALL_PATH="${INSTALL_DIR}/${APP_NAME}"
BASHRC="${HOME}/.bashrc"
START_MARKER="# >>> WSL SYSTEM INFO >>>"
END_MARKER="# <<< WSL SYSTEM INFO <<<"

# Colors (disabled automatically when output is not a terminal)
if [[ -t 1 && -z "${NO_COLOR:-}" ]]; then
    C_RESET=$'\033[0m'
    C_BOLD=$'\033[1m'
    C_CYAN=$'\033[36m'
    C_GREEN=$'\033[32m'
    C_YELLOW=$'\033[33m'
    C_BLUE=$'\033[34m'
    C_DIM=$'\033[2m'
else
    C_RESET="" C_BOLD="" C_CYAN="" C_GREEN="" C_YELLOW="" C_BLUE="" C_DIM=""
fi

line() {
    printf '%s\n' "${C_DIM}────────────────────────────────────────────────────────${C_RESET}"
}

section() {
    printf '\n%s%s%s\n' "${C_CYAN}${C_BOLD}" "$1" "${C_RESET}"
    line
}

value_or_missing() {
    local value="$1"
    [[ -n "$value" ]] && printf '%s' "$value" || printf 'Not installed'
}

command_version() {
    local cmd="$1"
    shift
    if command -v "$cmd" >/dev/null 2>&1; then
        "$cmd" "$@" 2>/dev/null | head -n 1
    else
        printf 'Not installed'
    fi
}

show_system() {
    local pretty kernel arch host uptime_text cpu ram disk shell_name wsl_status
    pretty=$(. /etc/os-release 2>/dev/null; printf '%s' "${PRETTY_NAME:-Linux}")
    kernel=$(uname -r 2>/dev/null || printf 'Unknown')
    arch=$(uname -m 2>/dev/null || printf 'Unknown')
    host=$(hostname 2>/dev/null || printf 'Unknown')
    uptime_text=$(uptime -p 2>/dev/null || printf 'Unavailable')
    cpu=$(grep -m1 'model name' /proc/cpuinfo 2>/dev/null | cut -d: -f2- | xargs || uname -p)
    ram=$(free -h 2>/dev/null | awk '/^Mem:/ {print $3 " used / " $2 " total"}')
    disk=$(df -h "$HOME" 2>/dev/null | awk 'NR==2 {print $3 " used / " $2 " total (" $5 " used)"}')
    shell_name="${SHELL##*/}"
    if grep -qi microsoft /proc/version 2>/dev/null; then
        wsl_status="WSL"
    else
        wsl_status="Linux / VM"
    fi

    printf '  %-15s %s\n' "Environment" "$wsl_status"
    printf '  %-15s %s\n' "Operating system" "$pretty"
    printf '  %-15s %s\n' "Kernel" "$kernel"
    printf '  %-15s %s\n' "Hostname" "$host"
    printf '  %-15s %s\n' "Architecture" "$arch"
    printf '  %-15s %s\n' "CPU" "$(value_or_missing "$cpu")"
    printf '  %-15s %s\n' "Memory" "$(value_or_missing "$ram")"
    printf '  %-15s %s\n' "Home disk" "$(value_or_missing "$disk")"
    printf '  %-15s %s\n' "Shell" "$shell_name"
    printf '  %-15s %s\n' "Uptime" "$uptime_text"
}

show_languages() {
    local nvm_version
    printf '  %-15s %s\n' "PHP" "$(command_version php --version)"
    printf '  %-15s %s\n' "Composer" "$(command_version composer --version)"
    printf '  %-15s %s\n' "Node.js" "$(command_version node --version)"
    printf '  %-15s %s\n' "npm" "$(command_version npm --version)"
    printf '  %-15s %s\n' "Python" "$(command_version python3 --version)"
    printf '  %-15s %s\n' "Java" "$(command_version java --version)"
    printf '  %-15s %s\n' "Go" "$(command_version go version)"
    printf '  %-15s %s\n' "Rust" "$(command_version rustc --version)"
    if declare -F nvm >/dev/null 2>&1; then
        nvm_version=$(nvm --version 2>/dev/null || true)
        printf '  %-15s %s\n' "NVM" "$(value_or_missing "$nvm_version")"
        printf '  %-15s %s\n' "NVM active" "$(nvm current 2>/dev/null || printf 'Unknown')"
    else
        printf '  %-15s %s\n' "NVM" "Not loaded / not installed"
    fi
}

show_services() {
    printf '  %-15s %s\n' "Nginx" "$(if command -v nginx >/dev/null 2>&1; then nginx -v 2>&1 | head -n 1; else printf 'Not installed'; fi)"
    printf '  %-15s %s\n' "MySQL client" "$(command_version mysql --version)"
    printf '  %-15s %s\n' "MariaDB client" "$(command_version mariadb --version)"
    printf '  %-15s %s\n' "PostgreSQL" "$(command_version psql --version)"
    printf '  %-15s %s\n' "Redis" "$(command_version redis-server --version)"
    printf '  %-15s %s\n' "Docker" "$(command_version docker --version)"
    printf '  %-15s %s\n' "Git" "$(command_version git --version)"
    printf '  %-15s %s\n' "Xdebug" "$(php -r 'echo phpversion("xdebug") ?: "Not enabled / not installed";' 2>/dev/null || printf 'PHP unavailable')"
}

show_dashboard() {
    clear 2>/dev/null || true
    printf '%s' "${C_CYAN}${C_BOLD}"
    cat <<'BANNER'
 __        __ ____  _       ____             _       __
 \ \      / / ___|| |     / ___|  ___   ___ | | __  \ \
  \ \ /\ / /\___ \| |     \___ \ / _ \ / _ \| |/ /   \ \
   \ V  V /  ___) | |___   ___) | (_) | (_) |   <     > >
    \_/\_/  |____/|_____| |____/ \___/ \___/|_|\_\   /_/
BANNER
    printf '%s' "${C_RESET}"
    printf '%s\n' "                 UBUNTU DEVELOPER ENVIRONMENT"
    printf '%s\n' "                 $(date '+%A, %d %B %Y  %H:%M:%S %Z' 2>/dev/null || date)"
    line

    section "SYSTEM INFORMATION"
    show_system

    section "PROGRAMMING LANGUAGES & RUNTIMES"
    show_languages

    section "DEVELOPMENT TOOLS & SERVICES"
    show_services

    line
    printf '  %s%s%s\n' "${C_GREEN}" "Ready to build. Have a productive session!" "${C_RESET}"
    printf '  %sRun: wsl-system-info --help%s\n' "${C_DIM}" "${C_RESET}"
    line
}

install_dashboard() {
    local source_path
    source_path="$(readlink -f "$0" 2>/dev/null || printf '%s' "$0")"

    if [[ ! -f "$source_path" ]]; then
        printf 'Cannot locate the script file. Save it as setup-system-info.sh first.\n' >&2
        exit 1
    fi

    mkdir -p "$INSTALL_DIR"
    cp "$source_path" "$INSTALL_PATH"
    chmod +x "$INSTALL_PATH"

    touch "$BASHRC"
    if ! grep -Fq 'export PATH="$HOME/.local/bin:$PATH"' "$BASHRC"; then
        printf '\n# User-local command directory\nexport PATH="$HOME/.local/bin:$PATH"\n' >> "$BASHRC"
    fi
    if ! grep -Fq "$START_MARKER" "$BASHRC"; then
        cat >> "$BASHRC" <<'BASHRC_BLOCK'

# >>> WSL SYSTEM INFO >>>
if [[ $- == *i* ]] && command -v wsl-system-info >/dev/null 2>&1; then
    wsl-system-info
fi
# <<< WSL SYSTEM INFO <<<
BASHRC_BLOCK
    fi

    printf 'Installed: %s\n' "$INSTALL_PATH"
    printf 'Updated: %s\n' "$BASHRC"
    printf '\nOpen a new Ubuntu terminal, or run: source ~/.bashrc\n'
}

uninstall_dashboard() {
    if [[ -f "$BASHRC" ]]; then
        sed -i "/$(printf '%s' "$START_MARKER" | sed 's/[.[\*^$]/\\&/g')/,/$(printf '%s' "$END_MARKER" | sed 's/[.[\*^$]/\\&/g')/d" "$BASHRC"
    fi
    rm -f "$INSTALL_PATH"
    printf 'Removed the dashboard command and its .bashrc startup entry.\n'
}

case "${1:-}" in
    --install)
        install_dashboard
        ;;
    --uninstall)
        uninstall_dashboard
        ;;
    --help|-h)
        cat <<'HELP'
WSL System Info dashboard

  bash setup-system-info.sh           Display system and tool versions
  bash setup-system-info.sh --install Install and show it on each interactive shell
  bash setup-system-info.sh --uninstall Remove the command and startup entry

After installation:
  wsl-system-info                      Display the dashboard manually
HELP
        ;;
    *)
        show_dashboard
        ;;
esac
