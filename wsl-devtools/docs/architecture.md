# Architecture

This document describes how the WSL2 web development toolkit is put together:
the directory layout, how modules work, the order tools are installed in, and the
rules that keep the toolkit safe to rerun on a machine that already has software
installed.

Status: written in Phase 0 and updated in every phase. Implemented through Phase 9: all modules,
`install-all.sh`, `install-menu.sh`, the QA suites (Phase 8) and the final documentation
(Phase 9). The real-install acceptance run is pending; see [progress.md](progress.md).

## 1. Overview

The toolkit is a set of Bash scripts for **Ubuntu 24.04 (noble) on WSL2 with systemd**.

- **Two entry points** do no installing themselves:
  - `scripts/install-all.sh` installs a selected set of tools in dependency order and prints a summary.
  - `scripts/install-menu.sh` is an interactive menu to install single modules or show status.
- **Modules** (`modules/install-*.sh`) hold all installation logic, one tool or tool group per file.
  Each module can be run on its own.
- **Libraries** (`lib/*.sh`) hold shared helpers: logging, error handling, system detection,
  package checks and guarded service control.
- **Configuration** (`config/*.conf`) holds versions and package lists, so no version number is
  hard-coded inside a module. The module order and dependencies are fixed facts of the design and
  live in `lib/orchestrator.sh` (§15).

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

## 2. Directory structure

