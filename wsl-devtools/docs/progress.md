# Progress

## Summary

| Phase | Title | Status |
|---|---|---|
| 0 | Requirements analysis and architecture | Completed, approved |
| 1 | Project foundation (structure, config, shared helpers) | Completed, approved |
| 2 | System preparation (detection, apt, base utilities) | Completed, approved |
| 3 | Web server and PHP environment (Nginx, PHP 7.4/8.4, FPM, sites, Xdebug, Composer) | Completed, approved |
| 4 | Node.js via official NVM | Completed, approved |
| 5 | MariaDB / MySQL (mutually exclusive) | Completed, approved |
| 6 | Optional tools: Redis, PostgreSQL, Mailpit, Docker Engine | Completed, approved |
| 7 | Installation orchestration: `install-all.sh` and `install-menu.sh` (reviewed) | Completed, approved |
| 8 | Testing and quality assurance | Completed, approved |
| 9 | Final documentation and project review | **Completed, awaiting review** (real-install acceptance run pending) |

Phase 3 merged the earlier plan's Phases 3–6, so the later phases were renumbered. Phase 7 merged
the provisional `install-all.sh` and `install-menu.sh` phases.

---

## Phase 0: Requirements analysis and architecture (2026-11-17)

### Implemented
Documentation only. No scripts, no installs, no system changes.

### Files created
- `docs/architecture.md`
- `docs/implementation-plan.md`
- `docs/progress.md`

(`CLAUDE.md` was added before Phase 0.)

### Decisions
- Support **Ubuntu 24.04 only**. 26.04 is out of scope: the PHP PPA has no `resolute` builds, and
  the 26.04 archive only has PHP 8.5.
- **MySQL and MariaDB are mutually exclusive.** Each module refuses if the other is installed.
- **Install tests run in a fresh, disposable Ubuntu 24.04 WSL distro.** The development machine
  gets only read-only checks.
- **Docker:** native Docker Engine from Docker's apt repository, after confirmation. Refuse if
  Docker Desktop integration is detected.
- **NVM** pinned to v0.41.0, re-verified in Phase 4.
- Run as the normal user with sudo per command. Toolkit-owned drop-in files only.

