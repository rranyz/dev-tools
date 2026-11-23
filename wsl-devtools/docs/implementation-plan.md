# Implementation Plan

The toolkit is built one phase at a time. A phase starts only after the previous one is
approved. Each phase ends with:

- execution instructions and expected output;
- a testing checklist;
- limitations;
- an update to `docs/progress.md`.

Target platform: **Ubuntu 24.04 (noble) on WSL2 with systemd.** See
[architecture.md](architecture.md) for the design.

## Decisions taken in Phase 0

| Topic | Decision | Reason |
|---|---|---|
| Ubuntu support | 24.04 only. Scripts refuse other releases. | Matches the development machine. Ubuntu 26.04 (`resolute`) is out of scope: on 2026-11-17 the PHP PPA publishes no `resolute` builds, and the 26.04 archive only has PHP 8.5. |
| MySQL vs MariaDB | One at a time. Each module refuses if the other is installed. | apt conflict (`virtual-mysql-server`), and shared port, socket, config tree and data directory. |
| Test environment | A fresh, disposable Ubuntu 24.04 WSL distro for install tests. The development machine is used only for read-only `status` checks. | The development machine already runs a working stack with real sites and data. |
| Docker | Native Docker Engine from Docker's apt repo, after confirmation. Refuse if Docker Desktop integration is present. | Avoids two Docker daemons. |
| NVM | Official `nvm-sh/nvm`, pinned to **v0.41.0** (newest tag on 2026-11-17, re-checked in Phase 4). | Requirement: official NVM only, pinned version. |
| Privileges | Run as the normal user and use sudo per command. Never use sudo for NVM or npm. | NVM is per-user. |
| Config changes | Only new toolkit-owned drop-in files, never edits to package files. | Rerun safety, and no overwrites. |

## Phases

### Phase 1: Project foundation (completed)
- **Goal:**
  - the directory structure;
  - config files;
  - shared helpers: messages, logging, error handling, command checks, confirmation, validation, safe config loading.
- **Files:**
  - `config/versions.conf`, `config/packages.conf`
  - `lib/common.sh`
  - `tests/test-common.sh`
  - `logs/.gitignore`, and `.gitkeep` in `modules/`, `scripts/`, `templates/`
  - `README.md` skeleton, `docs/testing.md`
- **Tests:** `bash -n`, `shellcheck`, `bash tests/test-common.sh`.
- **Exit criterion:** all tests pass, with no system changes.
- **Changed from Phase 0:**
  - `packages.conf` replaces `php-extensions.conf`.
  - System detection moved to Phase 2, as the user decided.

### Phase 2: System preparation (completed)
- **Goal:**
  - Ubuntu, WSL2, systemd, sudo and APT detection;
  - safe package-list updates;
  - install and verify curl, wget, zip, unzip and git.
- **Files:**
  - `lib/system.sh`, `lib/packages.sh`
  - `scripts/check-system.sh` (read-only)
  - `modules/install-base.sh`
  - `tests/helpers.sh`, `tests/test-system.sh`
- **Tests:**
  - `tests/test-system.sh`.
  - Read-only runs on the development machine.
  - Install and rerun in a fresh distro, run by the user.
- **Changed from the earlier plan:** the `install-all.sh` skeleton moved to the `install-all.sh` phase (Phase 7), because the
  Phase 2 brief did not ask for it.

### Phase 3: Web server and PHP environment (completed)
Merges the earlier Phases 3–6 (Nginx, PHP, Xdebug with per-site FPM, Composer), as the Phase 3
brief asked.
- **Goal:**
  - Nginx;
  - PHP 7.4 and 8.4 from the PPA with version-specific extensions and separate FPM services;
  - Nginx sites per PHP-FPM version;
  - Xdebug;
  - a confirmed CLI switch;
  - an interactive PHP menu;
  - Composer through the official installer.
- **Files:**
  - `lib/services.sh`, `lib/nginx.sh`, `lib/php.sh`
  - `modules/install-nginx.sh`, `modules/install-php.sh`, `modules/install-composer.sh`
  - `scripts/nginx-site.sh`, `templates/nginx-site.conf.tpl`
  - `tests/test-web.sh`
- **Tests:**
  - `tests/test-web.sh`.
  - Read-only runs on the development machine.
  - The fresh-distro checklist in `testing.md`, run by the user.

