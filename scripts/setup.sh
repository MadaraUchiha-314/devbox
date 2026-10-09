#!/usr/bin/env bash
#
# devbox setup — clone this laptop's settings and installations onto a machine (a
# remote cloud workspace, or a fresh laptop):
#
#     shell      zsh · oh-my-zsh · wget · curl · vim · build tools
#     node       nvm · node · npm · bun · yarn · pnpm
#     python     uv · python3 (+ pip, venv) · the-loop · poetry
#     system     go · gh · podman · shellcheck · ttyd
#     agents     claude · the-loop (claude plugin) · cursor
#
# and then configures it: ~/.vimrc and ~/.zshrc, a managed PATH/env block in ~/.zshrc,
# /workspace with the <host>/<org>/<repo> clone layout, and the startup commands
# (claude --upgrade, cursor --upgrade, keepalive).
#
# Tools are walked in dependency order and each one is detected before it is installed,
# so re-running this script is safe and boring.
#
#     scripts/setup.sh --dry-run     # show the plan, change nothing
#     scripts/setup.sh               # provision
#     scripts/setup.sh --only uv     # one tool
#
# System packages come from apt (Debian/Ubuntu) or Homebrew (macOS); everything else
# from the vendor's installer. For Arch, use scripts/setup-arch.sh — same steps, pacman.
# Generic devbox provisioning — no Intuit-specific steps; scripts/setup-intuit.sh layers
# those on top of this one.
#
# Sourcing this file (`. scripts/setup.sh`) defines clone_repo and the other helpers
# without provisioning anything.
#
# Written for bash 3.2 — the version macOS still ships as /bin/bash. No associative
# arrays, no mapfile, no ${var,,}.
#
# Spec: docs/specs/issue-2/  ·  Issue: #2

set -euo pipefail

# --- Pins -----------------------------------------------------------------------------
#
# Versions are pinned so a run is reproducible and a compromised "latest" cannot silently
# change what executes. To bump: read the vendor's latest release, change the value here,
# and check the tests still pass.
#
#   nvm       https://github.com/nvm-sh/nvm/releases
#   uv        https://github.com/astral-sh/uv/releases
#   bun       https://github.com/oven-sh/bun/releases
#   go        https://go.dev/dl/
#   ttyd      https://github.com/tsl0922/ttyd/releases
#   the-loop  https://pypi.org/project/the-loopy-one/ — a release can carry a config
#             migration, so an upgrade is a deliberate, reviewed commit, kept in step
#             with .the-loop/manifest.yaml.
#
# Honest caveat: bun.sh/install, the poetry, claude, cursor and oh-my-zsh installers are
# not themselves versioned. BUN_VERSION pins the bun that its installer installs; the
# rest install the vendor's current release. node is deliberately unpinned (--lts).

NVM_TAG="v0.40.6"
UV_VERSION="0.12.0"
BUN_VERSION="bun-v1.3.14"
GO_VERSION="1.22.5"
TTYD_VERSION="1.7.7"
THE_LOOP_VERSION="19.27.0"
PYTHON_VERSION="3.13"
PYTHON_MIN_MINOR=11

NVM_INSTALLER_URL="https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_TAG}/install.sh"
UV_INSTALLER_URL="https://astral.sh/uv/${UV_VERSION}/install.sh"
BUN_INSTALLER_URL="https://bun.sh/install"
POETRY_INSTALLER_URL="https://install.python-poetry.org"
CLAUDE_INSTALLER_URL="https://claude.ai/install.sh"
CURSOR_INSTALLER_URL="https://cursor.com/install"
OH_MY_ZSH_INSTALLER_URL="https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh"
GO_DOWNLOAD_URL="https://go.dev/dl"
TTYD_DOWNLOAD_URL="https://github.com/tsl0922/ttyd/releases/download/${TTYD_VERSION}"
GH_KEYRING_URL="https://cli.github.com/packages/githubcli-archive-keyring.gpg"

# Dependency order: nvm provides node, node brings npm (and corepack, for yarn/pnpm); uv
# provides python3 when the system has none, and installs the-loop; poetry's installer
# needs python3; the-loop's claude plugin needs claude.
TOOLS="zsh wget curl vim build-tools oh-my-zsh nvm node npm bun yarn pnpm uv python3 the-loop poetry go gh podman shellcheck ttyd claude the-loop-plugin cursor"

# Nice-to-haves: a failed install is reported in the summary and the run goes on, rather
# than aborting a provision that is otherwise fine.
OPTIONAL_TOOLS="yarn pnpm the-loop-plugin cursor"

