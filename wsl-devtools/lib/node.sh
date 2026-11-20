# shellcheck shell=bash
# lib/node.sh: helpers for NVM (github.com/nvm-sh/nvm) and Node.js. Everything here is per
# user and never uses sudo.
#
# Requires lib/common.sh to be sourced first. Functions that read ~/.bashrc or ~/.nvm take an
# optional path so tests can use fixtures.
#
# NVM is a shell function loaded from nvm.sh, not an executable. It does not work under
# strict mode (set -euo pipefail plus the ERR trap), so it is only called through nvm_call.

if [[ -n "${WSL_DEVTOOLS_NODE_LOADED:-}" ]]; then
    return 0
fi
WSL_DEVTOOLS_NODE_LOADED=1

NVM_HOME="${HOME}/.nvm"            # the toolkit installs NVM here and nowhere else
BASHRC_FILE="${HOME}/.bashrc"
NVM_BLOCK_BEGIN="# >>> wsl-devtools: nvm >>>"
NVM_BLOCK_END="# <<< wsl-devtools: nvm <<<"
# PATH for the "new shell" check: system directories only, so nothing leaks from this process.
CLEAN_SHELL_PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# sed expression that repairs "[-s " (missing space after "[") in NVM lines.
_BASHRC_FIX_SED='s/\[-s\([[:space:]]\)/[ -s\1/g'

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

# A Node.js version as accepted by this toolkit: 22, 22.11, 22.11.0, v22.11.0, lts, lts/*,
# lts/<codename>. Anything else (paths, spaces, shell characters) is refused.
is_valid_node_version() {
    local version="${1:-}"
    [[ "$version" =~ ^v?[0-9]+(\.[0-9]+){0,2}$ || "$version" =~ ^lts/(\*|[a-z]+)$ || "$version" == "lts" ]]
}

# "lts" is shorthand for nvm's "lts/*" (the newest LTS line).
normalize_node_version() {
    if [[ "${1:-}" == "lts" ]]; then
        echo 'lts/*'
    else
        echo "${1:-}"
    fi
}