### Phase 4: Node.js via NVM (completed)
- **Goal:**
  - Pinned NVM (tag verified before download), installed to `~/.nvm` with the official `install.sh`;
  - Node LTS and specific versions;
  - list installed and available versions, use, set default;
  - NVM update to the pin;
  - an idempotent `.bashrc` block;
  - verification, and an interactive Node menu.
- **Files:**
  - `lib/node.sh`
  - `modules/install-nodejs.sh`
  - `tests/test-node.sh`
  - `config/versions.conf` (NVM pin, installer URL and SHA-256)
- **Tests:**
  - `tests/test-node.sh`.
  - Read-only runs on the development machine.
  - The fresh-distro checklist in `testing.md`, run by the user: `command -v nvm`, `nvm --version`,
    `node --version`, `npm --version` in a new shell; the `.bashrc` block is not duplicated on
    rerun; no sudo is used.

### Phase 5: MariaDB / MySQL (completed)
- **Goal:**
  - two independent, mutually exclusive modules, from Ubuntu's archive;
  - the conflict, port, path and data-directory investigation;
  - verification of the service and connectivity;
  - a read-only security report and initial configuration guidance.
- **Files:**
  - `lib/database.sh`
  - `modules/install-mariadb.sh`, `modules/install-mysql.sh`
  - `tests/test-db.sh`
  - `port_listeners` moved from `install-nginx.sh` to `lib/system.sh`
- **Tests:**
  - `tests/test-db.sh`, including real SQL against a temporary MariaDB server.
  - Read-only runs on the development machine.
  - In fresh distros, run by the user: install one, verify the service, ping and a query; then the
    other module must exit 3 with an explanation and change nothing.

### Phase 6: Optional tools (completed)
Merges the earlier Phases 6–8, as the Phase 6 brief asked.
- **Goal:**
  - Redis, PostgreSQL, Mailpit and Docker Engine as independent modules;
  - each local-only by default, never overwriting existing configuration.
- **Files:**
  - `modules/install-redis.sh`, `modules/install-postgresql.sh`, `modules/install-mailpit.sh`,
    `modules/install-docker.sh`
  - `lib/docker.sh`
  - `templates/mailpit.service.tpl`
  - `tests/test-optional.sh`
  - shared helpers: `download_checked`, `sha256_of` (`lib/common.sh`); `port_listen_addresses`,
    `is_loopback_listener`, `report_port_listeners` (`lib/system.sh`); `service_restart`,
    `service_daemon_reload` (`lib/services.sh`)
- **Tests:**
  - `tests/test-optional.sh`.
  - Read-only runs and dry runs on the development machine.
  - In a fresh distro, run by the user: `redis-cli ping`; `pg_lsclusters` and `pg_isready`; the
    Mailpit UI on 8025 with `test` and a PHP `mail()` after `php-mail`; Docker `test-run`, and a
    published port bound to 127.0.0.1.

### Phase 7: Installation orchestration (completed)
Merges the earlier provisional Phases 7 (`install-all.sh`) and 8 (`install-menu.sh`), as the
Phase 7 brief asked.
- **Goal:**
  - `install-all.sh`: project information, environment checks, the module list, the selection
    (nothing preselected), dependency order, progress, failure handling (only dependents are
    skipped), a summary, and a verification table;
  - `install-menu.sh`: a 13-entry main menu over all modules plus installation status;
  - validated input, graceful Ctrl+C and unexpected errors;
  - no module changes.
- **Files:**
  - `lib/orchestrator.sh`
  - `scripts/install-all.sh`, `scripts/install-menu.sh`
  - `tests/test-orchestrator.sh`
- **Tests:**
  - `tests/test-orchestrator.sh` with stub modules, including a pseudo-terminal for the
    interactive paths.
  - Ctrl+C checked by hand through a pseudo-terminal.
  - Read-only runs and dry runs on the development machine.
  - In a fresh distro, run by the user: a full run, a rerun with everything already installed, a
    cancelled php skipping only composer.

### Phase 8: Testing and quality assurance (completed, approved)
- **Goal:**
  - a QA pass over the 18 areas of the Phase 8 brief (see testing.md §10);
  - mock-based failure scenarios and read-only live checks, with nothing destructive on the
    development machine;
  - fixes of low-risk issues.
