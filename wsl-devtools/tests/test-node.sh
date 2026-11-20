#!/usr/bin/env bash
# tests/test-node.sh: tests for lib/node.sh and modules/install-nodejs.sh.
#
# Makes no system changes. Helpers are tested with fixture files. Module tests run with a
# fake HOME (a stub ~/.nvm and ~/.bashrc), a fake "sudo" that records any use, and no
# terminal, so every confirmation is answered "no". The real ~/.bashrc and ~/.nvm are
# checked to be unchanged at the end. Module and live tests need Ubuntu 24.04 on WSL2;
# live tests also need the network and are skipped without it.
#
# Usage: bash tests/test-node.sh

set -uo pipefail

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "${TESTS_DIR}/.." && pwd)"
MODULE="${PROJECT_ROOT}/modules/install-nodejs.sh"

# shellcheck source=helpers.sh
source "${TESTS_DIR}/helpers.sh"
# shellcheck source=../lib/common.sh
source "${PROJECT_ROOT}/lib/common.sh"
# shellcheck source=../lib/system.sh
source "${PROJECT_ROOT}/lib/system.sh"
# shellcheck source=../lib/node.sh
source "${PROJECT_ROOT}/lib/node.sh"
load_project_config

# Fingerprints of the real files, compared at the end.
real_bashrc_sum="$( [[ -f "${HOME}/.bashrc" ]] && sha256_of "${HOME}/.bashrc" )"
real_nvm_head="$( [[ -d "${HOME}/.nvm/.git" ]] && git -C "${HOME}/.nvm" rev-parse HEAD 2>/dev/null )"

echo "Version validation"
for version in 22 22.11 22.11.0 v22.11.0 lts 'lts/*' lts/jod; do
    assert_ok "accepts '${version}'" is_valid_node_version "$version"
done
# shellcheck disable=SC2016 # '$(id)' is a literal input that must be refused
for version in '' '22;rm' '../x' latest node 'v1.2.3.4' 'lts/Jod' '22 ' 'v' '$(id)'; do
    assert_fail "refuses '${version}'" is_valid_node_version "$version"
done
assert_equals "lts is normalised to lts/*" 'lts/*' "$(normalize_node_version lts)"
assert_equals "22 is left as it is" '22' "$(normalize_node_version 22)"
assert_ok   "NVM tag v0.41.0 is valid"             is_valid_nvm_tag v0.41.0
assert_fail "NVM tag 0.41.0 (no v) is refused"     is_valid_nvm_tag 0.41.0
assert_fail "NVM tag master is refused"            is_valid_nvm_tag master
# shellcheck disable=SC2153 # NVM_VERSION comes from config/versions.conf
assert_ok   "configured NVM_VERSION is valid"      is_valid_nvm_tag "$NVM_VERSION"
assert_ok   "configured installer SHA-256 is valid" is_sha256 "$NVM_INSTALL_SCRIPT_SHA256"
assert_fail "short SHA-256 is refused"             is_sha256 abc123
assert_ok   "configured NODE_DEFAULT_VERSION is valid" is_valid_node_version "$NODE_DEFAULT_VERSION"
assert_ok   "v0.39.1 < v0.41.0"                    version_lt v0.39.1 v0.41.0
assert_ok   "v0.9.0 < v0.41.0 (not text order)"    version_lt v0.9.0 v0.41.0
assert_fail "v0.41.0 < v0.41.0 is false"           version_lt v0.41.0 v0.41.0
assert_fail "v0.41.0 < v0.39.1 is false"           version_lt v0.41.0 v0.39.1

echo ".bashrc detection"
rc_dir="${TMP_DIR}/bashrc"
mkdir -p "$rc_dir"
# shellcheck disable=SC2016 # literal shell text written into fixture files
{
    printf '# ~/.bashrc\nalias ll="ls -l"\n'
    printf 'export NVM_DIR="$HOME/.nvm"\n'
    printf '[ -s "$NVM_DIR/nvm.sh" ] && \\. "$NVM_DIR/nvm.sh"  # This loads nvm\n'
    printf '[-s "$NVM_DIR/bash_completion" ] && \\. "$NVM_DIR/bash_completion"\n'
} >"$rc_dir/official"
# shellcheck disable=SC2016
printf '# old setup\n# [ -s "$NVM_DIR/nvm.sh" ] && \\. "$NVM_DIR/nvm.sh"\nalias ll="ls -l"\n' >"$rc_dir/commented"
printf 'alias ll="ls -l"' >"$rc_dir/plain"     # no trailing newline on purpose
: >"$rc_dir/empty"
assert_ok   "official installer lines load nvm"   bashrc_has_nvm_init "$rc_dir/official"
assert_equals "official NVM lines found" "3 4 5" "$(bashrc_nvm_lines "$rc_dir/official" | tr '\n' ' ' | sed 's/ $//')"
assert_fail "commented-out lines do not count"    bashrc_has_nvm_init "$rc_dir/commented"
assert_fail "file without NVM lines"              bashrc_has_nvm_init "$rc_dir/plain"
assert_fail "missing file"                        bashrc_has_nvm_init "$rc_dir/does-not-exist"
assert_fail "official lines are not the toolkit block" bashrc_has_toolkit_block "$rc_dir/official"
assert_equals "broken '[-s' line found" "5" "$(bashrc_broken_nvm_lines "$rc_dir/official")"
assert_equals "no broken line in commented file" "" "$(bashrc_broken_nvm_lines "$rc_dir/commented")"
# shellcheck disable=SC2016
assert_equals "fixed line" '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"' \
    "$(bashrc_fixed_line '[-s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"')"

