# Architecture

This document describes how the WSL2 web development toolkit is put together:
the directory layout, how modules work, the order tools are installed in, and the
rules that keep the toolkit safe to rerun on a machine that already has software
installed.

Status: **proposed** (Phase 0). Nothing described here is implemented yet.

## 1. Overview

The toolkit is a set of Bash scripts for **Ubuntu 24.04 (noble) on WSL2 with systemd**.

- **Two entry points** do no installing themselves:
  - `scripts/install-all.sh` installs a selected set of tools in dependency order and prints a summary.
  - `scripts/install-menu.sh` is an interactive menu to install single modules or show status.
- **Modules** (`modules/install-*.sh`) hold all installation logic, one tool or tool group per file.
  Each module can be run on its own.
- **Libraries** (`lib/*.sh`) hold shared helpers: logging, error handling, system detection,
  package checks and guarded service control.
- **Configuration** (`config/*.conf`) holds versions, extension lists and module order,
  so no version number is hard-coded inside a module.

```
            install-all.sh        install-menu.sh        (orchestrators)
                   \                    /
                    \                  /
        modules/install-<tool>.sh  status | install | verify
                         |
          lib/common.sh  lib/system.sh  lib/packages.sh  lib/services.sh
                         |
                  config/*.conf
```

## 2. Proposed directory structure

```
wsl-devtools/
├── CLAUDE.md
├── README.md
├── config/
│   ├── versions.conf          # pinned versions: NVM, PHP versions, Node default, etc.   (Phase 1)
│   ├── packages.conf          # apt package lists, incl. per-version PHP extensions       (Phase 1)
│   └── modules.conf           # module order, core/optional flag, dependencies            (Phase 12)
├── lib/
│   ├── common.sh              # messages, logging, ERR trap, run/confirm, checks, validation,
│   │                          # safe config loading                                       (Phase 1)
│   ├── system.sh              # WSL2, Ubuntu release, systemd, sudo, user detection        (Phase 2)
│   ├── packages.sh            # dpkg/apt helpers, PPA and apt-repo checks, apt lock wait
│   └── services.sh            # systemctl wrappers that refuse to run without systemd
├── modules/
│   ├── install-base.sh        # git curl wget zip unzip ca-certificates gnupg software-properties-common
│   ├── install-nginx.sh
│   ├── install-php.sh         # PPA check, PHP 8.4 / 7.4, extensions, FPM, CLI default (on request)
│   ├── install-xdebug.sh
│   ├── install-composer.sh
│   ├── install-nodejs.sh      # official NVM, Node LTS and specific versions
│   ├── install-mariadb.sh
│   ├── install-mysql.sh
│   ├── install-redis.sh
│   ├── install-postgresql.sh
│   ├── install-mailpit.sh
│   ├── install-phpmyadmin.sh
│   └── install-docker.sh      # native Docker Engine
├── scripts/
│   ├── install-all.sh
│   ├── install-menu.sh
│   ├── check-system.sh        # read-only preflight + status of every tool                 (Phase 2)
│   └── nginx-site.sh          # create a site bound to a chosen PHP-FPM socket
├── templates/
│   └── nginx-site.conf.tpl
├── tests/
│   └── test-common.sh         # tests for lib/common.sh, no system changes                 (Phase 1)
├── logs/                      # run logs (git-ignored via logs/.gitignore)
└── docs/
    ├── architecture.md
    ├── implementation-plan.md
    ├── progress.md
    └── testing.md
```

### Configuration files

Config files are plain data. `load_config` (in `lib/common.sh`) checks every line before sourcing
the file. A line must be blank, a comment, or `NAME="value"`, where `NAME` is UPPER_CASE and
`value` contains no `$`, backticks, backslashes or double quotes. Anything else, including Windows
CRLF line endings, makes it refuse the whole file, so loading a config can never run a command.

## 3. Module contract

Every module follows the same shape so the orchestrators can treat them alike.

- **Actions** (first argument):
  - `status`: read-only. Reports installed / not installed / partially installed, versions and service state.
  - `install`: checks state first, installs only what is missing, then runs `verify`.
  - `verify`: read-only. Runs the tool's verification commands and fails loudly if any fail.
