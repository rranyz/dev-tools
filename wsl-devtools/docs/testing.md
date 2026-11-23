# Testing

How each part of the toolkit is checked. Run all commands from the project root
(`wsl-devtools/`).

**Where to start:**
- Static checks and automated tests: §1 and §2.
- The final end-to-end run in a fresh distro: §12. It links to the detailed per-phase checklists
  in §4–§10.

## Where tests run

| Kind of test | Where | Why |
|---|---|---|
| Static checks and `tests/` | Anywhere | They make no system changes |
| Read-only `status` / `verify` / `DRY_RUN=1` | Development machine | It already has a working stack that must not change |
| Real installs | A disposable Ubuntu 24.04 WSL distro | Installs can be repeated from a clean state |

sudo needs a password, so install tests are run by the user. Share the output (or the file from
`logs/`) for review.

## 1. Static checks

Syntax check every script and config file:

```bash
for f in lib/*.sh modules/*.sh scripts/*.sh tests/*.sh config/*.conf; do bash -n "$f" && echo "syntax ok: $f"; done
```

Lint with ShellCheck. This is a development-only dependency, install it once with
`sudo apt install shellcheck`. Run it from `wsl-devtools/`, so `.shellcheckrc` is used: it resolves
the `source=` paths relative to each script and disables SC2119 (optional fixture-path arguments).
Every other intended exception is a `# shellcheck disable=… # reason` comment next to the code:

```bash
shellcheck -x lib/*.sh modules/*.sh scripts/*.sh tests/*.sh
shellcheck config/*.conf
```

Expected: no output and exit status 0.

## 2. Automated tests

```bash
bash tests/test-common.sh   # expect: Passed: 64  Failed: 0  Skipped: 0
bash tests/test-system.sh   # expect: Passed: 42  Failed: 0  Skipped: 0
bash tests/test-web.sh      # expect: Passed: 63  Failed: 0  Skipped: 0 (on the development machine)
bash tests/test-node.sh     # expect: Passed: 108 Failed: 0  Skipped: 0 (on the development machine, online)
bash tests/test-db.sh       # expect: Passed: 64  Failed: 0  Skipped: 0 (on the development machine)
bash tests/test-optional.sh # expect: Passed: 82  Failed: 0  Skipped: 0 (on the development machine, online)
bash tests/test-orchestrator.sh # expect: Passed: 110 Failed: 0 Skipped: 0 (on the development machine; about 1 minute)
bash tests/test-qa.sh       # expect: Passed: 78  Failed: 0  Skipped: 0 (on the development machine; mocks, about 20 s)
bash tests/test-live.sh     # expect: Passed: 98  Failed: 0  Skipped: 1 (on the development machine; read-only, about 25 s)
```

Each test prints one `ok` line. A failing test prints `FAIL` and the script exits with status 1.
Shared helpers (`assert_ok`, `assert_fail`, `assert_equals`, `skip`, `finish`) are in
`tests/helpers.sh`.

`tests/test-common.sh` covers:

| Area | What is checked |
|---|---|
| Validation | `is_integer`, `is_valid_port`, `is_valid_version`, `is_valid_domain`, `is_one_of`, `is_supported_php_version`: valid and invalid input |
| `DRY_RUN` | Unset, `0` and `1` are valid; `yes` and `true` are not; `load_project_config` refuses `DRY_RUN=yes` with 3 |
| Command checks | `command_exists`, `require_commands` with present and missing commands |
| Configuration | Both real config files load. Files with `$(...)`, backticks, bare commands, lowercase names, unquoted values or CRLF line endings are refused, and a marker file proves nothing in them ran |
| Running commands | `run` returns the command's status. `DRY_RUN=1` does not execute |
| Confirmation | `confirm` answers "no" without a terminal |
| Logging | `log_init` creates a log file and messages are written to it. Unsafe log names are refused |
| Error handling | Strict mode stops at the first failure, the ERR trap reports the failed command, `die` exits with the given code |

The tests only create a temporary directory with `mktemp -d` and remove it on exit.

`tests/test-system.sh` covers:

| Area | Test cases |
|---|---|
| WSL2 detection | Kernel-name fixtures: `…-microsoft-standard-WSL2` → 2; `4.4.0-19041-Microsoft` → 1; `5.15.0-microsoft-custom` → unknown; `6.8.0-45-generic` → not WSL; missing file → not WSL |
| Ubuntu version | `os-release` fixtures: Ubuntu 24.04 → fields parsed, supported; Ubuntu 22.04 → Ubuntu, not supported; Debian 12 → not Ubuntu; missing file → error, fields cleared |
| systemd | PID 1 name fixtures `systemd` / `init` / missing. States running, degraded and starting are usable; offline, unknown and empty are not |
| Missing dependencies | `check_apt` fails with an empty `PATH`. `sudo_status` reports `missing` without sudo. `missing_packages` lists only the absent package. A non-existent package has no apt candidate. Installing an installed package would remove nothing |
| Base module | A fake `sudo` that records any real use, and fixture configs. Already-installed packages → `install` exits 2. An unavailable package with `DRY_RUN=1` → exit 3. A missing package with no terminal to confirm → exit 4. `verify` exits 0 or 1. An unknown action → exit 3. Sudo was never used for a change |
| Live, read-only | `scripts/check-system.sh` and `install-base.sh status` exit 0 on this machine |

The module and live groups need Ubuntu 24.04 on WSL2. Elsewhere they print `skip`.

`tests/test-web.sh` covers:

| Area | Test cases |
|---|---|
| Package versions | `upstream_version` strips the epoch and revision: `1:7.4.33-31+…` → `7.4.33`, and 3 more |
| PPA detection | Fixture apt dirs: a deb822 `.sources` file and a one-line `.list` are found; a commented-out entry and no sources are not |
| PHP packages | 7.4 includes `json` and `xdebug`; 8.4 has no `json` and 12 packages; module names (`mysql` → `mysqli`); socket and service names; 7.4 is EOL and 8.4 is not |
| Xdebug settings | Fixture `/etc/php`: `zend_extension` alone is no setting; a foreign `xdebug.mode` is found; commented lines are ignored; the toolkit's own file is not "foreign"; which SAPIs need toolkit settings; the drop-in uses `trigger` |
| Nginx sites | The template is filled in with no placeholders left and `listen 80;`. `is_safe_path` accepts or rejects 5 paths. Fixture `/etc/nginx`: existing site names and `server_name`s (in `sites-enabled` and `conf.d`) are detected, and similar names are not |
| Modules | With a fake `sudo` and no terminal: |
| | Nginx `install` → 2 when installed (4 when not); `status` → 0 |
| | PHP: `install 8.2` → 3, `install` with no version → 3, no action and no terminal → 3, `install 7.4` → 4 (EOL prompt answered no), `DRY_RUN=1 install 8.4 7.4` → 0 (or 2 if complete) |
| | `set-default 9.9` → 3, `set-default <other version>` → 4, `set-default <current>` → 2, and the CLI default is unchanged |
| | Composer `install` → 2 when installed, `verify` → 0 |
| | `nginx-site list` → 0; `create` with an invalid domain, an unsafe root, PHP 9.9, or an existing site name → 3 |
| | Sudo was never used for a change. Composer's own `sudo -K` is ignored |