```
wsl-devtools/
├── CLAUDE.md
├── README.md
├── .shellcheckrc              # ShellCheck settings (source paths, SC2119), development only (Phase 8)
├── config/
│   ├── versions.conf          # pinned versions: NVM, PHP versions, Node default, etc.   (Phase 1)
│   └── packages.conf          # apt package lists, incl. per-version PHP extensions       (Phase 1)
├── lib/
│   ├── common.sh              # messages, logging, ERR trap, run/confirm, checks, validation,
│   │                          # safe config loading                                       (Phase 1)
│   ├── system.sh              # WSL2, Ubuntu release, systemd, sudo, user detection        (Phase 2)
│   ├── packages.sh            # dpkg/apt helpers, guarded apt update/install, PPA check    (Phase 2-3)
│   ├── services.sh            # systemctl helpers; changes refuse to run without systemd   (Phase 3)
│   ├── nginx.sh               # nginx -t / reload, site checks, site template rendering    (Phase 3)
│   ├── php.sh                 # PHP versions, packages, FPM, CLI default, Xdebug settings  (Phase 3)
│   ├── node.sh                # NVM install/version checks, strict-mode bridge, .bashrc    (Phase 4)
│   ├── database.sh            # MariaDB/MySQL: detection, conflicts, status/install/verify (Phase 5)
│   ├── docker.sh              # Docker Desktop / other engine detection, key, apt source    (Phase 6)
│   └── orchestrator.sh        # module registry (order, deps), run/summary/verify helpers   (Phase 7)
├── modules/
│   ├── install-base.sh        # curl wget zip unzip git                                    (Phase 2)
│   ├── install-nginx.sh       # Nginx package and service, never writes config            (Phase 3)
│   ├── install-php.sh         # PPA, PHP 8.4 / 7.4, extensions, FPM, Xdebug, CLI default,
│   │                          # interactive PHP menu                                       (Phase 3)
│   ├── install-composer.sh    # official installer with signature check                   (Phase 3)
│   ├── install-nodejs.sh      # official NVM (pinned), Node LTS/specific versions, list,
│   │                          # use, default, update, verify, interactive Node menu        (Phase 4)
│   ├── install-mariadb.sh     # MariaDB from Ubuntu; refuses if MySQL is installed          (Phase 5)
│   ├── install-mysql.sh       # MySQL 8.0 from Ubuntu (EOL warning); refuses if MariaDB is  (Phase 5)
│   ├── install-redis.sh       # Redis from Ubuntu, localhost only                          (Phase 6)
│   ├── install-postgresql.sh  # PostgreSQL 16 from Ubuntu, localhost only                  (Phase 6)
│   ├── install-mailpit.sh     # pinned Mailpit binary + toolkit systemd unit, php-mail     (Phase 6)
│   └── install-docker.sh      # Docker Engine from Docker's repo; refuses next to Desktop  (Phase 6)
├── scripts/
│   ├── install-all.sh         # select tools, install in dependency order, summary, verify (Phase 7)
│   ├── install-menu.sh        # interactive main menu over all modules                     (Phase 7)
│   ├── check-system.sh        # read-only requirement checks + base utilities status       (Phase 2)
│   └── nginx-site.sh          # list sites; create a site bound to a PHP-FPM version       (Phase 3)
├── templates/
│   ├── nginx-site.conf.tpl    # site template used by nginx-site.sh                        (Phase 3)
│   └── mailpit.service.tpl    # systemd unit for Mailpit                                   (Phase 6)
├── tests/
│   ├── helpers.sh             # shared assertion helpers
│   ├── test-common.sh         # tests for lib/common.sh                                    (Phase 1)
│   ├── test-system.sh         # detection, packages, base module, check-system             (Phase 2)
│   ├── test-web.sh            # PHP/Nginx helpers, Nginx/PHP/Composer modules, site tool   (Phase 3)
│   ├── test-node.sh           # NVM helpers, .bashrc fixtures, Node module with a fake HOME (Phase 4)
│   ├── test-db.sh             # DB detection fixtures, security report, DB modules         (Phase 5)
│   ├── test-optional.sh       # Redis/PostgreSQL/Mailpit/Docker helpers and modules        (Phase 6)
│   ├── test-orchestrator.sh   # registry, install-all and install-menu with stub modules   (Phase 7)
│   ├── test-qa.sh             # failure scenarios with mocks: no systemd, missing tools,
│   │                          # failed apt steps, removal guard, invalid DRY_RUN           (Phase 8)
│   └── test-live.sh           # read-only health check with a before/after system snapshot (Phase 8)
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
  only runs `main "$@"` (the MariaDB and MySQL modules: `db_main <flavour> "$@"` from
  `lib/database.sh`) when executed directly
  (`[[ "${BASH_SOURCE[0]}" == "$0" ]]`), so orchestrators can also source it.
- **Exit codes:**

  | Code | Meaning |
  |---|---|
  | 0 | Success: installed and verified, or status/verify passed |
  | 1 | Failure |
  | 2 | Skipped: already installed, nothing to do |
  | 3 | Precondition not met: missing dependency, conflict, unsupported system, no systemd |
  | 4 | Cancelled: the user answered "no" (or there was no terminal to ask) |

  Any other code means an unexpected failure, reported by the ERR trap.
- **Run as separate processes:** orchestrators run `bash modules/install-<tool>.sh <action>` and read
  the exit code. Action functions may `exit` with the codes above.
- **Install flow** (first implemented in `modules/install-base.sh`):
  1. preflight;
  2. find the missing packages, exiting 2 if there are none;
  3. confirm, exiting 4 on "no";
  4. `sudo -v`;
  5. `apt-get update`;
  6. check each package has a candidate, exiting 3 if not;
  7. install, with the removal guard;
  8. verify.

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
- **apt installs are guarded** (`lib/packages.sh`):
  - `apt_install` first simulates the install (`apt-get -s`) and refuses if apt would remove any package.
  - It installs only the named missing packages, with `DEBIAN_FRONTEND=noninteractive` and
    `NEEDRESTART_MODE=l`, so services are listed rather than restarted.
  - It waits up to 120 s for the apt lock.
  - `apt_update` only refreshes package lists (`apt-get update --error-on=any`).
  - The toolkit never runs `apt upgrade`.
- **Never change the default PHP CLI** unless the user runs the explicit "set default PHP" action.
- **Never reload Nginx without a passing `sudo nginx -t`.** The same applies to `php-fpmX.Y -t`
  before restarting an FPM service.
- **Never touch** Windows settings, `/etc/wsl.conf`, `.wslconfig` or firewall rules.
- **Shell profile edits** (`~/.bashrc`) are limited to two things, each after confirmation and a
  backup (`~/.bashrc.wsl-devtools-<timestamp>.bak`):
  - appending the marked NVM block, only when no active line loads `nvm.sh` yet (so lines written
    by NVM's own installer count as set up, and the block is never duplicated);
  - `install-nodejs.sh fix-bashrc`, which repairs only lines with the `[-s` typo.

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
| 2 | Base packages | 1 | curl wget zip unzip git (`BASE_PACKAGES`). `APT_PREREQUISITE_PACKAGES` (ca-certificates gnupg software-properties-common) are installed by the PHP and Docker modules when they add apt sources. |
| 3 | Nginx | 2 | |
| 4 | PHP PPA check | 2 | Add `ppa:ondrej/php` only if absent and noble is published |
| 5 | PHP 8.4 (+ extensions, FPM) | 4 | Versioned packages only |
| 6 | PHP 7.4 (+ extensions, FPM) | 4 | Optional, EOL warning |
| 7 | Xdebug | 5 and/or 6 | Per installed PHP version |
| 8 | Composer | 5 or 6 (PHP CLI) | Installer signature verified |
| 9 | Database: MariaDB **or** MySQL | 2 | Mutually exclusive, see §9 |
| 10 | Node.js via NVM | 2 (curl, git) | User-level, independent of the PHP stack |
| 11 | Redis, PostgreSQL, Mailpit | 2 | Optional, independent of each other. Mailpit's `php-mail` needs PHP (5/6) |
| 12 | Docker Engine | 2 | Optional, see §10 |
| – | Nginx site ↔ PHP-FPM | 3, 5/6 | `scripts/nginx-site.sh`, run on demand |

If a step fails, the orchestrator skips the steps that depend on it, continues with the
independent ones, and lists both in the final summary. In `lib/orchestrator.sh` every module except
base depends on base, and composer depends on php. "Failed" means a selected dependency ended with
anything but 0 or 2; a dependency that was not selected is not added, and the module's own check
decides (for example, composer exits 3 when no PHP is installed). Details in §15.

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
| MariaDB | `mariadb` (also answers to the aliases `mysql`, `mysqld`) | 3306, `/run/mysqld/mysqld.sock` | `/etc/mysql/mariadb.cnf`, `mariadb.conf.d/`, `/var/lib/mysql` | `systemctl is-active mariadb`, `mariadb-admin ping` (socket and 127.0.0.1), `sudo mariadb -e 'SELECT VERSION()'` |
| MySQL | `mysql` | 3306, 33060, `/run/mysqld/mysqld.sock` | `/etc/mysql/mysql.cnf`, `mysql.conf.d/`, `/var/lib/mysql` | `systemctl is-active mysql`, `mysqladmin ping` (socket and 127.0.0.1), `sudo mysql -e 'SELECT VERSION()'` |
| Redis | `redis-server` | 127.0.0.1/::1:6379 | `/etc/redis/redis.conf` | `redis-cli -h 127.0.0.1 ping` → `PONG`, `INFO server` |
| PostgreSQL | `postgresql` (`postgresql@16-main`) | localhost:5432, `/var/run/postgresql` | `/etc/postgresql/16/main/`, data `/var/lib/postgresql/16/main` | `pg_lsclusters`, `pg_isready`, `sudo -u postgres psql -c 'SELECT version()'` |
| Mailpit | `mailpit` (unit created by the toolkit) | SMTP 127.0.0.1:1025, web UI/API 127.0.0.1:8025 | `/usr/local/bin/mailpit`, `/etc/systemd/system/mailpit.service`, data `/var/lib/mailpit` | `curl http://127.0.0.1:8025/api/v1/info`, SMTP greeting `220` |
| Docker Engine | `docker`, `containerd` | `/var/run/docker.sock`; published ports default to 127.0.0.1 | `/etc/docker/daemon.json`, `/etc/apt/keyrings/docker.asc`, `/etc/apt/sources.list.d/docker.sources` | `docker info`, `docker run --rm hello-world` (`test-run`) |

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
- **CLI default:**
  - `install-php.sh set-default X.Y` runs `update-alternatives --set` for `php`, `phar` and
    `phar.phar`, each only when that alternative and `/usr/bin/<name>X.Y` exist. It asks first.
  - Installing packages can make apt repoint `/usr/bin/php`, for example in auto mode, where the
    PPA's `php.default` (priority 100) follows the PPA's default version. So `install` records the
    target before installing and sets it back afterwards if it changed.
- **Nginx per site:**
  - `scripts/nginx-site.sh create <domain> <root> <php-version>` renders
    `templates/nginx-site.conf.tpl` with `fastcgi_pass unix:/run/php/phpX.Y-fpm.sock;` into a
    **new** file, `sites-available/<domain>`, and links it into `sites-enabled`.
  - It runs `sudo nginx -t` and reloads only if that passes. If the test fails, it removes only
    the two files it just created.
  - It refuses a site name or `server_name` that is already in use.
  - It checks that `www-data` can read the document root. On a fresh 24.04, home folders are mode
    750. If the check fails it explains and stops; it never runs chmod.
  - New sites use `listen 80;` like Ubuntu's default site. A `listen 127.0.0.1:80` server would
    take every request to 127.0.0.1 away from the existing `listen 80` sites, because Nginx
    prefers the more specific address.
- **Xdebug:**
  - `phpX.Y-xdebug` is installed per version.
  - The toolkit writes `conf.d/99-wsl-devtools-xdebug.ini` for cli and fpm (`xdebug.mode=debug`,
    `start_with_request=trigger`, client `127.0.0.1:9003`), but **only** where no `xdebug.*`
    settings exist yet. Existing files, like the development machine's `99-xdebug-debug.ini`, are
    reported and kept.
  - `trigger` avoids the "Could not connect to debugging client" message on every CLI command.
  - After adding the fpm file, `php-fpmX.Y -t` must pass before FPM is reloaded.
- **Verify needs sudo for two checks.** `nginx -t` and `php-fpmX.Y -t` need root. When sudo can't
  prompt (no terminal) and isn't cached, `verify` skips them with a warning instead of hanging.
- **Composer:**
  - Downloads the official installer and checks its SHA-384 against `composer.github.io/installer.sig`.
  - Runs the installer as the normal user in a temporary directory.
  - Only the final copy to `/usr/local/bin` uses sudo.
  - Composer itself runs `sudo -K` at startup, dropping cached sudo rights, so a later sudo step may ask again.

## 9. MySQL and MariaDB: one at a time

### What the packages share and where they conflict (Ubuntu 24.04, checked 2026-11-17)

| Item | MariaDB 10.11 | MySQL 8.0 |
|---|---|---|
| Packages | `mariadb-server`, `mariadb-client` (pull in `-core`, `galera-4`, plugin providers) | `mysql-server`, `mysql-client` (pull in `-8.0`, `-core-8.0`) |
| systemd unit | `mariadb`. MariaDB also installs `mysql.service` and `mysqld.service` as **aliases** | `mysql` |
| Ports | 3306 | 3306, and 33060 for the X Protocol |
| Socket | `/run/mysqld/mysqld.sock` | the same |
| Configuration | `/etc/mysql/mariadb.cnf`, `/etc/mysql/mariadb.conf.d/` | `/etc/mysql/mysql.cnf`, `/etc/mysql/mysql.conf.d/` |
| `my.cnf` | the `my.cnf` alternative points at `mariadb.cnf` | the same alternative, pointed at `mysql.cnf` |
| Data | `/var/lib/mysql` | the same directory; the on-disk formats are not interchangeable |
| Admin login | `root` by Unix socket: `sudo mariadb` | `root` by `auth_socket`: `sudo mysql` |
| Shared packages | `mysql-common` (and `mariadb-common`) | `mysql-common` |

Package relations:
- `mysql-server-8.0` declares `Conflicts: virtual-mysql-server`, and `mariadb-server` provides it.
- `mariadb-server-core` conflicts with `mysql-server-8.0` and `virtual-mysql-server-core`.
- `mariadb-client-core` conflicts with `mysql-client-8.0` and `virtual-mysql-client-core`, so even
  the clients cannot be installed together.

On the development machine, `apt-get -s install mysql-server` plans to **remove all nine MariaDB
packages**. Also, `/usr/bin/mysql`, `/usr/bin/mysqladmin` and `mysql.service` exist there, but
they belong to MariaDB. So the modules detect what is installed by **dpkg package names only**,
never by binary or unit names.

### Decision: mutually exclusive modules

Running both natively from Ubuntu's packages is not possible without removing one. Running a
second copy from upstream tarballs (own data directory, port, socket and systemd unit) would be
unmanaged by apt, get no security updates, and be easy to mix up with the main server. So:

- `install-mysql.sh install` exits 3 with an explanation when any MariaDB server or client package
  is installed, and `install-mariadb.sh install` does the same for MySQL. Nothing is changed and
  sudo is not asked for.
- With no server package installed, it also exits 3 when:
  - `/var/lib/mysql` already contains data, or cannot be inspected without root (left over from an
    earlier install, possibly the other flavour); the toolkit never reuses, moves or deletes it;
  - port 3306 (or 33060 for MySQL) is already in use, for example by a container.
- Packages of the other flavour left in the "config files" state (`rc`) only produce a warning.
- `apt_install` refuses any install that would remove a package, which is a second safety net.

Alternatives for a project that needs the other server:
1. **A container** on `127.0.0.1:3307` with its own volume, using Docker Engine (`install-docker.sh`, Phase 6).
2. **A separate WSL distro** with the other module.
3. **Switching** (manual, needs approval): dump all databases, remove the packages, move
   `/var/lib/mysql` aside, run the other module, import the dump. `install-<flavour>.sh guide`
   prints the steps. The toolkit never does this itself.

### Module behaviour (`lib/database.sh`, shared by both modules)

- `status` (read-only, no sudo): installed packages and version, the other flavour, `rc`
  leftovers, the unit state and boot setting (asked only when that flavour is installed, because
  of MariaDB's aliases), listeners per port (loopback or not), the socket, the data directory state
  and the `my.cnf` target.
- `install`:
  1. preflight with systemd;
  2. exit 2 if the packages are already installed (after verify);
  3. the conflict, leftover-data and port checks above;
  4. MySQL: an end-of-life warning with its own confirmation. Oracle ended 8.0 support in April
     2026, and Ubuntu 24.04 still updates its 8.0 package and offers no other MySQL;
  5. the plan, confirmation, `install_missing_packages`, start and enable the unit if needed,
     verify.

  Ubuntu's defaults are kept: the server binds to 127.0.0.1, and root uses socket login with no
  password. No configuration file, password or authentication setting is written or changed.
- `verify`:
  - The package, the unit (active, starts at boot), the socket, and port 3306 listening.
  - A warning if a port is bound beyond loopback.
  - `<admin> ping` over the socket and over TCP to 127.0.0.1. Ping exits 0 whenever the server
    answers, even "Access denied", so no credentials are needed.
  - With sudo usable: `sudo <client> -e 'SELECT VERSION()'` and a **read-only security report**:
    - root accounts and whether they use socket login (from `SHOW CREATE USER`, which is
      classified but never printed, because it contains password hashes);
    - root accounts allowed from other hosts, anonymous accounts, and a `test` database.

    Findings are warnings with advice. Without sudo, these checks are skipped with a warning.
- `guide`: safe initial configuration, printed only:
  - keep root on socket login and skip the root-password step of `*-secure-installation`;
  - one database and user per project, with the SQL;
  - `localhost` (socket) vs `127.0.0.1` (TCP) in application settings;
  - keep `bind-address = 127.0.0.1`;
  - systemctl and journalctl commands, dump and restore commands, and the switching steps.

## 10. Docker: Desktop vs native Engine

`modules/install-docker.sh`, with detection in `lib/docker.sh`.

**Detection (read-only):**

| Situation | How it is detected | Install does |
|---|---|---|
| Docker Desktop's WSL integration | `/mnt/wsl/docker-desktop*` exists; or `command -v docker` resolves into `/mnt/wsl/docker-desktop*`; or `/var/run/docker.sock` is a symlink into `/mnt/wsl` | Exit 3. A second daemon would give two Docker hosts with their own images and containers, a `docker` CLI and socket that point to one or the other, and confusing ports |
| Docker Desktop on Windows, integration off | `docker.exe` on `PATH` | Warn: turning the integration on later would clash |
| Another engine in this distro | Installed `docker.io`, `docker-engine`, `podman-docker`, `moby-engine`/`moby-cli`, Ubuntu's `containerd` or `runc` (they conflict with `containerd.io`), or a `docker` snap | Exit 3; nothing is removed |
| Docker Engine from Docker's repo | All of `DOCKER_PACKAGES` installed | Verify, exit 2 |

**Installation approach** (the module prints it before asking):
1. Source: Docker's official apt repository `download.docker.com/linux/ubuntu`, suite `noble`,
   component `stable`. Packages: `docker-ce docker-ce-cli containerd.io docker-buildx-plugin
   docker-compose-plugin`.
2. The signing key is downloaded to a temporary file. Its primary fingerprint, read with a
   throwaway GnuPG home, must equal `DOCKER_GPG_FINGERPRINT` (`9DC8 5822 9FC7 DD38 854A E2D8 8D81
   803C 0EBF CD88`). It is then installed as `/etc/apt/keyrings/docker.asc`. An existing file
   there with different content stops the install.
3. The apt source `/etc/apt/sources.list.d/docker.sources` (deb822, `Signed-By` the keyring) is
   written only when no source for that URL exists.
4. **`/etc/docker/daemon.json` with `{"ip": "127.0.0.1"}`** is written only when no `daemon.json`
   exists. Then `docker run -p 8080:80` listens on 127.0.0.1:8080, and publishing beyond this
   machine needs an explicit `-p 0.0.0.0:8080:80`. An existing `daemon.json` is never changed;
   `status` and `verify` show its `ip`.
5. `install_missing_packages` (with the removal guard), then `docker` and `containerd` are
   enabled and started.
6. **The docker group is asked separately.** Membership is root-equivalent, because the daemon
   runs as root. It takes effect only in new shells: close all WSL terminals or run
   `wsl.exe --terminate <distro>`. Until then, and without membership, the module uses
   `sudo docker`.
7. Verify: packages, both services, the socket, `docker info` (server version), the `daemon.json`
   ip, the group state. `test-run` (asks first) pulls and runs `hello-world`.

WSL notes: Windows reaches published ports as `localhost:<port>` through WSL's localhost
forwarding (NAT mode). Docker manages its own iptables/nftables rules.

## 11. WSL2 and systemd detection

| Check | Method | On failure |
|---|---|---|
| WSL2 | `/proc/sys/kernel/osrelease` contains `WSL2` (WSL1's kernel name ends in `-Microsoft`; another `microsoft` kernel counts as "unknown") | Stop: not a supported environment. WSL1 gets the `wsl.exe --set-version` hint |
| Ubuntu release | `/etc/os-release` has `ID=ubuntu`, `VERSION_ID="24.04"` | Stop: only 24.04 is supported |
| systemd is PID 1 | `ps -p 1 -o comm=` is `systemd` | Explain how systemd is enabled in WSL, stop service operations, do **not** edit `/etc/wsl.conf` |
| systemctl works | `systemctl is-system-running` returns `running` or `degraded` | Same as above |
| Not root | `id -u` is not 0 | Stop: run as the normal user |
| sudo | `sudo -n true` works, or the user is in the `sudo`/`admin` group (never prompts). `sudo -v` runs only right before a change | Stop |
| APT | `apt-get`, `apt-cache`, `dpkg`, `dpkg-query` present | Stop |
| Network | HTTPS request to the needed host (PPA, GitHub, Docker) | Stop the module that needs it |
| apt lock | Running `apt`/`apt-get`/`dpkg`/`unattended-upgrade` processes are reported as a warning; installs wait up to 120 s for the lock (`DPkg::Lock::Timeout`) | Stop with apt's message |

Implemented in `lib/system.sh`:
- `check_not_root`, `check_os`, `check_wsl2`, `check_apt`, `check_sudo` and `check_systemd` each log
  one result line.
- `preflight [--needs-systemd]` runs them in order and returns 3 at the first failure.
- `scripts/check-system.sh` runs all of them and reports every problem. It is read-only.

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

## 13. Node.js and NVM design

- **Source:** only the official repository, `github.com/nvm-sh/nvm`. No apt `nodejs`, no
  nvm-windows, no other version managers. Node.js binaries come from nodejs.org through
  `nvm install`, which checks them against nodejs.org's SHA-256 list.
- **Per user, no sudo.** NVM lives in `~/.nvm` of the user running the module. The module refuses
  to run as root and never calls sudo. It uses `check_not_root`, `check_os` and `check_wsl2`
  instead of `preflight`, because `preflight` requires sudo and NVM needs neither sudo nor systemd.
- **Pinned NVM, installed with the official `install.sh`:**
  1. `NVM_VERSION` in `config/versions.conf` must exist as a tag: `git ls-remote` against the
     repository. The commit the tag points to is remembered.
  2. `install.sh` is downloaded from `raw.githubusercontent.com/nvm-sh/nvm/<tag>/install.sh` to a
     temporary file, never piped into bash.
  3. Its SHA-256 must equal `NVM_INSTALL_SCRIPT_SHA256`. Upstream publishes no checksum, so the
     value was computed from the v0.41.0 tag and is pinned next to the version. Changing
     `NVM_VERSION` requires updating it.
  4. It runs with a fixed environment: `NVM_DIR=~/.nvm METHOD=git PROFILE=/dev/null`, with
     `XDG_CONFIG_HOME`, `NODE_VERSION`, `NVM_SOURCE`, `NVM_INSTALL_GITHUB_REPO` and
     `NVM_INSTALL_VERSION` removed. So it installs a git checkout from the official repository into
     `~/.nvm`, does not touch any profile file, and does not install Node.js.
  5. Afterwards, the installed version must equal the pin and `HEAD` must be the tag's commit.
- **Existing installations are respected.**
  - An NVM already in `~/.nvm` is reported and never reinstalled. If it is older than the pin, the
    module points to `update`.
  - A non-empty `~/.nvm` without `nvm.sh`, or `NVM_DIR` set to another directory, stops the install
    with exit 3.
- **Update** (`update`) moves NVM to the pin, never past it and never down:
  - It reruns the pinned `install.sh`, which fetches the tag and runs `git checkout -f`.
  - Because `checkout -f` discards local edits, it refuses when `~/.nvm` is not a git checkout or
    when `git status` shows changes to tracked files.
  - Node versions (`versions/`) and aliases (`alias/`) are git-ignored by NVM and are kept.
  - The newest upstream tag is shown for information only.
- **`~/.bashrc` block** (only when no active line loads `nvm.sh`):
  ```
  # >>> wsl-devtools: nvm >>>
  export NVM_DIR="$HOME/.nvm"
  [ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"
  [ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"
  # <<< wsl-devtools: nvm <<<
  ```
  The file is backed up first, and `bash -n` must still pass afterwards. A symlinked `~/.bashrc`
  stays a symlink.
- **NVM is a shell function, not a program.**
  - The module sources `~/.nvm/nvm.sh` into its own process (`nvm_load`) and checks for it with
    `command -v nvm`, never `which`.
  - `nvm.sh` does not work under `set -euo pipefail` and the ERR trap, so every call goes through
    `nvm_call`. It pauses strict mode for the call and then restores exactly the options and
    trap the caller had.
- **Switching versions.**
  - A script runs in a child process, so it cannot change the Node.js version of the shell that
    started it.
  - `use <version>` checks that the version is installed, runs its `node` and `npm` to prove it
    works, then prints the `nvm use` command to run.
  - `set-default` changes the `default` alias, which every new shell uses, after confirmation.
  - Installing a version never changes an existing default. When no default exists yet, nvm itself
    makes the first installed version the default, and the module says so before installing.
- **Verification** (`verify`):
  - In the module's process: `command -v nvm`, `nvm --version`, `node --version`, `npm --version`,
    and `node` must come from `~/.nvm/versions/node/`.
  - In a brand-new `bash -i` with an empty environment, which reads `~/.bashrc` like a new
    terminal: the same four commands.
  - Broken `[-s` lines in `~/.bashrc` are reported as warnings.
- **Version input** is validated before use: `lts`, `lts/*`, `lts/<codename>`, `22`, `22.11`,
  `22.11.0`, `v22.11.0`. A version to install must also exist at nodejs.org (`nvm version-remote`).

## 14. Optional services: Redis, PostgreSQL, Mailpit

All three are independent modules with `status`, `install`, `verify`, the usual exit codes,
`DRY_RUN=1`, and confirmation before any change. They keep each service on this machine only and
never edit existing configuration.

**Redis** (`install-redis.sh`, Ubuntu's `redis-server` 7.0):
- Install refuses (exit 3) when port 6379 is already in use.
- Ubuntu's defaults are kept: `bind 127.0.0.1 -::1`, `protected-mode yes`, no password.
  `/etc/redis/redis.conf` is never edited.
- Verify:
  - the unit `redis-server` is active;
  - listeners are loopback only (otherwise a warning);
  - `redis-cli -h 127.0.0.1 ping` returns `PONG` (a `NOAUTH` reply counts as running with a password);
  - `INFO server` reports `redis_version`.

**PostgreSQL** (`install-postgresql.sh`, Ubuntu's `postgresql` 16 + `postgresql-contrib`):
- **Install refuses (exit 3) when:**
  - another `postgresql-<N>` server is installed without Ubuntu's `postgresql` package (Ubuntu
    would add a second cluster on another port);
  - `/var/lib/postgresql` or `/etc/postgresql` has content but no server package is installed
    (data from an earlier install is never reused or changed);
  - port 5432 is busy.
- **Ubuntu's defaults:** cluster `16/main`, `listen_addresses` localhost, `postgres` by peer
  authentication (`sudo -u postgres psql`), no passwords. Nothing is edited.
- **Verify:**
  - every cluster from `pg_lsclusters` is online;
  - listeners are loopback only;
  - `pg_isready` answers on the socket and on 127.0.0.1;
  - with sudo, read-only: `SELECT version()`, `SHOW listen_addresses`, and `pg_hba_file_rules`
    host rules for non-local addresses (warnings).
- **`guide`:** a role and database per project, `.env`, the `php8.4-pgsql` note (the extension
  is not installed by default), dump/restore, and service commands.

**Mailpit** (`install-mailpit.sh`, pinned GitHub release):
- **Download:** `MAILPIT_VERSION` (v1.33.1), linux-amd64 only, checked against `MAILPIT_SHA256`
  (equal to GitHub's published asset digest) with `download_checked`. Only the `mailpit` binary
  is taken from the archive.
- **Files:**
  - `/usr/local/bin/mailpit`;
  - `/etc/systemd/system/mailpit.service` from `templates/mailpit.service.tpl`, with the header
    `# Managed by wsl-devtools`;
  - data in `/var/lib/mailpit` (`StateDirectory`).
- **The unit runs Mailpit:**
  - with `--smtp 127.0.0.1:1025 --listen 127.0.0.1:8025 --database /var/lib/mailpit/mailpit.db --disable-version-check`;
  - as a systemd `DynamicUser` (not root), with `ProtectSystem=strict`, `ProtectHome` and
    `NoNewPrivileges`.
  - The addresses come from config and must be loopback.
- **Install refuses (exit 3) when:** another `/usr/local/bin/mailpit` exists (it is never
  overwritten), a `mailpit.service` without the toolkit header exists, or port 1025 or 8025 is busy.
- **Verify:** the unit is active, listeners are loopback only,
  `GET http://127.0.0.1:8025/api/v1/info` returns `Version`, and the SMTP greeting starts with `220`.
- **`test`:** sends one message with `mailpit sendmail -S 127.0.0.1:1025` and checks that the
  API's `Messages` count went up.
- **`php-mail`** (opt-in, asks first):
  - Adds `conf.d/99-wsl-devtools-mailpit.ini` with
    `sendmail_path = "/usr/local/bin/mailpit sendmail -S 127.0.0.1:1025"` for each managed PHP
    version's cli and fpm.
  - It does this only where no active `sendmail_path` exists in `php.ini` or another `conf.d`
    file.
  - FPM is reloaded only after `php-fpmX.Y -t` passes; if that fails, the new file is removed.

## 15. Orchestration: `install-all.sh` and `install-menu.sh`

Both scripts only orchestrate: every action is `bash modules/install-<name>.sh <action> [args]`
in a child process, and the exit code is the result. No module was changed for them.

**Registry** (`lib/orchestrator.sh`):

| # | Module | Kind | Depends on | Needs systemd | Uses sudo |
|---|---|---|---|---|---|
| 1 | base | core | – | no | yes |
| 2 | nginx | core | base | yes | yes |
| 3 | php | core | base | yes | yes |
| 4 | composer | core | php | no | yes |
| 5 | nodejs | core | base | no | **no** |
| 6 | mariadb | core, exclusive with mysql | base | yes | yes |
| 7 | mysql | core, exclusive with mariadb | base | yes | yes |
| 8–11 | redis, postgresql, mailpit, docker | optional | base | yes | yes |

The `core` shortcut is `base nginx php composer nodejs`. The database is always an explicit choice,
because MariaDB and MySQL are mutually exclusive (§9).

**Before anything else** (both scripts, no log file yet):
- `DRY_RUN` must be unset, `0` or `1`. Any other value, such as `yes` or `true`, is refused
  (exit 3), because only `1` means a dry run and anything else would quietly install for real.
- A set `WSL_DEVTOOLS_MODULES_DIR` (the test override) is announced with a warning, because it
  changes which scripts run.
- Running as root is refused before a log file is created.
- An unwritable `logs/` stops the script with one clear message.

**`install-all.sh` flow:**
1. **Project information:** the toolkit path, the target platform, the log file
   (`logs/install-all-<timestamp>.log`) and the dry-run mode.
2. **Environment checks:** not root, Ubuntu 24.04, WSL2, APT and sudo. Any failure stops the run
   (exit 3). Without usable systemd the run continues, but the service modules are listed as
   unavailable and cannot be selected (§11); `/etc/wsl.conf` is not touched.
3. **The module list** (numbered), then **the selection**: numbers, names or `core`. Nothing is
   preselected. Invalid input, an unavailable module, or mariadb together with mysql is explained
   and asked again; `q` cancels. Numbers have at most 3 digits, because longer ones would wrap
   around in bash arithmetic. When php is selected, a second question picks 8.4 (default),
   7.4 (EOL) or both. `--modules` and `--php` skip the questions, with the same validation, which
   runs before any log file is created.
4. **Plan** in registry order with dependencies, then one confirmation (none in a dry run). Each
   module still asks its own questions; there is no auto-yes.
5. `sudo -v` once, unless the only selected module is nodejs.
6. **Run:** `[n/N] <module>`, in order. The output is not piped, so prompts, `-t` checks and
   colours work. `LOG_FILE` and `DRY_RUN` are exported, so module messages go into the same log.
   A module whose selected dependency did not end 0 or 2 is "not run: needs <dep>"; the
   independent modules continue. Every module runs at most once; already-installed modules exit 2
   through their own checks.
7. **Summary table** (result and time per module).
8. **Verification:** a read-only `verify` of every module that ended 0 or 2 (php with the selected
   versions), after all installs. The modules' output is appended to the log, and the screen shows
   a PASS/FAIL table with the command for details. Skipped in a dry run.
9. **Next steps** that are never automatic: Nginx sites, the default PHP CLI, Mailpit's `php-mail`,
   Docker's `test-run`, and a new terminal for nvm.

Exit codes:
- 0: every module installed or already installed, and verified (or a finished dry run);
- 1: a module or a verification failed, or a module returned an unexpected code;
- 3: a module was blocked, cancelled or not run, and nothing failed (or the system is
  unsupported);
- 4: cancelled before anything ran;
- 130: interrupted.

**`install-menu.sh`:** 13 entries:
- System preparation (with the read-only `check-system.sh`);
- Nginx, PHP, Composer, Node.js and NVM, MySQL, MariaDB, Redis, Docker, Mailpit, PostgreSQL;
- Installation status;
- Exit.

PHP and Node.js open the existing module menus (`install-php.sh menu`, `install-nodejs.sh menu`),
whose "Back to main menu" returns here. Each other module has a submenu: status, install, verify,
its extra actions (`guide`, `test`, `php-mail`, `test-run`), and back. "Installation status"
offers every module's `status`, or the verify table. Choices must be whole numbers in range;
anything else is explained and asked again. End of input (Ctrl+D) leaves the menu with exit 0.

**Ctrl+C and errors:** both scripts use strict mode and the ERR trap. Module exit codes are
captured (`|| rc=$?`), so a failing module is a result, not a crash of the orchestrator. Bash
restarts `read` after a trap handler, so there are two modes:
- **At a prompt**, Ctrl+C exits at once with 130. Nothing has run yet (install-all) or no action
  is running (menu).
- **While a module runs**, the module receives SIGINT and stops; the trap only sets a flag.
  install-all marks the module "interrupted", runs nothing more, prints the summary and exits 130;
  the menu says "Interrupted" and shows the menu again.
- After an interrupted install, the scripts suggest `sudo dpkg --configure -a`, because apt may
  have been stopped half-way. The toolkit never runs it itself.
