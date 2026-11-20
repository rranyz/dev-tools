# wsl-devtools

Modular Bash scripts for setting up a PHP and Node.js web development environment on
**Ubuntu 24.04 under WSL2 (with systemd)**.

Covered tools:
- **Core:** Nginx, PHP 8.4 and 7.4 (with PHP-FPM and Xdebug), Composer, Node.js via the official NVM, MariaDB or MySQL, git, curl, wget, zip, unzip
- **Optional:** Redis, PostgreSQL, Mailpit, Docker Engine

Two entry points do the coordinating: `scripts/install-all.sh` (guided installation of a chosen
set) and `scripts/install-menu.sh` (interactive menu). The installation logic lives in one
module per tool under `modules/`, and each module can be run on its own.

> **Status:** Phases 1–9 are implemented and documented. All automated tests pass, and the
> read-only checks pass on an existing setup. **The real installs in a fresh Ubuntu 24.04 distro
> have not been confirmed yet.** That acceptance run is the last step; see
> [docs/testing.md §12](docs/testing.md#12-final-acceptance-run-phase-9) and
> [docs/progress.md](docs/progress.md).

## System requirements

| Requirement | Why |
|---|---|
| Ubuntu **24.04** (noble) on **WSL2** | The only supported release. Other releases and WSL1 are refused |
| **systemd** running in the distro (`degraded` is fine) | Nginx, PHP-FPM, the databases and the optional services are systemd units |
| A **normal user with sudo**, not root | Packages are installed with sudo per command; NVM and Node.js are per user and never use sudo |
| Network access | apt, the PHP PPA, NVM, Composer, Mailpit and Docker are downloaded |
| amd64 (for Mailpit only) | Only the linux-amd64 Mailpit release is pinned |
| Bash | Only `~/.bashrc` is configured for NVM; zsh and fish are not |

Check a system without changing anything:

```bash
scripts/check-system.sh     # exit 0: ready; exit 3: a requirement is missing, with an explanation
```

## Installation prerequisites

Before the first run:

1. **WSL2 and an Ubuntu 24.04 distro.** In Windows PowerShell:
   `wsl --install -d Ubuntu-24.04` (add `--name <name>` for a second, disposable distro). Create
   your Linux user when asked.
2. **systemd enabled.** New Ubuntu distros have it on. If `scripts/check-system.sh` reports
   otherwise, it shows the two lines to add to `/etc/wsl.conf` and asks you to run
   `wsl.exe --shutdown`. The toolkit never edits `/etc/wsl.conf` and never changes Windows
   settings; that change is yours.
3. **Your sudo password.** Each module asks before it uses sudo.
4. **The project in the Linux filesystem**, for example `~/wsl-devtools`, not under `/mnt/c`
   (Windows drives are slow and can change file modes and line endings).
5. **Nothing else.** The base module installs curl, wget, zip, unzip and git. git and curl are
   needed for NVM, so install `base` first; `install-all.sh` orders this for you.

On a machine that already has some of these tools, nothing is removed or overwritten: modules
report "already installed" and leave existing configuration alone.

## Quick start

```bash
cd ~/wsl-devtools
scripts/check-system.sh       # read-only: is this system ready?
scripts/install-all.sh        # guided: choose tools, install in order, summary, verification
```

After the run, **open a new terminal**: `nvm` and `node` are loaded from `~/.bashrc`, and membership
of the `docker` group applies to new WSL sessions only.

## Installing with install-all.sh

```bash
scripts/install-all.sh                                     # asks which modules to install
scripts/install-all.sh --modules core,mariadb --php 8.4    # core = base nginx php composer nodejs
scripts/install-all.sh --modules core,mariadb --php both   # PHP 8.4 and 7.4 side by side
scripts/install-all.sh --modules redis,mailpit             # optional tools only
DRY_RUN=1 scripts/install-all.sh --modules php --php both  # show the plans, change nothing (or --dry-run)
scripts/install-all.sh --help
```

What a run does:
1. Shows the project information and runs the environment checks (Ubuntu, WSL2, systemd, sudo, apt).
2. Lists the 11 modules. You choose by number, by name or with `core`. **Nothing is preselected:**
   the database and the optional tools are installed only when you choose them. You can't choose
   MariaDB and MySQL together. Without systemd, the service modules are shown as unavailable.
3. If PHP is chosen, asks for 8.4, 7.4 or both.
4. Shows the plan and asks **once** to continue (no question in a dry run), then asks for your
   sudo password once (`sudo -v`; skipped when nodejs is the only module, because it never uses
   sudo).
5. Runs the modules in dependency order with `[n/N]` progress:
   base → nginx → php → composer → nodejs → mariadb | mysql → redis → postgresql → mailpit → docker.
   **Each module still asks its own questions** (the apt plan, the PHP 7.4 end-of-life warning,
   the docker group). There is no "yes to everything" option.
6. Prints a summary table with each module's result and time, then a verification table
   (PASS/FAIL) for the modules that finished, and suggested next steps.

If a module fails or is cancelled, only the modules that depend on it are skipped ("not run:
needs php"): composer needs php, and everything needs base. The other modules continue. A rerun
reports finished tools as "already installed", so running it again after a fix is safe.

The run log is `logs/install-all-<timestamp>.log`. It has the toolkit's messages and the full
verification output; apt's own output stays on the terminal. Ctrl+C at a prompt exits without
changes; Ctrl+C during a module stops that module, marks the rest "not run: interrupted" and shows
the `sudo dpkg --configure -a` hint.

## Using install-menu.sh

```bash
scripts/install-menu.sh            # interactive; needs a terminal
DRY_RUN=1 scripts/install-menu.sh  # every action only shows its plan
```

The main menu has 13 entries:

| # | Entry | Opens |
|---|---|---|
| 1 | System preparation | Status, Install, Verify (base utilities), Check system requirements |
| 2 | Nginx | Status, Install, Verify |
| 3 | PHP | The PHP menu (below) |
| 4 | Composer | Status, Install, Verify |
| 5 | Node.js and NVM | The Node.js menu (below) |
| 6 | MySQL | Status, Install, Verify, Show the setup guide |
| 7 | MariaDB | Status, Install, Verify, Show the setup guide |
| 8 | Redis | Status, Install, Verify |
| 9 | Docker | Status, Install, Verify, Run Docker's hello-world test container |
| 10 | Mailpit | Status, Install, Verify, Send a test email, Route PHP mail() to Mailpit, Show the setup guide |
| 11 | PostgreSQL | Status, Install, Verify, Show the setup guide |
| 12 | Installation status | Status of every module, or Verify every module (PASS/FAIL table) |
| 13 | Exit | |

- **PHP menu:**
  1. install PHP 7.4 (end-of-life);
  2. install PHP 8.4;
  3. install both;
  4. switch the default PHP CLI version;
  5. configure Nginx PHP-FPM sites;
  6. install or verify Xdebug;
  7. check installed PHP versions;
  8. back.
- **Node.js menu:**
  1. install NVM;
  2. install Node.js LTS;
  3. install a specific version;
  4. list installed versions;
  5. list available versions;
  6. switch version;
  7. set the default version;
  8. update NVM;
  9. verify;
  10. back.

Every submenu also has a "Back" entry. Each action runs the module as a separate process and then
shows its result. Invalid input is asked again.

**Ctrl+C:**
- during an action, it returns to the menu;
- at the main menu, it leaves the menu (exit 130).

The menu writes `logs/install-menu-<timestamp>.log`.

## Running modules directly

Every module has `status` (read-only), `install` (asks first) and `verify`. Prefix any command
with `DRY_RUN=1` to see what would run without changing anything.

```bash
modules/install-base.sh install             # curl, wget, zip, unzip, git
modules/install-nginx.sh install            # Nginx
modules/install-php.sh install 8.4 7.4      # PHP 8.4 and 7.4 (7.4 is end-of-life, see below)
modules/install-composer.sh install         # Composer (official installer, signature checked)
modules/install-nodejs.sh install           # NVM + ~/.bashrc block + Node.js LTS
modules/install-mariadb.sh install          # MariaDB (refused while MySQL is installed)
modules/install-mysql.sh install            # MySQL 8.0 (end-of-life upstream; refused while MariaDB is installed)
modules/install-redis.sh install            # Redis on 127.0.0.1:6379
modules/install-postgresql.sh install       # PostgreSQL 16 on localhost:5432
modules/install-mailpit.sh install          # Mailpit: SMTP 127.0.0.1:1025, web UI http://localhost:8025
modules/install-docker.sh install           # Docker Engine (explains the approach first)
```

`modules/install-php.sh` and `modules/install-nodejs.sh` without arguments open their own menus.

## PHP version management

> **PHP 7.4 is end-of-life** and gets no upstream security fixes. Install it only when a legacy
> project needs it. The module warns and asks separately before installing it.

```bash
modules/install-php.sh status                 # PPA, installed versions, FPM services, Xdebug, CLI default
modules/install-php.sh install 8.4            # one version: PPA (asks first), extensions, FPM, Xdebug
modules/install-php.sh install 8.4 7.4        # both, side by side
modules/install-php.sh set-default 7.4        # make 'php' run 7.4 (update-alternatives; asks first)
modules/install-php.sh verify                 # CLI, extensions, FPM service and socket, php-fpm -t
modules/install-php.sh xdebug                 # install/configure/show Xdebug for each version
scripts/nginx-site.sh create myapp.test /var/www/myapp/public 8.4   # a site on PHP-FPM 8.4
scripts/nginx-site.sh list                    # sites and the PHP version each one uses
```

- PHP comes from **Ondřej Surý's PPA**. The module checks whether the PPA is already configured,
  whether it publishes `noble`, and whether each package is available, before it asks.
- **Separate versions.** Each version has its own extensions, its own `phpX.Y-fpm` service and
  its own socket (`/run/php/phpX.Y-fpm.sock`). An Nginx site picks its version through that
  socket. Only versioned packages (`php8.4-…`) are installed.
- **Extensions:** `cli fpm mysql xml curl gd mbstring zip bcmath intl soap xdebug`, plus `json`
  for 7.4 (`config/packages.conf`).
- **7.4.33:** the 7.4 package is upstream **7.4.33** with the PPA's own patch revision, for example
  `1:7.4.33-31+ubuntu24.04.1+deb.sury.org+1`. It is not a pristine upstream build. The module
  shows the exact package version and warns if the upstream part ever differs.
- **The CLI default** (`php`) changes only through `set-default`, after confirmation. If an install
  makes apt repoint `/usr/bin/php`, the module sets it back.
- **Other PHP versions** (for example 8.2) are reported but never changed or removed.
- **Sites:**
  - `nginx-site.sh` only creates new files;
  - it refuses names and `server_name`s that are already in use;
  - `nginx -t` must pass before every reload;
  - `www-data` must be able to read the document root (no chmod is ever done).
- **Xdebug:**
  - the toolkit's settings use `start_with_request=trigger`, client `127.0.0.1:9003`;
  - they are written only where no `xdebug.*` settings exist yet;
  - start a debug session with `XDEBUG_TRIGGER=1`.

## Node.js and NVM version management

```bash
modules/install-nodejs.sh status              # NVM version, ~/.bashrc lines, Node versions, default
modules/install-nodejs.sh install             # NVM + ~/.bashrc block + Node.js LTS
modules/install-nodejs.sh install-node 22     # also: lts, lts/jod, 22.11.0
modules/install-nodejs.sh list                # installed versions and the default
modules/install-nodejs.sh list-remote 22      # available versions: lts (default), all or a major version
modules/install-nodejs.sh use 22              # checks 22 and prints 'nvm use 22' to run in your shell
modules/install-nodejs.sh set-default 22      # the version for every new shell (asks first)
modules/install-nodejs.sh update              # move NVM up to the pinned version (asks first)
modules/install-nodejs.sh verify              # nvm, node and npm, here and in a new shell
modules/install-nodejs.sh fix-bashrc          # repair a broken '[-s' NVM line (backup, asks first)
```

- **Official NVM only.** It comes from `github.com/nvm-sh/nvm`, pinned to **v0.41.0** in
  `config/versions.conf`.
  - The tag is checked with `git ls-remote` before anything is downloaded.
  - The official `install.sh` must match a pinned SHA-256.
  - After the install, NVM's commit must equal the tag's commit.
  - To move the pin, change `NVM_VERSION` and `NVM_INSTALL_SCRIPT_SHA256` together, then run
    `update`.
- **Per user, no sudo.** Only `~/.nvm` and `~/.bashrc` are changed. A marked block is added to
  `~/.bashrc` only when nothing there loads NVM yet, after a backup and your confirmation. A rerun
  never adds a second block.
- **NVM is a shell function**, not a program. A script cannot switch the Node.js version of the
  shell you run it from. In your own terminal, use the printed `nvm use <ver>`, or plain `nvm`
  commands (`nvm ls`, `nvm use 22`, `nvm alias default 22`).
- Installing a version never changes an existing default. When no default exists yet, nvm makes
  the first installed version the default, and the plan says so.

## Databases: MariaDB or MySQL

```bash
modules/install-mariadb.sh status|install|verify|guide
modules/install-mysql.sh   status|install|verify|guide
```

**Limitations:**
- **One at a time.** Ubuntu's MariaDB and MySQL packages conflict. Both also use port 3306,
  `/run/mysqld/mysqld.sock`, `/etc/mysql` and `/var/lib/mysql`. Each module refuses (exit 3,
  nothing changed) while the other is installed. Even a MariaDB client alone blocks MySQL.
- **MySQL is 8.0 only**, from Ubuntu's archive, and it is end-of-life upstream (April 2026). Ubuntu
  still updates the package. The module warns and asks separately. **MariaDB (10.11) is the
  recommended choice.**
- **No changes to authentication.**
  - root keeps socket login (`sudo mariadb`), and no password is set;
  - no users or databases are created;
  - `guide` shows the SQL for a per-project database and user, plus backup, restore and service
    commands.
- **Existing data is never touched.** If `/var/lib/mysql` has data but no server package is
  installed, the install refuses; you decide what to do with that data. Port 3306 (and 33060 for
  MySQL) must be free.
- `verify` checks the service, the socket, the listeners and a ping. In a terminal it also runs
  `SELECT VERSION()` and a read-only security report, which uses sudo.

If you need both, the documented alternatives are:
- MySQL in a container on `127.0.0.1:3307` (Docker Engine);
- a separate WSL distro;
- a manual switch.

See [architecture §9](docs/architecture.md#9-mysql-and-mariadb-one-at-a-time).

## Optional tools

| Tool | Source and version | Listens on | Extra actions | Notes |
|---|---|---|---|---|
| Redis | Ubuntu `redis-server` (7.0) | 127.0.0.1 and ::1, port 6379 | none | Ubuntu's defaults are kept (protected mode); config not edited |
| PostgreSQL | Ubuntu `postgresql` 16 + contrib | localhost:5432 | `guide` | Peer authentication; refuses next to another server version or leftover data. The PHP `pgsql` extension is not installed (the guide shows how) |
| Mailpit | GitHub release **v1.33.1**, SHA-256 pinned | SMTP 127.0.0.1:1025, web UI 127.0.0.1:8025 | `test`, `php-mail`, `guide` | Toolkit systemd unit (`DynamicUser`, no update checks). amd64 only. `php-mail` routes PHP `mail()` to Mailpit only where no `sendmail_path` is set |
| Docker Engine | Docker's apt repository, signing key fingerprint checked | published ports default to 127.0.0.1 | `test-run` | Refuses next to Docker Desktop's WSL integration or another engine. Creates `/etc/docker/daemon.json` only if none exists. Joining the `docker` group is a separate question (it is root-equivalent) |

Each install refuses (exit 3) when its port is already in use. From Windows, these services are
reached as `localhost:<port>`.

## Verification

```bash
scripts/check-system.sh                  # requirements (read-only)
modules/install-<tool>.sh status         # what is installed (read-only)
modules/install-<tool>.sh verify         # checks one tool; exit 0 = PASS
scripts/install-menu.sh                  # 12 -> 2: PASS/FAIL table for all 11 modules
bash tests/test-live.sh                  # read-only health check of everything installed
```

`install-all.sh` runs the verification table by itself at the end of every real run.

**What each `verify` checks:**

| Module | Checks |
|---|---|
| base | each package installed and its command runs |
| nginx | package, service active, `nginx -t`, HTTP answer on 127.0.0.1 |
| php | each version's CLI, extensions, FPM service, socket and `php-fpmX.Y -t` |
| composer | `composer --version` with each PHP |
| nodejs | `nvm`, `node` and `npm`, here and in a new shell |
| mariadb, mysql | service, socket, loopback listeners, ping |
| redis | package, service, port 6379, `redis-cli ping` |
| postgresql | cluster online, `pg_isready`; in a terminal also SQL and a read-only security report |
| mailpit | binary, service, listeners on localhost, API version, SMTP greeting |
| docker | packages, services, socket, and the server (`docker info`, or `sudo docker info` before the group applies) |

Checks that need root (`nginx -t`, `php-fpm -t`, SQL) run only when sudo can ask for your password.

**Manual checks:**

```bash
php -v; php7.4 -v; php8.4 -v
systemctl is-active nginx php8.4-fpm php7.4-fpm mariadb
sudo nginx -t
curl -I http://127.0.0.1/
composer --version
command -v nvm; nvm --version; node --version; npm --version   # in a new terminal
sudo mariadb -e 'SELECT VERSION();'
redis-cli ping                                                 # PONG
pg_isready -h 127.0.0.1
docker info                                                    # after a new WSL session
ss -ltn                                                        # services should listen on 127.0.0.1 / ::1
```

Mailpit's inbox is at http://localhost:8025 in a Windows browser.

## Exit codes

| Code | Module (`modules/*.sh`) | `install-all.sh` |
|---|---|---|
| 0 | Done | Every selected module done or already installed, and verification passed |
| 1 | Failed | A module failed, or verification failed |
| 2 | Already installed / nothing to do | (not used) |
| 3 | A requirement is not met; nothing was changed | A module was blocked, cancelled or not run because a dependency did not finish; or invalid options |
| 4 | Cancelled by you (or no terminal to ask) | Cancelled before anything ran |
| 130 | | Interrupted with Ctrl+C |

`DRY_RUN` must be unset, `0` or `1`. Any other value (for example `yes`) is refused with exit 3.

## Troubleshooting

| Problem | What to do |
|---|---|
| `[ERROR] systemd: …` (not PID 1, no `systemctl`, or offline) | The toolkit stops service work and shows how to enable systemd in `/etc/wsl.conf`. Make that change yourself, run `wsl.exe --shutdown` from Windows, reopen Ubuntu, then `scripts/check-system.sh` |
| apt waits or fails on the lock | Another apt process (often unattended-upgrades) is running. The toolkit waits up to 120 s. Wait for it to finish, then run the module again |
| "Refreshing package lists failed" | Check the network and the apt source named in the message. A broken third-party source stops the run on purpose |
| An install was interrupted | Run `sudo dpkg --configure -a` if apt asks for it, then run the same module again. Reruns are safe |
| sudo asks for the password again | Normal in long runs: sudo's timeout expired, or Composer's installer ended the sudo session (`sudo -K`) |
| `nvm: command not found` right after installing | Open a new terminal, or run `source ~/.bashrc` |
| `[-s: command not found` in every new shell | A broken NVM line in `~/.bashrc`: `modules/install-nodejs.sh fix-bashrc` |
| `docker` needs sudo after joining the group | Close all WSL terminals (or `wsl.exe --terminate <distro>`) and reopen |
| MySQL install refused | MariaDB is installed (or the reverse). They cannot run side by side; see [Databases](#databases-mariadb-or-mysql) |
| Docker install refused | Docker Desktop's WSL integration or another engine is present. The toolkit never installs a second daemon |
| Install refused: "Port … is already in use" | Another program listens on that port; `ss -ltnp` shows which |
| `install-php.sh verify` reports missing extensions | `modules/install-php.sh install <version>` installs the missing ones after asking |
| PHP CLI prints "Could not connect to debugging client" | Xdebug settings that are not the toolkit's use `start_with_request=yes`. `DRY_RUN=1 modules/install-php.sh xdebug` shows which file sets them, without changing anything; changing that file is your decision |
| Anything else | Run the module's `status` and `verify`, and check the log in `logs/` |

## Known limitations

- **Ubuntu 24.04 only.** On 26.04, the PHP PPA has no builds yet.
- **MySQL 8.0 only** (end-of-life upstream), and it cannot run next to MariaDB.
- **PHP 7.4** is end-of-life, and its package is the PPA's patched 7.4.33.
- **Mailpit** is amd64 only. Updating Mailpit or NVM means changing the pinned version and checksum
  in `config/versions.conf`.
- **Not verified yet:** the real installs, which are pending the acceptance run in a fresh distro.
- **The log file** does not hold apt's own output.
- **sudo** can ask for the password again during a long run.
- **A refused install has already refreshed the package lists.** When an install is refused
  because it would remove a package, `apt-get update` has already run. This is harmless; see
  [progress.md](docs/progress.md), item R1.
- **Node.js:** `install-nodejs.sh use` cannot switch your current shell. Only Bash (`~/.bashrc`)
  is configured.
- **Nginx sites** use `listen 80;`, like Ubuntu's default site. Under WSL's NAT networking they
  are reachable from Windows, not from the LAN.
- **Existing configurations are never changed.** For example, an existing Docker `daemon.json` or
  existing Xdebug settings keep their values, even when those differ from the toolkit's defaults.
- **Nothing is uninstalled.** Removing a tool is a manual step.

## Safety principles

- The scripts check what is already installed before changing anything, and are safe to rerun.
- They never remove packages, PHP versions or databases, and never overwrite existing configuration files.
- They never change Windows settings, `/etc/wsl.conf` or firewall rules.
- New services listen on localhost only.
- Risky actions ask for confirmation. Without an interactive terminal the answer is "no".
- Downloads are verified:
  - NVM's installer and Mailpit by SHA-256;
  - Composer by its published signature;
  - Docker's key by its fingerprint;
  - nothing is piped into a shell.

## Layout

| Path | Purpose |
|---|---|
| `config/` | Pinned versions (`versions.conf`) and apt package lists (`packages.conf`). Data only |
| `lib/` | Shared helpers: messages, logging, error handling, detection, apt, services, per-tool helpers, and the module registry (`orchestrator.sh`) |
| `modules/` | One installer per tool: base, nginx, php, composer, nodejs, mariadb, mysql, redis, postgresql, mailpit, docker |
| `scripts/` | `install-all.sh`, `install-menu.sh`, `check-system.sh`, `nginx-site.sh` |
| `templates/` | The Nginx site template and Mailpit's systemd unit |
| `tests/` | Automated tests (no system changes) |
| `logs/` | Run logs (not committed) |
| `docs/` | Architecture, implementation plan, progress and testing |
| `.shellcheckrc` | ShellCheck settings for development |

The full tree with every file is in [architecture §2](docs/architecture.md#2-directory-structure).

## Development checks

Run from `wsl-devtools/`. None of these change the system.

```bash
for f in lib/*.sh modules/*.sh scripts/*.sh tests/*.sh config/*.conf; do bash -n "$f"; done   # syntax
shellcheck -x lib/*.sh modules/*.sh scripts/*.sh tests/*.sh                     # lint (sudo apt install shellcheck); uses .shellcheckrc
shellcheck config/*.conf
for t in tests/test-*.sh; do bash "$t" || break; done                            # tests, no system changes
bash tests/test-live.sh                                                          # read-only health check of what is installed
```

## Documentation

- [Architecture](docs/architecture.md): design, module contract, safety rules, per-tool decisions
- [Implementation plan](docs/implementation-plan.md): phases and decisions
- [Progress](docs/progress.md): what each phase did, tests performed, known issues, final status
- [Testing](docs/testing.md): how to run every check, and the acceptance checklist