echo ".bashrc changes (fixture files)"
cp "$rc_dir/plain" "$rc_dir/append"
bashrc_append_nvm_block "$rc_dir/append"
assert_equals "block appended" "0" "$?"
assert_ok   "now loads nvm"                        bashrc_has_nvm_init "$rc_dir/append"
assert_ok   "toolkit block markers present"        bashrc_has_toolkit_block "$rc_dir/append"
assert_equals "original last line kept intact" 'alias ll="ls -l"' "$(sed -n 1p "$rc_dir/append")"
assert_ok   "file is valid bash"                   bash -n "$rc_dir/append"
before="$(sha256_of "$rc_dir/append")"
bashrc_append_nvm_block "$rc_dir/append"
assert_equals "second append -> 2 (nothing done)" "2" "$?"
assert_equals "second append changes nothing" "$before" "$(sha256_of "$rc_dir/append")"
assert_equals "exactly one block" "1" "$(grep -cxF "$NVM_BLOCK_BEGIN" "$rc_dir/append")"
cp "$rc_dir/official" "$rc_dir/official-copy"
bashrc_append_nvm_block "$rc_dir/official-copy"
assert_equals "no block added next to official lines -> 2" "2" "$?"
bashrc_append_nvm_block "$rc_dir/empty"
assert_ok   "block added to an empty file"         bashrc_has_toolkit_block "$rc_dir/empty"
backup="$(bashrc_backup "$rc_dir/official-copy")"
assert_ok   "backup created"                       test -f "$backup"
assert_ok   "backup has the same content"          cmp -s "$backup" "$rc_dir/official-copy"
backup2="$(bashrc_backup "$rc_dir/official-copy")"
assert_ok   "a second backup does not overwrite the first" test "$backup" != "$backup2" -a -f "$backup2"
bashrc_fix_broken_lines "$rc_dir/official-copy" 5
assert_equals "fix leaves no broken line" "" "$(bashrc_broken_nvm_lines "$rc_dir/official-copy")"
assert_equals "fix changed exactly one line" "1" \
    "$(diff "$rc_dir/official" "$rc_dir/official-copy" | grep -c '^>')"
assert_fail "fix refuses a non-number line"        bashrc_fix_broken_lines "$rc_dir/official-copy" '1;d'
ln -s "$rc_dir/official" "$rc_dir/link"
cp "$rc_dir/official" "$rc_dir/official-backup"
bashrc_fix_broken_lines "$rc_dir/link" 5
assert_ok   "symlinked .bashrc stays a symlink"   test -L "$rc_dir/link"
cp "$rc_dir/official-backup" "$rc_dir/official"

echo "Strict-mode bridge (nvm_call)"
bridge_output="$(
    set -Eeuo pipefail
    trap 'echo ERR-TRAP-FIRED' ERR
    # A stand-in for nvm: uses an unset variable and a failing pipe, then returns 7.
    # shellcheck disable=SC2317 # stub, called indirectly by nvm_call
    nvm() { local value="${UNSET_VARIABLE_FOR_TEST}"; false | true; return 7; }
    rc=0
    nvm_call || rc=$?
    # Read $- here: inside a nested $(...) bash clears errexit.
    flags="$-"
    printf 'rc=%s e=%s u=%s pipefail=%s trap=%s\n' "$rc" \
        "$([[ $flags == *e* ]] && echo on)" "$([[ $flags == *u* ]] && echo on)" \
        "$(shopt -qo pipefail && echo on)" "$(trap -p ERR | grep -c ERR-TRAP-FIRED)"
)"
assert_equals "nvm_call returns nvm's code and restores strict mode" \
    "rc=7 e=on u=on pipefail=on trap=1" "$bridge_output"
