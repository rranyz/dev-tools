#!/usr/bin/env bash
# modules/install-nodejs.sh: Node.js through the official NVM (https://github.com/nvm-sh/nvm).
#
# Usage: install-nodejs.sh                         interactive menu (in a terminal)
#        install-nodejs.sh status                  NVM, ~/.bashrc, Node.js versions (read-only)
#        install-nodejs.sh install                 NVM + ~/.bashrc block + NODE_DEFAULT_VERSION
#        install-nodejs.sh install-nvm             NVM (pinned NVM_VERSION) + ~/.bashrc block
#        install-nodejs.sh install-node <ver>      e.g. lts, 22, 22.11.0, lts/jod
#        install-nodejs.sh list                    installed Node.js versions
#        install-nodejs.sh list-remote [lts|all|<major>]   versions available at nodejs.org
#        install-nodejs.sh use <ver>               check a version and print the "nvm use" command
#        install-nodejs.sh set-default <ver>       version for every new shell (asks first)
#        install-nodejs.sh update                  move NVM to the pinned NVM_VERSION (asks first)
#        install-nodejs.sh verify                  nvm, node and npm, here and in a new shell
#        install-nodejs.sh fix-bashrc              repair broken "[-s" NVM lines (asks first)
#
# Everything is per user: no sudo, and only ~/.nvm and ~/.bashrc are changed.
# Exit codes: 0 ok, 1 failed, 2 already installed / nothing to do, 3 precondition not met,
#             4 cancelled.

MODULE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=../lib/common.sh
source "${MODULE_DIR}/../lib/common.sh"
# shellcheck source=../lib/system.sh
source "${MODULE_DIR}/../lib/system.sh"
# shellcheck source=../lib/packages.sh
source "${MODULE_DIR}/../lib/packages.sh"
# shellcheck source=../lib/node.sh
source "${MODULE_DIR}/../lib/node.sh"

SELF="${MODULE_DIR}/install-nodejs.sh"
SCRIPT_NAME="install-nodejs.sh"
NODE_TMP_DIR=""
PINNED_COMMIT=""
MENU_VERSION=""

usage() {
    printf 'Usage: %s [status | install | install-nvm | install-node <ver> | list | list-remote [lts|all|<major>]\n' "$SCRIPT_NAME"
    printf '        | use <ver> | set-default <ver> | update | verify | fix-bashrc | menu]\n'
    printf 'Versions: lts, lts/<codename>, 22, 22.11.0, v22.11.0\n'
}

cleanup() {
    if [[ -n "$NODE_TMP_DIR" ]]; then
        rm -rf -- "$NODE_TMP_DIR"
    fi
}

# ---------------------------------------------------------------------------
# Checks
# ---------------------------------------------------------------------------

# NVM needs neither sudo nor systemd, so the shared preflight (which requires sudo) is not used.
node_preflight() {
    log_step "Checking the system"
    if ! { check_not_root && check_os && check_wsl2; }; then
        return 3
    fi
    if ! require_commands git curl sha256sum; then
        log_error "Install the base tools first: modules/install-base.sh install"
        return 3
    fi
}

# Print NVM_DIR from the environment when it points somewhere other than ~/.nvm.
other_nvm_dir() {
    if [[ -n "${NVM_DIR:-}" && "${NVM_DIR%/}" != "$NVM_HOME" ]]; then
        echo "$NVM_DIR"
    fi
}

# Exit 3 with a clear message unless a Node.js version string is valid.
require_valid_node_version() {
    if ! is_valid_node_version "${1:-}"; then
        log_error "'${1:-}' is not a Node.js version. Examples: lts, lts/jod, 22, 22.11.0, v22.11.0."
        exit 3
    fi
}

load_nvm_or_exit() {
    if ! nvm_load; then
        log_error "NVM is not installed in ${NVM_HOME}. Install it first: ${SCRIPT_NAME} install-nvm"
        exit 3
    fi
}