`tests/test-node.sh` covers:

| Area | Test cases |
|---|---|
| Version input | `22`, `22.11`, `22.11.0`, `v22.11.0`, `lts`, `lts/*`, `lts/jod` accepted. Empty, `22;rm`, `../x`, `latest`, `node`, `v1.2.3.4`, `lts/Jod`, `$(id)` refused. `lts` → `lts/*`. NVM tag and SHA-256 formats, the configured values, `version_lt` (v0.9.0 < v0.41.0) |
| `.bashrc` detection | Fixtures: NVM's official lines are found (lines 3–5), commented-out lines don't count, a missing file, the `[-s` typo is found (and only in active lines) and its fixed form |
| `.bashrc` changes | Fixtures: the block is appended once (a second call returns 2 and changes nothing), the last line of a file without a trailing newline stays intact, `bash -n` passes, no block next to the official lines, an empty file. Backups never overwrite each other. The fix changes exactly one line, refuses a non-number line, and keeps a symlink a symlink |
| Strict-mode bridge | Under `set -Eeuo pipefail` with an ERR trap, a stand-in `nvm` using an unset variable and a failing pipe returns its code (7), and `-e`, `-u`, `pipefail` and the trap are back afterwards. Strict mode is not switched on when it was off |
| Installer download | `file://` fixture: a matching SHA-256 is accepted, a wrong one and a missing tag are refused |
| Tag check | A local git repository fixture: an annotated tag resolves to its commit, a missing tag → 2, an unreachable repository → 1, newest tag |
| Module (fake HOME) | Stub `~/.nvm` (v0.41.0, Node 18 and 20, default 18), fake `sudo`, no terminal: |
| | `status`, `verify`, `list` → 0. Unknown action → 3, no action → 3 |
| | `install-node 'x;y'` / no version / `99` → 3; `20` (installed) → 2; `22` → 4, and `nvm install` was not called; `DRY_RUN=1 install-node 22` → 0 |
| | `use 19` → 3, `use 20` → 0. `set-default 18` → 2, `20` → 4, `19` → 3, and the alias is unchanged. `list-remote 'x;y'` → 3 |
| | `install-nvm` (present) → 2, `update` (at the pin) → 2, `fix-bashrc` (nothing broken) → 2. A broken line: `fix-bashrc` → 4, dry run → 0, file unchanged, no backup |
| | Older NVM without `.git`: `update` → 3. Empty HOME with a fixture repository: `install-nvm` → 4, nothing created; a tag that does not exist → 3; `use` → 3; `status` → 0. A foreign non-empty `~/.nvm` → 3 |
| | sudo was never called |
| Live, read-only | `status` → 0. With network: the pinned tag exists, `v9.9.9` does not, and `install.sh` at the pin matches `NVM_INSTALL_SCRIPT_SHA256` |
| Real files | The real `~/.bashrc` checksum and `~/.nvm` HEAD are the same before and after the run |

`tests/test-db.sh` covers:

| Area | Test cases |
|---|---|
| Metadata | Units `mariadb`/`mysql`, ports (3306; 3306 and 33060), admin, client and secure-installation tools, package lists from config, the other flavour, unknown flavour/key refused |
| Installed flavour | Fixture dpkg output: MariaDB only; MySQL only (the shared `mariadb-common` is ignored); only shared packages → none; a half-configured package counts (→ both); removed with config files left → none, and listed as leftovers; a MariaDB client alone counts; nothing → none |
| Data directory | Missing, empty, has data, unreadable (mode 000), a file instead of a directory |
| Listeners | `127.0.0.1`, `127.0.0.53`, `[::1]`, `[::1%lo]`, `localhost` are loopback; `0.0.0.0`, `*`, `[::]`, `192.168.1.5`, `[fe80::1]` are not |
| Security report (fixtures) | A clean server: socket login, no warnings. Remote root, anonymous accounts and a `test` database are each warned about. Password hashes from `SHOW CREATE USER` are never printed. An unreadable account list is only a warning |
| Security report (real SQL) | A temporary MariaDB server started as the current user (`/dev/shm`, `--skip-networking`, own socket), stopped and removed afterwards. Its fresh data has anonymous accounts and a `test` database: both found, root@localhost reported as socket login, then a `root@%` account is found. Skipped if the MariaDB server binaries are missing |
| Modules | Fake `sudo`, no terminal. Both modules: `status` and `guide` → 0, unknown action → 3, no action → 3 |
| | With MariaDB installed (the development machine): `install-mariadb install` → 2, `verify` → 0; `install-mysql install` → 3 (also with `DRY_RUN=1`), `verify` → 1. The mirror cases when MySQL is installed; with neither, `install` → 4 (or 3 with leftover data) |
| | sudo was never used, and the MariaDB service state is unchanged |

`tests/test-optional.sh` covers:

| Area | Test cases |
|---|---|
| Shared helpers | `download_checked` with a `file://` fixture: matching checksum (file written), wrong checksum and missing file refused. Loopback detection. A free port has no listeners and reports cleanly |
| Docker detection | Fixture tree (`DOCKER_FS_ROOT`) and fake `docker`/`docker.exe` paths: nothing → no integration; `/mnt/wsl/docker-desktop` → integration; `/var/run/docker.sock` symlinked into `/mnt/wsl` → integration; a `docker` CLI resolving into Docker Desktop → integration; a normal CLI → none. Fixture package lists: none, `docker.io`, `containerd runc` → conflicts; Docker's own packages → none |
| Docker files | The apt source has `Signed-By` the keyring, suite `noble` and the configured URL. The generated `daemon.json` is valid JSON with `ip` 127.0.0.1. An existing file's `ip` is read (`0.0.0.0`, or none). A non-key file has no fingerprint. With network: Docker's published key has the pinned fingerprint |
| Mailpit | The rendered unit has no placeholders, the managed header, SMTP on 127.0.0.1:1025, UI on 127.0.0.1:8025, `DynamicUser=yes`, `--disable-version-check`. Config check refuses a non-local address and an invalid port. Toolkit, foreign and missing unit files are told apart. JSON string/number values from the API |
| PHP `sendmail_path` | Fixture `/etc/php`: commented lines and the toolkit's own drop-in are ignored; an active `php.ini` setting is found with its line; the drop-in path and content |
| PostgreSQL helpers | Fixture `/etc/postgresql`: a commented `listen_addresses` → default localhost; an explicit `'*'` is shown. Empty, non-empty and missing data directories |
| Modules | Fake `sudo`, no terminal. All four: `status` → 0, unknown action → 3, no action → 3. When not installed (the development machine): `verify` → 1, `install` → 4, `DRY_RUN=1 install` → 0; `install-mailpit test` / `php-mail` → 3; `install-docker test-run` → 3; `guide` → 0. sudo was never used; no Mailpit unit or Docker keyring was written |

