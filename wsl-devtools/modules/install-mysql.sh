#!/usr/bin/env bash
# modules/install-mysql.sh: MySQL server and client from Ubuntu's archive (MySQL 8.0 on 24.04).
#
# Usage: install-mysql.sh status|install|verify|guide
#   status   packages, service, ports, socket, data directory (read-only)
#   install  install if missing and MariaDB is not installed (asks first, with an
#            end-of-life warning), start, verify
#   verify   service, socket, ports, ping; with sudo also "SELECT VERSION()" and a
#            read-only security report
#   guide    safe initial configuration: per-project users, backups, service commands
#
# MariaDB and MySQL are mutually exclusive (docs/architecture.md §9). This module never
# removes packages, never touches existing data and never changes passwords or
# authentication settings. Shared logic: lib/database.sh.
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
# shellcheck source=../lib/database.sh
source "${MODULE_DIR}/../lib/database.sh"

# Called by db_install before the install plan. Returns 1 when the user says no.
db_extra_confirm() {
    local candidate
    candidate="$(package_candidate mysql-server-8.0 || true)"
    log_warn "Ubuntu 24.04 offers only MySQL 8.0 (package ${candidate:-unknown})."
    log_warn "Oracle ended upstream support for MySQL 8.0 in April 2026. Ubuntu still publishes updates for its"
    log_warn "package, but new MySQL features and the 8.4 LTS series are not available from Ubuntu's archive."
    log_warn "Use it when a project needs MySQL specifically; MariaDB is the actively supported option here."
    [[ "${DRY_RUN:-0}" == "1" ]] && return 0
    confirm "Install MySQL 8.0 anyway?"
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    db_main mysql "$@"
fi