# Resolve a version to an installed one (v22.20.0), or print nothing.
installed_match() {
    local resolved
    resolved="$(nvm_call version "$1" 2>/dev/null)" || return 0
    if [[ "$resolved" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] && node_version_is_installed "$resolved"; then
        echo "$resolved"
    fi
}

installed_list() {
    local list
    list="$(node_installed_versions | tr '\n' ' ')"
    echo "${list% }"
}

# "nvm use 22" / "nvm use 'lts/*'" as the user should type it.
nvm_use_command() {
    if [[ "$1" == *'*'* ]]; then
        printf "nvm use '%s'" "$1"
    else
        printf 'nvm use %s' "$1"
    fi
}

# ---------------------------------------------------------------------------
# status
# ---------------------------------------------------------------------------

bashrc_report() {
    local -a lines broken
    local n line

    if [[ ! -e "$BASHRC_FILE" ]]; then
        log_info "${BASHRC_FILE}: does not exist"
        return 0
    fi
    mapfile -t lines < <(bashrc_nvm_lines)
    if bashrc_has_toolkit_block; then
        log_info "${BASHRC_FILE}: wsl-devtools NVM block present"
    elif bashrc_has_nvm_init; then
        log_info "${BASHRC_FILE}: existing NVM lines ${lines[*]} (not managed by the toolkit, kept as they are)"
    else
        log_info "${BASHRC_FILE}: does not load NVM"
    fi
    mapfile -t broken < <(bashrc_broken_nvm_lines)
    for n in "${broken[@]}"; do
        line="$(sed -n "${n}p" "$BASHRC_FILE")"
        log_warn "${BASHRC_FILE} line ${n} is broken ('[-s' needs a space after '['): ${line}"
        log_warn "Fix it with: ${SCRIPT_NAME} fix-bashrc"
    done
    if [[ -e "${HOME}/.bash_profile" ]] && ! grep -q 'bashrc' "${HOME}/.bash_profile"; then
        log_warn "${HOME}/.bash_profile exists and does not load ~/.bashrc, so login shells will not have nvm."
    fi
}

node_status() {
    local version kind other default resolved

    log_step "Node.js / NVM: status"
    if version="$(nvm_installed_version)"; then
        kind="git checkout"
        nvm_is_git_checkout || kind="not a git checkout"
        # shellcheck disable=SC2153 # NVM_VERSION comes from config/versions.conf
        if version_lt "$version" "$NVM_VERSION"; then
            log_info "NVM: ${version} in ${NVM_HOME} (${kind}); pinned ${NVM_VERSION}, update available: ${SCRIPT_NAME} update"
        else
            log_info "NVM: ${version} in ${NVM_HOME} (${kind}); pinned ${NVM_VERSION}"
        fi
    else
        log_info "NVM: not installed in ${NVM_HOME} (pinned ${NVM_VERSION})"
    fi
    other="$(other_nvm_dir)"
    if [[ -n "$other" ]]; then
        log_warn "NVM_DIR is set to ${other}, not ${NVM_HOME}. This toolkit manages ${NVM_HOME} only."
    fi

    bashrc_report

    log_info "Node.js versions: $(installed_list | sed 's/^$/none/')"
    if default="$(nvm_default_alias)"; then
        resolved="-"
        if nvm_load; then
            resolved="$(installed_match default)"
        fi
        log_info "Default: ${default} (${resolved:-not installed})"
    else
        log_info "Default: not set"
    fi
    if nvm_load && command_exists node; then
        log_info "Active node after loading nvm: $(command -v node)"
    fi
    if is_package_installed nodejs; then
        log_warn "The apt package 'nodejs' $(package_version nodejs) is installed as well. NVM's node comes first on PATH once nvm is loaded; the toolkit does not remove it."
    fi
}

# ---------------------------------------------------------------------------
# NVM install and update
# ---------------------------------------------------------------------------

# Check the pinned tag exists upstream and remember its commit in PINNED_COMMIT.
# Returns 0, or 3 when it cannot be confirmed.
check_pinned_tag() {
    local rc=0

    if ! is_valid_nvm_tag "${NVM_VERSION:-}" || ! is_sha256 "${NVM_INSTALL_SCRIPT_SHA256:-}"; then
        log_error "config/versions.conf: NVM_VERSION must look like v0.41.0 and NVM_INSTALL_SCRIPT_SHA256 must be 64 lowercase hex characters."
        return 3
    fi
    PINNED_COMMIT="$(nvm_remote_tag_commit "$NVM_VERSION")" || rc=$?
    case "$rc" in
        0) ;;
        2)
            log_error "Tag ${NVM_VERSION} does not exist in ${NVM_REPO_URL}. Check NVM_VERSION in config/versions.conf."
            return 3
            ;;
        *)
            log_error "Could not reach ${NVM_REPO_URL} to check tag ${NVM_VERSION}. Check the network and try again."
            return 3
            ;;
    esac
    log_success "Tag ${NVM_VERSION} exists in ${NVM_REPO_URL} (commit ${PINNED_COMMIT:0:12})."
}