readonly NVM_TAG UV_VERSION BUN_VERSION GO_VERSION TTYD_VERSION THE_LOOP_VERSION
readonly PYTHON_VERSION PYTHON_MIN_MINOR
readonly NVM_INSTALLER_URL UV_INSTALLER_URL BUN_INSTALLER_URL POETRY_INSTALLER_URL
readonly CLAUDE_INSTALLER_URL CURSOR_INSTALLER_URL OH_MY_ZSH_INSTALLER_URL
readonly GO_DOWNLOAD_URL TTYD_DOWNLOAD_URL GH_KEYRING_URL TOOLS OPTIONAL_TOOLS

# --- Environment ----------------------------------------------------------------------
#
# Where the vendors install to. Exported because their installers read these, and
# prepended to *this script's* PATH so a freshly installed tool can be verified — and
# used by the next tool — in the same run.

: "${HOME:?HOME is not set — this script installs into your home directory}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ZSHRC="${HOME}/.zshrc"
VIMRC="${HOME}/.vimrc"
WORKSPACE="${DEVBOX_WORKSPACE:-/workspace}"
# Overridable for one reason only: the test suite must not find the host's own go.
GO_ROOT="${DEVBOX_GO_ROOT:-/usr/local/go}"

export NVM_DIR="${NVM_DIR:-${HOME}/.nvm}"
export BUN_INSTALL="${BUN_INSTALL:-${HOME}/.bun}"
PATH="${HOME}/.local/bin:${BUN_INSTALL}/bin:${GO_ROOT}/bin:${HOME}/go/bin:${PATH}"

# Markers delimiting the block this script manages inside ~/.zshrc, so re-runs replace
# rather than duplicate. Shared with scripts/setup-arch.sh on purpose.
ZSHRC_BEGIN="# >>> devbox setup.sh managed block >>>"
ZSHRC_END="# <<< devbox setup.sh managed block <<<"

DRY_RUN=0
SELECTED="${TOOLS}"
SUMMARY=""
WORKDIR=""
INSTALLED_ANY=0
ZSHRC_BODY=""
APT_UPDATED=0

# --- Output ---------------------------------------------------------------------------

log() { printf '==> %s\n' "$*"; }
ok() { printf '  ✓ %s\n' "$*"; }
warn() { printf '  ! %s\n' "$*" >&2; }

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

usage() {
    printf '%s\n' \
        "Usage: scripts/setup.sh [--dry-run] [--only <tool>] [--help]" \
        "" \
        "Provision this devbox with: ${TOOLS}" \
        "then write ~/.vimrc, ~/.zshrc and its managed block, create /workspace and run the" \
        "startup commands." \
        "" \
        "  --dry-run        Print the planned action for every tool; change nothing." \
        "  --only <tool>    Act on one tool only (and refresh the ~/.zshrc block)." \
        "                   One of: ${TOOLS}" \
        "  --help           Print this usage and exit." \
        "" \
        "Exit codes: 0 success  1 runtime failure  2 usage error"
}

usage_error() {
    printf 'error: %s\n' "$*" >&2
    usage >&2
    exit 2
}

record() { SUMMARY="${SUMMARY}${1}|${2}|${3}"$'\n'; }

have() { command -v "$1" >/dev/null 2>&1; }

is_optional() {
    case " ${OPTIONAL_TOOLS} " in
        *" $1 "*) return 0 ;;
    esac
    return 1
}

# --- The privilege chokepoint ---------------------------------------------------------
#
# Every command this script runs with root privileges passes through here: system
# packages, /usr/local (go, ttyd), /workspace and the login shell. Nothing under $HOME
# ever does. As root (a cloud container) it runs the command directly.

maybe_sudo() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif have sudo; then
        sudo "$@"
    else
        die "need root to run: $* (no sudo on PATH)"
    fi
}

# --- Temp directory -------------------------------------------------------------------
#
# Created lazily, so --dry-run really does touch nothing. mktemp -d gives a fresh
# 0700 directory owned by this user, which is what stops a pre-planted symlink in a
# shared /tmp from being followed.

cleanup() {
    if [ -n "${WORKDIR}" ] && [ -d "${WORKDIR}" ]; then
        rm -rf "${WORKDIR}"
    fi
}

ensure_workdir() {
    if [ -z "${WORKDIR}" ]; then
        WORKDIR="$(mktemp -d)"
    fi
}

