# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

**WSL2 Web Development Setup**

## 1. Project Overview

You are assisting me in developing a modular Bash-based installation toolkit for setting up a web development environment inside Ubuntu on WSL2.

The project must be simple, readable, modular, maintainable, and safe.

Your responsibility is to act as a senior Bash developer, technical reviewer, and implementation assistant.

I am developing this project phase by phase. Do not generate the entire project at once.

## 2. Development Environment

- Operating system: Windows 11
- Linux environment: Ubuntu on WSL2
- Shell: Bash
- Service manager: systemd
- AI development assistant: Claude Code

Do not modify Windows settings or `/etc/wsl.conf` without my explicit approval.

## 3. Project Objectives

Build two main installation scripts:

1. `scripts/install-all.sh`
   - Install selected tools in the correct dependency order.
   - Coordinate independent installation modules.
   - Display progress and installation results.
   - Handle failures and report errors.
   - Verify installed tools.

2. `scripts/install-menu.sh`
   - Display an interactive installation menu.
   - Allow installation of individual modules.
   - Allow users to check installation status.
   - Provide clear navigation and error messages.

Keep installation logic inside independent modules. Main scripts should primarily orchestrate those modules.

## 4. Required Technologies

### Core tools

- Nginx
- PHP 7.4.33
- PHP 8.4
- PHP-FPM
- Composer
- Node.js through official NVM
- MySQL
- MariaDB
- Git
- curl
- wget
- zip
- unzip

### Optional tools

- Redis
- Docker
- Mailpit
- PostgreSQL

## 5. PHP Requirements

Use Ondřej Surý's PHP PPA.

Before adding it:
- Check whether the PPA is already configured.
- Check whether the required Ubuntu version is supported.
- Verify package availability.
- Do not assume the available PHP 7.4 package is exactly upstream version 7.4.33.
- Explain any package-version limitations.

Support:
- Installing PHP 7.4 and PHP 8.4 independently.
- Installing both versions side by side.
- Version-specific PHP extensions.
- Separate PHP-FPM services and sockets.
- Selecting the default PHP CLI version using update-alternatives.
- Configuring Nginx to use the selected PHP-FPM socket per website.
- Installing and verifying Xdebug.

Never:
- Automatically remove an existing PHP version.
- Automatically change the default PHP CLI version.
- Overwrite existing Nginx configuration files.
- Reload Nginx without successful configuration validation.

Warn users that PHP 7.4 is end-of-life and should only be used when legacy compatibility requires it.

## 6. Node.js and NVM Requirements

Use ONLY the official repository:

https://github.com/nvm-sh/nvm

Requirements:
- Dedicated module: `modules/install-nodejs.sh`.
- Pin NVM version in `config/versions.conf`.
- Verify the chosen release exists before installation.
- Install NVM per Linux user under `~/.nvm`.
- Install Node.js LTS and specific versions.
- Support listing, switching, and setting the default Node.js version.
- Safely and idempotently configure `.bashrc`.
- Verify using `command -v nvm`, `nvm --version`, `node --version`, and `npm --version`.

Do not:
- Install Node.js through APT as the primary approach.
- Use nvm-windows.
- Use third-party Node.js version managers.
- Use sudo for NVM or npm operations.

Remember that NVM is a sourced Bash function, not a normal executable.

## 7. Database Requirements

Support MySQL and MariaDB as separate modules.

Before implementing simultaneous installation:
- Investigate package conflicts.
- Check service names.
- Check default ports.
- Check shared data directories and configuration paths.
- Propose a safe coexistence strategy.

Do not assume both database servers can safely operate simultaneously.

Never remove or modify an existing database installation without approval.

## 8. WSL2 and systemd Requirements

Detect:
- Whether the environment is WSL2.
- Ubuntu version.
- Whether systemd is available.
- Whether systemctl is functional.

Before performing service operations, verify systemd and systemctl.