# Download, check and run the official install.sh for NVM_VERSION.
run_official_installer() {
    local script

    NODE_TMP_DIR="$(mktemp -d)"
    trap cleanup EXIT
    script="${NODE_TMP_DIR}/install.sh"
    log_info "Downloading ${NVM_INSTALL_SCRIPT_URL}/${NVM_VERSION}/install.sh"
    nvm_download_installer "$NVM_VERSION" "$script" "$NVM_INSTALL_SCRIPT_SHA256" || return 1
    log_success "Installer checksum verified (SHA-256)."
    if ! nvm_run_installer "$script"; then
        log_error "The NVM installer failed. See its messages above."
        return 1
    fi
}

# After installing or updating: the version must equal the pin, and HEAD the tag's commit.
check_nvm_matches_pin() {
    local version head

    if ! version="$(nvm_installed_version)"; then
        log_error "NVM is not usable in ${NVM_HOME} after the installer ran."
        return 1
    fi
    if [[ "$version" != "$NVM_VERSION" ]]; then
        log_error "NVM in ${NVM_HOME} is ${version}, expected ${NVM_VERSION}."
        return 1
    fi
    if [[ -n "$PINNED_COMMIT" ]] && nvm_is_git_checkout; then
        head="$(git -C "$NVM_HOME" rev-parse HEAD)"
        if [[ "$head" != "$PINNED_COMMIT" ]]; then
            log_error "${NVM_HOME} is at commit ${head}, but tag ${NVM_VERSION} is ${PINNED_COMMIT}."
            return 1
        fi
    fi
    log_success "NVM ${version} in ${NVM_HOME} (matches the tag's commit)."
}

# Install NVM when missing. Returns 0 (installed now, or planned in a dry run),
# 2 (already installed), 1, 3 or 4.
ensure_nvm() {
    local version other

    if version="$(nvm_installed_version)"; then
        log_success "NVM ${version} is already installed in ${NVM_HOME}."
        if version_lt "$version" "$NVM_VERSION"; then
            log_info "The pinned version is ${NVM_VERSION}. Nothing is changed here; to upgrade: ${SCRIPT_NAME} update"
        fi
        return 2
    fi
    other="$(other_nvm_dir)"
    if [[ -n "$other" ]]; then
        log_error "NVM_DIR is set to ${other}. This toolkit installs NVM in ${NVM_HOME} only."
        log_error "Remove or change that NVM_DIR setting yourself first (the toolkit does not)."
        return 3
    fi
    if [[ -e "$NVM_HOME" ]] && [[ ! -d "$NVM_HOME" || -n "$(ls -A "$NVM_HOME")" ]]; then
        log_error "${NVM_HOME} exists but has no usable nvm.sh. It is left alone: move it away yourself, then rerun."
        return 3
    fi

    log_step "NVM: install ${NVM_VERSION}"
    check_pinned_tag || return $?
    log_info "Installer: ${NVM_INSTALL_SCRIPT_URL}/${NVM_VERSION}/install.sh (official, SHA-256 checked before it runs)"
    log_info "Target: ${NVM_HOME} (git checkout of ${NVM_REPO_URL}). The installer does not touch ~/.bashrc."
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] Would download install.sh, check its SHA-256 and run:"
        log_info "[dry-run]   NVM_DIR=${NVM_HOME} METHOD=git PROFILE=/dev/null bash install.sh"
        return 0
    fi
    if ! confirm "Download and run the official NVM ${NVM_VERSION} installer into ${NVM_HOME}?"; then
        log_warn "Cancelled. Nothing was changed."
        return 4
    fi
    run_official_installer || return 1
    check_nvm_matches_pin || return 1
}