# --- The network chokepoint -----------------------------------------------------------
#
# Every byte of third-party code this script downloads passes through `fetch`, so the
# hardening lives in exactly one place:
#
#   --fail          a 404's HTML body is an error, not a shell script to execute
#   --proto         the request itself may only be HTTPS
#   --proto-redir   ...and so may every hop it is redirected through. --proto alone
#                   does NOT cover redirects; curl's default allows http there, and
#                   these installer URLs (astral.sh especially) ARE redirectors.
#   -o then run     the download COMPLETES before anything runs, so a dropped
#                   connection cannot execute half an installer — no `curl | sh`
#   "${BASH}"       the interpreter already running this script, not whatever a
#                   poisoned PATH resolves `bash` to

# fetch <url> <name> — download into the private temp dir; prints the local path.
fetch() {
    local url="$1" name="$2" dest
    ensure_workdir
    dest="${WORKDIR}/${name}"
    log "downloading ${url}" >&2
    # Explicit `|| return`: callers run this in $(...), where bash does not carry
    # `set -e`, so a failed download would otherwise still hand back a path to run.
    curl --fail --location --proto '=https' --proto-redir '=https' --tlsv1.2 \
        --silent --show-error "${url}" -o "${dest}" >&2 || return 1
    printf '%s' "${dest}"
}

fetch_and_run() {
    local url="$1"
    shift
    local installer
    installer="$(fetch "${url}" installer.sh)" || die "download failed: ${url}"

    log "running installer from ${installer}"
    "${BASH}" "${installer}" "$@"
}

# --- System packages ------------------------------------------------------------------
#
# apt on Debian/Ubuntu, Homebrew on macOS. `apt-get update` runs at most once per run.

apt_update_once() {
    if [ "${APT_UPDATED}" -eq 0 ]; then
        log "apt-get update"
        maybe_sudo apt-get update -y
        APT_UPDATED=1
    fi
}

# system_install <apt-package...> [-- <brew-package...>]
#   Without a `--` the same names are used for both.
system_install() {
    local apt_pkgs=() brew_pkgs=() seen_sep=0 arg
    for arg in "$@"; do
        if [ "${arg}" = "--" ]; then
            seen_sep=1
        elif [ "${seen_sep}" -eq 1 ]; then
            brew_pkgs+=("${arg}")
        else
            apt_pkgs+=("${arg}")
        fi
    done
    [ "${seen_sep}" -eq 1 ] || brew_pkgs=("${apt_pkgs[@]}")

    if have apt-get; then
        apt_update_once
        log "apt-get install ${apt_pkgs[*]}"
        maybe_sudo apt-get install -y "${apt_pkgs[@]}"
    elif have brew; then
        log "brew install ${brew_pkgs[*]}"
        brew install "${brew_pkgs[@]}"
    else
        die "no supported package manager (apt-get or brew) to install: ${apt_pkgs[*]} — install it yourself and re-run (on Arch, use scripts/setup-arch.sh)"
    fi
}

# --- ~/.zshrc managed block -----------------------------------------------------------
#
# All PATH / env additions that tools require go through this. The block is built in
# memory (register_env, for every tool, whether or not this run installs it — so an
# --only run never drops another tool's lines), then written between the markers,
# replacing any previous copy. Re-runs never stack duplicate PATH entries, and nothing
# outside the markers is touched.

# Append a line to the managed block, skipping exact duplicates so tools that share a
# PATH entry (e.g. ~/.local/bin) don't stack it.
add_zshrc_line() {
    case $'\n'"${ZSHRC_BODY}" in
        *$'\n'"$1"$'\n'*) return 0 ;;
    esac
    ZSHRC_BODY="${ZSHRC_BODY}$1"$'\n'
}

# Add a directory to PATH for BOTH the running process and future shells.
add_path() {
    local dir="$1"
    add_zshrc_line "export PATH=\"${dir}:\$PATH\""
    case ":${PATH}:" in
        *":${dir}:"*) ;;
        *) export PATH="${dir}:${PATH}" ;;
    esac
}

write_zshrc_block() {
    touch "${ZSHRC}"
    if grep -qF "${ZSHRC_BEGIN}" "${ZSHRC}"; then
        local tmp
        tmp="$(mktemp)"
        sed "/^${ZSHRC_BEGIN}\$/,/^${ZSHRC_END}\$/d" "${ZSHRC}" >"${tmp}"
        mv "${tmp}" "${ZSHRC}"
    fi
    {
        printf '%s\n' "${ZSHRC_BEGIN}"
        printf '%s' "${ZSHRC_BODY}"
        printf '%s\n' "${ZSHRC_END}"
    } >>"${ZSHRC}"
    ok "updated ~/.zshrc managed block"
}