The temporary server's data is put on tmpfs because every fsync of the bootstrap is slow on
WSL's virtual disk (about 90 s on the development machine against under a second on `/dev/shm`).

`tests/test-orchestrator.sh` covers `lib/orchestrator.sh`, `scripts/install-all.sh` and
`scripts/install-menu.sh`. The scripts run against **stub modules** (`WSL_DEVTOOLS_MODULES_DIR`)
that only record their calls and exit with a chosen code, a fake `sudo` that records every use,
and a temporary `LOG_DIR`. Interactive runs use a pseudo-terminal (`script` from util-linux).

| Area | Test cases |
|---|---|
| Registry | 11 modules, each with a label, kind, dependency entry and a real module file; every dependency comes before its module; no optional tool in `core`; sorting and de-duplication; mariadb + mysql detected as exclusive; nodejs uses no sudo; which modules need systemd; durations and result texts |
| Validation | Unknown module, mariadb + mysql, PHP 9.9, `--php` without php, an unknown option, a number that would wrap around in bash arithmetic (`18446744073709551619`), `DRY_RUN=yes`, and an invalid `--php` without `--modules` → 3, with no module run and no log file created. The `WSL_DEVTOOLS_MODULES_DIR` override is announced. No terminal and no `--modules` → 4; no terminal to confirm → 4, nothing run, no `sudo -v`. An unwritable `LOG_DIR` → 1 with one clear message |
| Order and dependencies (`DRY_RUN=1`) | Registry order, each module once, PHP versions passed (`8.4 7.4`); `DRY_RUN` and `LOG_FILE` reach the modules; no verify pass in a dry run. base → 1: its four dependents (and composer through php) are "not run", exit 1. php → 3: only composer is skipped, exit 3. base → 2 satisfies its dependents; php → 4 skips composer. An unexpected exit code 7 → "failed (exit 7)", exit 1, the independent module still runs |
| No systemd | A fake `systemctl` reporting `offline`: nginx cannot be selected (3); nodejs and composer still run (0) |
| Interactive | Confirmed run: install, then verify, `sudo -v` once, verify without `LOG_FILE` (its output is appended to the log), PASS table. nodejs alone: no `sudo -v`. A failing verify → FAIL, exit 1. No verify for a blocked module. **n** → 4, nothing run. Selection prompt: an empty answer, `99`, `mariadb mysql` and `foo` are re-asked, then `1 5` runs base and nodejs. PHP prompt: `7` is re-asked, `3` → both, with the EOL warning. `q` → 4 |
| Ctrl+C (timed input in a pseudo-terminal) | During php's install (the stub sleeps): exit 130, nothing runs afterwards, php "interrupted", composer "not run: interrupted", the `dpkg --configure -a` hint. Before the run: 130, "Nothing was changed", nothing ran. Menu: Ctrl+C during an action returns to the menu, and Exit then gives 0; Ctrl+C at the main prompt → 130 |
| Menu (piped input) | `0`, `99`, `x` and an empty line are re-asked; Exit → 0; end of input → 0, also inside a submenu; a submenu validates its range. Redis status and verify; PHP and Node.js open their own menus (with no "Result:" line after them); Mailpit `php-mail`, Docker `test-run`, MySQL and MariaDB `guide`; an install result is shown; status and verify of all 11 modules with the PASS/FAIL table; `DRY_RUN=yes` → 3; arguments are refused (3) |

`tests/test-qa.sh` (Phase 8) runs the real modules in failure scenarios built from mocks. A fake
`sudo` first on `PATH` records every call and **never runs anything**, so no apt command, service
change or root write can happen; read-only commands (`apt-get -s`, `apt-cache`, `dpkg-query`)
run for real. Answers are typed into a pseudo-terminal.

| Area | Test cases |
|---|---|
| systemd unavailable | A fake `systemctl` reports `offline`. `install` and `DRY_RUN=1 install` of nginx, redis, postgresql, mailpit, docker, mariadb and mysql → 3, the problem explained, no sudo. `install-php install 8.4` and `xdebug` → 3, with the `wsl.conf` explanation (nothing edited). `nginx-site create` → 3. `install-all --modules nginx` → 3. base and nginx `status` still 0; `check-system` → 3 |
| Missing dependencies | A `PATH` of symlinks to the real tools minus one: php install without curl → 3 ("curl is missing"); nodejs install without git → 3; NVM install without sha256sum → 3; base verify without the curl command → 1, naming it; composer install without php → 3. No sudo used |
| Failed package installations | `install-base.sh install` with a fixture `BASE_PACKAGES`, answered **y**: `apt-get update` fails → 1, explained, nothing installed; `apt-get install` of `sl` fails → 1, explained; only the missing package was requested, with the lock timeout and `NEEDRESTART_MODE=l`; apt "succeeds" but the package is absent → verify catches it, 1. Removal guard: `mysql-server` on a MariaDB system → 1, "would remove …", and `apt-get install` is never called. An unavailable package → 3. Answer **n** → 4, no sudo |
| Invalid `DRY_RUN` | `DRY_RUN=yes` → 3 for all 11 modules, `check-system`, `nginx-site`, `install-all` and `install-menu`; no sudo |

`tests/test-live.sh` (Phase 8) is **read-only**. It checks what is installed, so it also runs in the
fresh distro after installs:

| Area | Test cases |
|---|---|
| Snapshot | Before and after everything below: metadata of every file and checksums of readable files under `/etc/nginx`, `/etc/php`, `/etc/mysql`, `/etc/apt/sources.list.d`, `/etc/apt/keyrings`, `/etc/redis`, `/etc/postgresql`, `/etc/docker`, `/usr/local/bin`; the Mailpit unit; `~/.bashrc`; `~/.nvm` HEAD, default alias and versions; `update-alternatives --query php`; all package versions and states; `is-active`/`is-enabled` of 11 units. **Must be identical** |
| Repeat runs | Two rounds of `status` (→ 0), `verify` (→ 0 or 1) and `install` without a terminal (→ 2, 3 or 4) for all 11 modules; both rounds give the same results. `install-all` → 4; the menu's status and verify → 0; `check-system`, `nginx-site list` → 0; `DRY_RUN=1 install-php install 8.4 7.4` → 0 or 2 |
| Services | `systemctl is-active` for every enabled toolkit unit |
| PHP | `phpX.Y -v` for each managed version; its FPM unit active and socket present; the `php` alternative points to an existing program and `php -v` matches it |
| Composer | `XDEBUG_MODE=off composer --version` |
| Nginx ↔ PHP-FPM | Nginx answers on `http://localhost`; every `fastcgi_pass unix:` socket in the enabled sites exists; `sudo -n nginx -t` and `php-fpmX.Y -t` when sudo needs no password (otherwise skipped, see §10) |
| Node.js | In a brand-new `bash -i`: `command -v nvm`, `nvm --version`, `node --version`, `npm --version`. `use <default>` → 0, `use 99` → 3, `set-default <other>` without a terminal → 4, alias unchanged |
| Databases | `mariadb-admin`/`mysqladmin ping`; port 3306 on loopback only; installing the other flavour → 3 |

Composer runs `sudo -K` itself, so `test-live.sh` ends a cached sudo session.

## 3. Manual checks for Phase 1

Run these in an interactive terminal.

```bash
# Message colours (INFO blue, OK green, WARN yellow, ERROR red)
bash -c 'source lib/common.sh; log_step "Demo"; log_info info; log_success done; log_warn careful; log_error broken'

# No colours when NO_COLOR is set or output is redirected
NO_COLOR=1 bash -c 'source lib/common.sh; log_info plain'
bash -c 'source lib/common.sh; log_info plain' | cat

# Confirmation prompt: try y, n, Enter (= no) and invalid input
bash -c 'source lib/common.sh; if confirm "Continue?"; then echo yes; else echo no; fi'

# Error trap: should print "[ERROR] Command failed (exit 2) ..." and not print "reached"
bash -c 'source lib/common.sh; enable_strict_mode; ls /nonexistent; echo reached'

# Log file: creates logs/demo-<timestamp>.log
bash -c 'source lib/common.sh; log_init demo; log_info "hello"' && tail -n 2 logs/demo-*.log
rm -f logs/demo-*.log
```

## 4. Phase 2 checks

### On the development machine (read-only)

```bash
scripts/check-system.sh;              echo "exit=$?"   # expect exit=0
modules/install-base.sh status;       echo "exit=$?"   # expect exit=0, five "installed" lines
modules/install-base.sh verify;       echo "exit=$?"   # expect exit=0, one version line per tool
modules/install-base.sh install;      echo "exit=$?"   # expect "already installed", exit=2, no password prompt
```

Expected `check-system.sh` output on the development machine:

```
==> System requirements
[OK] OS: Ubuntu 24.04.5 LTS
[OK] WSL: WSL2
[OK] systemd: running (degraded: some units failed, see 'systemctl --failed'; this does not block the toolkit)
[OK] sudo: available (your password will be asked when needed)
[OK] APT: available
...
[OK] This system meets the toolkit's requirements.
```

### In a fresh Ubuntu 24.04 test distro

Create the distro yourself from Windows, for example
`wsl --install -d Ubuntu-24.04 --name wsl-devtools-test`. Copy or clone the project into it, then:

- [ ] `scripts/check-system.sh` reports every requirement. If systemd is off, it explains how to
      enable it and exits 3 without changing anything.
- [ ] `modules/install-base.sh status` shows which of curl, wget, zip, unzip and git are missing.
      A fresh image usually already has most of them.
- [ ] `DRY_RUN=1 modules/install-base.sh install` prints the `sudo apt-get …` commands and changes nothing.
- [ ] `modules/install-base.sh install`, answer **n** → "Cancelled", exit 4.
- [ ] `modules/install-base.sh install`, answer **y** → password prompt, `apt-get update`, install, verify, exit 0.
- [ ] Run `modules/install-base.sh install` again → "already installed", exit 2.
- [ ] `modules/install-base.sh verify` → one version line per tool, exit 0.

If a fresh image already has all five utilities, check the install path by removing one yourself
first, for example `sudo apt remove zip`. The toolkit itself never removes packages.

## 5. Phase 3 checks

### On the development machine (read-only)

```bash
modules/install-nginx.sh status          # nginx 1.24, active, 3 enabled sites
modules/install-php.sh status            # 7.4 and 8.4 managed, 8.2 and 8.5 "not managed", CLI default php8.4 (manual)
modules/install-composer.sh status       # /usr/local/bin/composer 2.8.12
modules/install-composer.sh verify       # works with PHP 7.4 and 8.4
scripts/nginx-site.sh list               # each enabled site with its PHP version
DRY_RUN=1 modules/install-php.sh install 7.4   # missing 7.4 extensions, candidates, the 7.4.33 note
DRY_RUN=1 modules/install-php.sh xdebug        # what Xdebug changes would be made
modules/install-php.sh verify            # in a terminal: includes sudo php-fpm -t
modules/install-nginx.sh verify          # in a terminal: includes sudo nginx -t
```

`install-php.sh verify` currently **fails on the development machine**, and this is correct. The
brief's extension list isn't fully installed there: PHP 8.4 lacks `bcmath`, and PHP 7.4 lacks
xml, curl, gd, mbstring, zip, bcmath, intl, soap and xdebug.

### In a fresh Ubuntu 24.04 test distro

Run `modules/install-base.sh install` first. Then:

- [ ] `modules/install-nginx.sh install` → asks first, installs, exit 0. `curl -I http://127.0.0.1/` → 200.
- [ ] Rerun `modules/install-nginx.sh install` → "already installed", exit 2.
- [ ] `modules/install-php.sh install 8.4` → adds the PPA after asking, shows the plan, installs, exit 0.
  - [ ] `php -v` shows 8.4.
  - [ ] `systemctl is-active php8.4-fpm` → active.
  - [ ] `/run/php/php8.4-fpm.sock` exists.
  - [ ] `/etc/php/8.4/{cli,fpm}/conf.d/99-wsl-devtools-xdebug.ini` exist.
- [ ] `modules/install-php.sh install 7.4` → EOL warning plus its own prompt, then the 7.4.33
  package note. After it:
  - [ ] **`php -v` still shows 8.4**.
  - [ ] `php7.4 -v` shows 7.4.33.
  - [ ] Both FPM services are active.