# An NVM release tag, e.g. v0.41.0.
is_valid_nvm_tag() {
    [[ "${1:-}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

is_sha256() {
    [[ "${1:-}" =~ ^[0-9a-f]{64}$ ]]
}

# True when version $1 sorts before $2 (v0.39.1 < v0.41.0).
version_lt() {
    local first
    [[ "${1:-}" != "${2:-}" ]] || return 1
    first="$(printf '%s\n%s\n' "$1" "$2" | sort -V | head -n 1)"
    [[ "$first" == "$1" ]]
}

# ---------------------------------------------------------------------------
# Calling NVM safely from strict-mode scripts
# ---------------------------------------------------------------------------

# Run a command with strict mode paused, then restore exactly the options and ERR trap the
# caller had. Returns the command's exit status.
_nvm_relaxed() {
    local rc=0 had_errexit=0 had_nounset=0 had_pipefail=0 saved_trap
    [[ $- == *e* ]] && had_errexit=1
    [[ $- == *u* ]] && had_nounset=1
    shopt -qo pipefail && had_pipefail=1
    saved_trap="$(trap -p ERR)"

    set +e +u +o pipefail
    trap - ERR
    "$@"
    rc=$?

    if (( had_pipefail )); then set -o pipefail; fi
    if (( had_nounset )); then set -u; fi
    if (( had_errexit )); then set -e; fi
    if [[ -n "$saved_trap" ]]; then eval "$saved_trap"; fi
    return "$rc"
}

# Usage: nvm_call ls     (like "nvm ls", safe under strict mode)
nvm_call() {
    _nvm_relaxed nvm "$@"
}

_source_nvm_sh() {
    # shellcheck source=/dev/null
    source "${NVM_HOME}/nvm.sh"
}

# Load nvm.sh from ~/.nvm into this shell. Like a new terminal, this also activates the
# default Node.js version. Returns 1 when NVM is not installed or does not load.
nvm_load() {
    if command_exists nvm && [[ "${NVM_DIR:-}" == "$NVM_HOME" ]]; then
        return 0
    fi
    [[ -s "${NVM_HOME}/nvm.sh" ]] || return 1
    export NVM_DIR="$NVM_HOME"
    # nvm.sh can return non-zero when the default alias points at a missing version; that is
    # reported by verify. What matters here is whether the nvm function now exists.
    _nvm_relaxed _source_nvm_sh || true
    command_exists nvm
}

# ---------------------------------------------------------------------------
# The NVM installation in ~/.nvm (read-only)
# ---------------------------------------------------------------------------

nvm_is_git_checkout() {
    [[ -d "${1:-$NVM_HOME}/.git" ]]
}

# Print the installed NVM version as a tag (v0.41.0). Returns 1 when NVM is not installed.
# Uses the exact git tag when there is one, else the version in NVM's package.json.
nvm_installed_version() {
    local dir="${1:-$NVM_HOME}" version=""
    [[ -s "${dir}/nvm.sh" ]] || return 1
    if nvm_is_git_checkout "$dir"; then
        version="$(git -C "$dir" describe --tags --exact-match 2>/dev/null)" || version=""
    fi
    if ! is_valid_nvm_tag "$version" && [[ -r "${dir}/package.json" ]]; then
        version="$(sed -n 's/^[[:space:]]*"version":[[:space:]]*"\([0-9][0-9.]*\)".*/v\1/p' "${dir}/package.json" | head -n 1)"
    fi
    is_valid_nvm_tag "$version" || return 1
    echo "$version"
}

# True when tracked NVM files were changed locally. The official installer runs
# "git checkout -f", which would throw such changes away.
nvm_has_local_changes() {
    local dir="${1:-$NVM_HOME}" changes
    changes="$(git -C "$dir" status --porcelain --untracked-files=no)" || return 0
    [[ -n "$changes" ]]
}

# Installed Node.js versions (v22.11.0 ...), oldest first, read from ~/.nvm/versions/node.
node_installed_versions() {
    local dir="${1:-$NVM_HOME}/versions/node" path
    local -a found=()
    [[ -d "$dir" ]] || return 0
    for path in "$dir"/v*; do
        if [[ -x "${path}/bin/node" ]]; then
            found+=("${path##*/}")
        fi
    done
    (( ${#found[@]} > 0 )) || return 0
    printf '%s\n' "${found[@]}" | sort -V
}

node_version_is_installed() {
    [[ -x "${2:-$NVM_HOME}/versions/node/${1:-}/bin/node" ]]
}

# The text of the "default" alias (e.g. 18 or lts/*). Returns 1 when none is set.
nvm_default_alias() {
    local file="${1:-$NVM_HOME}/alias/default"
    [[ -s "$file" ]] || return 1
    head -n 1 "$file"
}

# ---------------------------------------------------------------------------
# The official repository and installer (network)
# ---------------------------------------------------------------------------

# Print the commit a tag points to in NVM_REPO_URL.
# Returns 1 when the repository cannot be reached, 2 when the tag does not exist.
nvm_remote_tag_commit() {
    local tag="$1" output sha ref commit=""
    output="$(GIT_TERMINAL_PROMPT=0 git -c http.lowSpeedLimit=1000 -c http.lowSpeedTime=20 \
        ls-remote --tags "${NVM_REPO_URL}.git" "refs/tags/${tag}" "refs/tags/${tag}^{}")" || return 1
    # An annotated tag is listed twice: the tag object, and the commit it points to (^{}).
    while read -r sha ref; do
        if [[ "$ref" == "refs/tags/${tag}^{}" ]]; then
            commit="$sha"
            break
        fi
        [[ "$ref" == "refs/tags/${tag}" ]] && commit="$sha"
    done <<<"$output"
    [[ -n "$commit" ]] || return 2
    echo "$commit"
}

# Print the newest vX.Y.Z tag in NVM_REPO_URL. Informational only: the toolkit installs the pin.
nvm_latest_remote_tag() {
    local tags
    tags="$(GIT_TERMINAL_PROMPT=0 git ls-remote --tags --refs "${NVM_REPO_URL}.git")" || return 1
    awk -F'refs/tags/' '$2 ~ /^v[0-9]+\.[0-9]+\.[0-9]+$/ {print $2}' <<<"$tags" | sort -V | tail -n 1
}

# Download NVM's install.sh for a tag to a file and check it against the expected SHA-256.
# Usage: nvm_download_installer <tag> <destination> <sha256>
nvm_download_installer() {
    local tag="$1" destination="$2" expected="$3"
    if ! download_checked "${NVM_INSTALL_SCRIPT_URL}/${tag}/install.sh" "$destination" "$expected"; then
        log_error "Nothing was run. If the download is fine, NVM_INSTALL_SCRIPT_SHA256 does not belong to ${tag}."
        return 1
    fi
}

# Run a downloaded, checked install.sh. The environment is pinned so it installs into
# ~/.nvm with git, from the official repository, without touching any profile file and
# without installing Node.js.
nvm_run_installer() {
    run env -u XDG_CONFIG_HOME -u NODE_VERSION -u NVM_SOURCE -u NVM_INSTALL_GITHUB_REPO \
        -u NVM_INSTALL_VERSION NVM_DIR="$NVM_HOME" METHOD=git PROFILE=/dev/null bash "$1"
}

# ---------------------------------------------------------------------------
# ~/.bashrc
# ---------------------------------------------------------------------------

# Line numbers of active (not commented-out) lines that mention nvm.sh or NVM_DIR.
bashrc_nvm_lines() {
    local file="${1:-$BASHRC_FILE}"
    [[ -r "$file" ]] || return 0
    awk '/^[[:space:]]*#/ {next} /nvm\.sh|NVM_DIR/ {print NR}' "$file"
}

# True when an active line loads nvm.sh: the toolkit block, or lines from NVM's own installer
# or from the user. Either way no second block is added.
bashrc_has_nvm_init() {
    local file="${1:-$BASHRC_FILE}"
    [[ -r "$file" ]] || return 1
    awk '/^[[:space:]]*#/ {next} /nvm\.sh/ {found=1} END {exit !found}' "$file"
}

bashrc_has_toolkit_block() {
    local file="${1:-$BASHRC_FILE}"
    [[ -r "$file" ]] && grep -qxF "$NVM_BLOCK_BEGIN" "$file" && grep -qxF "$NVM_BLOCK_END" "$file"
}

# Line numbers of active NVM lines with "[-s" (missing space), which bash runs as a command
# named "[-s" and reports "command not found" in every new shell.
bashrc_broken_nvm_lines() {
    local file="${1:-$BASHRC_FILE}"
    [[ -r "$file" ]] || return 0
    awk '/^[[:space:]]*#/ {next} /NVM_DIR|nvm\.sh/ && /(^|[[:space:];&|(])\[-s[[:space:]]/ {print NR}' "$file"
}

# Print a line as bashrc_fix_broken_lines would write it.
bashrc_fixed_line() {
    sed "$_BASHRC_FIX_SED" <<<"$1"
}

# Copy a file to <file>.wsl-devtools-<timestamp>[-N].bak and print the backup path.
# Never overwrites an existing backup.
bashrc_backup() {
    local file="$1" base backup n=1
    base="${file}.wsl-devtools-$(date '+%Y%m%d-%H%M%S')"
    backup="${base}.bak"
    while [[ -e "$backup" ]]; do
        backup="${base}-${n}.bak"
        n=$((n + 1))
    done
    cp -p -- "$file" "$backup" || return 1
    echo "$backup"
}

# The block is literal shell text for ~/.bashrc: $HOME and $NVM_DIR expand when it is read.
# shellcheck disable=SC2016
nvm_block_text() {
    printf '%s\n' \
        "$NVM_BLOCK_BEGIN" \
        'export NVM_DIR="$HOME/.nvm"' \
        '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"' \
        '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"' \
        "$NVM_BLOCK_END"
}

# Append the toolkit's NVM block. Returns 2 (nothing done) when the file already loads nvm.sh.
# Callers make the backup and ask first.
bashrc_append_nvm_block() {
    local file="${1:-$BASHRC_FILE}"
    if bashrc_has_nvm_init "$file"; then
        return 2
    fi
    # Start on a new line if the file does not end with one.
    if [[ -s "$file" && -n "$(tail -c 1 "$file")" ]]; then
        printf '\n' >>"$file" || return 1
    fi
    { printf '\n'; nvm_block_text; } >>"$file"
}

# Repair "[-s" on the given line numbers only. --follow-symlinks keeps a symlinked
# ~/.bashrc (dotfile managers) a symlink.
# Usage: bashrc_fix_broken_lines <file> <line>...
bashrc_fix_broken_lines() {
    local file="$1" line
    local -a expressions=()
    shift
    for line in "$@"; do
        is_integer "$line" || return 2
        expressions+=(-e "${line}${_BASHRC_FIX_SED}")
    done
    (( ${#expressions[@]} > 0 )) || return 0
    sed -i --follow-symlinks "${expressions[@]}" "$file"
}

# ---------------------------------------------------------------------------
# New-shell check
# ---------------------------------------------------------------------------

# Start a new interactive bash with a clean environment (so nothing from this process, such
# as PATH or NVM_DIR, leaks in). It reads ~/.bashrc like a new terminal would. Prints
# "@nvm=", "@nvm_version=", "@node=", "@npm=" lines; values are empty when a check failed.
# The shell's stderr (for example "no job control") goes to the file named in $1.
new_shell_check() {
    local err_file="$1"
    # shellcheck disable=SC2016 # expanded by the new shell, not here
    local script='printf "@nvm=%s\n" "$(command -v nvm)"
printf "@nvm_version=%s\n" "$(nvm --version 2>/dev/null)"
printf "@node=%s\n" "$(node --version 2>/dev/null)"
printf "@npm=%s\n" "$(npm --version 2>/dev/null)"'
    env -i HOME="$HOME" USER="${USER:-$(id -un)}" LOGNAME="${LOGNAME:-$(id -un)}" TERM=dumb \
        PATH="$CLEAN_SHELL_PATH" timeout 60 bash -ic "$script" </dev/null 2>"$err_file"
}

# Print one value from new_shell_check output. Usage: shell_check_value <output> <key>
shell_check_value() {
    sed -n "s/^@${2}=//p" <<<"$1" | tail -n 1
}