relaxed_output="$(
    set +e +u
    # shellcheck disable=SC2317 # stub, called indirectly by nvm_call
    nvm() { return 0; }
    nvm_call
    flags="$-"
    printf 'e=%s u=%s' "$([[ $flags == *e* ]] && echo on)" "$([[ $flags == *u* ]] && echo on)"
)"
assert_equals "nvm_call does not turn strict mode on when it was off" "e= u=" "$relaxed_output"

echo "Installer download and checksum (file:// fixture)"
mirror="${TMP_DIR}/mirror"
mkdir -p "$mirror/v0.0.1"
printf 'echo fake installer\n' >"$mirror/v0.0.1/install.sh"
fixture_sum="$(sha256_of "$mirror/v0.0.1/install.sh")"
saved_url="$NVM_INSTALL_SCRIPT_URL"
NVM_INSTALL_SCRIPT_URL="file://${mirror}"
assert_ok   "matching checksum is accepted"  nvm_download_installer v0.0.1 "${TMP_DIR}/dl1.sh" "$fixture_sum"
assert_fail "wrong checksum is refused"      nvm_download_installer v0.0.1 "${TMP_DIR}/dl2.sh" "$(printf '0%.0s' {1..64})"
assert_fail "missing tag is refused"         nvm_download_installer v9.9.9 "${TMP_DIR}/dl3.sh" "$fixture_sum"
NVM_INSTALL_SCRIPT_URL="$saved_url"

echo "Tag check (local git repository fixture)"
fixture_repo="${TMP_DIR}/nvm-fixture"
git init -q "${fixture_repo}.git"
git -C "${fixture_repo}.git" -c user.name=test -c user.email=test@example.invalid \
    commit -q --allow-empty -m init
git -C "${fixture_repo}.git" -c user.name=test -c user.email=test@example.invalid \
    tag -a v0.41.0 -m release
saved_repo="$NVM_REPO_URL"
NVM_REPO_URL="$fixture_repo"
assert_equals "annotated tag resolves to its commit" \
    "$(git -C "${fixture_repo}.git" rev-parse HEAD)" "$(nvm_remote_tag_commit v0.41.0)"
nvm_remote_tag_commit v9.9.9 >/dev/null
assert_equals "missing tag -> 2" "2" "$?"
assert_equals "newest tag" "v0.41.0" "$(nvm_latest_remote_tag)"
NVM_REPO_URL="${TMP_DIR}/no-such-repo"
nvm_remote_tag_commit v0.41.0 >/dev/null 2>&1
assert_equals "unreachable repository -> 1" "1" "$?"
NVM_REPO_URL="$saved_repo"

echo "Modules (fake HOME, fake sudo, no terminal)"
read_os_release >/dev/null 2>&1
if [[ "$(detect_wsl_version)" != "2" ]] || ! is_supported_ubuntu; then
    skip "module tests need Ubuntu ${SUPPORTED_UBUNTU_VERSION} on WSL2"