# Literal text for ~/.zshrc: it expands at login, not here.
# shellcheck disable=SC2016
register_env() {
    # oh-my-zsh is installed with KEEP_ZSHRC=yes, so its own bootstrap lines are ours.
    add_zshrc_line 'export ZSH="$HOME/.oh-my-zsh"'
    add_zshrc_line 'ZSH_THEME="robbyrussell"'
    add_zshrc_line 'plugins=(git)'
    add_zshrc_line '[ -s "$ZSH/oh-my-zsh.sh" ] && source "$ZSH/oh-my-zsh.sh"'

    add_zshrc_line 'export NVM_DIR="$HOME/.nvm"'
    add_zshrc_line '[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"'
    add_zshrc_line '[ -s "$NVM_DIR/bash_completion" ] && \. "$NVM_DIR/bash_completion"'

    add_zshrc_line 'export BUN_INSTALL="$HOME/.bun"'
    add_path "${BUN_INSTALL}/bin"

    # uv, the-loop, poetry, claude, cursor and the node symlinks all live here.
    add_path "${HOME}/.local/bin"

    add_path "${GO_ROOT}/bin"
    add_path "${HOME}/go/bin"
}

# --- Preflight ------------------------------------------------------------------------

preflight() {
    # curl is how every vendor installer arrives; apt can bring it on a bare image.
    if ! have curl && ! have apt-get; then
        die "curl is required but was not found on PATH"
    fi

    case "$(uname -s)" in
        Darwin | Linux) ;;
        *) die "unsupported operating system: $(uname -s) (supported: Darwin, Linux)" ;;
    esac

    case "$(uname -m)" in
        arm64 | aarch64 | x86_64) ;;
        *) die "unsupported architecture: $(uname -m) (supported: arm64, aarch64, x86_64)" ;;
    esac
}

# --- Tool registry --------------------------------------------------------------------
#
# Each tool <t> (hyphens become underscores in function names) has:
#   detect_<t>   side-effect free; true when already installed
#   version_<t>  prints the installed version (or 'unknown')
#   install_<t>  installs it; the driver re-runs detect_<t> afterwards to verify

detect_zsh() { have zsh; }
detect_wget() { have wget; }
detect_curl() { have curl; }
detect_vim() { have vim; }
detect_build_tools() { have cc && have make && have git; }
detect_oh_my_zsh() { [ -d "${HOME}/.oh-my-zsh" ]; }
detect_uv() { have uv; }
detect_bun() { have bun; }
detect_node() { have node; }
detect_npm() { have npm; }
detect_yarn() { have yarn; }
detect_pnpm() { have pnpm; }
detect_poetry() { have poetry; }
detect_go() { have go; }
detect_gh() { have gh; }
detect_podman() { have podman; }
detect_shellcheck() { have shellcheck; }
detect_ttyd() { have ttyd; }
detect_claude() { have claude; }
detect_cursor() { have cursor || have cursor-agent; }

# nvm is a shell function, not a binary — it is never on PATH, so look for its script.
detect_nvm() { [ -s "${NVM_DIR}/nvm.sh" ]; }

# macOS ships an Xcode /usr/bin/python3 shim and old distros an old python3, so "is
# python3 on PATH" is not the question. The floor matches this repo's pyproject.toml.
detect_python3() {
    have python3 || return 1

    local reported major rest minor
    reported="$(python3 -V 2>&1)" || return 1
    reported="${reported#Python }"
    major="${reported%%.*}"
    rest="${reported#*.}"
    minor="${rest%%.*}"

    case "${major}" in '' | *[!0-9]*) return 1 ;; esac
    case "${minor}" in '' | *[!0-9]*) return 1 ;; esac

    if [ "${major}" -gt 3 ]; then
        return 0
    fi
    [ "${major}" -eq 3 ] && [ "${minor}" -ge "${PYTHON_MIN_MINOR}" ]
}

# The pin is checked against the uv tool venv's receipt, where the requested specifier
# is recorded — so a box on another version counts as "not installed" and is moved to
# the pin.
detect_the_loop() {
    have the-loop && have uv || return 1
    local receipt
    receipt="$(uv tool dir 2>/dev/null)/the-loopy-one/uv-receipt.toml"
    grep -q "name = \"the-loopy-one\", specifier = \"==${THE_LOOP_VERSION}\"" "${receipt}" 2>/dev/null
}

detect_the_loop_plugin() {
    grep -qF '"the-loop@the-loop"' "${HOME}/.claude/plugins/installed_plugins.json" 2>/dev/null
}

# The first dotted version number a tool prints, so the summary column holds a version
# rather than a banner.
version_of() {
    local reported
    reported="$("$@" 2>/dev/null | grep -oE '[0-9]+(\.[0-9]+)+' | head -n 1)" || true
    printf '%s' "${reported:-unknown}"
}