- **Independently executable:** each module sources `lib/` relative to its own path and
  only runs `main "$@"` when executed directly
  (`[[ "${BASH_SOURCE[0]}" == "$0" ]]`), so orchestrators can also source it.
- **Exit codes:**

  | Code | Meaning |
  |---|---|
  | 0 | Success: installed and verified, or status/verify passed |
  | 1 | Failure |
  | 2 | Skipped: already installed, nothing to do |
  | 3 | Precondition not met: missing dependency, conflict, unsupported system, no systemd |

## 4. Safety rules built into the design

- **Look before acting.** Every `install` runs `status` first and stops at anything unexpected.
- **Detect packages with dpkg, not binary names.** For example, `/usr/bin/mysql` exists on a
  MariaDB-only system because MariaDB ships a compatibility client.
- **Never edit package-owned configuration.** The toolkit only creates **new** files that carry the
  header `# Managed by wsl-devtools`, such as `/etc/php/8.4/fpm/conf.d/99-wsl-devtools-xdebug.ini`
  or a new file in `/etc/nginx/sites-available/`. If the target path already exists, the toolkit
  refuses and explains.
- **Never remove anything**: packages, PHP versions, databases or data. Conflicts end with a clear
  message and exit code 3.
- **Never change the default PHP CLI** unless the user runs the explicit "set default PHP" action.
- **Never reload Nginx without a passing `sudo nginx -t`.** The same applies to `php-fpmX.Y -t`
  before restarting an FPM service.
- **Never touch** Windows settings, `/etc/wsl.conf`, `.wslconfig` or firewall rules.
- **Shell profile edits** (`~/.bashrc`) are limited to the NVM block, are idempotent, recognise an
  existing NVM block, and back up the file before any change.

## 5. Privilege model

- The scripts run as the **normal user** and refuse to run as root, because NVM is per-user and
  must be installed in the invoking user's home.
- System changes go through `sudo`. The orchestrator calls `sudo -v` once at start so the password
  prompt appears up front.
- NVM, Node and npm operations never use `sudo`.

## 6. Dependency and installation order

| # | Step | Depends on | Notes |
|---|---|---|---|
| 1 | Preflight | – | WSL2, Ubuntu 24.04, systemd, sudo, network, apt lock |
| 2 | Base packages | 1 | git curl wget zip unzip ca-certificates gnupg software-properties-common |
| 3 | Nginx | 2 | |
| 4 | PHP PPA check | 2 | Add `ppa:ondrej/php` only if absent and noble is published |
| 5 | PHP 8.4 (+ extensions, FPM) | 4 | Versioned packages only |
| 6 | PHP 7.4 (+ extensions, FPM) | 4 | Optional, EOL warning |
| 7 | Xdebug | 5 and/or 6 | Per installed PHP version |
| 8 | Composer | 5 or 6 (PHP CLI) | Installer signature verified |
| 9 | Database: MariaDB **or** MySQL | 2 | Mutually exclusive, see §9 |
| 10 | Node.js via NVM | 2 (curl, git) | User-level, independent of the PHP stack |
| 11 | Redis, PostgreSQL, Mailpit | 2 | Optional, independent of each other |
| 12 | phpMyAdmin | 3, 5, 9 | Optional |
| 13 | Docker Engine | 2 | Optional, see §10 |
| – | Nginx site ↔ PHP-FPM | 3, 5/6 | `scripts/nginx-site.sh`, run on demand |

If a step fails, the orchestrator skips the steps that depend on it, continues with the
independent ones, and lists both in the final summary.

## 7. Services, ports, paths and verification