If systemd is unavailable:
- Explain the issue.
- Stop service-dependent operations.
- Do not silently switch to manual service management.
- Do not modify WSL configuration without approval.

## 9. Docker Requirements

Detect existing Docker installations.

Distinguish:
- Docker Desktop with WSL integration.
- Native Docker Engine installed inside Ubuntu.

Do not install a duplicate Docker daemon without explaining the consequences and receiving approval.

## 10. Architecture and Coding Standards

- Use Bash.
- Follow readable and consistent Bash practices.
- Keep functions focused and small.
- Use meaningful variable and function names.
- Quote variables appropriately.
- Use strict error handling where suitable.
- Validate user input.
- Avoid unnecessary dependencies.
- Keep configuration separate from implementation.
- Make modules independently executable where practical.
- Make installation operations safe to repeat.
- Check existing installations before modifying the system.
- Do not hide errors or silently ignore failed commands.

Avoid overengineering. Prefer straightforward solutions that are easy to understand and maintain.

## 11. Safety Requirements

Before installing or modifying anything:
1. Check the current system state.
2. Check whether the software is already installed.
3. Check existing services and configurations.
4. Explain potentially destructive changes.
5. Ask for approval when a change could affect existing services, data, or configurations.

Never:
- Remove packages without approval.
- Delete databases or user data.
- Overwrite existing configuration files.
- Change Windows settings.
- Change `/etc/wsl.conf`.
- Modify firewall settings without approval.
- Expose local development services to external networks without approval.

## 12. Documentation Requirements

Maintain these files:

- `README.md`
- `docs/architecture.md`
- `docs/implementation-plan.md`
- `docs/progress.md`
- `docs/testing.md`

Update progress after each approved phase.

Document:
- What was implemented.
- Files created or modified.
- Technical decisions.
- Tests performed.
- Known issues.
- Remaining work.

## 13. Mandatory Phase-by-Phase Workflow

For every phase:

1. State the phase objective.
2. Inspect existing files and project state.
3. Identify files to create or modify.
4. Explain the implementation approach.
5. Implement only the approved phase.
6. Explain important code and functions.
7. Provide execution instructions.
8. Show expected output.
9. Provide a testing checklist.
10. Explain limitations and risks.
11. Update relevant documentation.
12. Report completion status.

Do not start the next phase until I explicitly approve it.

If requirements are unclear, ask questions before implementation.

Do not assume approval from my previous instructions.

## 14. Existing Project Inspection

Before creating or modifying files:
- Inspect the current project structure.
- Read existing documentation.
- Check existing scripts and configurations.
- Identify reusable code.
- Avoid duplicating existing functionality.
- Preserve working implementations unless a change is approved.

## 15. Final Development Goal

The final result must be a modular, maintainable, and safe Ubuntu WSL2 web development setup toolkit.

The user must be able to:
- Install all selected tools.
- Install individual tools.
- Select PHP versions.
- Manage Node.js versions through NVM.
- Check installation status.
- Verify services and configurations.
- Understand installation errors.
- Safely rerun installation scripts.

Always prioritize correctness, safety, readability, and maintainability over unnecessary complexity.

## 16. Repository Notes

- The git repository root is the parent directory `dev-tools/`, not `wsl-devtools/`; git commands act on the parent.
- Checks, run from `wsl-devtools/` (none of them change the system):
  - syntax: `for f in lib/*.sh modules/*.sh scripts/*.sh tests/*.sh config/*.conf; do bash -n "$f"; done`
  - lint: `shellcheck -x lib/*.sh modules/*.sh scripts/*.sh tests/*.sh` and `shellcheck config/*.conf` (development-only dependency; `.shellcheckrc` sets the source path and the SC2119 exception)
  - tests: `for t in tests/test-*.sh; do bash "$t" || break; done`, or one suite, e.g. `bash tests/test-node.sh`
- Real installs are tested by the user in a disposable Ubuntu 24.04 WSL distro; on the development machine only `status`, `verify` and `DRY_RUN=1` runs are used (see `docs/testing.md`).
