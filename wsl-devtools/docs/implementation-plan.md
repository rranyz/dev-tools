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
| NVM | Official `nvm-sh/nvm`, pinned to **v0.41.0** (latest tag on 2026-11-17, re-checked in Phase 7). | Requirement: official NVM only, pinned version. |
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

### Phase 2: System detection, module contract and base packages
- **Goal:**
  - WSL2, Ubuntu, systemd and sudo detection;
  - a read-only system check;
  - the first real module;
  - an `install-all.sh` skeleton running preflight → base.
- **Files:**
  - `lib/system.sh`, `lib/packages.sh`
  - `scripts/check-system.sh` (preflight plus status of every tool, read-only)
  - `modules/install-base.sh`
  - `scripts/install-all.sh` (skeleton)
- **Tests:**
  - Run `check-system.sh` on the development machine. It must report the existing stack correctly and change nothing.
  - In the fresh distro, install, then rerun. The second run must report "skipped".
  - `DRY_RUN=1` on the development machine.

### Phase 3: Nginx
- **Goal:** install Nginx, verify the service, never touch existing sites.
- **Files:** `modules/install-nginx.sh`.
- **Tests:** `sudo nginx -t`, `curl -sI http://localhost`, rerun.

### Phase 4: PHP 8.4 and 7.4
- **Goal:**
  - PPA check and add;
  - PHP 8.4 and/or 7.4 with versioned extensions and FPM;
  - a `set-default` action for the PHP CLI.
- **Files:** `modules/install-php.sh`, `config/packages.conf` (confirm the extension lists).
- **Tests:**
  - Each version alone, then both together.
  - Socket per version.
  - `php -v` is unchanged unless `set-default` is used.
  - EOL warning shown for 7.4.

### Phase 5: Xdebug and per-site Nginx ↔ PHP-FPM
- **Goal:**
  - Xdebug per PHP version, with a toolkit drop-in and `start_with_request=trigger`;
  - a site generator bound to a chosen FPM socket.
- **Files:** `modules/install-xdebug.sh`, `scripts/nginx-site.sh`, `templates/nginx-site.conf.tpl`.
- **Tests:**
  - Create one 7.4 site and one 8.4 site, and check `phpinfo()` versions.
  - Refuse an existing site name.
  - With a deliberately broken template, `nginx -t` fails and nothing is reloaded.

### Phase 6: Composer
- **Goal:** install Composer to `/usr/local/bin`, verifying the installer signature against
  `composer.github.io/installer.sig`.
- **Files:** `modules/install-composer.sh`.
- **Tests:** `composer --version` works with each PHP version, and a rerun is skipped.

### Phase 7: Node.js via NVM
- **Goal:**
  - Pinned NVM (tag verified before download), installed to `~/.nvm`;
  - Node LTS and specific versions;
  - list, use and set default;
  - an idempotent `.bashrc` block.
- **Files:** `modules/install-nodejs.sh`, `config/versions.conf` (NVM pin).
- **Tests:**
  - `command -v nvm`, `nvm --version`, `node --version`, `npm --version` in a new shell.
  - The `.bashrc` block is not duplicated on rerun.
  - No sudo used.

### Phase 8: MariaDB / MySQL
- **Goal:** two mutually exclusive modules.
- **Files:** `modules/install-mariadb.sh`, `modules/install-mysql.sh`.
- **Tests:**
  - Install one, verify the service and a query.
  - Then run the other module: it must exit 3 with an explanation and change nothing.

### Phase 9: Redis, PostgreSQL, Mailpit
- **Files:** `modules/install-redis.sh`, `modules/install-postgresql.sh`, `modules/install-mailpit.sh`.
- **Tests:**
  - `redis-cli ping`.
  - `pg_lsclusters`.
  - Mailpit UI on 8025, and a test mail sent through PHP `mail()` via the SMTP port 1025.