| Tool | systemd unit | Port / socket | Config path | Verification |
|---|---|---|---|---|
| Nginx | `nginx` | 80 | `/etc/nginx/` (`sites-available`, `sites-enabled`) | `sudo nginx -t`, `systemctl is-active nginx`, `curl -sI http://localhost` |
| PHP-FPM 8.4 | `php8.4-fpm` | `/run/php/php8.4-fpm.sock` | `/etc/php/8.4/fpm/` | `php8.4 -v`, `sudo php-fpm8.4 -t`, `systemctl is-active php8.4-fpm` |
| PHP-FPM 7.4 | `php7.4-fpm` | `/run/php/php7.4-fpm.sock` | `/etc/php/7.4/fpm/` | `php7.4 -v`, `sudo php-fpm7.4 -t`, `systemctl is-active php7.4-fpm` |
| PHP CLI default | – | – | `update-alternatives --display php` | `php -v` |
| Xdebug | – | IDE listens on 9003 | `/etc/php/X.Y/{cli,fpm}/conf.d/` | `XDEBUG_MODE=off phpX.Y -m \| grep -i xdebug`, `phpX.Y -v` |
| Composer | – | – | `/usr/local/bin/composer` | `XDEBUG_MODE=off composer --version` |
| NVM / Node | – | – | `~/.nvm`, `~/.bashrc` | `command -v nvm`, `nvm --version`, `node --version`, `npm --version` |
| MariaDB | `mariadb` | 3306, `/run/mysqld/mysqld.sock` | `/etc/mysql/mariadb.cnf`, `/var/lib/mysql` | `mariadb --version`, `systemctl is-active mariadb`, `sudo mariadb -e 'SELECT VERSION()'` |
| MySQL | `mysql` | 3306, 33060, `/run/mysqld/mysqld.sock` | `/etc/mysql/mysql.cnf`, `/var/lib/mysql` | `mysqld --version`, `systemctl is-active mysql`, `sudo mysql -e 'SELECT VERSION()'` |
| Redis | `redis-server` | 6379 | `/etc/redis/redis.conf` | `redis-cli ping` → `PONG` |
| PostgreSQL | `postgresql` (`postgresql@16-main`) | 5432 | `/etc/postgresql/16/main/` | `pg_lsclusters`, `sudo -u postgres psql -c 'SELECT version()'` |
| Mailpit | `mailpit` (unit created by toolkit) | SMTP 1025, web UI 8025 | `/usr/local/bin/mailpit`, `/etc/systemd/system/mailpit.service` | `mailpit version`, `curl -s http://localhost:8025` |
| phpMyAdmin | served by Nginx + PHP-FPM | via Nginx | `/usr/share/phpmyadmin`, `/etc/phpmyadmin/` | HTTP 200 from its Nginx site |
| Docker Engine | `docker`, `containerd` | `/var/run/docker.sock` | `/etc/docker/` | `docker version`, `docker run --rm hello-world` |

All services bind to localhost where the package allows it. Exposing a service on other
interfaces is never done without approval.

## 8. PHP design

- **Source:** Ondřej Surý's PPA (`ppa:ondrej/php`). Before adding it, the module checks:
  - whether a `ondrej-ubuntu-php-*.sources`/`.list` entry already exists;
  - that the PPA publishes the running release (`noble`);
  - with `apt-cache policy`, that the needed `phpX.Y-*` packages have a candidate.
- **Versions:** PHP 8.4 and PHP 7.4 can be installed independently or side by side.
- **PHP 7.4 version reality:** the PPA package is `7.4.33-NN+ubuntu24.04.1+deb.sury.org+1`.
  Upstream 7.4.33 is the final upstream release; `NN` is Sury's patch revision with backported
  fixes. The toolkit reports the exact installed package version and does not claim "exactly
  upstream 7.4.33". PHP 7.4 is **end-of-life**; the module prints a warning and asks for
  confirmation before installing it.
- **Versioned packages only.** The PPA's unversioned `php-*` metapackages follow the PPA's default
  version (currently 8.4) and would pull in an unwanted version later, so modules install
  `php8.4-mbstring`, never `php-mbstring`.
- **Extensions:** per-version lists in `config/packages.conf`. Some extensions differ between
  versions (for example `php7.4-json` exists, while JSON is built into PHP 8).
- **FPM:** one service and one socket per version: `phpX.Y-fpm`, `/run/php/phpX.Y-fpm.sock`.
- **CLI default:** the `set-default` action runs `update-alternatives --set php /usr/bin/phpX.Y`
  (plus `phar`, `phar.phar`, `php-config`, `phpize` when present). It runs only when the user asks.