- **Files:**
  - `tests/test-qa.sh` (no systemd, missing dependencies, failed apt steps, removal guard, invalid
    `DRY_RUN`) and `tests/test-live.sh` (a read-only health check and repeat runs, with a
    before/after system snapshot);
  - fixes in `lib/common.sh` (`DRY_RUN` validation for every entry script) and
    `lib/packages.sh` (a message when `apt-get install` fails).
- **Tests:** all suites; ShellCheck; the distro checklist in testing.md §10, run by the user.

### Phase 9: Final documentation and project review (completed, approved)
Defined by the user's Phase 9 brief, which replaces the earlier provisional definition.
- **Goal:**
  - a finished `README.md` covering: requirements, prerequisites, `install-all.sh`,
    `install-menu.sh`, PHP and NVM/Node.js version management, database limitations, optional
    tools, verification, troubleshooting, known limitations;
  - a review of the directory structure and of Bash readability and maintainability;
  - a check that the documentation matches the implementation;
  - a final project status report in `progress.md`;
  - no new features, and no changes to the installation logic.
- **Also from the earlier Phase 9 step:** the acceptance checklist in `docs/testing.md` §12, which
  the user runs in a new 24.04 distro.
- **Files:** `README.md`, `docs/testing.md`, `docs/architecture.md`, this file,
  `docs/progress.md`. No code changes.
- **Deferred:** R1 (no `apt-get -s` before the package-list refresh) stays a documented
  limitation, as the user decided.
- **Exit criterion:**
  - the user approves the documentation and the review;
  - all static checks and suites still pass.
  - The real-install acceptance run (testing.md §12) remains open until the user reports it.

## Testing approach (all phases)

1. **Static checks:** `bash -n` and `shellcheck`. The user installs shellcheck with
   `sudo apt install shellcheck`, as a development-only dependency.
2. **Read-only checks on the development machine:** `status`, `verify` and `DRY_RUN=1` only.
3. **Install tests:** in a disposable Ubuntu 24.04 WSL distro that the user creates and removes on
   the Windows side.
4. **Idempotency:** every `install` is run twice. The second run must change nothing and exit 2.
5. sudo needs a password, so install tests are run by the user, who shares the output.

## Risks and mitigation

