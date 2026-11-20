# shellcheck shell=bash
# lib/nginx.sh: Nginx helpers.
#
# Requires lib/common.sh, lib/system.sh and lib/services.sh.
# The toolkit never edits existing Nginx files. It only adds new site files
# and reloads Nginx only after "nginx -t" passes.

if [[ -n "${WSL_DEVTOOLS_NGINX_LOADED:-}" ]]; then
    return 0
fi
WSL_DEVTOOLS_NGINX_LOADED=1

NGINX_DIR="${NGINX_DIR:-/etc/nginx}"   # override for tests
NGINX_SITE_TEMPLATE="${WSL_DEVTOOLS_ROOT}/templates/nginx-site.conf.tpl"

# Validate the whole Nginx configuration (needs root).
nginx_config_test() {
    log_info "Checking the Nginx configuration (nginx -t)."
    if ! run sudo nginx -t; then
        log_error "nginx -t failed. Nginx was not reloaded."
        return 1
    fi
}

# Reload Nginx, but only after the configuration test passes.
nginx_reload() {
    nginx_config_test || return 1
    service_reload nginx
}

# True if a site file with this name exists in sites-available or sites-enabled.
nginx_site_exists() {
    local name="$1"
    [[ -e "${NGINX_DIR}/sites-available/${name}" || -e "${NGINX_DIR}/sites-enabled/${name}" ]]
}

# True if an enabled site or conf.d file already uses this server_name.
nginx_server_name_in_use() {
    local domain="$1" file
    local escaped="${domain//./\\.}"
    for file in "${NGINX_DIR}/sites-enabled"/* "${NGINX_DIR}/conf.d"/*.conf; do
        [[ -f "$file" ]] || continue
        if grep -qE "(^|[[:space:];{])server_name([[:space:]]+[^;]*)?[[:space:]]${escaped}([[:space:];]|$)" "$file"; then
            return 0
        fi
    done
    return 1
}

# Print the template filled in for one site. Inputs must already be validated.
# Usage: render_site_config domain document_root php_fpm_socket
render_site_config() {
    local domain="$1" root="$2" socket="$3" template

    template="$(<"$NGINX_SITE_TEMPLATE")"
    template="${template//\{\{SERVER_NAME\}\}/$domain}"
    template="${template//\{\{DOCUMENT_ROOT\}\}/$root}"
    template="${template//\{\{PHP_FPM_SOCKET\}\}/$socket}"
    template="${template//\{\{CREATED\}\}/$(date '+%Y-%m-%d')}"
    printf '%s\n' "$template"
}

# For "list": print "server_name | root | socket" for one site file.
nginx_site_summary() {
    local file="$1" names root socket
    names="$(awk '$1 == "server_name" { $1 = ""; sub(/;.*/, ""); print; exit }' "$file")"
    root="$(awk '$1 == "root" { sub(/;.*/, "", $2); print $2; exit }' "$file")"
    socket="$(grep -oE 'unix:[^;[:space:]]+' "$file" | head -n 1 || true)"
    printf '%s|%s|%s\n' "${names# }" "${root:--}" "${socket#unix:}"
}