else
    fakebin="${TMP_DIR}/fakebin"
    mkdir -p "$fakebin"
    SUDO_MARKER="${TMP_DIR}/sudo-was-called"
    # Fake sudo: records any use at all. This module must never call sudo.
    printf '#!/usr/bin/env bash\ntouch "%s"\nexit 1\n' "$SUDO_MARKER" >"$fakebin/sudo"
    chmod +x "$fakebin/sudo"

    # A fake HOME with a stub NVM: v0.41.0 (from package.json, no .git), Node v18.0.0 and
    # v20.5.0 installed, default alias 18, and a ~/.bashrc that loads it.
    make_fake_home() {
        local home="$1" nvm_version="$2" version
        mkdir -p "$home/.nvm/alias"
        printf '{\n  "name": "nvm",\n  "version": "%s",\n}\n' "$nvm_version" >"$home/.nvm/package.json"
        for version in v18.0.0 v20.5.0; do
            mkdir -p "$home/.nvm/versions/node/$version/bin"
            printf '#!/bin/sh\necho %s\n' "$version" >"$home/.nvm/versions/node/$version/bin/node"
            printf '#!/bin/sh\necho 10.0.0\n' >"$home/.nvm/versions/node/$version/bin/npm"
            chmod +x "$home/.nvm/versions/node/$version/bin/node" "$home/.nvm/versions/node/$version/bin/npm"
        done
        echo 18 >"$home/.nvm/alias/default"
        # shellcheck disable=SC2016 # stub code, expanded when the stub runs
        cat >"$home/.nvm/nvm.sh" <<'STUB'
# Stub nvm for tests: just enough behaviour for the module's code paths.
_fake_resolve() {
    local want="$1" dir
    [ "$want" = default ] && want="$(cat "$NVM_DIR/alias/default" 2>/dev/null)"
    want="${want#v}"
    for dir in "$NVM_DIR"/versions/node/v"$want"*; do
        [ -d "$dir" ] && { basename "$dir"; return 0; }
    done
    echo N/A
    return 3
}
nvm() {
    local version
    case "$1" in
        --version) sed -n 's/.*"version": "\(.*\)".*/\1/p' "$NVM_DIR/package.json" ;;
        version) _fake_resolve "$2" ;;
        version-remote)
            case "$2" in
                22 | v22*) echo v22.9.0 ;;
                20 | v20*) echo v20.5.0 ;;
                'lts/*') echo v24.1.0 ;;
                *) echo N/A; return 3 ;;
            esac
            ;;
        use)
            shift
            [ "$1" = --silent ] && shift
            version="$(_fake_resolve "$1")" || return 3
            PATH="$NVM_DIR/versions/node/$version/bin:$PATH"
            ;;
        alias) printf '%s\n' "$3" >"$NVM_DIR/alias/default" ;;
        ls) ls "$NVM_DIR/versions/node" ;;
        install) touch "$NVM_DIR/install-was-called"; return 1 ;;
        *) return 1 ;;
    esac
}
nvm use --silent default >/dev/null 2>&1
STUB
        nvm_block_text >"$home/.bashrc"
    }

    fake_home="${TMP_DIR}/home"
    make_fake_home "$fake_home" 0.41.0
    fake_bashrc_sum="$(sha256_of "$fake_home/.bashrc")"
    run_module() {
        local home="$1"
        shift
        env -u NVM_DIR HOME="$home" PATH="${fakebin}:/usr/local/bin:/usr/bin:/bin" \
            DRY_RUN="${DRY_RUN:-0}" "$@" </dev/null >/dev/null 2>&1
    }
    expect_exit() {
        local description="$1" expected="$2" home="$3"
        shift 3
        run_module "$home" "$MODULE" "$@"
        assert_equals "$description" "$expected" "$?"
    }

    expect_exit "status -> 0"                              0 "$fake_home" status
    expect_exit "verify -> 0 (stub NVM, default 18)"       0 "$fake_home" verify
    expect_exit "list -> 0"                                0 "$fake_home" list
    expect_exit "unknown action -> 3"                      3 "$fake_home" bogus
    expect_exit "no action and no terminal -> 3"           3 "$fake_home"
    expect_exit "install-node 'x;y' -> 3"                  3 "$fake_home" install-node 'x;y'
    expect_exit "install-node without version -> 3"        3 "$fake_home" install-node
    expect_exit "install-node 99 (not at nodejs.org) -> 3" 3 "$fake_home" install-node 99
    expect_exit "install-node 20 (installed) -> 2"         2 "$fake_home" install-node 20
    expect_exit "install-node 22 (no terminal to confirm) -> 4" 4 "$fake_home" install-node 22
    assert_fail "nvm install was not called"               test -e "$fake_home/.nvm/install-was-called"
    DRY_RUN=1 expect_exit "DRY_RUN=1 install-node 22 -> 0" 0 "$fake_home" install-node 22
    assert_fail "dry run did not call nvm install"         test -e "$fake_home/.nvm/install-was-called"
    expect_exit "use 19 (not installed) -> 3"              3 "$fake_home" use 19
    expect_exit "use 20 -> 0"                              0 "$fake_home" use 20
    expect_exit "set-default 18 (current) -> 2"            2 "$fake_home" set-default 18
    expect_exit "set-default 20 (no terminal to confirm) -> 4" 4 "$fake_home" set-default 20
    expect_exit "set-default 19 (not installed) -> 3"      3 "$fake_home" set-default 19
    assert_equals "default alias unchanged" "18" "$(cat "$fake_home/.nvm/alias/default")"
    expect_exit "list-remote 'x;y' -> 3"                   3 "$fake_home" list-remote 'x;y'
    expect_exit "install-nvm (present, .bashrc set up) -> 2" 2 "$fake_home" install-nvm
    expect_exit "update (at the pin) -> 2"                 2 "$fake_home" update
    expect_exit "fix-bashrc (nothing broken) -> 2"         2 "$fake_home" fix-bashrc
    assert_equals "fake .bashrc unchanged" "$fake_bashrc_sum" "$(sha256_of "$fake_home/.bashrc")"

    # Broken .bashrc line: fix-bashrc asks (no terminal -> 4) and changes nothing.
    broken_home="${TMP_DIR}/home-broken"
    make_fake_home "$broken_home" 0.41.0
    cp "$rc_dir/official" "$broken_home/.bashrc"
    broken_sum="$(sha256_of "$broken_home/.bashrc")"
    expect_exit "fix-bashrc (broken line, no terminal) -> 4" 4 "$broken_home" fix-bashrc
    DRY_RUN=1 expect_exit "DRY_RUN=1 fix-bashrc -> 0"      0 "$broken_home" fix-bashrc
    assert_equals "broken .bashrc unchanged" "$broken_sum" "$(sha256_of "$broken_home/.bashrc")"
    assert_equals "no backup made" "0" "$(find "$broken_home" -maxdepth 1 -name '.bashrc.wsl-devtools-*' | wc -l)"

    # Older NVM that is not a git checkout: update refuses.
    old_home="${TMP_DIR}/home-old"
    make_fake_home "$old_home" 0.39.1
    expect_exit "update (older, not a git checkout) -> 3"  3 "$old_home" update

    # Empty HOME with a fixture config: the tag is checked against a local repository,
    # then there is no terminal to confirm.
    empty_home="${TMP_DIR}/home-empty"
    mkdir -p "$empty_home"
    config_fixture="${TMP_DIR}/config"
    mkdir -p "$config_fixture"
    cp "${PROJECT_ROOT}/config/packages.conf" "$config_fixture/"
    sed "s|^NVM_REPO_URL=.*|NVM_REPO_URL=\"${fixture_repo}\"|" \
        "${PROJECT_ROOT}/config/versions.conf" >"$config_fixture/versions.conf"
    WSL_DEVTOOLS_CONFIG_DIR="$config_fixture" expect_exit \
        "install-nvm (not installed, no terminal) -> 4"   4 "$empty_home" install-nvm
    assert_fail "the .nvm directory was not created"       test -e "$empty_home/.nvm"
    assert_fail "the .bashrc file was not created"         test -e "$empty_home/.bashrc"
    sed -i 's|^NVM_VERSION=.*|NVM_VERSION="v9.9.9"|' "$config_fixture/versions.conf"
    WSL_DEVTOOLS_CONFIG_DIR="$config_fixture" expect_exit \
        "install-nvm with a tag that does not exist -> 3" 3 "$empty_home" install-nvm
    expect_exit "use 20 without NVM -> 3"                  3 "$empty_home" use 20
    expect_exit "status without NVM -> 0"                  0 "$empty_home" status

    # A non-empty ~/.nvm without nvm.sh is left alone.
    junk_home="${TMP_DIR}/home-junk"
    mkdir -p "$junk_home/.nvm"
    touch "$junk_home/.nvm/something"
    expect_exit "install-nvm over a foreign ~/.nvm -> 3"   3 "$junk_home" install-nvm

    assert_fail "sudo was never called"                    test -e "$SUDO_MARKER"