# Add the toolkit's NVM block to ~/.bashrc unless the file already loads nvm.sh.
# Returns 0 (added, or planned in a dry run), 2 (already set up), 1 or 4.
ensure_bashrc_block() {
    local backup="" syntax_ok_before=0

    if bashrc_has_nvm_init; then
        log_success "${BASHRC_FILE} already loads NVM. Not changed."
        return 2
    fi
    log_step "${BASHRC_FILE}: NVM block"
    log_info "These lines will be appended:"
    nvm_block_text | sed 's/^/    /'
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] Would back up ${BASHRC_FILE} and append the block."
        return 0
    fi
    if ! confirm "Append the NVM block to ${BASHRC_FILE} (a backup is made first)?"; then
        log_warn "Cancelled. ${BASHRC_FILE} was not changed."
        return 4
    fi
    if [[ -e "$BASHRC_FILE" ]]; then
        bash -n "$BASHRC_FILE" 2>/dev/null && syntax_ok_before=1
        backup="$(bashrc_backup "$BASHRC_FILE")" || return 1
        log_success "Backup: ${backup}"
    fi
    bashrc_append_nvm_block "$BASHRC_FILE" || return 1
    if (( syntax_ok_before )) && ! bash -n "$BASHRC_FILE"; then
        log_error "${BASHRC_FILE} has a syntax error after the change. Restore it with: cp -p '${backup}' '${BASHRC_FILE}'"
        return 1
    fi
    log_success "NVM block added to ${BASHRC_FILE}."
    log_info "Open a new terminal, or run in this one: source ~/.bashrc"
}

# Steps shared by install-nvm and install. Exits on failure or cancel.
# Sets NVM_STEP_RC and BASHRC_STEP_RC to 0 (changed) or 2 (nothing to do).
NVM_STEP_RC=0
BASHRC_STEP_RC=0
install_nvm_steps() {
    NVM_STEP_RC=0
    BASHRC_STEP_RC=0
    ensure_nvm || NVM_STEP_RC=$?
    is_one_of "$NVM_STEP_RC" 0 2 || exit "$NVM_STEP_RC"
    ensure_bashrc_block || BASHRC_STEP_RC=$?
    is_one_of "$BASHRC_STEP_RC" 0 2 || exit "$BASHRC_STEP_RC"
}

node_install_nvm() {
    node_preflight || exit 3
    install_nvm_steps
    [[ "${DRY_RUN:-0}" == "1" ]] && return 0
    verify_nvm || exit 1
    verify_new_shell nvm-only || exit 1
    if (( NVM_STEP_RC == 2 && BASHRC_STEP_RC == 2 )); then
        log_success "NVM: nothing to do."
        exit 2
    fi
    log_success "NVM is ready. Next: ${SCRIPT_NAME} install-node lts"
}

node_update() {
    local version latest

    node_preflight || exit 3
    if ! version="$(nvm_installed_version)"; then
        log_error "NVM is not installed in ${NVM_HOME}. Install it first: ${SCRIPT_NAME} install-nvm"
        exit 3
    fi
    log_step "NVM: update"
    log_info "Installed: ${version}. Pinned in config/versions.conf: ${NVM_VERSION}."
    latest="$(nvm_latest_remote_tag)" || latest=""
    if [[ -n "$latest" ]] && version_lt "$NVM_VERSION" "$latest"; then
        log_info "Upstream has a newer release, ${latest}. To use it, change NVM_VERSION and"
        log_info "NVM_INSTALL_SCRIPT_SHA256 in config/versions.conf (see the comment there)."
    fi
    if [[ "$version" == "$NVM_VERSION" ]]; then
        log_success "NVM is already at the pinned version. Nothing to do."
        exit 2
    fi
    if version_lt "$NVM_VERSION" "$version"; then
        log_success "Installed ${version} is newer than the pin. It is not downgraded."
        exit 2
    fi
    if ! nvm_is_git_checkout; then
        log_error "${NVM_HOME} is not a git checkout, so it cannot be updated in place safely."
        log_error "Move it away yourself and run ${SCRIPT_NAME} install-nvm (Node versions would need reinstalling)."
        exit 3
    fi
    if nvm_has_local_changes; then
        log_error "NVM's own files in ${NVM_HOME} have local changes, and the installer would discard them."
        log_error "Nothing was changed. Review them with: git -C ${NVM_HOME} status"
        exit 3
    fi
    check_pinned_tag || exit $?
    log_info "Plan: rerun the official ${NVM_VERSION} installer. It fetches the tag into ${NVM_HOME} and checks it out."
    log_info "Installed Node.js versions, aliases and ~/.bashrc are kept."
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] Would download install.sh, check its SHA-256 and run it as for install-nvm."
        return 0
    fi
    if ! confirm "Update NVM from ${version} to ${NVM_VERSION}?"; then
        log_warn "Cancelled. Nothing was changed."
        exit 4
    fi
    run_official_installer || exit 1
    check_nvm_matches_pin || exit 1
    verify_nvm || exit 1
    log_success "NVM updated to ${NVM_VERSION}. Open a new terminal to use it."
}

