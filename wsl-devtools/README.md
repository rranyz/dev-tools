# wsl-devtools

Modular Bash scripts for setting up a PHP and Node.js web development environment on
**Ubuntu 24.04 under WSL2 (with systemd)**.

Covered tools:
- **Core:** Nginx, PHP 8.4 and 7.4 (with PHP-FPM and Xdebug), Composer, Node.js via the official NVM, MariaDB or MySQL, git, curl, wget, zip, unzip
- **Optional:** Redis, PostgreSQL, Mailpit, phpMyAdmin, Docker Engine

> **Status:** under development, built phase by phase. Phase 1 (foundation) is complete.
> Nothing can be installed yet. See [docs/progress.md](docs/progress.md).

## Safety principles

- The scripts check what is already installed before changing anything, and are safe to rerun.
- They never remove packages, PHP versions or databases, and never overwrite existing configuration files.
- They never change Windows settings, `/etc/wsl.conf` or firewall rules.
- Risky actions ask for confirmation. Without an interactive terminal the answer is "no".

## Layout

| Path | Purpose |
|---|---|
| `config/` | Pinned versions (`versions.conf`) and apt package lists (`packages.conf`) |
| `lib/` | Shared helpers: messages, logging, error handling, checks, validation, config loading |
| `modules/` | One installer per tool (from Phase 2) |
| `scripts/` | Entry points: `install-all.sh`, `install-menu.sh` (later phases) |
| `templates/` | Config templates, such as the Nginx site template (later phases) |
| `tests/` | Automated tests |
| `logs/` | Run logs (not committed) |
| `docs/` | Architecture, implementation plan, progress and testing |

## Checks

```bash
bash -n lib/common.sh tests/test-common.sh   # syntax
shellcheck lib/common.sh tests/test-common.sh  # lint (sudo apt install shellcheck)
bash tests/test-common.sh                     # tests, no system changes
```

## Documentation

- [Architecture](docs/architecture.md)
- [Implementation plan](docs/implementation-plan.md)
- [Progress](docs/progress.md)
- [Testing](docs/testing.md)