fi

echo "Live, read-only (this machine)"
if [[ "$(detect_wsl_version)" != "2" ]] || ! is_supported_ubuntu; then
    skip "live tests need Ubuntu ${SUPPORTED_UBUNTU_VERSION} on WSL2"
else
    assert_ok "install-nodejs.sh status -> 0" env PATH="/usr/local/bin:/usr/bin:/bin" "$MODULE" status
    if GIT_TERMINAL_PROMPT=0 timeout 20 git ls-remote "${NVM_REPO_URL}.git" HEAD >/dev/null 2>&1; then
        assert_ok "pinned tag ${NVM_VERSION} exists upstream" nvm_remote_tag_commit "$NVM_VERSION"
        nvm_remote_tag_commit v9.9.9 >/dev/null 2>&1
        assert_equals "tag v9.9.9 does not exist upstream -> 2" "2" "$?"
        assert_ok "install.sh at ${NVM_VERSION} matches NVM_INSTALL_SCRIPT_SHA256" \
            nvm_download_installer "$NVM_VERSION" "${TMP_DIR}/install.sh" "$NVM_INSTALL_SCRIPT_SHA256"
    else
        skip "network checks (github.com not reachable)"
    fi
fi

echo "Real files untouched"
assert_equals "real ~/.bashrc unchanged" "$real_bashrc_sum" \
    "$( [[ -f "${HOME}/.bashrc" ]] && sha256_of "${HOME}/.bashrc" )"
assert_equals "real ~/.nvm HEAD unchanged" "$real_nvm_head" \
    "$( [[ -d "${HOME}/.nvm/.git" ]] && git -C "${HOME}/.nvm" rev-parse HEAD 2>/dev/null )"

finish