# ---------------------------------------------------------------------------
# Node.js versions
# ---------------------------------------------------------------------------

# Run node and npm of one installed version, in this process.
verify_node_version() {
    local version="$1" node_version npm_version

    if ! nvm_call use --silent "$version" >/dev/null; then
        log_error "nvm use ${version} failed."
        return 1
    fi
    if ! node_version="$(node --version 2>&1)"; then
        log_error "node ${version} does not run: ${node_version}"
        return 1
    fi
    if ! npm_version="$(npm --version 2>&1)"; then
        log_error "npm of Node.js ${version} does not run: ${npm_version}"
        return 1
    fi
    log_success "Node.js ${node_version}, npm ${npm_version} ($(command -v node))"
}

# Install one Node.js version. Returns 0 (installed now, or planned in a dry run),
# 2 (already installed), 1, 3 or 4.
ensure_node() {
    local version resolved default

    version="$(normalize_node_version "$1")"
    log_step "Node.js ${version}: install"
    resolved="$(nvm_call version-remote "$version")" || resolved=""
    if [[ ! "$resolved" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        log_error "Node.js '${version}' was not found at nodejs.org, or nodejs.org could not be reached."
        log_error "See what exists with: ${SCRIPT_NAME} list-remote"
        return 3
    fi
    if node_version_is_installed "$resolved"; then
        log_success "Node.js ${resolved} ('${version}') is already installed."
        return 2
    fi
    log_info "Plan: download Node.js ${resolved} from nodejs.org into ${NVM_HOME}/versions/node/ (nvm checks its SHA-256)."
    if default="$(nvm_default_alias)"; then
        log_info "The default version (${default}) is not changed."
    else
        log_info "No default version is set yet, so nvm will make ${resolved} the default."
    fi
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] Would run: nvm install ${resolved}"
        return 0
    fi
    if ! confirm "Install Node.js ${resolved}?"; then
        log_warn "Cancelled. Nothing was changed."
        return 4
    fi
    if ! nvm_call install "$resolved"; then
        log_error "nvm install ${resolved} failed. See its messages above."
        return 1
    fi
    verify_node_version "$resolved" || return 1
}

node_install_node() {
    local rc=0

    require_valid_node_version "${1:-}"
    node_preflight || exit 3
    load_nvm_or_exit
    ensure_node "$1" || rc=$?
    exit "$rc"
}

# install: what install-all.sh runs. NVM, the ~/.bashrc block and NODE_DEFAULT_VERSION.
node_install() {
    local node_rc=0

    if ! is_valid_node_version "${NODE_DEFAULT_VERSION:-}"; then
        log_error "config/versions.conf: NODE_DEFAULT_VERSION '${NODE_DEFAULT_VERSION:-}' is not a valid version."
        exit 3
    fi
    node_preflight || exit 3
    install_nvm_steps
    if [[ "${DRY_RUN:-0}" == "1" ]] && (( NVM_STEP_RC == 0 )); then
        log_info "[dry-run] Then: install Node.js ${NODE_DEFAULT_VERSION} and verify."
        return 0
    fi
    load_nvm_or_exit
    ensure_node "$NODE_DEFAULT_VERSION" || node_rc=$?
    is_one_of "$node_rc" 0 2 || exit "$node_rc"
    [[ "${DRY_RUN:-0}" == "1" ]] && return 0
    node_verify || exit 1
    if (( NVM_STEP_RC == 2 && BASHRC_STEP_RC == 2 && node_rc == 2 )); then
        log_success "Node.js / NVM: everything is already installed. Nothing to do."
        exit 2
    fi
    log_success "Node.js / NVM installed."
}

# nvm prints colour codes even into pipes and files; turn them off there.
nvm_color_flags() {
    [[ -t 1 ]] || echo "--no-colors"
}

node_list() {
    local default
    local -a colors

    load_nvm_or_exit
    log_step "Node.js: installed versions"
    if [[ -z "$(installed_list)" ]]; then
        log_info "No Node.js version is installed. Install one: ${SCRIPT_NAME} install-node lts"
        return 0
    fi
    read -r -a colors <<<"$(nvm_color_flags)"
    nvm_call ls --no-alias "${colors[@]}" || exit 1
    if default="$(nvm_default_alias)"; then
        log_info "default -> ${default} ($(installed_match default | sed 's/^$/not installed/'))"
    else
        log_info "No default version is set: ${SCRIPT_NAME} set-default <version>"
    fi
}

node_list_remote() {
    local filter="${1:-lts}"
    local -a colors

    load_nvm_or_exit
    read -r -a colors <<<"$(nvm_color_flags)"
    case "$filter" in
        lts)
            log_step "Node.js: LTS releases at nodejs.org"
            nvm_call ls-remote --lts "${colors[@]}" || exit 1
            ;;
        all)
            log_step "Node.js: all releases at nodejs.org"
            nvm_call ls-remote "${colors[@]}" || exit 1
            ;;
        *)
            if [[ ! "$filter" =~ ^v?[0-9]+$ ]]; then
                log_error "Show 'lts', 'all' or a major version like 22, not '${filter}'."
                exit 3
            fi
            log_step "Node.js ${filter}: releases at nodejs.org"
            nvm_call ls-remote "${colors[@]}" "$filter" || exit 1
            ;;
    esac
}