| Risk | Impact | Mitigation |
|---|---|---|
| PHP 7.4 is EOL; the PPA could drop it or stop updating it | Legacy apps lose their runtime or security fixes | EOL warning and confirmation; check package availability at install time; report the exact package version |
| The PPA's unversioned `php-*` metapackages follow the PPA default (8.4 today) | An unwanted PHP version gets pulled in later | Install versioned packages only |
| MySQL/MariaDB package conflict | apt would remove the existing server | Mutually exclusive modules, detected by dpkg package names; `apt_install` refuses removals; never remove |
| Leftover `/var/lib/mysql` from an earlier install | A new server starts on foreign or incompatible data | Refuse (exit 3) when the data directory has data or can't be inspected and no server package is installed |
| MySQL 8.0 is end-of-life upstream (April 2026) | No upstream fixes; Ubuntu still updates its package | EOL warning with a separate confirmation; MariaDB is the recommended choice |
| Existing Nginx sites and configs | Overwriting breaks working projects | Create new files only; refuse existing names; `nginx -t` before reload |
| systemd shows `degraded` because of desktop units | False "no systemd" result | Accept `running` and `degraded` |
| systemd disabled on another machine | Service operations fail | Detect, explain, stop. Do not edit `wsl.conf` |
| sudo needs a password | Unattended runs and Claude cannot run installs | `sudo -v` up front; the user runs install tests |
| Xdebug active for every CLI call | Noisy output, slow Composer | `start_with_request=trigger` in the toolkit drop-in; `XDEBUG_MODE=off` in verification |
| A downloaded binary or apt key is replaced upstream | Running changed code as root | Mailpit: SHA-256 pinned in config (`download_checked`); Docker: key fingerprint pinned and checked before the key is installed |
| Docker publishes container ports on all interfaces by default | Containers reachable beyond this machine (mirrored networking, port proxies) | A new `/etc/docker/daemon.json` sets `"ip": "127.0.0.1"`; an existing one is never changed |
| Docker Desktop integration next to a native Engine | Two daemons, conflicting CLI and socket | Detect and refuse; never install next to it |
| The `docker` group is root-equivalent | Any process of the user can control root | Asked separately, with the explanation; `sudo docker` otherwise |
| Docker group change needs a new login | `docker` fails right after install | Tell the user to open a new shell; `verify` uses `sudo docker` until then |
| A duplicate Docker daemon next to Docker Desktop | Two Docker hosts, confusing contexts | Detect Desktop and refuse |
| Services bound to all interfaces | Exposure to the LAN if WSL networking is switched to mirrored mode or port proxies are added | New toolkit configs bind to localhost where possible; never change existing bindings without approval |
| apt lock held by unattended-upgrades | Install fails mid-way | Bounded wait for the lock, then a clear error |
| A network or download failure mid-install | Partial install | Idempotent modules; a rerun completes the remaining steps |
| `DRY_RUN` set to something other than `1` (for example `yes`) | A real install when a dry run was meant | Every entry script refuses values other than unset, `0` or `1` (exit 3) |
| Ctrl+C while apt or dpkg runs (install-all, menu) | A half-configured package | The module stops; the scripts suggest `sudo dpkg --configure -a` and never run it themselves; rerunning is safe |
| A long install-all run outlives sudo's timeout, or Composer's `sudo -K` drops it | A later module asks for the password again | Documented; each module asks for sudo itself when it needs it |
| install-all asks many questions | Tempting to add an auto-yes | Not added: the modules' own confirmations carry the EOL, conflict and docker-group warnings |
| An NVM tag or download URL changes | NVM install fails | Verify the tag exists before downloading; pin in config |
| NVM's `install.sh` has no published checksum | A changed script would run as the user | Download to a file, never pipe; check it against the SHA-256 pinned in `versions.conf`; run with a fixed environment (`PROFILE=/dev/null`, `METHOD=git`) |
| NVM's installer runs `git checkout -f` when updating | Local edits in `~/.nvm` would be lost | `update` refuses when tracked files in `~/.nvm` have changes, or when it is not a git checkout |

## Open questions

Resolved:
- **PHP extensions** (Phase 3): the brief's list, `cli fpm mysql xml curl gd mbstring zip bcmath
  intl soap xdebug`, plus `json` for 7.4. `common`, `opcache` and `readline` come in as dependencies.
- **Nginx site binding** (Phase 3): `listen 80;` like the existing sites (see architecture.md §8).
- **Xdebug start mode** (Phase 3): `trigger`, the user's choice.
- **Existing NVM 0.39.1** on the development machine (Phase 4): left as it is. `install` reports it
  and points to `update`, which upgrades to the pin only after confirmation.
- **`~/.bashrc` typo** (Phase 4): reported by `status` and `verify`. `install-nodejs.sh fix-bashrc`
  fixes only that line, after a backup and confirmation. Not run on the development machine.
- **Node versions** (Phase 4): free-form, validated input (`lts`, `lts/<codename>`, `22`,
  `22.11.0`, …), checked at nodejs.org before installing. No preset list to maintain.
- **MySQL/MariaDB coexistence** (Phase 5): mutually exclusive. Alternatives are documented: a
  container on 127.0.0.1:3307 with Docker Engine (Phase 6), a separate WSL distro, or a manual switch.
- **MySQL source** (Phase 5): Ubuntu's archive (8.0), with an end-of-life warning. Oracle's
  repository (8.4 LTS) was not chosen.
- **Database initial setup** (Phase 5): written guidance (`guide`) plus a read-only security report
  in `verify`. No user creation, and root and authentication are never changed.
- **NVM install method** (Phase 4): the official `install.sh` at the pinned tag, checksum-checked,
  with `PROFILE=/dev/null`; the toolkit writes its own `.bashrc` block.

- **Mailpit** (Phase 6): the pinned GitHub release binary v1.33.1 (SHA-256 = GitHub's published
  digest), with a toolkit systemd unit bound to 127.0.0.1. PHP `mail()` routing is a separate
  opt-in action (`php-mail`).
- **Docker** (Phase 6): Docker's official apt repository, key fingerprint checked; a new
  `daemon.json` makes published ports default to 127.0.0.1 (only when none exists).

Open: none.
