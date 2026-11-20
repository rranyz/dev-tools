#!/usr/bin/env bash
# modules/install-mariadb.sh: MariaDB server and client from Ubuntu's archive.
#
# Usage: install-mariadb.sh status|install|verify|guide
#   status   packages, service, ports, socket, data directory (read-only)
#   install  install if missing and MySQL is not installed (asks first), start, verify
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

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    db_main mariadb "$@"
fi