- [ ] Rerun `modules/install-php.sh install 8.4 7.4` → exit 2.
- [ ] `modules/install-php.sh set-default 7.4` → asks, then `php -v` shows 7.4. Answering **n**
  instead → exit 4, and nothing changes.
- [ ] Sites: create two directories, each with a `phpinfo` page:
  ```bash
  sudo mkdir -p /var/www/app74 /var/www/app84
  echo '<?php echo PHP_VERSION;' | sudo tee /var/www/app74/index.php /var/www/app84/index.php
  scripts/nginx-site.sh create app74.test /var/www/app74 7.4
  scripts/nginx-site.sh create app84.test /var/www/app84 8.4
  curl -H 'Host: app74.test' http://127.0.0.1/   # 7.4.33
  curl -H 'Host: app84.test' http://127.0.0.1/   # 8.4.x
  ```
- [ ] Running `scripts/nginx-site.sh create app74.test /var/www/app74 8.4` again → refused, exit 3,
  and the file is unchanged.
- [ ] A document root under a private home folder (mode 750) → explained, exit 3, no chmod.
- [ ] `modules/install-php.sh xdebug` → shows `mode=debug | start_with_request=trigger | client 127.0.0.1:9003`.
  `XDEBUG_TRIGGER=1 php -r 'echo 1;'` tries to connect to port 9003; a plain `php -r 'echo 1;'` stays quiet.
- [ ] `modules/install-composer.sh install` → signature verified, installed, works with 7.4 and 8.4.
  Rerun → exit 2.
- [ ] `modules/install-php.sh` with no arguments opens the menu. Invalid input is re-asked,
  7 shows status, and 8 exits.
- [ ] `sudo nginx -t` passes, and none of the existing files in `/etc/nginx/sites-available` changed.

## 6. Phase 4 checks

### On the development machine (read-only)

```bash
modules/install-nodejs.sh status              # NVM v0.39.1 (pinned v0.41.0, update available), lines 119-121, line 121 broken, 6 Node versions, default 18
modules/install-nodejs.sh verify              # exit 0; nvm/node/npm here and in a new shell; warns about line 121
modules/install-nodejs.sh list                # installed versions, default -> 18
modules/install-nodejs.sh list-remote 26      # Node 26 releases at nodejs.org
modules/install-nodejs.sh use 22              # checks v22.20.0 and prints 'nvm use 22'
modules/install-nodejs.sh install-nvm         # "already installed", points to update, exit 2
DRY_RUN=1 modules/install-nodejs.sh update    # tag check and the plan, changes nothing
DRY_RUN=1 modules/install-nodejs.sh fix-bashrc   # shows line 121 before/after, changes nothing
DRY_RUN=1 modules/install-nodejs.sh install   # plans the newest LTS, default unchanged
```

Expected `status` output on the development machine:

```
==> Node.js / NVM: status
[INFO] NVM: v0.39.1 in /home/<you>/.nvm (git checkout); pinned v0.41.0, update available: install-nodejs.sh update
[INFO] /home/<you>/.bashrc: existing NVM lines 119 120 121 (not managed by the toolkit, kept as they are)
[WARN] /home/<you>/.bashrc line 121 is broken ('[-s' needs a space after '['): [-s "$NVM_DIR/bash_completion" ] && ...
[WARN] Fix it with: install-nodejs.sh fix-bashrc
[INFO] Node.js versions: v18.20.8 v19.9.0 v22.20.0 v24.13.0 v24.20.0 v26.7.0
[INFO] Default: 18 (v18.20.8)
[INFO] Active node after loading nvm: /home/<you>/.nvm/versions/node/v18.20.8/bin/node
```

Optional, on the development machine, only if you want these changes (each asks first):
- `modules/install-nodejs.sh fix-bashrc`: backs up `~/.bashrc` and fixes line 121.
- `modules/install-nodejs.sh update`: NVM v0.39.1 → v0.41.0. Your Node versions and aliases stay.

### In a fresh Ubuntu 24.04 test distro

Run `modules/install-base.sh install` first (git and curl are needed). Then, as your normal user:

- [ ] `modules/install-nodejs.sh status` → NVM not installed, `.bashrc` does not load NVM, exit 0.
- [ ] `DRY_RUN=1 modules/install-nodejs.sh install-nvm` → tag check, the planned installer command
  and the `.bashrc` block; nothing changes (`ls ~/.nvm` fails).
- [ ] `modules/install-nodejs.sh install-nvm`, answer **n** → "Cancelled", exit 4, no `~/.nvm`.
- [ ] `modules/install-nodejs.sh install-nvm`, answer **y** twice:
  - [ ] "Tag v0.41.0 exists" and "Installer checksum verified (SHA-256)".
  - [ ] NVM's own output, then "NVM v0.41.0 … (matches the tag's commit)".
  - [ ] A backup `~/.bashrc.wsl-devtools-<timestamp>.bak` and "NVM block added".
  - [ ] The new-shell check shows `nvm`; exit 0. No password prompt at any point.
- [ ] Rerun `modules/install-nodejs.sh install-nvm` → "already installed", "already loads NVM", exit 2.
  `grep -c 'wsl-devtools: nvm >>>' ~/.bashrc` → 1.
- [ ] Open a **new terminal**: `command -v nvm` → `nvm`; `nvm --version` → `0.41.0`.
- [ ] `modules/install-nodejs.sh install-node lts` → plan says nvm will make it the default (none set
  yet), asks, installs, prints node and npm versions. Rerun → exit 2.
- [ ] `modules/install-nodejs.sh install-node 22` → installs; "The default version (v26.x.y) is not changed"
- [ ] `modules/install-nodejs.sh install-node 99` → not found, exit 3.
- [ ] `modules/install-nodejs.sh list` → both versions; default → the exact LTS version installed first (e.g. v26.13.1).
- [ ] `modules/install-nodejs.sh list-remote` → LTS releases; `list-remote 22` → the 22.x releases.
- [ ] `modules/install-nodejs.sh use 22` → prints `nvm use 22`. Running that in the terminal makes
  `node --version` show 22.
- [ ] `modules/install-nodejs.sh set-default 22`, answer **n** → exit 4. Answer **y** → the new-shell
  check shows v22; a new terminal's `node --version` shows v22.
- [ ] `modules/install-nodejs.sh verify` → exit 0.
- [ ] `modules/install-nodejs.sh update` → "already at the pinned version", exit 2.
- [ ] `modules/install-nodejs.sh install` → everything present, exit 2.
- [ ] `modules/install-nodejs.sh` with no arguments opens the menu; invalid input is re-asked; 9
  verifies; 10 exits.