version_zsh() { version_of zsh --version; }
version_wget() { version_of wget --version; }
version_curl() { version_of curl --version; }
version_vim() { version_of vim --version; }
version_build_tools() { version_of cc --version; }
version_oh_my_zsh() { printf 'installed'; }
version_bun() { bun --version 2>/dev/null || printf 'unknown'; }
version_node() { node -v 2>/dev/null || printf 'unknown'; }
version_npm() { npm -v 2>/dev/null || printf 'unknown'; }
version_yarn() { yarn --version 2>/dev/null || printf 'unknown'; }
version_pnpm() { pnpm --version 2>/dev/null || printf 'unknown'; }
version_the_loop() { printf '%s' "${THE_LOOP_VERSION}"; }
version_the_loop_plugin() { printf 'user scope'; }
version_poetry() { version_of poetry --version; }
# Never `go version`: any go command writes telemetry under ~/.config/go, and detection
# must leave the disk alone. A go tree records its version in GOROOT/VERSION.
version_go() {
    local root
    root="$(dirname "$(dirname "$(command -v go)")")"
    if [ -r "${root}/VERSION" ]; then
        version_of head -n 1 "${root}/VERSION"
    else
        printf 'installed'
    fi
}
version_gh() { version_of gh --version; }
version_podman() { version_of podman --version; }
version_shellcheck() { version_of shellcheck --version; }
version_ttyd() { version_of ttyd --version; }
version_claude() { version_of claude --version; }
version_cursor() { printf 'installed'; }

# `uv --version` prints "uv 0.12.0", and older builds append a commit and date —
# report just the number, like every other tool.
version_uv() {
    local reported
    reported="$(uv --version 2>/dev/null)" || {
        printf 'unknown'
        return 0
    }
    reported="${reported#uv }"
    printf '%s' "${reported%% *}"
}

# `python3 -V` prints "Python 3.13.1"; report just the number.
version_python3() {
    local reported
    reported="$(python3 -V 2>&1)" || {
        printf 'unknown'
        return 0
    }
    printf '%s' "${reported#Python }"
}

version_nvm() {
    if [ ! -s "${NVM_DIR}/nvm.sh" ]; then
        printf 'unknown'
        return 0
    fi
    # nvm.sh is not written against `set -u`; it is sourced in this subshell only.
    set +u
    # shellcheck disable=SC1091
    . "${NVM_DIR}/nvm.sh"
    set -u
    nvm --version 2>/dev/null || printf 'unknown'
}

# --- Tool registry: install -----------------------------------------------------------

install_zsh() { system_install zsh; }
install_wget() { system_install wget; }
install_curl() { system_install curl; }
install_vim() { system_install vim; }

install_build_tools() {
    if [ "$(uname -s)" = "Darwin" ]; then
        die "build tools (cc, make, git) are missing — run 'xcode-select --install' and re-run"
    fi
    system_install build-essential ca-certificates git
}

# The upstream installer, run bare, is interactive and would overwrite the ~/.zshrc this
# script manages, so it is driven non-interactively:
#   RUNZSH=no       don't drop into a zsh subshell when done
#   KEEP_ZSHRC=yes  don't touch/replace ~/.zshrc (register_env adds its bootstrap lines)
#   CHSH=no         set_login_shell changes the login shell, idempotently
install_oh_my_zsh() {
    RUNZSH=no KEEP_ZSHRC=yes CHSH=no fetch_and_run "${OH_MY_ZSH_INSTALLER_URL}"
}

# PROFILE=/dev/null: the nvm lines live in the managed ~/.zshrc block, not wherever the
# nvm installer would append its own.
install_nvm() { PROFILE=/dev/null fetch_and_run "${NVM_INSTALLER_URL}"; }

install_node() {
    detect_nvm || die "cannot install node: nvm is not available at ${NVM_DIR} (it is node's installer)"
    log "installing the current Node.js LTS via nvm"
    set +u
    # shellcheck disable=SC1091
    . "${NVM_DIR}/nvm.sh"
    nvm install --lts
    nvm alias default 'lts/*'

    # nvm only loads in interactive zsh; non-interactive shells (Claude Code hooks, cron,
    # ssh commands) get no node. Symlink the default node into ~/.local/bin, which is on
    # the base PATH.
    local node_bin bin
    node_bin="$(dirname "$(nvm which default)")"
    set -u
    mkdir -p "${HOME}/.local/bin"
    for bin in node npm npx corepack; do
        if [ -e "${node_bin}/${bin}" ]; then
            ln -sfn "${node_bin}/${bin}" "${HOME}/.local/bin/${bin}"
        fi
    done
    ok "node symlinked into ~/.local/bin for non-interactive shells"
}