node_use() {
    local requested resolved

    require_valid_node_version "${1:-}"
    requested="$(normalize_node_version "$1")"
    require_not_root || exit 3
    load_nvm_or_exit
    resolved="$(installed_match "$requested")"
    if [[ -z "$resolved" ]]; then
        log_error "Node.js '${requested}' is not installed. Installed: $(installed_list | sed 's/^$/none/')"
        log_error "Install it with: ${SCRIPT_NAME} install-node ${requested}"
        exit 3
    fi
    log_step "Node.js ${requested}: switch"
    verify_node_version "$resolved" || exit 1
    log_info "A script cannot change the Node.js version of the shell that started it."
    log_info "Run this in your terminal:   $(nvm_use_command "$requested")"
    log_info "Per project: put '${requested}' in a .nvmrc file, then run 'nvm use' in that folder."
    log_info "For every new shell: ${SCRIPT_NAME} set-default ${requested}"
}

node_set_default() {
    local requested resolved current_alias current

    require_valid_node_version "${1:-}"
    requested="$(normalize_node_version "$1")"
    require_not_root || exit 3
    load_nvm_or_exit
    resolved="$(installed_match "$requested")"
    if [[ -z "$resolved" ]]; then
        log_error "Node.js '${requested}' is not installed. Installed: $(installed_list | sed 's/^$/none/')"
        exit 3
    fi
    current_alias="$(nvm_default_alias)" || current_alias=""
    current="$(installed_match default)"
    log_info "Current default: ${current_alias:-not set}${current:+ (${current})}"
    if [[ -n "$current" && "$current" == "$resolved" ]]; then
        log_success "Node.js ${resolved} is already the default. Nothing to do."
        exit 2
    fi
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] Would run: nvm alias default ${requested}"
        return 0
    fi
    if ! confirm "Make Node.js ${requested} (${resolved}) the default for every new shell?"; then
        log_warn "Cancelled. The default was not changed."
        exit 4
    fi
    if ! nvm_call alias default "$requested" >/dev/null; then
        log_error "nvm alias default ${requested} failed."
        exit 1
    fi
    log_success "Default set: ${requested} (${resolved})."
    verify_new_shell || exit 1
}

# ---------------------------------------------------------------------------
# verify
# ---------------------------------------------------------------------------

# nvm itself, in this process.
verify_nvm() {
    local version

    log_step "NVM: verify"
    if ! nvm_load; then
        log_error "nvm could not be loaded from ${NVM_HOME}/nvm.sh."
        return 1
    fi
    # nvm is a shell function, so "command -v nvm" prints its name, not a path.
    log_success "command -v nvm: $(command -v nvm) (shell function from ${NVM_HOME}/nvm.sh)"
    if ! version="$(nvm_call --version)"; then
        log_error "nvm --version failed."
        return 1
    fi
    log_success "nvm --version: ${version}"
}

