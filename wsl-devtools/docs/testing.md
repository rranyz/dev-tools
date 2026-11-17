# Testing

How each part of the toolkit is checked. Run all commands from the project root
(`wsl-devtools/`).

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
for f in lib/*.sh tests/*.sh config/*.conf; do bash -n "$f" && echo "syntax ok: $f"; done
```

Lint with ShellCheck. This is a development-only dependency, install it once with
`sudo apt install shellcheck`:

```bash
shellcheck -x lib/*.sh tests/*.sh
shellcheck config/*.conf
```

Expected: no output and exit status 0.

## 2. Automated tests

```bash
bash tests/test-common.sh
```

Expected: one `ok` line per test, ending with `Passed: 58  Failed: 0` and exit status 0. A
failing test prints `FAIL` and the script exits with status 1.

`tests/test-common.sh` covers:

| Area | What is checked |
|---|---|
| Validation | `is_integer`, `is_valid_port`, `is_valid_version`, `is_valid_domain`, `is_one_of`, `is_supported_php_version`: valid and invalid input |
| Command checks | `command_exists`, `require_commands` with present and missing commands |
| Configuration | Both real config files load. Files with `$(...)`, backticks, bare commands, lowercase names, unquoted values or CRLF line endings are refused, and a marker file proves nothing in them ran |
| Running commands | `run` returns the command's status. `DRY_RUN=1` does not execute |
| Confirmation | `confirm` answers "no" without a terminal |
| Logging | `log_init` creates a log file and messages are written to it. Unsafe log names are refused |
| Error handling | Strict mode stops at the first failure, the ERR trap reports the failed command, `die` exits with the given code |

The tests only create a temporary directory with `mktemp -d` and remove it on exit.

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

## 4. Per-phase checklist template

Copy this into `docs/progress.md` for each phase:

- [ ] `bash -n` passes on all new or changed scripts
- [ ] `shellcheck` reports no issues
- [ ] `bash tests/test-*.sh` passes
- [ ] `status` on the development machine reports the existing setup correctly and changes nothing
- [ ] `install` in the test distro succeeds and `verify` passes
- [ ] A second `install` run changes nothing and reports "skipped"
- [ ] Failure cases print a clear message and a non-zero exit code