# npm has no installer of its own: every Node.js distribution bundles it. Reaching here
# means node is installed but npm is not, which is an anomaly worth reporting rather
# than papering over.
install_npm() {
    die "npm is missing even though node is installed — a Node.js distribution should bundle npm; reinstall node (nvm install --lts --reinstall-packages-from=current)"
}

install_bun() { fetch_and_run "${BUN_INSTALLER_URL}" "${BUN_VERSION}"; }

# yarn & pnpm via corepack (ships with node) — no global npm churn.
install_corepack_tool() {
    have corepack || die "cannot install $1: corepack (bundled with node) is not available"
    corepack enable --install-directory "${HOME}/.local/bin" "$1"
    corepack prepare "$2" --activate
}

install_yarn() { install_corepack_tool yarn yarn@stable; }
install_pnpm() { install_corepack_tool pnpm pnpm@latest; }

install_uv() { fetch_and_run "${UV_INSTALLER_URL}"; }

# The system python3 when the package manager has a new-enough one (with pip and venv,
# which Debian splits out); otherwise uv's managed CPython, symlinked into ~/.local/bin
# as python3/python.
install_python3() {
    if have apt-get; then
        system_install python3 python3-venv python3-pip
        detect_python3 && return 0
        log "the system python3 is older than 3.${PYTHON_MIN_MINOR} — adding a newer one via uv"
    fi
    detect_uv || die "cannot install python3: uv is not available (it is python3's installer)"
    log "installing CPython ${PYTHON_VERSION} via uv"
    if ! uv python install --preview-features python-install-default --default "${PYTHON_VERSION}"; then
        die "uv could not install python3 (uv $(version_uv)): 'uv python install --default' needs a recent uv, and an already-installed uv is never upgraded by this script. Run 'uv self update' and re-run."
    fi
}

# the-loop CLI (gh-webhook/poll/sessions/events), PyPI package `the-loopy-one`, as a uv
# tool. uv brings its own CPython, so this works even with no system python.
# --reinstall self-heals an orphaned venv (e.g. after a base-Python upgrade).
install_the_loop() {
    detect_uv || die "cannot install the-loop: uv is not available (it is the-loop's installer)"
    uv tool install "the-loopy-one==${THE_LOOP_VERSION}" --reinstall
}

install_poetry() {
    detect_python3 || die "cannot install poetry: python3 is not available (it runs poetry's installer)"
    local installer
    installer="$(fetch "${POETRY_INSTALLER_URL}" install-poetry.py)" || die "download failed"
    python3 "${installer}"
}

# Official tarball into /usr/local/go: distro packages lag upstream.
install_go() {
    local os arch tarball
    case "$(uname -s)" in
        Darwin) os="darwin" ;;
        *) os="linux" ;;
    esac
    case "$(uname -m)" in
        x86_64) arch="amd64" ;;
        aarch64 | arm64) arch="arm64" ;;
    esac
    tarball="$(fetch "${GO_DOWNLOAD_URL}/go${GO_VERSION}.${os}-${arch}.tar.gz" go.tar.gz)" || die "download failed"
    maybe_sudo rm -rf "${GO_ROOT}"
    maybe_sudo tar -C "$(dirname "${GO_ROOT}")" -xzf "${tarball}"
}

# GitHub's own apt repository (Debian/Ubuntu carry a stale gh, or none).
install_gh() {
    if ! have apt-get; then
        system_install gh
        return 0
    fi
    local keyring
    keyring="$(fetch "${GH_KEYRING_URL}" githubcli-archive-keyring.gpg)" || die "download failed"
    maybe_sudo mkdir -p -m 755 /etc/apt/keyrings
    maybe_sudo install -m 0644 "${keyring}" /etc/apt/keyrings/githubcli-archive-keyring.gpg
    echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" |
        maybe_sudo tee /etc/apt/sources.list.d/github-cli.list >/dev/null
    APT_UPDATED=0
    system_install gh
}

install_podman() { system_install podman; }

# Lints scripts/*.sh per CLAUDE.md.
install_shellcheck() { system_install shellcheck; }

# ttyd — share a terminal over the web. Not carried by the apt mirrors, so the upstream
# static build goes into /usr/local/bin; Homebrew has it on macOS.
install_ttyd() {
    if [ "$(uname -s)" = "Darwin" ]; then
        system_install ttyd
        return 0
    fi
    local arch binary
    case "$(uname -m)" in
        x86_64) arch="x86_64" ;;
        *) arch="aarch64" ;;
    esac
    binary="$(fetch "${TTYD_DOWNLOAD_URL}/ttyd.${arch}" ttyd)" || die "download failed"
    maybe_sudo install -m 0755 "${binary}" /usr/local/bin/ttyd
}