# The default node and npm, in this process (nvm.sh activated the default when it loaded).
verify_default_node() {
    local path node_version npm_version

    log_step "Node.js: verify default version"
    if ! path="$(command -v node)"; then
        log_error "No node command: no default version is active. Set one: ${SCRIPT_NAME} set-default <version>"
        return 1
    fi
    if [[ "$path" != "${NVM_HOME}/versions/node/"* ]]; then
        log_error "node is ${path}, not a version from ${NVM_HOME}. Set a default: ${SCRIPT_NAME} set-default <version>"
        return 1
    fi
    if ! node_version="$(node --version 2>&1)" || ! npm_version="$(npm --version 2>&1)"; then
        log_error "node or npm at ${path} does not run."
        return 1
    fi
    log_success "node --version: ${node_version} (${path})"
    log_success "npm --version: ${npm_version}"
}

# The same checks in a brand-new interactive bash, which proves ~/.bashrc loads NVM.
# Usage: verify_new_shell [nvm-only]
verify_new_shell() {
    local scope="${1:-all}" err_file output nvm_name nvm_version node_version npm_version failed=0

    log_step "New shell: verify (bash -i reading ${BASHRC_FILE})"
    err_file="$(mktemp)"
    output="$(new_shell_check "$err_file")" || true
    nvm_name="$(shell_check_value "$output" nvm)"
    nvm_version="$(shell_check_value "$output" nvm_version)"
    node_version="$(shell_check_value "$output" node)"
    npm_version="$(shell_check_value "$output" npm)"

    if [[ "$nvm_name" == "nvm" && -n "$nvm_version" ]]; then
        log_success "new shell: command -v nvm -> nvm, nvm --version -> ${nvm_version}"
    else
        log_error "new shell: nvm is not available. ${BASHRC_FILE} does not load ${NVM_HOME}/nvm.sh."
        failed=1
    fi
    if [[ "$scope" != "nvm-only" ]]; then
        if [[ -n "$node_version" && -n "$npm_version" ]]; then
            log_success "new shell: node --version -> ${node_version}, npm --version -> ${npm_version}"
        else
            log_error "new shell: node/npm not available. Set a default: ${SCRIPT_NAME} set-default <version>"
            failed=1
        fi
    fi
    if (( failed )) && [[ -s "$err_file" ]]; then
        log_info "The new shell's error output was:"
        sed 's/^/    /' "$err_file"
    fi
    rm -f -- "$err_file"
    return "$failed"
}

node_verify() {
    local failed=0

    require_not_root || return 1
    if verify_nvm; then
        verify_default_node || failed=1
    else
        failed=1
    fi
    verify_new_shell || failed=1
    if [[ -n "$(bashrc_broken_nvm_lines)" ]]; then
        log_warn "${BASHRC_FILE} has broken NVM lines (see '${SCRIPT_NAME} status'). Fix: ${SCRIPT_NAME} fix-bashrc"
    fi
    return "$failed"
}

# ---------------------------------------------------------------------------
# fix-bashrc
# ---------------------------------------------------------------------------