### Phase 10: phpMyAdmin
- **Files:** `modules/install-phpmyadmin.sh` (plus an Nginx site through `nginx-site.sh`).
- **Tests:**
  - Login page loads through Nginx.
  - apache2 is **not** installed.
  - No debconf prompt blocks the run.

### Phase 11: Docker Engine
- **Files:** `modules/install-docker.sh`.
- **Tests:**
  - Detection result on the development machine (none).
  - Install in the fresh distro.
  - `docker run --rm hello-world` in a new shell.

### Phase 12: Full `install-all.sh`
- **Goal:** module selection, dependency-aware order, progress, a summary table and a log file.
- **Tests:**
  - Full run in a fresh distro, then a full rerun with everything skipped.
  - A simulated failure must skip only the dependent modules.

### Phase 13: `install-menu.sh`
- **Goal:** an interactive menu for install, status and verify per module, plus PHP default
  and Node version actions.
- **Tests:** invalid input handling, navigation, and status on the development machine.

### Phase 14: Final verification and documentation
- **Goal:** an end-to-end run on a new 24.04 distro, and a completed `README.md` and `docs/testing.md`.

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
| MySQL/MariaDB package conflict | apt would remove the existing server | Mutually exclusive modules; never remove |
| Existing Nginx sites and configs | Overwriting breaks working projects | Create new files only; refuse existing names; `nginx -t` before reload |
| systemd shows `degraded` because of desktop units | False "no systemd" result | Accept `running` and `degraded` |
| systemd disabled on another machine | Service operations fail | Detect, explain, stop. Do not edit `wsl.conf` |
| sudo needs a password | Unattended runs and Claude cannot run installs | `sudo -v` up front; the user runs install tests |
| Xdebug active for every CLI call | Noisy output, slow Composer | `start_with_request=trigger` in the toolkit drop-in; `XDEBUG_MODE=off` in verification |
| phpMyAdmin from apt recommends apache2 and asks debconf questions | Apache grabs port 80; the run blocks | `--no-install-recommends`, preseeded debconf (method decided in Phase 10) |
| Docker group change needs a new login | `docker` fails right after install | Tell the user to open a new shell; `verify` uses `sudo docker` until then |
| A duplicate Docker daemon next to Docker Desktop | Two Docker hosts, confusing contexts | Detect Desktop and refuse |
| Services bound to all interfaces | Exposure to the LAN if WSL networking is switched to mirrored mode or port proxies are added | New toolkit configs bind to localhost where possible; never change existing bindings without approval |
| apt lock held by unattended-upgrades | Install fails mid-way | Bounded wait for the lock, then a clear error |
| A network or download failure mid-install | Partial install | Idempotent modules; a rerun completes the remaining steps |
| An NVM tag or download URL changes | NVM install fails | Verify the tag exists before downloading; pin in config |

## Open questions (decided in their phase, not blocking Phase 1)

1. **phpMyAdmin** (Phase 10): Ubuntu's apt package (5.2.1, uses the default PHP) or the upstream
   release tarball in `/usr/share/phpmyadmin`?
2. **Mailpit** (Phase 9): pinned GitHub release binary with checksum verification, or the
   project's install script? Which version to pin?
3. **PHP extensions** (Phase 4): the default list per version, for example
   cli, fpm, mysql, curl, mbstring, xml, zip, intl, gd, bcmath, opcache, readline,
   plus `redis` and `pgsql` when those modules are chosen.
4. **Nginx site binding** (Phase 5): should new sites listen on `127.0.0.1:80` only, or on all
   interfaces like the existing sites?
5. **Existing NVM 0.39.1** on the development machine (Phase 7): leave it, or offer an upgrade to
   the pinned version?
6. **`~/.bashrc` typo** on the development machine: fix line 121 (`[-s` → `[ -s`), separately and
   with approval?
7. **Node versions** (Phase 7): besides LTS, which specific versions should the module offer by
   default?