Full rationale: [implementation-plan.md](implementation-plan.md#decisions-taken-in-phase-0).

### Tests performed
Read-only inspection of the development machine:

| Area | Finding |
|---|---|
| WSL / OS | WSL 2.7.12, NAT networking, kernel 6.18 WSL2, Ubuntu 24.04.5 (noble), amd64 |
| systemd | PID 1 is systemd, `/etc/wsl.conf` has `systemd=true`. `is-system-running` = **degraded** (lightdm, gpu-manager, tpm-udev failed, which is harmless under WSL) |
| sudo | Password required |
| PHP PPA | `ondrej-ubuntu-php-noble.sources` already configured |
| PHP | 7.4.33-30, 8.2 (FPM), 8.4.25 (FPM), 8.5 (CLI only) installed. Candidates: 7.4.33-31, 8.4.27 |
| PHP CLI default | `update-alternatives` manual mode → `/usr/bin/php8.4` |
| PHP-FPM | `php7.4-fpm`, `php8.2-fpm`, `php8.4-fpm` active; sockets in `/run/php/` |
| Xdebug | 3.5.3 for PHP 8.2 and 8.4, active in CLI |
| Nginx | 1.24, active on port 80 (all interfaces). Sites enabled: `default`, `casinoadmin2.local`, `casinoadmin-api2.local` |
| MariaDB | 10.11.14 active on `127.0.0.1:3306`. MySQL server not installed (`mysql-server` candidate 8.0.46) |
| NVM / Node | NVM 0.39.1 (official repo). Node 18.20.8, 19.9.0, 22.20.0, 24.13.0, 24.20.0, 26.7.0 installed. Default alias → 18 |
| Composer | 2.8.12, `/usr/local/bin/composer` |
| Not installed | Redis, PostgreSQL, Mailpit, Docker (no Docker Desktop either), shellcheck |
| Ubuntu 26.04 check | PPA has no `resolute` dist. The 26.04 archive has PHP 8.5, MariaDB 11.8, MySQL 8.4 |

### Known issues (development machine, not caused by the toolkit)
- `~/.bashrc` line 121: `[-s "$NVM_DIR/bash_completion" ]` is missing a space after `[`, so every
  new shell prints `[-s: command not found`. Not changed; a fix needs approval (open question 6).
- The default Node version is 18, which is end-of-life. Not changed.
- PHP 8.2 and 8.5 are installed outside the toolkit's scope. The toolkit will report them but never touch them.
- Xdebug in CLI prints "Could not connect to debugging client" on every PHP command (for example `composer`).
- Nginx listens on all interfaces (`0.0.0.0:80`, `[::]:80`). Under NAT networking this is reachable
  from Windows but not from the LAN.

### Remaining work
Phases 1–14 as listed in [implementation-plan.md](implementation-plan.md). Open questions 1–7 there
are resolved in their phases.

### Next step
Approved. Phase 1 started.

---

## Phase 1: Project foundation (2026-11-17)

### Implemented
The directory structure, the config files and the shared helper library. No installs and no
system changes.

### Files created
| File | Purpose |
|---|---|
| `config/versions.conf` | Supported Ubuntu release, PHP PPA and versions (8.4, 7.4; 7.4 marked EOL), NVM repo and pinned tag v0.41.0, default Node (`lts/*`), Composer location |
| `config/packages.conf` | apt package lists per module. PHP extensions are suffixes (`php<ver>-<ext>`) |
| `lib/common.sh` | Messages, log file, strict mode and ERR trap, `run` with `DRY_RUN`, command checks, `confirm`, validators, `load_config` |
| `tests/test-common.sh` | 58 tests for `lib/common.sh` |
| `logs/.gitignore` | Keeps run logs out of git |
| `modules/.gitkeep`, `scripts/.gitkeep`, `templates/.gitkeep` | Keep the empty directories in git |
| `README.md` | Project overview skeleton |
| `docs/testing.md` | How to run static checks, tests and manual checks; per-phase checklist |

`docs/architecture.md` and `docs/implementation-plan.md` were updated to match.

### Decisions
- Shared helpers go in **`lib/common.sh`**, not `modules/common.sh`, so `modules/` holds only
  installers (the user's choice).
- **System detection** (`lib/system.sh`, `scripts/check-system.sh`) moved to Phase 2 (the user's choice).
- `config/packages.conf` replaces the planned `config/php-extensions.conf`.
- **Config files are data only.** `load_config` refuses any line that isn't a plain
  `NAME="value"`, so sourcing a config cannot run commands.
- Sourcing `lib/common.sh` changes no shell options. Entry scripts opt in with
  `enable_strict_mode`.
- `confirm` defaults to **no**, including when there is no terminal.
- `is_valid_domain` requires a lowercase name with at least one dot (for example `myapp.test`).

### Tests performed
- `bash -n` on `lib/common.sh`, `tests/test-common.sh` and both config files: passed.
- `bash tests/test-common.sh`: **58 passed, 0 failed**.
- Manual check: a config value containing a backslash is refused. An error inside nested
  functions is reported once by the ERR trap.
- `shellcheck`: **not run**. It isn't installed, and installing it needs sudo. Run the commands in
  [testing.md](testing.md#1-static-checks).

### Known issues and limitations
- `shellcheck` results are still to be confirmed by the user.
- Config values cannot contain `$`, backticks, backslashes or double quotes. That is fine for
  versions and package lists. If a later phase needs such a value, the format rule will be
  revisited.
- The PHP extension list in `packages.conf` is a proposal until Phase 4 (open question 3).

### Remaining work
Phases 2–14.

### Next step
Approved. Phase 2 started.

---

## Phase 2: System preparation (2026-11-17)

### Implemented
- Detection of Ubuntu, WSL2, the Ubuntu version, systemd and `systemctl`, sudo and APT.
- Safe package-list updates.
- Installation and verification of curl, wget, zip, unzip and git.

Installs were tested only through fakes and dry runs. **No package was installed on the
development machine.**

### Files
| File | Change |
|---|---|
| `lib/system.sh` | New. Read-only detection: `read_os_release`, `detect_wsl_version`, `is_systemd_pid1`, `systemd_state`, `sudo_status`, `require_sudo`, `apt_busy_process`; the `check_*` functions and `preflight` |
| `lib/packages.sh` | New. `is_package_installed`, `package_version`, `missing_packages`, `package_candidate`, `apt_update`, `apt_would_remove`, `apt_install` (refuses removals) |
| `modules/install-base.sh` | New. `status`, `install`, `verify` for `BASE_PACKAGES` |
| `scripts/check-system.sh` | New. Read-only readiness report; exit 0 or 3 |
| `tests/helpers.sh`, `tests/test-system.sh` | New. Shared assertions; 42 tests |
| `lib/common.sh` | `CONFIG_DIR` can be overridden with `WSL_DEVTOOLS_CONFIG_DIR` (for tests); new `load_project_config` |
| `config/packages.conf` | `BASE_PACKAGES="curl wget zip unzip git"`; new `APT_PREREQUISITE_PACKAGES` |
| `tests/test-common.sh` | Uses `tests/helpers.sh` |
| `modules/.gitkeep`, `scripts/.gitkeep` | Removed; the folders now have real files |
| `README.md`, `docs/*.md` | Updated |

### Decisions
- **WSL2 detection** reads the kernel name (`/proc/sys/kernel/osrelease`):
  - contains `WSL2` → WSL2;
  - ends in `-Microsoft` → WSL1, which is refused with a conversion hint;
  - any other `microsoft` kernel → refused as "unknown".
- **systemd** counts as usable when PID 1 is systemd and the state is running, degraded, starting
  or initializing. This machine reports `degraded` because of desktop units. When systemd is
  unusable, the toolkit explains how to enable it and stops. It never edits `/etc/wsl.conf` and
  never falls back to manual service management.
- **sudo detection never prompts.** The password is asked (`sudo -v`) only right before a real change.
- **Package lists are refreshed only when something must be installed**, and only after
  confirmation. `--error-on=any` makes any failing apt source stop the run. The toolkit never runs
  `apt upgrade`.
- **apt installs refuse to remove packages.** They are simulated first, run with
  `NEEDRESTART_MODE=l` (services are not auto-restarted), and wait up to 120 s for the apt lock.
- **Exit code 4 = cancelled by the user** was added to the module contract.
- `ca-certificates`, `gnupg` and `software-properties-common` moved to `APT_PREREQUISITE_PACKAGES`,
  used by the PHP PPA and Docker phases. The brief limits base utilities to five tools.
- The `install-all.sh` skeleton moved to Phase 12.

### Tests performed
- `bash -n` on all scripts and configs: passed.
- `bash tests/test-common.sh`: 58 passed, 0 failed.
- `bash tests/test-system.sh`: **42 passed, 0 failed**.
- On the development machine, all read-only:
  - `check-system.sh` → exit 0;
  - `install-base.sh status` / `verify` → exit 0;
  - `install-base.sh install` → "already installed", exit 2, no password prompt.
- A dry run with an unavailable package exits 3 after printing the planned `sudo apt-get update`.
  With no terminal, the install is cancelled with exit 4.
- Fixed during testing:
  - The apt-busy warning matched the always-running `unattended-upgrade-shutdown` helper. It now
    matches only `/usr/bin/unattended-upgrade`.
  - The zip version line showed the copyright notice.
- **Not yet done:**
  - `shellcheck` (not installed);
  - a real install in a fresh Ubuntu 24.04 distro.

  Both are for the user; see [testing.md](testing.md#4-phase-2-checks).

### Known issues and limitations
- A WSL2 setup with a custom kernel whose name lacks `WSL2` is reported as "unknown" and refused.
- `--error-on=any` means a broken unrelated apt source (for example a third-party `.list`) stops
  the install until it is fixed. This is deliberate, so problems are not hidden.
- The development machine has 81 upgradable packages (seen in an apt simulation). The toolkit
  does not upgrade them. That is the user's choice.

### Remaining work
Phases 3–14.

### Next step
Approved. Phase 3 started.

---

## Phase 3: Web server and PHP environment (2026-11-17)

### Implemented
- Nginx install and verification.
- PHP 7.4 and 8.4 from Ondřej Surý's PPA, each with the brief's extensions and its own FPM service and socket.
- Nginx sites tied to a chosen PHP-FPM version.
- Xdebug.
- Switching the CLI default after confirmation.
- The interactive PHP menu.
- Composer through the official installer.

**Nothing was installed or changed on the development machine.** Only read-only runs, dry runs,
and tests with a fake `sudo`.

### Files
| File | Change |
|---|---|
| `lib/services.sh` | New. `systemd_ready` (cached `check_systemd`), `service_is_active`, `service_is_enabled`, `service_state`, `service_reload`, `service_enable_now`. Changes refuse to run without systemd |
| `lib/nginx.sh` | New. `nginx_config_test`, `nginx_reload` (test first), `nginx_site_exists`, `nginx_server_name_in_use`, `render_site_config`, `nginx_site_summary` |
| `lib/php.sh` | New. Installed and managed versions, `php_packages_for_version`, `php_module_name`, `is_php_ppa_configured`, FPM socket, service and config test, reload, `php_cli_default`, `php_cli_mode`, `php_set_cli_default`, the Xdebug settings helpers (`xdebug_foreign_settings`, `xdebug_sapis_needing_settings`, `configure_xdebug`, `xdebug_show`) |
| `modules/install-nginx.sh` | New. `status`, `install`, `verify`. Never writes Nginx config |
| `modules/install-php.sh` | New. `status`, `install <ver…>`, `verify`, `set-default`, `xdebug`, `site`, `menu` |
| `modules/install-composer.sh` | New. `status`, `install` (signature-checked official installer), `verify` (with each PHP) |
| `scripts/nginx-site.sh` | New. `list`; `create <domain> <root> <php-version>` |
| `templates/nginx-site.conf.tpl` | New. Site template |
| `tests/test-web.sh` | New. 63 tests |
| `lib/packages.sh` | Added `upstream_version`, `apt_source_configured`, `install_missing_packages` (moved out of `install-base.sh`) |
| `lib/common.sh` | Added `is_safe_path`, `exit_code_meaning` |
| `lib/system.sh` | Added `can_use_sudo_now` |
| `modules/install-base.sh` | Uses `install_missing_packages` |
| `config/versions.conf` | `PHP74_UPSTREAM_VERSION`, `PHP_PPA_URL`, the Xdebug settings, the Composer URLs |
| `config/packages.conf` | `PHP_EXTENSIONS` (the brief's list) replaces `PHP_COMMON_EXTENSIONS`; phase numbers in comments |
| `templates/.gitkeep` | Removed |
| `README.md`, `docs/*.md` | Updated |

### Decisions
- **Extensions:** exactly the brief's list, `cli fpm mysql xml curl gd mbstring zip bcmath intl
  soap xdebug`, plus `json` for 7.4. Only versioned packages (`php8.4-…`) are installed.
- **PPA:**
  - Detected in both deb822 `.sources` and `.list` files.
  - If missing: check that it publishes `noble`, ask, install the apt prerequisites,
    `add-apt-repository -n`, then refresh.
- **PHP 7.4.33:** the package is `1:7.4.33-31+ubuntu24.04.1+deb.sury.org+1`. The module shows the
  upstream part (7.4.33) and explains that `-31…` is the PPA's own patch revision, not a pristine
  upstream build. It warns if the upstream part ever differs.
- **EOL:** installing 7.4 shows a warning and asks separately.
- **CLI default:** changed only through `set-default`, after confirmation. If installing makes apt
  repoint `/usr/bin/php`, the module sets it back to the previous target.
- **Xdebug:**
  - The toolkit settings use trigger mode, the user's choice.
  - They are written only where no `xdebug.*` settings exist. The development machine's
    `99-xdebug-debug.ini` (from an older script) is detected and kept.
- **Nginx sites:**
  - New sites only; existing names and `server_name`s are refused.
  - `listen 80;` like the existing sites. `127.0.0.1:80` would take localhost requests away from
    them.
  - `nginx -t` runs before every reload, and a failed test removes only the new files.
  - `www-data` must be able to read the document root; no chmod is ever done.
- **Verify** skips the two root-only checks (`nginx -t`, `php-fpm -t`) with a warning when sudo
  can't prompt, instead of hanging.
- **Composer:** the official installer is SHA-384-checked and run as the normal user. Only the
  copy to `/usr/local/bin` uses sudo. Composer works with any installed managed PHP.
- **Menu:** each choice runs the module as a child process, so errors and cancels return to the
  menu with a clear result. "Back to main menu" exits until the main menu exists (Phase 10).
- **Plan renumbered:** Phase 3 now covers the earlier Phases 3–6.

### Tests performed
- `bash -n` on all scripts: passed.
- Test suites, all passing:
  - `test-common.sh`: 58
  - `test-system.sh`: 42
  - `test-web.sh`: **63**
- Read-only runs on the development machine:
  - `install-nginx status` and `verify` (`nginx -t` skipped: no terminal), HTTP 200;
  - `install-php status` shows 7.4 and 8.4 managed, 8.2 and 8.5 unmanaged, CLI default php8.4 manual;
  - `install-composer status` and `verify` (works with 7.4 and 8.4);
  - `nginx-site list`.
- `DRY_RUN=1 install-php install 7.4` lists the 9 missing 7.4 packages with candidates and the 7.4.33 note.
- `DRY_RUN=1 install-php xdebug` plans `php7.4-xdebug` and toolkit settings for 7.4 only. 8.4
  keeps its existing settings.
- The PHP menu was driven through a pseudo-terminal: invalid input, status, back.
- Fixed during testing:
  - `server_name` detection missed names written on the same line as `server {`.
  - The fake `sudo` recorded Composer's own `sudo -K`, so the test now allows it.
- **Not yet done:**
  - `shellcheck`;
  - real installs, `nginx -t`/`php-fpm -t`, site creation and reload, Xdebug and Composer installs
    in a fresh distro.

  These are for the user; see [testing.md](testing.md#5-phase-3-checks).

### Known issues and limitations
- **Development machine:** `install-php.sh verify` reports missing extensions. PHP 8.4 lacks
  `bcmath`; PHP 7.4 lacks xml, curl, gd, mbstring, zip, bcmath, intl, soap and xdebug.
  `install-php.sh install 8.4 7.4` would add them, after confirmation.
- **Development machine:** the existing Xdebug settings (`start_with_request=yes`) still print
  "Could not connect" on CLI commands. The toolkit leaves them alone. Removing or changing
  `/etc/php/8.4/{cli,fpm}/conf.d/99-xdebug-debug.ini` is the user's decision.
- Installing a PHP extension package lets apt's own triggers restart that version's PHP-FPM. That
  is Ubuntu packaging behaviour, not a toolkit action.
- The site tool asks for sudo before the `www-data` permission check, even when the user later
  cancels.
- Composer runs `sudo -K` at startup, so a sudo step after a Composer command asks for the
  password again.

### Remaining work
Phases 4–11 (Node.js/NVM, databases, Redis/PostgreSQL/Mailpit, Docker, `install-all.sh`,
main menu, final verification).

### Next step
Approved (the Phase 4 brief). Phase 4 started.

---

## Phase 4: Node.js and official NVM (2026-11-17)

### Implemented
- NVM from the official `nvm-sh/nvm` only, pinned to v0.41.0:
  - the tag is checked with `git ls-remote` before anything is downloaded;
  - the official `install.sh` at that tag is checked against a pinned SHA-256, then run with
    `PROFILE=/dev/null` and `METHOD=git` into `~/.nvm`.
- A marked, idempotent `~/.bashrc` block, added only when nothing loads `nvm.sh` yet, after
  confirmation and a backup.
- Loading NVM in the module's own Bash process. NVM is a sourced function, so every call goes
  through a strict-mode bridge.
- Node.js: install LTS or a specific version, list installed versions, list available versions,
  switch, set the default.
- NVM update to the pin.
- Verification, here and in a new shell.
- An opt-in `fix-bashrc` for the `[-s` typo.
- The Node.js menu with the brief's 10 items.

**Nothing was installed or changed on the development machine.** Only read-only runs, dry runs,
and tests with a fake HOME. `~/.bashrc` and `~/.nvm` were checked to be unchanged.

### Files
| File | Change |
|---|---|
| `lib/node.sh` | New. Validation (`is_valid_node_version`, `is_valid_nvm_tag`, `is_sha256`, `version_lt`), `nvm_call`/`nvm_load` (strict-mode bridge), `nvm_installed_version`, `nvm_has_local_changes`, `node_installed_versions`, `nvm_default_alias`, `nvm_remote_tag_commit`, `nvm_latest_remote_tag`, `nvm_download_installer`, `nvm_run_installer`, the `.bashrc` helpers (`bashrc_has_nvm_init`, `bashrc_broken_nvm_lines`, `bashrc_backup`, `bashrc_append_nvm_block`, `bashrc_fix_broken_lines`), `new_shell_check` |
| `modules/install-nodejs.sh` | New. `status`, `install`, `install-nvm`, `install-node <ver>`, `list`, `list-remote [lts\|all\|<major>]`, `use <ver>`, `set-default <ver>`, `update`, `verify`, `fix-bashrc`, `menu` |
| `tests/test-node.sh` | New. 108 tests |
| `config/versions.conf` | NVM pin comment (re-verified 2026-11-17); new `NVM_INSTALL_SCRIPT_URL`, `NVM_INSTALL_SCRIPT_SHA256` |
| `README.md`, `docs/*.md` | Updated |
| `CLAUDE.md` | §16: the real check and test commands replace the "no phase implemented yet" note |

### Decisions
- **Install method:** the official `install.sh` at the pinned tag (the user's choice). It is
  downloaded to a temporary file, not piped, and must match `NVM_INSTALL_SCRIPT_SHA256`.
  - Upstream publishes no checksum, so the value was computed from the v0.41.0 tag. Moving the pin
    means updating both values.
  - `XDG_CONFIG_HOME`, `NODE_VERSION`, `NVM_SOURCE`, `NVM_INSTALL_GITHUB_REPO` and
    `NVM_INSTALL_VERSION` are removed from its environment, so it always installs a git checkout
    of the official repository into `~/.nvm` and installs no Node.js.
  - After it runs, the version must equal the pin and `HEAD` must be the tag's commit
    (`4e8758a801ee…`; v0.41.0 is an annotated tag).
- **No sudo, no preflight.** The module runs `check_not_root`, `check_os` and `check_wsl2` and
  needs git, curl and sha256sum. It never calls sudo; the tests record any use.
- **`.bashrc`:**
  - The toolkit block is added only when no active line loads `nvm.sh`. NVM's own installer lines
    count as set up, so a rerun or an existing setup never gets a second block.
  - Every change is preceded by a backup and must still pass `bash -n`.
- **Switching:** `use` checks the version and prints `nvm use <ver>` (the user's choice). A child
  process can't change its parent shell.
- **Defaults:** `set-default` asks first. Installing a version never changes an existing default.
  When none exists, nvm's own "first version becomes the default" is announced in the plan.
- **Update:**
  - It only moves up to the pin, never past it and never down.
  - It refuses when `~/.nvm` is not a git checkout or has local changes, because the installer
    uses `git checkout -f`.
  - The newest upstream tag is shown for information only.
- **Development machine:**
  - NVM 0.39.1 is left as it is. `install` reports it; `update` would upgrade it after confirmation.
  - The `.bashrc` typo is reported and fixable with `fix-bashrc`. Neither was run here.
- **Node versions:** free-form, validated input, checked at nodejs.org (`nvm version-remote`) before
  installing (the user's choice).

### Tests performed
- `bash -n` on all scripts and configs: passed.
- Test suites, all passing:
  - `test-common.sh`: 58
  - `test-system.sh`: 42
  - `test-web.sh`: 63
  - `test-node.sh`: **108**
- Network checks (this machine, 2026-11-17):
  - v0.41.0 is the newest NVM tag;
  - `install.sh` at v0.41.0 matches the pinned SHA-256;
  - `v9.9.9` does not exist.
- Read-only runs on the development machine:
  - `status` → 0 (v0.39.1, update available, line 121 broken, 6 versions, default 18);
  - `verify` → 0 (nvm 0.39.1, node v18.20.8, npm 10.9.10, also in a new shell);
  - `list`, `list-remote 26` → 0;
  - `use 22` → 0, and `use 99` / `use 'x;y'` → 3;
  - `set-default 18` → 2, and `set-default 22` → 4 (no terminal);
  - `install-nvm` → 2, `install-node 22.20.0` → 2, `install-node 99` → 3;
  - `fix-bashrc` → 4 (no terminal).
- Dry runs:
  - `update`: the tag check and the plan;
  - `fix-bashrc`: line 121 before/after;
  - `install`: plans Node v26.13.1 (newest LTS); the default stays 18.
- The Node menu was driven through a pseudo-terminal: invalid choices, an invalid version re-asked,
  empty input goes back, `use 22`, `list`, 10 exits.
- Fixed during testing: `nvm ls`/`ls-remote` printed colour codes into pipes; `--no-colors` is now
  passed when output is not a terminal.
- **Not yet done:**
  - `shellcheck` (not installed);
  - a real NVM and Node install, the `.bashrc` block, update and set-default in a fresh distro.

  These are for the user; see [testing.md](testing.md#6-phase-4-checks).

### Known issues and limitations
- `use` cannot switch the calling shell; it prints the `nvm use` command instead.
- `update` never goes past the pinned version. To move the pin, edit `NVM_VERSION` and
  `NVM_INSTALL_SCRIPT_SHA256` together.
- The pinned SHA-256 protects against a changed `install.sh`. The code the installer then fetches
  with git is checked by comparing `HEAD` with the tag's commit from `ls-remote`, not by a
  signature: NVM's tags are not signed.
- The new-shell check runs `bash -i`. zsh and fish are out of scope.
- `.bashrc` is the only profile file handled. If `~/.bash_profile` exists without loading
  `.bashrc`, `status` warns that login shells will not have nvm.
- `nvm.sh` activates the default version whenever it loads, so `status` shows the default's path,
  not the version active in your own terminal.
- **Development machine:** NVM 0.39.1 (pin: 0.41.0), the `[-s` typo on `.bashrc` line 121, and
  default Node 18 (end-of-life) are unchanged. `update`, `fix-bashrc` and `set-default` would change
  them, each after confirmation.

### Remaining work
Phases 5–11 (databases, Redis/PostgreSQL/Mailpit, Docker, `install-all.sh`, main menu,
final verification).

### Next step
Approved (the Phase 5 brief). Phase 5 started.

---

## Phase 5: MariaDB and MySQL (2026-11-17)

### Investigation (read-only)
| Item | MariaDB 10.11.14 | MySQL 8.0.46 |
|---|---|---|
| Unit | `mariadb` (+ aliases `mysql`, `mysqld`) | `mysql` |
| Ports | 3306 | 3306, 33060 |
| Socket | `/run/mysqld/mysqld.sock` | the same |
| Config | `/etc/mysql/mariadb.cnf`, `mariadb.conf.d/` | `/etc/mysql/mysql.cnf`, `mysql.conf.d/` |
| Data | `/var/lib/mysql` | the same |
| Root login | unix_socket | auth_socket |

- **Conflicts:** server, server-core and client-core packages conflict in both directions, through
  `virtual-mysql-server`, `virtual-mysql-server-core` and `virtual-mysql-client-core`.
- On the development machine, `apt-get -s install mysql-server` would remove all nine MariaDB
  packages.
- Ubuntu 24.04 has only MySQL 8.0. Oracle ended upstream support for it in April 2026.
- **Conclusion:** running both natively side by side is unsafe. Chosen: mutually exclusive
  modules, with documented alternatives (a container on 127.0.0.1:3307 after Phase 8, a separate
  WSL distro, or a manual switch).

### Implemented
- `install-mariadb.sh` and `install-mysql.sh`, each with `status`, `install`, `verify` and `guide`.
  Each runs on its own; the shared logic is in `lib/database.sh`.
- **Install refuses (exit 3, nothing changed, no sudo prompt) when:**
  - the other flavour's packages are installed;
  - `/var/lib/mysql` holds data, or can't be inspected, with no server package installed;
  - port 3306 or 33060 is already in use.
- **MySQL:** an end-of-life warning with its own confirmation.
- **Verify:** the service (active, starts at boot), the socket, listeners (with a warning if one is
  not on loopback), ping over the socket and over TCP. In a terminal, also `SELECT VERSION()` and a
  read-only security report.
- **Guide:**
  - keep root on socket login, with no root password;
  - one database and user per project;
  - `localhost` vs `127.0.0.1`, and keeping the bind address;
  - service, backup and restore commands;
  - the manual switching steps.

**Nothing was installed or changed on the development machine.** No database was written to; the
SQL tests ran against a temporary server in tmpfs.

### Files
| File | Change |
|---|---|
| `lib/database.sh` | New. `db_meta`, `db_installed_packages`, `db_installed_flavour`, `db_datadir_state`, `is_loopback_listener`, `db_listeners`, `db_status`, `db_verify`, `db_security_report`, `db_install`, `db_guide`, `db_main` |
| `modules/install-mariadb.sh` | New |
| `modules/install-mysql.sh` | New, with the end-of-life confirmation `db_extra_confirm` |
| `tests/test-db.sh` | New. 64 tests |
| `lib/system.sh` | `port_listeners`, moved here from `modules/install-nginx.sh` |
| `modules/install-nginx.sh` | Uses the shared `port_listeners` (no behaviour change) |
| `config/packages.conf` | Comment only |
| `README.md`, `docs/*.md` | Updated |

### Decisions
- **Mutually exclusive** (as in Phase 0, confirmed by the user).
- **Detection by dpkg package names only.** On a MariaDB system, `/usr/bin/mysql`, `mysqladmin`
  and `mysql.service` exist as MariaDB's compatibility names.
- A MariaDB client alone also blocks MySQL, because the client packages conflict too.
- `mysql-common`, `mariadb-common` and `galera-4` don't count.
- **MySQL from Ubuntu's archive** (8.0), with an end-of-life warning (the user's choice). Oracle's
  8.4 repository was not added.
- **No changes to authentication.** Root keeps socket login. The toolkit writes no configuration
  and sets no password. There is no user-creation action; the guide shows the SQL instead (the
  user's choice).
- **Connectivity without credentials:** `mysqladmin ping` exits 0 whenever the server answers,
  even with "Access denied". The SQL check uses `sudo <client>` and runs only when sudo can be used.
- **The security report never prints `SHOW CREATE USER` output**, because it contains password hashes.

### Tests performed
- `bash -n` on all scripts and configs: passed.
- Test suites, all passing:
  - `test-common.sh`: 58
  - `test-system.sh`: 42
  - `test-web.sh`: 63, after the `port_listeners` move
  - `test-node.sh`: 108
  - `test-db.sh`: **64**
- Real SQL for the security report: a temporary MariaDB 10.11.14 server run as the user. It
  detected anonymous accounts, the `test` database and an added `root@%`, and reported
  root@localhost as socket login. A cleaned-up instance gave no warnings.
- Development machine, read-only:
  - `install-mariadb.sh`: `status` → 0, `verify` → 0 (SQL part skipped: no terminal), `install` → 2;
  - `install-mysql.sh`: `status` → 0, `install` → 3 (MariaDB installed; alternatives listed; no
    sudo), `verify` → 1;
  - `guide` for both.
- Fixed during testing:
  - The guide named `mariadb_secure_installation`; MariaDB's tool is `mariadb-secure-installation`.
  - The temporary-server test took 1m40s, because every bootstrap fsync on WSL's virtual disk is
    slow. Its data now goes on `/dev/shm`, and the suite takes about 3 s.
- **Not yet done:**
  - `shellcheck` (not installed);
  - the SQL check and security report through `sudo` on the development machine (it needs your
    password: run `modules/install-mariadb.sh verify` in a terminal);
  - real installs in fresh distros;
  - the MySQL security report against a real MySQL 8.0.

  See [testing.md](testing.md#7-phase-5-checks).

### Known issues and limitations
- No simultaneous native install of MariaDB and MySQL. The alternatives are documented, not
  implemented. A container helper could come with Docker in Phase 8, if approved.
- MySQL 8.0 is end-of-life upstream; it is the only MySQL in Ubuntu 24.04's archive.
- The SQL check and security report need sudo and are skipped without a terminal.
- Leftover configuration files (`rc` packages) only produce a warning. Leftover data blocks the
  install, and the user decides what to do with it.
- `guide`'s `127.0.0.1` note: whether a TCP login matches a `'user'@'localhost'` account depends
  on the server's name resolution. The guide explains how to add a `'user'@'127.0.0.1'` account if
  the login is refused.

### Remaining work
Phases 6–11 (Redis/PostgreSQL/Mailpit, Docker, `install-all.sh`, main menu, final
verification).

### Next step
Approved (the Phase 6 brief). Phase 6 started.

---

## Phase 6: Optional tools (2026-11-17)

### Implemented
Four independent modules.

| Module | Source | Local-only by | Actions |
|---|---|---|---|
| `install-redis.sh` | Ubuntu `redis-server` 7.0 | Ubuntu's defaults (`bind 127.0.0.1 -::1`, protected mode), not edited | `status`, `install`, `verify` |
| `install-postgresql.sh` | Ubuntu `postgresql` 16 + contrib | Ubuntu's defaults (`listen_addresses` localhost, peer auth), not edited | `status`, `install`, `verify`, `guide` |
| `install-mailpit.sh` | Pinned GitHub release v1.33.1, SHA-256 checked | Toolkit unit: `--smtp 127.0.0.1:1025 --listen 127.0.0.1:8025` | `status`, `install`, `verify`, `test`, `php-mail`, `guide` |
| `install-docker.sh` | Docker's apt repository, key fingerprint checked | New `daemon.json` with `"ip": "127.0.0.1"`, only when none exists | `status`, `install`, `verify`, `test-run` |

Each install checks first and refuses with exit 3, changing nothing, when:
- **All:** the port is already in use.
- **PostgreSQL:** another server version is installed, or data/config remain from an earlier
  install.
- **Mailpit:** another `/usr/local/bin/mailpit` or a foreign `mailpit.service` exists.
- **Docker:** Docker Desktop's WSL integration is active, or another engine or conflicting packages
  (`docker.io`, `containerd`, `runc`, `podman-docker`, a snap) are installed. Docker also explains
  its whole approach before asking.

**Nothing was installed or changed on the development machine.** No Mailpit binary was executed
here.

### Files
| File | Change |
|---|---|
| `modules/install-redis.sh`, `install-postgresql.sh`, `install-mailpit.sh`, `install-docker.sh` | New |
| `lib/docker.sh` | New. `docker_desktop_integration`, `docker_conflicting_packages`, `key_fingerprint` (throwaway GnuPG home), `docker_sources_text`, `docker_daemon_json_text`, `docker_daemon_ip`, group checks |
| `templates/mailpit.service.tpl` | New. `DynamicUser`, `StateDirectory`, `ProtectSystem=strict`, localhost addresses |
| `tests/test-optional.sh` | New. 82 tests |
| `lib/common.sh` | `sha256_of` (moved from `lib/node.sh`), new `download_checked` |
| `lib/system.sh` | `port_listen_addresses`, `is_loopback_listener` (moved from `lib/database.sh`), new `report_port_listeners` |
| `lib/services.sh` | New `service_restart`, `service_daemon_reload` |
| `lib/node.sh`, `lib/database.sh` | Use the shared helpers (no behaviour change) |
| `config/versions.conf` | `MAILPIT_VERSION`, `MAILPIT_DOWNLOAD_URL`, `MAILPIT_SHA256`, `MAILPIT_SMTP_ADDRESS`, `MAILPIT_UI_ADDRESS`, `DOCKER_APT_URL`, `DOCKER_GPG_FINGERPRINT`, `DOCKER_DEFAULT_BIND_IP` |
| `config/packages.conf` | Comments |
| `README.md`, `docs/*.md` | Updated |

### Decisions
- **Docker from Docker's repository** (the user's choice, as in Phase 0):
  - the fingerprint is checked before the key is installed;
  - an existing keyring with different content, or a foreign `docker.sources`, stops the install;
  - published ports default to 127.0.0.1 through a new `daemon.json`, and an existing one is never
    changed (the user's choice);
  - joining the docker group is a separate question, with the root-equivalence warning.
- **Mailpit:**
  - v1.33.1 rather than v1.34.0, which was published on the day of implementation;
  - SHA-256 `84d7fe37…1716`, equal to GitHub's published digest and to a real download;
  - amd64 only;
  - the unit runs as a `DynamicUser` with `--disable-version-check`, so it makes no calls to GitHub;
  - PHP `mail()` routing is the separate opt-in `php-mail` (the user's choice), only where no
    `sendmail_path` is set yet.
- **PostgreSQL:** Ubuntu's 16 only, with no PGDG repository. The security report in verify is
  read-only (`listen_addresses`, `pg_hba_file_rules`).
- **Phases renumbered:** the old Phases 7 and 8 are merged into this phase or dropped. The
  remaining phases are provisionally 7 (`install-all.sh`), 8 (`install-menu.sh`) and 9 (final).

### Tests performed
- `bash -n` on all scripts and configs: passed.
- Test suites, all passing:
  - `test-common.sh`: 58
  - `test-system.sh`: 42
  - `test-web.sh`: 63
  - `test-node.sh`: 108
  - `test-db.sh`: 64
  - `test-optional.sh`: **82**, including the live check of Docker's key fingerprint
- Network checks (2026-11-17):
  - the Mailpit v1.33.1 tarball's SHA-256 equals GitHub's digest; it contains `LICENSE`,
    `README.md` and `mailpit`;
  - Docker's key has fingerprint `9DC8…CD88`;
  - Docker's repository publishes `noble`.
- Development machine, read-only, for all four modules:
  - `status` → 0, `verify` → 1, `install` → 4 (no terminal), `DRY_RUN=1 install` → 0;
  - `test`, `php-mail` and `test-run` → 3; `guide` → 0.
  - Afterwards no `mailpit.service`, Docker keyring, `/etc/docker` or `/usr/local/bin/mailpit` exist.
- Mailpit flags and API fields were checked against its documentation and the v1.33.1 Swagger file:
  - flags `--smtp`, `--listen`, `--database`, `--disable-version-check`, `sendmail -S`;
  - `/api/v1/info` returns `Version` and `Messages`.
- **Not done:**
  - `shellcheck` (not installed);
  - any real install, the Mailpit binary itself (`mailpit version`, `sendmail`), the PostgreSQL SQL
    report, Docker `test-run` and the docker group. They need a fresh distro and the user's
    password.

  See [testing.md](testing.md#8-phase-6-checks).

### Known issues and limitations
- **Mailpit:**
  - amd64 only;
  - an existing `/usr/local/bin/mailpit` is never replaced;
  - updating means changing `MAILPIT_VERSION` and `MAILPIT_SHA256`;
  - its version is read from `mailpit version` output with a `vX.Y.Z` pattern, which is not
    verified on a real binary yet.
- **Docker:**
  - refuses next to Docker Desktop integration or another engine (switching is manual);
  - an existing `daemon.json` is never changed, so its published-port default stays as it is;
  - the group applies in new shells only;
  - Docker manages its own iptables/nftables rules.
- **PostgreSQL:** 16 from Ubuntu only. The `pgsql` PHP extension is not installed by the toolkit
  (the guide shows how).
- The SQL checks (PostgreSQL) and the Docker server check need sudo; without a terminal they are
  skipped with a warning.

### Remaining work
Provisional Phases 7–9: `install-all.sh`, `install-menu.sh`, final verification.

### Next step
Approved (the Phase 7 brief). Phase 7 started.

---

## Phase 7: Installation orchestration (2026-11-19)

### Implemented
- **`scripts/install-all.sh`** runs these steps in order:
  1. project information;
  2. environment checks;
  3. the numbered list of the 11 modules;
  4. the selection (numbers, names or `core`; nothing preselected; then a PHP-version question);
  5. the plan and one confirmation;
  6. `sudo -v` once;
  7. the modules in dependency order with `[n/N]` progress;
  8. the summary table;
  9. a verification pass with a PASS/FAIL table;
  10. the next steps.

  `--modules`, `--php` and `--dry-run` support repeat runs.
- **`scripts/install-menu.sh`** has the brief's 13 entries:
  - PHP and Node.js open the existing module menus;
  - every other tool has a submenu: status, install, verify, its extra actions, and back;
  - "Installation status" shows every module's status, or the verify table.
- **Ctrl+C:**
  - at a prompt it exits with 130 and changes nothing;
  - during a module it stops that module. install-all then prints the partial summary; the menu
    returns to its main screen.
  - After an interrupted install, the `dpkg --configure -a` hint is shown.
- **No module was changed.** All installation logic stays in `modules/`.

**Nothing was installed or changed on the development machine.** The checks were dry runs,
read-only status and verify runs, and stub modules.

### Files
| File | Change |
|---|---|
| `lib/orchestrator.sh` | New (234 lines). The registry (`MODULE_ORDER`, `MODULE_LABEL`, `MODULE_KIND`, `MODULE_DEPS`, `SYSTEMD_MODULES`, `NO_SUDO_MODULES`, `CORE_SELECTION`, `EXCLUSIVE_PAIRS`), `module_script` (`WSL_DEVTOOLS_MODULES_DIR` override for tests), `sort_modules`, `exclusive_conflicts`, `run_module`, `result_text`, `format_duration`, the two Ctrl+C trap modes, `explain_interrupted_install`, `status_all`, `verify_modules` |
| `scripts/install-all.sh` | New (482 lines) |
| `scripts/install-menu.sh` | New (226 lines) |
| `tests/test-orchestrator.sh` | New. 89 tests (110 after the review) |
| `README.md`, `docs/architecture.md` (new §15, §2 tree, §6 dependency rule, status line), `docs/implementation-plan.md`, `docs/testing.md` (new §9), `docs/progress.md` | Updated |

### Execution flow and dependencies
Order: base → nginx → php → composer → nodejs → mariadb | mysql → redis → postgresql → mailpit →
docker.
- Everything depends on base, and composer depends on php.
- A selected dependency that ended with anything other than 0 or 2 makes its dependents "not run:
  needs <dep>". The independent modules still run.
- An unselected dependency is not added; the module's own check decides.

See [architecture.md §15](architecture.md#15-orchestration-install-allsh-and-install-menush).

### Decisions
- **The registry is code, not config.** The order and dependencies are design facts, so
  `config/modules.conf`, planned in Phase 0, was not created.
- **Nothing is preselected,** not even the database. `core` excludes the database, because
  MariaDB and MySQL are mutually exclusive. Optional tools are installed only when chosen.
- **No auto-yes.** One overall confirmation, and each module keeps its own questions (the EOL
  warning, the apt plan, the docker group).
- **Without systemd:** the service modules are shown as unavailable and cannot be selected. base,
  composer and nodejs can still run.
- **The verification pass** runs after all installs, for modules that ended 0 or 2. Their output goes
  to the log, so the screen shows a compact table.
- **Output is not piped through `tee`,** because that would break the modules' terminal checks
  and prompts. The modules write their own messages to the shared log through the exported
  `LOG_FILE`.
- **`--modules` / `--php` are validated before the log file is created,** so a typo leaves no
  log behind.
- **Ctrl+C:** bash restarts `read` after a trap handler, which a test showed. So there are two
  modes: exit at prompts, and a flag while a module runs.

### Tests performed
- `bash -n` on all scripts and configs: passed.
- Test suites, all passing:
  - `test-common.sh`: 58
  - `test-system.sh`: 42
  - `test-web.sh`: 63
  - `test-node.sh`: 108
  - `test-db.sh`: 64
  - `test-optional.sh`: 82
  - `test-orchestrator.sh`: **89**
- Ctrl+C through a pseudo-terminal (Python `pty`) with stub modules:
  - during php's install → php "interrupted", composer and nodejs "not run: interrupted", the
    dpkg hint, exit 130;
  - at the selection prompt, at the confirmation, and inside an environment check → "Interrupted.
    Nothing was changed.", exit 130;
  - in the menu, during the PHP menu → "Back to the menu", then at the main prompt → exit 130.
  - In one early run the selection-prompt case printed its message but the process had not
    exited within 3 s. Eight later runs at several timings exited at once. It could not be
    reproduced; see the known issues.
- Development machine, read-only:
  - `DRY_RUN=1 install-all.sh --modules base,nginx,php,composer,nodejs,mariadb,redis` → 0:
    - base, nginx, composer and mariadb "already installed";
    - php, nodejs and redis "planned (dry run)";
  - argument errors → 3, and no terminal → 4;
  - the menu's verify table: base, nginx, composer, nodejs and mariadb PASS. php FAILs (the
    known missing 7.4/8.4 extensions from Phase 3), and mysql, redis, postgresql, mailpit and
    docker FAIL because they are not installed;
  - Redis status from the menu.
- Fixed during testing:
  - an apostrophe inside `${LOG_FILE:-…}` broke the menu's syntax;
  - Ctrl+C at a prompt was ignored (`read` restarted), which led to the two-mode trap;
  - the verify table showed absolute paths.
- **Not yet done:**
  - `shellcheck` (not installed);
  - real installs through `install-all.sh` and the menu in a fresh distro.

  See [testing.md §9](testing.md#9-phase-7-checks).

### Known issues and limitations
- **The log file** has the toolkit's messages and the verification output, but not apt's or the
  installers' own output (that stays on the terminal).
- **sudo:** a long run can ask for the password again, after sudo's timeout or Composer's
  `sudo -K`.
- **Dry run:** modules return 0 after their plan, so a dependent may report exit 3 for a dependency
  that is only planned.
- **Menu:** it starts a new log file each time it is opened.
- ~~Possible Ctrl+C timing issue~~: resolved in the review below. It was a race in the test
  driver, not in the scripts.
- **On this machine,** selecting mysql exits 3 by design (MariaDB is installed).

### Review (2026-11-19)

The review covered syntax, error handling, existing-installation detection, idempotency,
security and safety, and readability for `lib/orchestrator.sh`, both scripts and the test suite.
No module was changed.

**Checked and fine:**
- `bash -n` passes on every file.
- Strict mode and the ERR trap are in place. Module exit codes are captured, so a failing module
  is a result, not a crash. Unexpected codes show as "failed (exit N)".
- Detection of existing installations stays in the modules. Exit 2 counts as success, so
  dependents still run, and MariaDB and MySQL are refused together at selection and by the module.
- The selection is de-duplicated, each module runs once, and a rerun only reports "already
  installed".
- No `eval`; arguments are passed in arrays and variables are quoted. The orchestrators delete
  nothing, edit no configuration, use sudo only for `sudo -v`, and have no auto-yes.
- `LOG_FILE=""` before a function call is cleared for the child and restored afterwards. This was
  checked.

**Findings and fixes:**

| # | Severity | Finding | Fix |
|---|---|---|---|
| 1 | Medium | A huge number in the `install-all` selection wrapped around in bash arithmetic: `18446744073709551619` selected php | At most 3 digits, as the menu already required |
| 2 | Medium | `DRY_RUN=yes` or `DRY_RUN=true` meant a **real** install, because only `1` means dry run | Both scripts refuse any value other than unset, `0` or `1` (exit 3). New `check_orchestrator_env` |
| 3 | Low | `install-all` created a log file before refusing root | `require_not_root` now runs before the log is started |
| 4 | Low | An unwritable `logs/` gave raw bash errors | `start_orchestrator_log`: one clear message, exit 1 (both scripts) |
| 5 | Low | An invalid `--php` without `--modules` was noticed only after the selection prompts | Validated right after argument parsing |
| 6 | Low | `WSL_DEVTOOLS_MODULES_DIR` silently changed which scripts run | A warning naming the directory |
| 7 | Low | Readability: a `local` inside a loop; a meaningless "Result: done" after leaving the PHP or Node.js menu | Tidied up; no result line for `menu` |
| 8 | Test gap | Ctrl+C was checked only by hand | 12 automated tests with timed input in a pseudo-terminal (the other 9 new tests cover findings 1–7) |
| 9 | Docs | The "possible Ctrl+C timing issue" | It was the test driver: it stopped reading on the pty's EIO and checked `waitpid(WNOHANG)` before the child was reaped. With a driver that waits up to 5 s, 20 of 20 runs at delays from 0.3 to 3 s exited 130 at once. Known issue removed |

**Accepted as designed** (no change):
- a rerun still asks the overall confirmation and `sudo -v`. The modules' own verify needs sudo
  for `nginx -t` anyway;
- verify runs inside each install and again in the final pass;
- the log does not hold apt's own output;
- a long run can ask for the sudo password again.

**Files changed:** `lib/orchestrator.sh` (`check_orchestrator_env`, `start_orchestrator_log`,
the `verify_modules` tidy-up), `scripts/install-all.sh`, `scripts/install-menu.sh`,
`tests/test-orchestrator.sh` (89 → 110 tests; stubs can now sleep), `docs/architecture.md` §15,
`docs/testing.md`, this file.

**Tests:**
- `bash -n`: passed.
- All suites pass: 58, 42, 63, 108, 64, 82 and **110**. The orchestrator suite was run three
  times with no flaky result.
- Read-only on the development machine:
  - `DRY_RUN=yes` → 3;
  - `--modules 18446744073709551619` → 3;
  - an unwritable `LOG_DIR` → 1 with the message;
  - `DRY_RUN=1 --modules core,mariadb` → 0;
  - the menu's verify table is unchanged.
- The log files from these runs were removed.

**Remaining issues** (not fixed in this phase):
- **The modules** also treat any `DRY_RUN` other than `1` as a real run, for example
  `DRY_RUN=yes modules/install-redis.sh install`. Fixing that changes `lib/common.sh` and the
  modules' behaviour, so it needs your approval. Proposal: refuse invalid values once in
  `load_project_config`, which every module calls.
- `shellcheck` has not been run (not installed; `sudo apt install shellcheck`).
- No real install through `install-all.sh` or the menu yet; that needs the fresh distro
  ([testing.md §9](testing.md#9-phase-7-checks)).

### Remaining work
Phase 8 (provisional): the end-to-end run on a fresh 24.04 distro, and the final documentation.

### Next step
Approved (the Phase 8 brief). Phase 8 started.

---

## Phase 8: Testing and quality assurance (2026-11-19)

### Implemented
- A QA pass over the 18 areas of the Phase 8 brief. The QA matrix in
  [testing.md §10](testing.md#10-phase-8-quality-assurance) gives the method and result per
  area.
- **No destructive test ran on the development machine.** Failure scenarios use mocks: a fake
  `sudo` that records every call and runs nothing, a fake `systemctl`, and a `PATH` without
  chosen tools. Live checks are read-only and are bracketed by a before/after system snapshot,
  which was identical.
- Two low-risk fixes, with tests (below).
- Removed all references to phpMyAdmin (the user's request): `CLAUDE.md` §4,
  `config/packages.conf`, `README.md` and `docs/*`.

### Files
| File | Change |
|---|---|
| `tests/test-qa.sh` | New. 78 tests: systemd unavailable, missing dependencies, failed apt steps, the removal guard, invalid `DRY_RUN` in all 15 entry scripts |
| `tests/test-live.sh` | New. 98 tests + 1 skip: the system snapshot, two rounds of every module, live service/PHP/Composer/Nginx-FPM/Node/database checks |
| `tests/test-common.sh` | 6 new tests (58 → 64): `DRY_RUN` validation |
| `lib/common.sh` | Fix A: `is_valid_dry_run`; `load_project_config` refuses an invalid `DRY_RUN` (exit 3 in every module and script) |
| `lib/orchestrator.sh` | Uses `is_valid_dry_run` |
| `lib/packages.sh` | Fix B1: `apt_install` names the failed packages when `apt-get install` fails |
| `.shellcheckrc` | New. `source-path=SCRIPTDIR`, `external-sources=true`, `disable=SC2119` (with the reason) |
| `config/*.conf`, `lib/docker.sh`, `lib/orchestrator.sh`, `lib/system.sh`, `lib/database.sh`, `lib/node.sh`, `modules/install-nodejs.sh` | ShellCheck directives with reasons only; no behaviour change |
| `tests/*.sh` | ShellCheck cleanups (see the ShellCheck review below); the test counts are unchanged |
| `CLAUDE.md`, `config/packages.conf`, `README.md`, `docs/architecture.md`, `docs/implementation-plan.md`, `docs/progress.md`, `docs/testing.md` | Updated |

### Testing results
- **`bash -n`:** passed on every script and config file.
- **ShellCheck 0.9.0:** clean. `shellcheck -x lib/*.sh modules/*.sh scripts/*.sh tests/*.sh` and
  `shellcheck config/*.conf` print nothing and exit 0. See the ShellCheck review below.
- **Suites:** all pass, 709 tests:

  | Suite | Passed | Skipped |
  |---|---|---|
  | `test-common.sh` | 64 | 0 |
  | `test-system.sh` | 42 | 0 |
  | `test-web.sh` | 63 | 0 |
  | `test-node.sh` | 108 | 0 |
  | `test-db.sh` | 64 | 0 |
  | `test-optional.sh` | 82 | 0 |
  | `test-orchestrator.sh` | 110 | 0 |
  | `test-qa.sh` | 78 | 0 |
  | `test-live.sh` | 98 | 1 (`nginx -t`/`php-fpm -t`: need your password) |

- **Live results, development machine (read-only):**

  | Module | status | verify | install (no terminal) |
  |---|---|---|---|
  | base, nginx, composer, mariadb | 0 | 0 | 2 already installed |
  | php | 0 | 1 (8.4 lacks bcmath; 7.4 lacks several extensions, known since Phase 3) | 4 (would add the missing extensions; needs confirmation) |
  | nodejs | 0 | 0 | 4 (newest LTS not installed; needs confirmation) |
  | mysql | 0 | 1 (not installed) | 3 (MariaDB is installed) |
  | redis, postgresql, mailpit, docker | 0 | 1 (not installed) | 4 (needs confirmation) |

  - Services: `systemctl is-active nginx php7.4-fpm php8.4-fpm mariadb` → all active.
  - `php -v` → 8.4.25 (the CLI default), `php7.4 -v` → 7.4.33.
  - `composer --version` → 2.8.12.
  - New shell: `nvm --version` → 0.39.1, `node --version` → v18.20.8, `npm --version` → 10.9.10.
  - Every `fastcgi_pass` socket in the enabled sites exists, and Nginx answers on localhost.
  - MariaDB ping works; port 3306 is on loopback only.
  - **The snapshot before and after all runs is identical.**
- **Not run here:** `sudo nginx -t` and `sudo php-fpmX.Y -t` (they need your password), and every
  real install (they need the disposable distro). Both are in the testing.md §10 checklist.

### ShellCheck review
The first run gave 218 findings in the scripts (24 warnings, 194 notes) and 37 in the config files.
**None was a bug in the toolkit code** (`lib/`, `modules/`, `scripts/`); the real cleanups were in
the tests.

| Finding | Count | Verdict | Action |
|---|---|---|---|
| SC1091 sourced file not followed | 111 | Tooling: `source=` paths were resolved from the working directory | `.shellcheckrc`: `source-path=SCRIPTDIR`, `external-sources=true`, so the libraries are really checked through their callers |
| SC2034 unused variable | 37 + 6 | False positive: the config files are data, and the library variables are used by the scripts that source them | A file-level directive in both configs (a comment, so `load_config` still accepts them); per-declaration directives in `lib/docker.sh`, `lib/orchestrator.sh`, `lib/system.sh` |
| SC2119 / SC2120 | 48 / 4 | Intended: optional fixture-path arguments for tests | SC2119 disabled in `.shellcheckrc`; SC2120 on the 4 definitions |
| SC2153, SC2016, SC2317 | 2, 14, 5 | Intended: `NVM_VERSION` from config, literal `.bashrc` and stub text, stubs called indirectly | Directives with reasons; the `DRY_RUN` unit tests were rewritten in-process instead |
| SC2088 | 2 | A `~` in test labels | Labels reworded |
| SC2015 `A && pass \|\| fail` | 45 | **Real**, in the tests: if `pass` failed, `fail` would run too | Rewritten as `assert_ok` / `assert_fail`, or `if` blocks |
| SC2010 `ls \| grep`, SC2155, SC2046, SC2181 | 1, 1, 2, 1 | **Real**, in the tests: fragile or masking patterns | A glob loop, separate declaration, an array, `if ( … )` |

All 9 suites passed afterwards with unchanged counts, and `test-live.sh` again found the system
unchanged.

### Failed tests
None in the final runs. During development:
- the "answer n" QA test did not check the exit code (fixed in the test);
- a manual look at the failed-install output found finding B1.

### Issues and fixes
| # | Severity | Issue | Status |
|---|---|---|---|
| A | Medium | Modules treated `DRY_RUN=yes` or `DRY_RUN=true` as a **real** run (known since the Phase 7 review) | **Fixed:** `load_project_config` refuses values other than unset, `0` or `1` (exit 3); tested for all 15 entry scripts |
| B1 | Low | When `apt-get install` itself failed, the module exited 1 with no toolkit message | **Fixed:** "apt-get install failed for: <packages>. See apt's messages above. Running the install again is safe." |
| R1 | Low | The removal guard runs after `apt-get update`, so a refused install has still refreshed the package lists | **Reported.** Harmless (a list refresh only) but avoidable. Recommended: simulate (`apt-get -s`) once before the refresh as well. Changes the shared install sequence, so it needs your approval |
| R2 | Info | Composer runs `sudo -K` and ends a cached sudo session (documented since Phase 3); `test-live.sh` therefore does too | Accepted |
| R3 | Info | The development machine's `.bashrc` prints a banner and the `[-s` error in every new shell; the NVM new-shell check still passes | Your files; `fix-bashrc` exists |

### Security and safety review
- **Privileges:**
  - every script refuses root;
  - sudo is used per command, and only after a confirmation;
  - NVM and npm never use sudo (tested with a recording fake `sudo`);
  - sudo is never asked for in read-only actions without a terminal.
- **No unattended changes:** `confirm` answers no without a terminal. Every install stopped at 2,
  3 or 4 in two unattended rounds, and the snapshot proved that nothing changed.
- **Package safety:**
  - versioned PHP packages only;
  - the removal guard refuses any install that would remove a package (tested with
    `mysql-server` next to MariaDB: 9 packages would have gone);
  - no `apt upgrade`;
  - `NEEDRESTART_MODE=l`, so services are not restarted automatically.
- **Downloads:**
  - NVM `install.sh`: SHA-256 pinned, and the tag commit checked;
  - Composer: SHA-384 checked against the published signature;
  - Mailpit: SHA-256 pinned;
  - Docker: the key fingerprint is checked before the key is installed;
  - nothing is piped into a shell.
- **Configuration:**
  - only new, marked drop-in files; existing configs, `daemon.json` and `sendmail_path` are never
    overwritten;
  - `nginx -t` passes before every reload;
  - `/etc/wsl.conf`, Windows settings and the firewall are never touched (the no-systemd tests
    only explain how to enable it).
- **Network exposure:** new services bind to 127.0.0.1, Docker's published ports default to
  127.0.0.1, and Nginx sites use `listen 80` like the existing ones (documented).
- **Input:**
  - config files are data only (`load_config`);
  - domains, paths, versions, menu choices and module selections are validated;
  - numbers are length-limited before arithmetic;
  - `DRY_RUN` is validated.
- **Test hooks:** `WSL_DEVTOOLS_CONFIG_DIR`, `WSL_DEVTOOLS_MODULES_DIR` and `LOG_DIR` can point
  the toolkit elsewhere. The orchestrators warn about the modules override. Someone who controls
  your environment can already run code as you, so this adds no new risk.

### Remaining limitations
- Real installs, `nginx -t`, the PHP CLI switch, sites on 7.4 and 8.4, NVM `set-default`, the
  optional tools, a network failure, Ctrl+C during apt, and a distro without systemd: all are in
  the user checklist in [testing.md §10](testing.md#10-phase-8-quality-assurance).
- Earlier limitations still apply:
  - Mailpit is amd64 only;
  - only MySQL 8.0 (EOL) is available in Ubuntu 24.04;
  - the log file does not hold apt's own output;
  - a long run can ask for the sudo password again.
- R1 above, if you want it changed.

### Next step
Approved (2026-11-20), with R1 left as a documented limitation. Phase 9 started.

---


## Phase 9: Final documentation and project review (2026-11-20)

Phase 9 was done in two steps on the same day:
1. a first documentation pass, following the provisional plan;
2. the user's Phase 9 brief, which defines the phase and takes precedence. It covers 16 tasks and
   adds the code review and the final report.

**No code, config, template or test file changed in Phase 9.**

### Implemented
| Brief task | Where | What |
|---|---|---|
| 1 README | `README.md` | Rewritten as the user guide; the earlier content kept and reorganised |
| 2 System requirements | README "System requirements" | Ubuntu 24.04, WSL2, systemd (`degraded` is fine), a sudo user who is not root, network, amd64 for Mailpit, Bash; `check-system.sh` |
| 3 Prerequisites | README "Installation prerequisites" | Creating the distro, systemd (the user's change, never the toolkit's), the sudo password, the project in the Linux filesystem, `base` first |
| 4 install-all.sh | README "Installing with install-all.sh" | The options and the 6 stages of a run, the dependency order, the failure rule, the log, Ctrl+C |
| 5 install-menu.sh | README "Using install-menu.sh" | All 13 main entries with their submenu actions, the PHP menu (8 items), the Node.js menu (10 items), "Installation status", Ctrl+C, `DRY_RUN=1` |
| 6 PHP | README "PHP version management" | The EOL warning, commands, the PPA checks, per-version FPM and sockets, extensions, the 7.4.33 package note, the CLI-default rule, sites, Xdebug |
| 7 NVM / Node.js | README "Node.js and NVM version management" | Commands, how the pin is verified and how to move it, the `.bashrc` block, why `use` only prints the command, default handling |
| 8 Databases | README "Databases: MariaDB or MySQL" | Mutual exclusion and why, MySQL 8.0 EOL, no changes to authentication, existing data, what `verify` does, the alternatives |
| 9 Optional tools | README "Optional tools" | A table: source and version, addresses, extra actions, notes |
| 10 Verification | README "Verification" | The read-only commands, what each module's `verify` checks, manual commands |
| 11 Troubleshooting | README "Troubleshooting" | 14 problems, each with the action to take |
| 12 Known issues | README "Known limitations" | 12 items |
| 13 Directory review | below | Reviewed; architecture.md §2 corrected |
| 14 Bash review | below | Reviewed; recommendations only |
| 15 Docs vs implementation | below | Swept; 2 architecture.md and 8 README mismatches fixed |
| 16 Status report | this section | |

The first pass also added the testing.md §12 acceptance checklist, the "where to start" note and
the §11 correction. It also updated architecture.md's status line and the §2 heading and tree.

### Files
| File | Change |
|---|---|
| `README.md` | Rewritten (tasks 1–12) |
| `docs/architecture.md` | Status line; §2 heading, tree (`.shellcheckrc`, `test-qa.sh`, `test-live.sh`) and the `check-system.sh` description; §3 entry-point wording (`db_main`) |
| `docs/testing.md` | "Where to start" note, §11 fix, new §12 (acceptance run and results template) |
| `docs/implementation-plan.md` | Phase 8 approved; Phase 9 redefined by the brief |
| `docs/progress.md` | Summary table; this section |

### Directory structure review (task 13)
```
wsl-devtools/
├── CLAUDE.md  README.md  .shellcheckrc
├── config/      versions.conf  packages.conf                       (data only, checked by load_config)
├── lib/         common  system  packages  services  nginx  php  node  database  docker  orchestrator (.sh)
├── modules/     install-{base,nginx,php,composer,nodejs,mariadb,mysql,redis,postgresql,mailpit,docker}.sh
├── scripts/     install-all.sh  install-menu.sh  check-system.sh  nginx-site.sh
├── templates/   nginx-site.conf.tpl  mailpit.service.tpl
├── tests/       helpers.sh + test-{common,system,web,node,db,optional,orchestrator,qa,live}.sh
├── logs/        .gitignore only (run logs are not committed)
└── docs/        architecture.md  implementation-plan.md  progress.md  testing.md
```
- **The layout is sound.**
  - Each top-level folder has one role.
  - Installation logic is only in `modules/`; the scripts only coordinate.
  - Shared code is in `lib/`, and every tool-specific library has one consumer area.
  - Versions and package lists are only in `config/`.
- No orphaned files, no empty folders apart from `logs/`, and no duplicated helpers (Phases 5–6
  moved shared helpers into `lib/`).
- **Fixed in the docs:** architecture.md §2 described `check-system.sh` as showing "status of every
  tool". It runs the requirement checks and `install-base.sh status` only.
- **Observation:** git has only the initial commit. All of Phases 1–9 is uncommitted (see the
  recommendations).

### Bash readability and maintainability review (task 14)
Method:
- the length of every function (awk over `lib/`, `modules/`, `scripts/`);
- the header, strict mode and entry guard of each entry point;
- a TODO/FIXME search;
- ShellCheck.

| Check | Result |
|---|---|
| Size | 37 files with scripts, configs and tests. 338 functions in `lib/`, `modules/` and `scripts/`, 14 lines on average |
| Long functions | 14 are over 50 lines. 2 are over 80: `site_create` (`scripts/nginx-site.sh`, 86) and `mailpit_install` (`modules/install-mailpit.sh`, 82). Both are linear check → plan → confirm → apply sequences with comments, so they are readable as they are |
| Headers | Every library and entry script starts with its purpose. Every entry script also lists its usage and exit codes |
| Strict mode | Every entry script calls `enable_strict_mode`; the MariaDB and MySQL modules do it through `db_main`. Libraries change no shell options when sourced |
| Entry guard | Every module and script runs only when executed (`[[ "${BASH_SOURCE[0]}" == "$0" ]]`) |
| Naming | Functions are prefixed by area (`php_`, `nvm_`, `db_`, `docker_`, `service_`, `apt_`, `orch_`). Variables are quoted. Arrays are used for command arguments; no `eval` |
| Error handling | One ERR trap in `lib/common.sh`. Modules return the documented 0–4 codes, and the orchestrators turn any other code into "failed (exit N)" |
| Exceptions | ShellCheck 0.9.0 is clean. Every `# shellcheck disable=` has a written reason |
| Leftovers | No TODO, FIXME or XXX comments |

**Verdict:** consistent and maintainable. **Nothing was changed**, as the brief asks. The
recommendations are listed below.

### Documentation vs implementation (task 15)
Checked against the code (read-only):
- `install-all.sh --help`;
- the action `case` blocks and usage headers of all 11 modules and `nginx-site.sh`;
- the menu tables (`MENU_ITEMS`, `MENU_TITLE`, `MODULE_EXTRAS`, `status_submenu`) and the PHP and
  Node.js menu texts;
- `final_exit_code`, `exit_code_meaning`, `check_environment`;
- each module's `verify` messages;
- the port-in-use messages;
- `APT_LOCK_TIMEOUT_SECONDS`;
- the systemd error messages;
- the pinned versions in `config/versions.conf` (NVM v0.41.0, Mailpit v1.33.1 everywhere);
- the module and menu counts (11 and 13 everywhere).

| Found | Fixed in |
|---|---|
| `check-system.sh` described as "status of every tool" | architecture.md §2 |
| §3 said every module runs `main`; the DB modules run `db_main <flavour>` | architecture.md §3 |
| README (draft) said install-all exit 4 = "cancelled" in general; a module cancelled mid-run gives 3 | README exit-code table |
| README (draft) said nginx `verify` checks "enabled at boot"; it doesn't (`status` shows it) | README verification table |
| README (draft) wording for the base, redis, postgresql, mailpit and docker checks; the port message; the Xdebug hint (now `DRY_RUN=1 … xdebug`, read-only); `sudo -v` and the dry-run confirmation in install-all | README |

**No mismatch revealed a code defect.** Relative links and `#anchors` in `README.md` and
`docs/*.md`: 0 broken.

### Tests performed (2026-11-20, development machine)
| Check | Result |
|---|---|
| `bash -n` on 37 script and config files | All pass |
| `shellcheck -x lib/*.sh modules/*.sh scripts/*.sh tests/*.sh` and `shellcheck config/*.conf` (0.9.0) | No output, exit 0 |
| `test-common.sh` | 64 passed |
| `test-system.sh` | 42 passed |
| `test-web.sh` | 63 passed |
| `test-node.sh` | 108 passed |
| `test-db.sh` | 64 passed |
| `test-optional.sh` | 82 passed |
| `test-orchestrator.sh` | 110 passed |
| `test-qa.sh` | 78 passed |
| `test-live.sh` (read-only) | 98 passed, 1 skipped (`nginx -t`/`php-fpm -t` need your password); the system snapshot before and after was identical |
| **Total** | **709 passed, 0 failed, 1 skipped** |
| `scripts/check-system.sh` | exit 0 |
| Link check (scratch script) | 0 broken |
| Changed files (by modification time) | Only `.md` files |

**Not performed:**
- real installs in a fresh distro (testing.md §12, your run);
- `sudo nginx -t` and `sudo php-fpmX.Y -t` here (they need your password).

`test-live.sh` ran Composer's `sudo -K`, so your cached sudo session was ended.

### Known issues and limitations
- **The real installs are unverified** until the testing.md §12 acceptance run.
- The full list is in the README's "Known limitations":
  - Ubuntu 24.04 only;
  - MySQL 8.0 only, and only one of MySQL and MariaDB;
  - PHP 7.4 is end-of-life and comes from the PPA's patched 7.4.33;
  - Mailpit is amd64 only;
  - apt's own output is not in the log;
  - sudo can ask for the password again;
  - R1;
  - `use` cannot switch your current shell, and only Bash is configured;
  - Nginx sites use `listen 80`;
  - existing configurations keep their values;
  - nothing is uninstalled.
- **Development machine** (unchanged; your decision):
  - PHP 8.4 lacks `bcmath`, and 7.4 lacks several extensions, so `install-php.sh verify` fails;
  - NVM is 0.39.1 (the pin is v0.41.0);
  - `~/.bashrc` line 121 has the `[-s` typo;
  - the default Node.js is 18 (end-of-life);
  - Xdebug `start_with_request=yes` in `99-xdebug-debug.ini`.

### Future improvements (recommendations, none started)
1. **Commit** Phases 1–9 (only the initial commit exists), ideally before the acceptance run, so
   that fixes show up as small diffs.
2. **Acceptance run** (testing.md §12), and record the results here.
3. **R1:** simulate `apt-get -s install` before `apt-get update`, so a refused install leaves the
   package lists untouched.
4. **Split `site_create` and `mailpit_install`** into check, plan and apply helpers, but only if
   they need to change anyway.
5. **Put apt's output in the log.** For example, run apt through `script(1)`, which keeps the
   terminal behaviour for prompts. It needs a design review.
6. **Run CI:** ShellCheck plus the suites that need no Ubuntu/WSL fixtures, on every push.
7. **Write an uninstall/rollback guide** (documentation only). The toolkit itself stays
   no-removal.
8. **Mailpit for arm64:** a second pinned checksum.
9. **Ubuntu 26.04,** once the PHP PPA publishes `resolute` builds.
10. **An optional MySQL container helper** on 127.0.0.1:3307 for MariaDB machines.
11. **Pins:** re-check NVM, Mailpit and the Docker key regularly. `test-node.sh` and
    `test-optional.sh` already check them online.

### Next step
**Waiting for your review and approval of Phase 9.** No further changes until then.

---

## Development session summary (2026-11-20)

The details are in the [Phase 9 section](#phase-9-final-documentation-and-project-review-2026-11-20).
This summary records what happened in the session.

### Current phase
- **Phase 9: Final documentation and project review.** Completed and **waiting for your review
  and approval.**
- Phase 8 was approved during this session.
- No later phase has been started.

### Completed tasks
1. A read-only inspection of the project:
   - `CLAUDE.md` and all of the docs;
   - the code structure;
   - the static checks and test suites, run before any change.
2. **Approval:** Phase 8 approved. R1 left as a documented limitation (your choice).
3. A first documentation pass:
   - README;
   - testing.md "Where to start" note, §11 fix and the new §12 acceptance run;
   - architecture.md status line and tree;
   - the implementation-plan.md Phase 9 entry.
4. Your Phase 9 brief, all 16 tasks:
   - the README rewritten as the user guide: requirements, prerequisites, `install-all.sh`,
     `install-menu.sh`, PHP and NVM/Node.js management, database limitations, optional tools,
     verification, exit codes, troubleshooting, known limitations;
   - the directory structure review;
   - the Bash readability and maintainability review;
   - a sweep comparing the docs with the code: 10 mismatches fixed in the docs, and no code
     defects found;
   - the final status report.
5. This summary.

### Files created or modified
| File | Change |
|---|---|
| `README.md` | Rewritten |
| `docs/architecture.md` | Status line; §2 heading, tree and the `check-system.sh` description; §3 wording for the database modules' `db_main` entry point |
| `docs/testing.md` | "Where to start" note; §11 fix; new §12 (acceptance run, results template) |
| `docs/implementation-plan.md` | Phase 8 approved; Phase 9 as defined by your brief |
| `docs/progress.md` | Summary table, Phase 8 next step, the Phase 9 section, this summary |

- **Created:** no project files. A link checker was written to the session's scratch directory,
  outside the project.
- **Not changed:** `lib/`, `modules/`, `scripts/`, `tests/`, `config/`, `templates/`, `CLAUDE.md`.
  This was confirmed by file modification times.

### Tests performed and actual results
| When | Check | Result |
|---|---|---|
| Before any change | `bash -n` on all scripts and configs | Pass |
| | ShellCheck 0.9.0 | Clean |
| | 8 offline suites (common, system, web, node, db, optional, orchestrator, qa) | 611 passed, 0 failed |
| After the first documentation pass | The same three checks | Pass, clean, 611 passed |
| | `scripts/check-system.sh` | Exit 0 |
| | Link check | 0 broken |
| After the Phase 9 brief (final) | `bash -n` on 37 files | Pass |
| | ShellCheck on the scripts (`-x`) and the configs | Clean, exit 0 |
| | All 9 suites, including `test-live.sh` | **709 passed, 0 failed, 1 skipped** |
| | `test-live.sh` system snapshot | Identical before and after |
| | Link check | 0 broken |
| After this summary | Link check | 0 broken |

- **The skipped test:** `sudo nginx -t` / `php-fpm -t`, because they need your password.
- **Not run:**
  - real installs (testing.md §12);
  - `sudo nginx -t` and `sudo php-fpmX.Y -t` on this machine.
- **Side effect:** `test-live.sh` runs Composer, which runs `sudo -K`, so your cached sudo session
  was ended. Nothing else changed.

### Outstanding issues
1. **Acceptance run (testing.md §12) not done.** The real installs are unverified.
2. **R1** (deferred): a refused install has already refreshed the package lists.
3. **Git:** all of Phases 1–9 is uncommitted; only `868738f chore: initial commit` exists.
4. **Development machine** (unchanged, your decision):
   - PHP 8.4 lacks `bcmath`, and PHP 7.4 lacks several extensions;
   - NVM 0.39.1 (the pin is v0.41.0);
   - the `[-s` typo on `~/.bashrc` line 121;
   - the default Node.js is 18 (end-of-life);
   - Xdebug `start_with_request=yes`.
5. **Recommendation only:** `site_create` (86 lines) and `mailpit_install` (82 lines) could be
   split if they need changes.

### Next recommended task
1. Your review and approval of Phase 9.
2. Commit Phases 1–9 to git (only when you ask).
3. Run the testing.md §12 acceptance run in a disposable Ubuntu 24.04 distro, and share the
   results table, the logs and any failure output.

**No next phase has been started.**