node_fix_bashrc() {
    local -a broken
    local n line backup

    require_not_root || exit 3
    mapfile -t broken < <(bashrc_broken_nvm_lines)
    if (( ${#broken[@]} == 0 )); then
        log_success "No broken NVM lines in ${BASHRC_FILE}. Nothing to do."
        exit 2
    fi
    log_step "${BASHRC_FILE}: fix broken NVM lines"
    for n in "${broken[@]}"; do
        line="$(sed -n "${n}p" "$BASHRC_FILE")"
        log_info "line ${n}"
        printf '    before: %s\n    after:  %s\n' "$line" "$(bashrc_fixed_line "$line")"
    done
    if [[ "${DRY_RUN:-0}" == "1" ]]; then
        log_info "[dry-run] Would back up ${BASHRC_FILE} and change only the line(s) above."
        return 0
    fi
    if ! confirm "Fix ${#broken[@]} line(s) in ${BASHRC_FILE} (a backup is made first)?"; then
        log_warn "Cancelled. ${BASHRC_FILE} was not changed."
        exit 4
    fi
    backup="$(bashrc_backup "$BASHRC_FILE")" || exit 1
    log_success "Backup: ${backup}"
    bashrc_fix_broken_lines "$BASHRC_FILE" "${broken[@]}" || exit 1
    if ! bash -n "$BASHRC_FILE" || [[ -n "$(bashrc_broken_nvm_lines)" ]]; then
        log_error "The fix did not work. Restore with: cp -p '${backup}' '${BASHRC_FILE}'"
        exit 1
    fi
    log_success "Fixed. New shells no longer print '[-s: command not found'."
}

# ---------------------------------------------------------------------------
# menu
# ---------------------------------------------------------------------------

# Run an action of this module as a child process and report how it ended.
menu_run() {
    local rc=0
    bash "$SELF" "$@" || rc=$?
    log_info "Result: $(exit_code_meaning "$rc")"
}

# Ask for a Node.js version until the input is valid; sets MENU_VERSION.
# Empty input (or end of input) returns 1, back to the menu.
ask_node_version() {
    local prompt="$1" answer
    MENU_VERSION=""
    while true; do
        read -r -p "${prompt} (empty = back): " answer || return 1
        [[ -n "$answer" ]] || return 1
        if is_valid_node_version "$answer"; then
            MENU_VERSION="$answer"
            return 0
        fi
        log_warn "'${answer}' is not a Node.js version. Examples: lts, lts/jod, 22, 22.11.0, v22.11.0."
    done
}

ask_remote_filter() {
    local answer
    while true; do
        read -r -p "Show l) LTS releases, a) all releases, or a major version like 22 (empty = back): " answer || return 1
        case "$answer" in
            "") return 1 ;;
            l | L) MENU_VERSION="lts"; return 0 ;;
            a | A) MENU_VERSION="all"; return 0 ;;
            *)
                if [[ "$answer" =~ ^v?[0-9]+$ ]]; then
                    MENU_VERSION="$answer"
                    return 0
                fi
                log_warn "Please enter l, a or a major version number."
                ;;
        esac
    done
}

node_menu() {
    local choice
    while true; do
        printf '\nNode.js menu (official NVM)\n'
        printf '   1) Install NVM\n'
        printf '   2) Install Node.js LTS\n'
        printf '   3) Install a specific Node.js version\n'
        printf '   4) List installed versions\n'
        printf '   5) List available versions\n'
        printf '   6) Switch Node.js version\n'
        printf '   7) Set default version\n'
        printf '   8) Update NVM\n'
        printf '   9) Verify installation\n'
        printf '  10) Back to main menu\n'
        read -r -p "Choose 1-10: " choice || return 0
        case "$choice" in
            1) menu_run install-nvm ;;
            2) menu_run install-node lts ;;
            3) ask_node_version "Node.js version to install, e.g. 22, 22.11.0, lts/jod" && menu_run install-node "$MENU_VERSION" ;;
            4) menu_run list ;;
            5) ask_remote_filter && menu_run list-remote "$MENU_VERSION" ;;
            6)
                printf 'Installed: %s\n' "$(installed_list | sed 's/^$/none/')"
                ask_node_version "Switch to which version" && menu_run use "$MENU_VERSION"
                ;;
            7)
                printf 'Installed: %s\n' "$(installed_list | sed 's/^$/none/')"
                ask_node_version "Make which version the default" && menu_run set-default "$MENU_VERSION"
                ;;
            8) menu_run update ;;
            9) menu_run verify ;;
            10) return 0 ;;
            *) log_warn "Please enter a number from 1 to 10." ;;
        esac
    done
}

main() {
    local action

    enable_strict_mode
    load_project_config || exit 3

    action="${1:-}"
    if (( $# > 0 )); then
        shift
    fi
    if [[ -z "$action" ]]; then
        if [[ -t 0 ]]; then
            action="menu"
        else
            usage
            exit 3
        fi
    fi

    case "$action" in
        status) node_status ;;
        install) node_install ;;
        install-nvm) node_install_nvm ;;
        install-node) node_install_node "${1:-}" ;;
        list) node_list ;;
        list-remote) node_list_remote "${1:-lts}" ;;
        use) node_use "${1:-}" ;;
        set-default) node_set_default "${1:-}" ;;
        update) node_update ;;
        verify) node_verify || exit 1 ;;
        fix-bashrc) node_fix_bashrc ;;
        menu) node_menu ;;
        *)
            usage
            exit 3
            ;;
    esac
}

if [[ "${BASH_SOURCE[0]}" == "$0" ]]; then
    main "$@"
fi
