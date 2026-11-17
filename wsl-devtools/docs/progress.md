# Progress

## Summary

| Phase | Title | Status |
|---|---|---|
| 0 | Requirements analysis and architecture | Completed, approved |
| 1 | Project foundation (structure, config, shared helpers) | **Completed, awaiting approval** |
| 2 | System detection, module contract and base packages | Not started |
| 3 | Nginx | Not started |
| 4 | PHP 8.4 and 7.4 | Not started |
| 5 | Xdebug and per-site Nginx ↔ PHP-FPM | Not started |
| 6 | Composer | Not started |
| 7 | Node.js via NVM | Not started |
| 8 | MariaDB / MySQL | Not started |
| 9 | Redis, PostgreSQL, Mailpit | Not started |
| 10 | phpMyAdmin | Not started |
| 11 | Docker Engine | Not started |
| 12 | Full `install-all.sh` | Not started |
| 13 | `install-menu.sh` | Not started |
| 14 | Final verification and documentation | Not started |

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
- **NVM** pinned to v0.41.0, re-verified in Phase 7.
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
**Waiting for explicit approval to start Phase 2.**