- **Nginx per site:** `scripts/nginx-site.sh <domain> <root> <php-version>` renders
  `templates/nginx-site.conf.tpl` with `fastcgi_pass unix:/run/php/phpX.Y-fpm.sock;`, writes a
  **new** file, enables it with a symlink, runs `sudo nginx -t`, and reloads only if that passes.
  If the test fails, it removes the new symlink so the running config is unaffected.
- **Xdebug:** `phpX.Y-xdebug` per version, plus a toolkit drop-in with
  `xdebug.mode=debug` and `xdebug.start_with_request=trigger`. `trigger` avoids the
  "Could not connect to debugging client" message on every CLI command.

## 9. MySQL and MariaDB: one at a time

They cannot be installed side by side from Ubuntu's packages:

- `mysql-server-8.0` declares `Conflicts: virtual-mysql-server`, and `mariadb-server` provides
  `virtual-mysql-server`. Installing one through apt removes the other.
- Both use port 3306, the socket `/run/mysqld/mysqld.sock`, the config tree `/etc/mysql/`, the
  `my.cnf` alternative and the data directory `/var/lib/mysql`. Their on-disk data formats are
  not interchangeable in both directions.

Decision: **mutually exclusive modules.** `install-mysql.sh` exits with code 3 and an explanation
if any `mariadb-server*` package is installed, and the reverse applies too. Switching servers is
a manual step the user approves separately, after backing up their data.

## 10. Docker: Desktop vs native Engine

Detection checks, in order:

1. a `docker` command, and whether it is the Docker Desktop WSL proxy
   (`/mnt/wsl/docker-desktop*`, `docker context ls`, a `docker.exe` on `PATH`);
2. the `docker-ce` / `docker.io` / `containerd.io` packages;
3. the `docker.service` unit.

- **Docker Desktop integration found:** report it and install nothing. Running a second daemon
  inside Ubuntu would give two Docker hosts, conflicting `docker` CLIs and contexts, and confusing
  port bindings.
- **Native Engine found:** report its status only.
- **Nothing found:** after confirmation, install Docker Engine from Docker's official apt repository
  (`download.docker.com`, keyring in `/etc/apt/keyrings/`), enable `docker.service`, and add the user
  to the `docker` group. Membership takes effect only in a new shell or WSL session, and the module
  says so.

## 11. WSL2 and systemd detection

| Check | Method | On failure |
|---|---|---|
| WSL2 | `/proc/version` contains `microsoft` and `WSL_INTEROP` is set | Stop: not a supported environment |
| Ubuntu release | `/etc/os-release` has `ID=ubuntu`, `VERSION_ID="24.04"` | Stop: only 24.04 is supported |
| systemd is PID 1 | `ps -p 1 -o comm=` is `systemd` | Explain how systemd is enabled in WSL, stop service operations, do **not** edit `/etc/wsl.conf` |
| systemctl works | `systemctl is-system-running` returns `running` or `degraded` | Same as above |
| Not root | `id -u` is not 0 | Stop: run as the normal user |
| sudo | `sudo -v` succeeds | Stop |
| Network | HTTPS request to the needed host (PPA, GitHub, Docker) | Stop the module that needs it |
| apt lock | `/var/lib/dpkg/lock-frontend` free | Wait a bounded time, then stop with a message |

`degraded` is accepted because desktop-only units commonly fail under WSL
(`lightdm`, `gpu-manager` and `tpm-udev` on the development machine) without affecting services.

## 12. Error handling and logging

- Entry scripts and modules use `set -Eeuo pipefail` and an `ERR` trap that prints the script,
  line number and failing command.
- All output goes to the terminal and to `logs/install-YYYYmmdd-HHMMSS.log`.
- A `run` helper prints and logs every system-changing command. With `DRY_RUN=1` it prints the
  command without running it, which is useful on a machine that already has a working setup.
- A `confirm` helper asks before risky actions. Without a terminal it defaults to **no**.
- Commands are never silenced with `|| true` or `2>/dev/null` unless the failure is an expected,
  handled outcome, and then there is a comment explaining why.
- The orchestrator records each module's exit code and prints a summary table
  (installed / skipped / failed / blocked).