- [ ] `sudo` was never asked for, and `ls -ld ~/.nvm` is owned by you, not root.

## 7. Phase 5 checks

### On the development machine (read-only)

```bash
modules/install-mariadb.sh status          # 9 packages 1:10.11.14, service active and enabled, 127.0.0.1:3306 only, data present, my.cnf -> mariadb.cnf
modules/install-mariadb.sh verify          # exit 0; in a terminal also SELECT VERSION() and the security report
modules/install-mariadb.sh install         # "already installed", verify, exit 2
modules/install-mysql.sh status            # not installed; MariaDB installed instead; 3306 used, 33060 free
modules/install-mysql.sh install           # refused: MariaDB is installed, alternatives listed, exit 3, no password prompt
modules/install-mariadb.sh guide           # initial configuration guidance
```

Expected `install-mysql.sh install` output on the development machine:

```
==> MySQL: checks before installing
[ERROR] MariaDB is installed: 9 package(s), version 1:10.11.14-0ubuntu0.24.04.1: mariadb-client ... mariadb-server-core
[ERROR] MySQL and MariaDB cannot be installed together from Ubuntu's packages: apt would remove MariaDB,
[ERROR] and both use port 3306, /run/mysqld/mysqld.sock, /etc/mysql and /var/lib/mysql. Nothing was changed.
[INFO] Alternatives:
[INFO]   - keep MariaDB (modules/install-mariadb.sh status);
[INFO]   - run MySQL in a container on 127.0.0.1:3307 (Docker Engine: modules/install-docker.sh);
[INFO]   - use a separate WSL distro for projects that need MySQL.
```

### In a fresh Ubuntu 24.04 test distro: MariaDB

- [ ] `modules/install-mariadb.sh status` → not installed, ports free, data directory `missing`.
- [ ] `DRY_RUN=1 modules/install-mariadb.sh install` → checks pass, the plan lists
  `mariadb-server mariadb-client` with candidates, nothing changes.
- [ ] `modules/install-mariadb.sh install`, answer **n** → exit 4. Answer **y** → password prompt,
  install, `service mariadb: active`, both pings answer, exit 0.
- [ ] `modules/install-mariadb.sh verify` in a terminal:
  - [ ] `SELECT VERSION() -> 10.11.x-MariaDB…`;
  - [ ] the security report shows `root@localhost: socket login`, no anonymous accounts and no
    `test` database.
- [ ] `ss -ltn | grep 3306` shows only `127.0.0.1:3306`.
- [ ] Rerun `modules/install-mariadb.sh install` → exit 2.
- [ ] `modules/install-mysql.sh install` → exit 3. `dpkg -l 'mariadb-server'` still shows `ii`.
- [ ] Follow `modules/install-mariadb.sh guide` to create a `myapp` database and user. Then
  `mariadb -u myapp -p myapp -e 'SELECT 1'` works.

### In a second fresh distro: MySQL

- [ ] `modules/install-mysql.sh install` → the end-of-life warning with its own prompt (**n** →
  exit 4), then the plan and the install prompt. Answer **y** to both → `service mysql: active`, exit 0.
- [ ] `modules/install-mysql.sh verify` in a terminal → `SELECT VERSION() -> 8.0.x`; the security
  report shows `root@localhost: socket login`.
- [ ] `ss -ltn` shows `127.0.0.1:3306` and `127.0.0.1:33060` only.
- [ ] `modules/install-mariadb.sh install` → exit 3; MySQL untouched.

### Leftover data (either distro, optional)

- [ ] After `sudo apt remove --autoremove mariadb-server mariadb-client` (your own step;
  `--autoremove` also removes the `-core` packages, and the data stays in `/var/lib/mysql`),
  `modules/install-mysql.sh install` → "contains data … never reuses, moves or deletes", exit 3.
  If a MariaDB package is still installed, the conflict message appears instead, also exit 3.

## 8. Phase 6 checks

### On the development machine (read-only)

None of the four tools is installed here, and there is no Docker Desktop integration.

```bash
modules/install-redis.sh status               # not installed, port 6379 free
modules/install-postgresql.sh status          # not installed, port 5432 free
modules/install-mailpit.sh status             # not installed (pinned v1.33.1), ports 1025/8025 free
modules/install-docker.sh status              # no Desktop integration, Docker Engine not installed
DRY_RUN=1 modules/install-docker.sh install   # prints the full installation approach, changes nothing, no network
DRY_RUN=1 modules/install-mailpit.sh install  # download URL, files, local-only addresses
modules/install-postgresql.sh guide           # roles, .env, backups
modules/install-mailpit.sh guide              # SMTP settings, php-mail, service commands
```

### In a fresh Ubuntu 24.04 test distro

Run `modules/install-base.sh install` first.

**Redis**
- [ ] `modules/install-redis.sh install`: **n** → exit 4; **y** → installed, `redis-cli ping -> PONG`, exit 0.
- [ ] `ss -ltn | grep 6379` shows only `127.0.0.1:6379` and `[::1]:6379`. Rerun `install` → exit 2.

**PostgreSQL**
- [ ] `modules/install-postgresql.sh install` (**y**) → cluster 16/main online, `pg_isready` on the
  socket and on 127.0.0.1, exit 0.
- [ ] `modules/install-postgresql.sh verify` in a terminal → `SELECT version()`,
  `listen_addresses = 'localhost'`, "TCP rules only for local addresses".
- [ ] `ss -ltn | grep 5432` shows only loopback addresses. Rerun `install` → exit 2.
- [ ] Follow `guide` to create a role and database, then `psql -h 127.0.0.1 -U myapp myapp -c 'select 1'`.

**Mailpit**
- [ ] `modules/install-mailpit.sh install` (**y**) → "Release checksum verified", the unit is
  installed, both checks pass (API version v1.33.1, SMTP `220 …`), exit 0.
- [ ] `head -1 /etc/systemd/system/mailpit.service` shows `# Managed by wsl-devtools`.
  `ss -ltn` shows `127.0.0.1:1025` and `127.0.0.1:8025` only.
- [ ] `modules/install-mailpit.sh test` → "arrived (0 -> 1 messages)". Open `http://localhost:8025`
  in a Windows browser and see the message.
- [ ] After `modules/install-php.sh install 8.4`: `modules/install-mailpit.sh php-mail` (**y**) →
  drop-ins for 8.4 cli and fpm. Then `php -r 'mail("a@example.test","Hi","From PHP");'` appears in
  the UI. Rerun `php-mail` → exit 2.