install_claude() { fetch_and_run "${CLAUDE_INSTALLER_URL}"; }

# the-loop Claude Code PLUGIN (skills/hooks), distinct from the CLI above. User scope,
# so every claude session on this box loads it — including the tmux sessions the poller
# spawns from any cwd. `marketplace add` is a no-op when the marketplace is known.
install_the_loop_plugin() {
    have claude || die "cannot install the-loop plugin: claude is not available"
    claude plugin marketplace add MadaraUchiha-314/the-loop >/dev/null 2>&1 || true
    claude plugin install the-loop@the-loop --scope user
}

install_cursor() { fetch_and_run "${CURSOR_INSTALLER_URL}"; }

# --- Configuration --------------------------------------------------------------------

write_dotfiles() {
    log "dotfiles"
    cat >"${VIMRC}" <<'EOF'
set nu
sy on
EOF
    ok "wrote ~/.vimrc"

    # The managed block (PATH/env) is appended separately by write_zshrc_block. Written
    # before oh-my-zsh is installed, so its installer finds a ~/.zshrc to keep.
    if [ ! -f "${ZSHRC}" ]; then
        cat >"${ZSHRC}" <<'EOF'
# ~/.zshrc — generated by devbox setup.sh
export EDITOR=vim
setopt AUTO_CD
HISTSIZE=10000
SAVEHIST=10000
HISTFILE="$HOME/.zsh_history"
EOF
        ok "created ~/.zshrc"
    else
        ok "\$HOME/.zshrc exists; managed block will be refreshed"
    fi
}

login_shell() {
    if have getent; then
        getent passwd "$(id -un)" | cut -d: -f7
    elif have dscl; then
        dscl . -read "/Users/$(id -un)" UserShell 2>/dev/null | awk '{print $2}'
    fi
}

set_login_shell() {
    local zsh_bin
    zsh_bin="$(command -v zsh || true)"
    if [ -z "${zsh_bin}" ]; then
        warn "zsh not found; login shell unchanged"
    elif [ "$(login_shell)" = "${zsh_bin}" ]; then
        ok "login shell is already ${zsh_bin}"
    elif maybe_sudo chsh -s "${zsh_bin}" "$(id -un)"; then
        ok "login shell set to ${zsh_bin}"
    else
        warn "could not change login shell; run: chsh -s ${zsh_bin}"
    fi
}

# Repos are cloned as /workspace/<git-host>/<org>/<repo> (see clone_repo).
setup_workspace() {
    log "workspace"
    if [ -d "${WORKSPACE}" ]; then
        ok "${WORKSPACE} exists"
    elif maybe_sudo mkdir -p "${WORKSPACE}" && maybe_sudo chown "$(id -u):$(id -g)" "${WORKSPACE}"; then
        ok "created ${WORKSPACE}"
    else
        # e.g. macOS, whose root filesystem is read-only.
        warn "could not create ${WORKSPACE}; skipping the workspace steps"
        return 0
    fi

    # Pre-trust the workspace for Claude Code so headless the-loop spawns don't stall
    # on the workspace-trust dialog.
    local seeder="${SCRIPT_DIR}/seed-claude-trust.py"
    if [ ! -f "${seeder}" ]; then
        warn "${seeder} not found; skipping claude trust seed for ${WORKSPACE}"
    elif ! have python3; then
        warn "python3 missing; skipping claude trust seed for ${WORKSPACE}"
    elif python3 "${seeder}" "${WORKSPACE}"; then
        ok "trusted ${WORKSPACE} for claude"
    else
        warn "could not seed claude trust"
    fi
}

# clone_repo <repo-url>
#   Parses host/org/repo from an https or ssh git URL and clones into
#   /workspace/<host>/<org>/<repo>. Skips if the repo already exists.
clone_repo() {
    local url="$1" host org repo path rest stripped
    case "${url}" in
        git@*) # git@host:org/repo(.git)
            host="${url#git@}"
            host="${host%%:*}"
            rest="${url#*:}"
            org="${rest%%/*}"
            repo="${rest#*/}"
            repo="${repo%.git}"
            ;;
        http*://*) # https URL: host/org/repo(.git)
            stripped="${url#*://}"
            host="${stripped%%/*}"
            rest="${stripped#*/}"
            org="${rest%%/*}"
            repo="${rest#"${org}"/}"
            repo="${repo%.git}"
            repo="${repo%%/*}"
            ;;
        *)
            warn "unrecognized git URL: ${url}"
            return 1
            ;;
    esac
    path="${WORKSPACE}/${host}/${org}/${repo}"
    if [ -d "${path}/.git" ]; then
        ok "${host}/${org}/${repo} already cloned"
        return 0
    fi
    log "cloning ${host}/${org}/${repo}"
    mkdir -p "${WORKSPACE}/${host}/${org}"
    git clone "${url}" "${path}" && ok "cloned into ${path}"
}

