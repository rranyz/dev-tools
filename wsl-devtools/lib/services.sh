# shellcheck shell=bash
# lib/services.sh: systemd service helpers.
#
# Requires lib/common.sh and lib/system.sh. Read-only helpers work without
# sudo. Helpers that change a service first make sure systemd is usable and
# refuse otherwise: there is no fallback to manual service management.

if [[ -n "${WSL_DEVTOOLS_SERVICES_LOADED:-}" ]]; then
    return 0
fi
WSL_DEVTOOLS_SERVICES_LOADED=1

_SYSTEMD_READY=""   # cached result of check_systemd: "", "yes" or "no"

# True when systemd is usable. Runs (and logs) check_systemd once per script.
systemd_ready() {
    if [[ -z "$_SYSTEMD_READY" ]]; then
        if check_systemd; then _SYSTEMD_READY="yes"; else _SYSTEMD_READY="no"; fi
    fi
    [[ "$_SYSTEMD_READY" == "yes" ]]
}

service_is_active() {
    systemctl is-active --quiet "$1" 2>/dev/null
}

service_is_enabled() {
    systemctl is-enabled --quiet "$1" 2>/dev/null
}

# Print "active"/"inactive"/... for status displays.
service_state() {
    # is-active exits non-zero for anything but "active"; only its output matters here.
    systemctl is-active "$1" 2>/dev/null || true
}

# Reload a running service gracefully. Returns 3 when systemd is not usable.
service_reload() {
    systemd_ready || return 3
    run sudo systemctl reload "$1"
}

# Enable a service at boot and start it now. Returns 3 when systemd is not usable.
service_enable_now() {
    systemd_ready || return 3
    run sudo systemctl enable --now "$1"
}

# Restart a service (used right after the toolkit created its configuration).
service_restart() {
    systemd_ready || return 3
    run sudo systemctl restart "$1"
}

# Make systemd read new or changed unit files.
service_daemon_reload() {
    systemd_ready || return 3
    run sudo systemctl daemon-reload
}