- [ ] Rerun `install` → exit 2.

**Docker**
- [ ] `modules/install-docker.sh install` shows the approach (repository, fingerprint, files,
  `daemon.json`, group question) before the prompt. **n** → exit 4, nothing created.
- [ ] **y** → "Signing key fingerprint verified", packages installed, `docker` and `containerd`
  active. Then the docker-group question: answer **y**.
- [ ] `cat /etc/docker/daemon.json` → `{"ip": "127.0.0.1"}`. `verify` → "Docker server … answers
  (sudo docker info)".
- [ ] Close all WSL terminals (or `wsl.exe --terminate <distro>`), reopen: `docker info` works
  without sudo; `modules/install-docker.sh test-run` (**y**) → "containers work".
- [ ] `docker run -d -p 8080:80 nginx` then `ss -ltn | grep 8080` → `127.0.0.1:8080` only;
  `http://localhost:8080` opens from Windows. Clean up with `docker rm -f <id>`.
- [ ] Rerun `install` → exit 2.
- [ ] With Docker Desktop's WSL integration turned on for a distro, `install` in that distro →
  "Docker Desktop's WSL integration is active", exit 3, nothing changed.

## 9. Phase 7 checks

### On the development machine (read-only)

```bash
scripts/install-all.sh --help
DRY_RUN=1 scripts/install-all.sh --modules core,mariadb,redis   # plans only; summary: already installed / planned (dry run)
scripts/install-all.sh --modules mariadb,mysql                  # exit 3: cannot be installed together
scripts/install-menu.sh                                         # 12 -> 1 (status), 12 -> 2 (verify table), 13
```

Expected on the development machine: in the verify table, base, nginx, composer, nodejs and
mariadb PASS. php FAILs because of the missing 7.4/8.4 extensions recorded under Phase 3, and the
tools that are not installed FAIL too. Do **not** answer **y** to an install prompt here.

Ctrl+C is covered by `tests/test-orchestrator.sh`. To see it yourself, in a terminal:
- [ ] `scripts/install-all.sh`, Ctrl+C at "Install which modules?" → "Interrupted. Nothing was
  changed.", exit 130.
- [ ] `scripts/install-menu.sh` → 3 (PHP menu), Ctrl+C → "Interrupted. Back to the menu."; Ctrl+C
  again at the main menu → "Interrupted. Leaving the menu.", exit 130.

### In a fresh Ubuntu 24.04 test distro

- [ ] `scripts/install-all.sh`: the project information, the environment checks and the list of 11
  modules. Answer `core mariadb`, then PHP `1`, then **y**. Each module asks its own question:
  answer **y**. Expected: every module "installed and verified", the verification table all PASS,
  exit 0, and a log in `logs/install-all-*.log`.
- [ ] Rerun with `--modules core,mariadb`: every module "already installed", all PASS, exit 0.
- [ ] In a new distro, `scripts/install-all.sh --modules base,php,composer`, answer **n** at PHP's
  package question: php "cancelled", composer "not run: needs php", exit 3.
- [ ] `scripts/install-all.sh --modules redis,mailpit,postgresql`: the optional tools only.
- [ ] Ctrl+C while a module is installing: that module is "interrupted", the rest "not run:
  interrupted", the `dpkg --configure -a` hint is shown, exit 130. A rerun completes the work.
- [ ] `scripts/install-menu.sh`: open each of the 13 entries; 12 → 2 shows PASS for the installed
  tools.

## 10. Phase 8: quality assurance

### QA matrix

Results on the development machine, 2026-11-19 (Ubuntu 24.04.5, WSL2, systemd degraded but usable).

| # | Area | How it is tested | Result here |
|---|---|---|---|
| 1 | Bash syntax | `bash -n` on every script and config | Pass |
| 2 | ShellCheck | `shellcheck -x` and `shellcheck config/*.conf` (§1), ShellCheck 0.9.0 | Pass: no output (218 + 37 findings before, see progress.md) |
| 3 | Individual modules | `test-live` (status/verify/install × 11), module suites | Pass |
| 4 | Full workflow | `test-orchestrator` (stubs), `DRY_RUN=1 install-all`; real run in the distro (below) | Pass / distro pending |
| 5 | Menu navigation | `test-orchestrator` (piped and pty), `test-live` (real modules) | Pass |
| 6 | Existing packages | `test-live`: base, nginx, composer, mariadb `install` → 2 | Pass |
| 7 | Repeated execution | `test-live`: two rounds, same results, snapshot identical | Pass |
| 8 | Missing dependencies | `test-qa` | Pass |
| 9 | Invalid input | `test-common`, `test-web`, `test-node`, `test-db`, `test-orchestrator`, `test-qa` (`DRY_RUN`) | Pass |
| 10 | Failed installations | `test-qa` (update/install failure, removal guard, unavailable, verify after install) | Pass |
| 11 | systemd unavailable | `test-qa` (fake `systemctl`); a real distro without systemd (below) | Pass / distro pending |
| 12 | PHP multi-version | `test-live` (7.4 and 8.4 side by side, FPM per version), `test-web`, dry run of both | Pass |
| 13 | PHP CLI switching | `test-web` (set-default 3/4/2, unchanged), `test-live` (alternative ↔ `php -v`); real switch in the distro | Pass / distro pending |
| 14 | Nginx ↔ PHP-FPM | `test-web` (template, conflicts), `test-live` (sockets, `curl`); `nginx -t` needs your password | Pass / `nginx -t` by you |
| 15 | NVM and Node switching | `test-node`, `test-live` (new shell, use, set-default) | Pass |
| 16 | Database coexistence | `test-db`, `test-live` (ping, loopback, other flavour → 3), `test-qa` (removal guard) | Pass |
| 17 | Optional modules | `test-optional`, `test-live`, `test-qa` (no systemd) | Pass (not installed here) |
| 18 | Errors and interruption | `test-orchestrator` (Ctrl+C), `test-qa` | Pass |

### On the development machine (read-only, needs your password)

```bash
sudo nginx -t
for v in 7.4 8.4; do sudo php-fpm$v -t; done
bash tests/test-live.sh        # after "sudo -v", the nginx -t / php-fpm -t checks run too
```

### In a fresh Ubuntu 24.04 test distro

Areas that need real installs. Run `bash tests/test-live.sh` after each block; it must pass and
report the system unchanged.
- [ ] **Full workflow (4, 6, 7):** `scripts/install-all.sh`, choose `core mariadb`, PHP **3** (both),
  answer **y** to everything → all "installed and verified", exit 0. Run it again → all "already
  installed", exit 0.
