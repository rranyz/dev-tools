# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

The repository holds one project, `wsl-devtools/`: a modular Bash toolkit that sets up a PHP and Node.js web development stack on Ubuntu 24.04 under WSL2 with systemd. Its requirements, safety rules and phase workflow are in `wsl-devtools/CLAUDE.md`; read that file before changing anything.

## Commands

Run these from `wsl-devtools/`. None of them change the system.

- Syntax check: `for f in lib/*.sh modules/*.sh scripts/*.sh tests/*.sh config/*.conf; do bash -n "$f"; done`
- Lint: `shellcheck -x lib/*.sh modules/*.sh scripts/*.sh tests/*.sh && shellcheck config/*.conf` (`.shellcheckrc` sets the source path)
- All tests: `for t in tests/test-*.sh; do bash "$t" || break; done`
- One suite: `bash tests/test-node.sh`
- Read-only system check: `scripts/check-system.sh`

On this machine, use only `status`, `verify` and `DRY_RUN=1` runs. Real installs are tested in a disposable WSL distro (see `wsl-devtools/docs/testing.md`).

## Architecture

- `scripts/install-all.sh` and `scripts/install-menu.sh` only coordinate. They call the modules and do no installing themselves.
- `modules/install-<tool>.sh` holds all installation logic for one tool. Each module runs on its own with the subcommands `status | install | verify`.
- `lib/*.sh` holds shared helpers. `common.sh` has logging, the ERR trap, `run`/`confirm` and `DRY_RUN`. `services.sh` refuses service changes when systemd is missing. `orchestrator.sh` is the module registry: install order and dependencies are defined there.
- `config/versions.conf` and `config/packages.conf` hold pinned versions and package lists, so modules hard-code no versions.
- `templates/` holds the Nginx site and Mailpit unit templates.

Details are in `wsl-devtools/docs/architecture.md`, and project status is in `docs/progress.md`. The git root is `dev-tools/`.