run_startup_commands() {
    log "startup commands"
    if have claude; then
        if claude --upgrade >/dev/null 2>&1; then ok "claude --upgrade"; else warn "claude --upgrade failed"; fi
    fi
    if have cursor; then
        if cursor --upgrade >/dev/null 2>&1; then ok "cursor --upgrade"; else warn "cursor --upgrade failed"; fi
    fi
    local keepalive="${SCRIPT_DIR}/start-keepalive.sh"
    if [ ! -x "${keepalive}" ]; then
        warn "${keepalive} not found; skipping keepalive"
    elif "${keepalive}"; then
        ok "keepalive"
    else
        warn "keepalive failed to start"
    fi
}

# --- Driver ---------------------------------------------------------------------------

validate_tool() {
    local candidate="$1" known
    for known in ${TOOLS}; do
        if [ "${candidate}" = "${known}" ]; then
            return 0
        fi
    done
    usage_error "unknown tool: ${candidate} (expected one of: ${TOOLS})"
}

parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --dry-run) DRY_RUN=1 ;;
            --only)
                [ $# -ge 2 ] || usage_error "--only requires a tool name"
                validate_tool "$2"
                SELECTED="$2"
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *) usage_error "unknown argument: $1" ;;
        esac
        shift
    done
}

provision() {
    local tool fn
    for tool in ${SELECTED}; do
        fn="${tool//-/_}"
        if "detect_${fn}"; then
            record "${tool}" "$("version_${fn}")" "already present"
            log "${tool}: already present"
            continue
        fi

        if [ "${DRY_RUN}" -eq 1 ]; then
            record "${tool}" "-" "planned"
            log "${tool}: not found — would install"
            continue
        fi

        log "${tool}: not found — installing"
        if is_optional "${tool}"; then
            # A subshell, so an optional tool's die() reports instead of aborting.
            if ! ("install_${fn}") || ! "detect_${fn}"; then
                warn "${tool}: install failed (optional — continuing)"
                record "${tool}" "-" "failed (optional)"
                continue
            fi
        else
            "install_${fn}"
            if ! "detect_${fn}"; then
                die "${tool}: installation reported success but ${tool} is still not available"
            fi
        fi
        record "${tool}" "$("version_${fn}")" "installed"
        INSTALLED_ANY=1
    done
}

configure() {
    if [ "${DRY_RUN}" -eq 1 ]; then
        log "would write ~/.vimrc, ~/.zshrc and its managed block, set the login shell, create ${WORKSPACE} and run the startup commands"
        return 0
    fi
    write_zshrc_block
    # An --only run installs one tool; the box-wide steps are for a full provision.
    if [ "${SELECTED}" = "${TOOLS}" ]; then
        set_login_shell
        setup_workspace
        run_startup_commands
    fi
}

print_summary() {
    printf '\n%-16s %-32s %s\n' "TOOL" "VERSION" "STATUS"
    printf '%s' "${SUMMARY}" | while IFS='|' read -r tool version status; do
        [ -n "${tool}" ] || continue
        printf '%-16s %-32s %s\n' "${tool}" "${version}" "${status}"
    done
}

print_next_steps() {
    if [ "${DRY_RUN}" -eq 1 ]; then
        printf '\n%s\n' "Dry run — nothing was downloaded, installed or written."
        return 0
    fi
    # Only ask for a new shell when there is actually something new to pick up:
    # a re-run on a provisioned box should say so, not hand out busywork.
    if [ "${INSTALLED_ANY}" -eq 0 ]; then
        printf '\n%s\n' "Nothing to do — this box is already provisioned."
        return 0
    fi
    printf '\n%s\n%s\n%s\n' \
        "Open a new shell so the freshly installed tools are on your PATH:" \
        "    exec zsh -l" \
        "Clone repos with:  . scripts/setup.sh && clone_repo <git-url>"
}

main() {
    parse_args "$@"
    preflight
    trap cleanup EXIT
    register_env
    if [ "${DRY_RUN}" -eq 0 ]; then
        write_dotfiles
    fi
    provision
    configure
    print_summary
    print_next_steps
}

# Run main only when executed, not when sourced — sourcing exposes clone_repo and the
# other helpers to the calling shell without provisioning anything.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