- [ ] **PHP (12, 13):**
  - `php7.4 -v`, `php8.4 -v`, and `systemctl is-active php7.4-fpm php8.4-fpm`.
  - `modules/install-php.sh set-default 7.4` (**y**) → `php -v` shows 7.4. Switch back to 8.4.
  - Answer **n** → nothing changes.
- [ ] **Nginx ↔ FPM (14):**
  - `sudo mkdir -p /var/www/a/public /var/www/b/public`, then add an `index.php` to each with
    `<?php echo PHP_VERSION;`.
  - `scripts/nginx-site.sh create a.test /var/www/a/public 7.4` and `… b.test … 8.4`.
  - `curl -H 'Host: a.test' http://127.0.0.1` → 7.4.33; `b.test` → 8.4.x. Then `sudo nginx -t`.
- [ ] **NVM (15):**
  - in a new terminal: `command -v nvm`, `nvm --version`, `node --version`, `npm --version`;
  - `modules/install-nodejs.sh install-node 22`, then `use 22` → prints `nvm use 22`;
  - `set-default 22` (**y**) → a new terminal shows `node --version` v22.
- [ ] **Databases (16):** `modules/install-mysql.sh install` → exit 3, nothing changed;
  `systemctl is-active mariadb`; `ss -ltn | grep 3306` → 127.0.0.1 only.
- [ ] **Optional (17):** `scripts/install-all.sh --modules redis,postgresql,mailpit,docker`, then the
  Phase 6 checks (§8).
- [ ] **Failure (10):** disconnect the network (or set a wrong proxy), then `modules/install-redis.sh
  install` → exit 1 with "Refreshing package lists failed". Reconnect and rerun → it installs.
- [ ] **Interruption (18):** Ctrl+C during a PHP install → "interrupted", the dpkg hint. Run
  `sudo dpkg --configure -a` if apt says so, then rerun.
- [ ] **No systemd (11):** in a test distro with `systemd=false` in `/etc/wsl.conf` (set by you, in
  that distro only): `scripts/check-system.sh` → explains, exit 3; `install-all.sh` lists the
  service modules as unavailable; `modules/install-nginx.sh install` → 3. Nothing is changed.

## 11. Per-phase checklist template

Copy this into `docs/progress.md` for each phase:

- [ ] `bash -n` passes on all new or changed scripts
- [ ] `shellcheck` reports no issues
- [ ] `bash tests/test-*.sh` passes
- [ ] `status` on the development machine reports the existing setup correctly and changes nothing
- [ ] `install` in the test distro succeeds and `verify` passes
- [ ] A second `install` run changes nothing and reports "already installed" (exit 2)
- [ ] Failure cases print a clear message and a non-zero exit code

## 12. Final acceptance run (Phase 9)

This is the last check before the toolkit counts as verified: a real install in a brand-new
Ubuntu 24.04 distro, run by you. Each step links to the detailed checklist; tick the boxes there
and record the outcome in the results table below.

Rules for the whole run:
- Use a **disposable** distro, never the development machine.
- After each block, run `bash tests/test-live.sh`. It must pass (skips are fine) and report the
  system unchanged by its own checks.
- Keep the `logs/` directory until the results are recorded.

### Steps

1. **Create the distro** (from Windows):
   ```
   wsl --install -d Ubuntu-24.04 --name wsl-devtools-test
   ```
   Create your user, copy or clone the project into your Linux home directory, and `cd` into it.
   After a clone, run `chmod +x modules/*.sh scripts/*.sh`, because git stores the scripts as
   non-executable.
2. **System check:** `scripts/check-system.sh` → exit 0 (see [§4](#4-phase-2-checks)).
3. **Static checks and tests in the distro:** §1, then the suites in §2. Counts may differ from
   the development machine, because tests that depend on what is installed adapt or skip; none
   may fail.
4. **Full workflow:** the first three checkboxes of [§9](#9-phase-7-checks):
   - `scripts/install-all.sh`, choose `core mariadb`, PHP **3** (both), and answer **y** to every
     question → everything "installed and verified", exit 0;
   - rerun → everything "already installed", exit 0;
   - the cancelled-php case.
5. **Base, Nginx, PHP, sites, Xdebug, Composer:** the distro checklists in [§4](#4-phase-2-checks)
   and [§5](#5-phase-3-checks), including the CLI switch and the two sites on 7.4 and 8.4. Then
   `sudo nginx -t`.
6. **NVM and Node.js:** the distro checklist in [§6](#6-phase-4-checks), in a **new terminal**.
7. **MariaDB:** the MariaDB checklist in [§7](#7-phase-5-checks).
8. **Optional tools:** the [§8](#8-phase-6-checks) checklist for Redis, PostgreSQL, Mailpit and
   Docker.
9. **Failure cases:** the Failure (10) and Interruption (18) items in
   [§10](#10-phase-8-quality-assurance), and the Ctrl+C item in [§9](#9-phase-7-checks).
10. **No systemd:** the No systemd (11) item in [§10](#10-phase-8-quality-assurance). Do this in the
    test distro only, and last, because it needs `systemd=false` in that distro's `/etc/wsl.conf`
    (you make that change; the toolkit never does).
11. **MySQL:** in a **second** fresh distro, the MySQL checklist in [§7](#7-phase-5-checks).
12. **Menu:** `scripts/install-menu.sh`, open each of the 13 entries; 12 → 2 shows PASS for every
    installed tool.

When you are done, remove the test distros from Windows with `wsl --unregister <name>`.

### Results

Copy this table into your reply, or into `docs/progress.md` under Phase 9.

| Item | Value |
|---|---|
| Date | |
| `wsl.exe --version` (WSL, kernel) | |
| Ubuntu (`lsb_release -ds`) | |
| Architecture (`dpkg --print-architecture`) | |

| Step | Result (pass / fail / skipped) | Exit codes seen | Notes |
|---|---|---|---|
| 1 Create the distro | | | |
| 2 System check | | | |
| 3 Static checks and tests | | | |
| 4 Full workflow and rerun | | | |
| 5 Nginx, PHP, sites, Xdebug, Composer | | | |
| 6 NVM and Node.js | | | |
| 7 MariaDB | | | |
| 8 Optional tools | | | |
| 9 Failure and interruption | | | |
| 10 No systemd | | | |
| 11 MySQL (second distro) | | | |
| 12 Menu | | | |

### What to share for review

- The filled-in tables.
- For every failed step: the command, its full terminal output and its exit code.
- `logs/install-all-*.log` and `logs/install-menu-*.log` from the distro.
- The `tests/test-live.sh` summary lines.

Every failure is investigated first. Fixes are proposed separately and are made only after your
approval.
