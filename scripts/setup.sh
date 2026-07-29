#!/usr/bin/env bash
#
# devbox setup — provision this machine with the toolchain it is built on:
#
#     nvm · node · npm · bun · python3 · uv
#
# Six names, four installers: npm ships inside every Node.js distribution, and nvm is
# what installs Node. Tools are walked in dependency order and each one is detected
# before it is installed, so re-running this script is safe and boring.
#
#     scripts/setup.sh --dry-run     # show the plan, change nothing
#     scripts/setup.sh               # provision
#     scripts/setup.sh --only uv     # one tool
#
# Written for bash 3.2 — the version macOS still ships as /bin/bash. No associative
# arrays, no mapfile, no ${var,,}. External commands used: curl, id, mktemp, rm, uname.
#
# Spec: docs/specs/issue-2/  ·  Issue: #2

set -euo pipefail

# --- Pins -----------------------------------------------------------------------------
#
# Versions are pinned so a run is reproducible and a compromised "latest" cannot silently
# change what executes. To bump: read the vendor's latest release, change the value here,
# and check the tests still pass.
#
#   nvm  https://github.com/nvm-sh/nvm/releases
#   uv   https://github.com/astral-sh/uv/releases
#   bun  https://github.com/oven-sh/bun/releases
#
# Honest caveat: bun.sh/install is not itself versioned, so BUN_VERSION pins the bun that
# the installer installs, not the installer. node is deliberately unpinned (--lts).

NVM_TAG="v0.40.6"
UV_VERSION="0.12.0"
BUN_VERSION="bun-v1.3.14"
PYTHON_VERSION="3.13"
PYTHON_MIN_MINOR=11

NVM_INSTALLER_URL="https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_TAG}/install.sh"
UV_INSTALLER_URL="https://astral.sh/uv/${UV_VERSION}/install.sh"
BUN_INSTALLER_URL="https://bun.sh/install"

# Dependency order: uv provides python3, nvm provides node, node brings npm.
TOOLS="uv python3 nvm node npm bun"

readonly NVM_TAG UV_VERSION BUN_VERSION PYTHON_VERSION PYTHON_MIN_MINOR
readonly NVM_INSTALLER_URL UV_INSTALLER_URL BUN_INSTALLER_URL TOOLS

# --- Environment ----------------------------------------------------------------------
#
# Where the vendors install to. Exported because their installers read these, and
# prepended to *this script's* PATH so a freshly installed tool can be verified in the
# same run. The operator's shell profiles are never touched — the vendor installers
# already append their own lines, and a second writer is how rc files rot.

: "${HOME:?HOME is not set — this script installs into your home directory}"

export NVM_DIR="${NVM_DIR:-${HOME}/.nvm}"
export BUN_INSTALL="${BUN_INSTALL:-${HOME}/.bun}"
PATH="${HOME}/.local/bin:${BUN_INSTALL}/bin:${PATH}"

DRY_RUN=0
SELECTED="${TOOLS}"
SUMMARY=""
WORKDIR=""
INSTALLED_ANY=0

# --- Output ---------------------------------------------------------------------------

log() { printf '==> %s\n' "$*"; }

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

usage() {
    printf '%s\n' \
        "Usage: scripts/setup.sh [--dry-run] [--only <tool>] [--help]" \
        "" \
        "Provision this devbox with: ${TOOLS}" \
        "" \
        "  --dry-run        Print the planned action for every tool; change nothing." \
        "  --only <tool>    Act on one tool only. One of: ${TOOLS}" \
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

# --- Temp directory -------------------------------------------------------------------
#
# Created lazily, so --dry-run really does touch nothing. mktemp -d gives a fresh
# 0700 directory owned by this user, which is what stops a pre-planted symlink in a
# shared /tmp from being followed.

cleanup() {
    if [ -n "${WORKDIR}" ] && [ -d "${WORKDIR}" ]; then
        rm -rf "${WORKDIR}"
    fi
    return 0
}
trap cleanup EXIT

ensure_workdir() {
    if [ -z "${WORKDIR}" ]; then
        WORKDIR="$(mktemp -d)"
    fi
}

# --- The network chokepoint -----------------------------------------------------------
#
# Every byte of third-party code this script executes passes through here, so the
# hardening lives in exactly one place:
#
#   --fail          a 404's HTML body is an error, not a shell script to execute
#   --proto '=https'  a redirect may not downgrade the connection to plaintext
#   -o then bash    the download COMPLETES before anything runs, so a dropped
#                   connection cannot execute half an installer
#   "${BASH}"       the interpreter already running this script, not whatever a
#                   poisoned PATH resolves `bash` to

fetch_and_run() {
    local url="$1"
    shift
    local installer
    ensure_workdir
    installer="${WORKDIR}/installer.sh"

    log "downloading ${url}"
    curl --fail --location --proto '=https' --tlsv1.2 --silent --show-error \
        "${url}" -o "${installer}"

    log "running installer from ${installer}"
    "${BASH}" "${installer}" "$@"
}

# --- Preflight ------------------------------------------------------------------------

preflight() {
    if [ "$(id -u)" -eq 0 ]; then
        die "refusing to run as root: this script installs into \$HOME and must not give a vendor installer system privileges. Re-run it as your own user, without sudo."
    fi

    if ! command -v curl >/dev/null 2>&1; then
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

# --- Tool registry: detect ------------------------------------------------------------

detect_uv() { command -v uv >/dev/null 2>&1; }
detect_bun() { command -v bun >/dev/null 2>&1; }
detect_node() { command -v node >/dev/null 2>&1; }
detect_npm() { command -v npm >/dev/null 2>&1; }

# nvm is a shell function, not a binary — it is never on PATH, so look for its script.
detect_nvm() { [ -s "${NVM_DIR}/nvm.sh" ]; }

# macOS ships an Xcode /usr/bin/python3 shim, so "is python3 on PATH" is not the
# question. The floor matches this repo's own pyproject.toml requires-python.
detect_python3() {
    command -v python3 >/dev/null 2>&1 || return 1

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

# --- Tool registry: version -----------------------------------------------------------

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

version_bun() { bun --version 2>/dev/null || printf 'unknown'; }
version_node() { node -v 2>/dev/null || printf 'unknown'; }
version_npm() { npm -v 2>/dev/null || printf 'unknown'; }

# `python3 -V` prints "Python 3.13.1"; report just the number so the summary column
# holds a version rather than a sentence.
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

install_uv() { fetch_and_run "${UV_INSTALLER_URL}"; }

install_nvm() { fetch_and_run "${NVM_INSTALLER_URL}"; }

install_bun() { fetch_and_run "${BUN_INSTALLER_URL}" "${BUN_VERSION}"; }

install_python3() {
    detect_uv || die "cannot install python3: uv is not available (it is python3's installer)"
    log "installing CPython ${PYTHON_VERSION} via uv"
    if ! uv python install --default "${PYTHON_VERSION}"; then
        die "uv could not install python3 (uv $(version_uv)): 'uv python install --default' needs a recent uv, and an already-installed uv is never upgraded by this script. Run 'uv self update' and re-run."
    fi
}

install_node() {
    detect_nvm || die "cannot install node: nvm is not available at ${NVM_DIR} (it is node's installer)"
    log "installing the current Node.js LTS via nvm"
    set +u
    # shellcheck disable=SC1091
    . "${NVM_DIR}/nvm.sh"
    nvm install --lts
    nvm alias default 'lts/*'
    set -u
}

# npm has no installer of its own: every Node.js distribution bundles it. Reaching here
# means node is installed but npm is not, which is an anomaly worth reporting rather
# than papering over.
install_npm() {
    die "npm is missing even though node is installed — a Node.js distribution should bundle npm; reinstall node (nvm install --lts --reinstall-packages-from=current)"
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
    local tool
    for tool in ${SELECTED}; do
        if "detect_${tool}"; then
            record "${tool}" "$("version_${tool}")" "already present"
            log "${tool}: already present"
            continue
        fi

        if [ "${DRY_RUN}" -eq 1 ]; then
            record "${tool}" "-" "planned"
            log "${tool}: not found — would install"
            continue
        fi

        log "${tool}: not found — installing"
        "install_${tool}"

        if ! "detect_${tool}"; then
            die "${tool}: installation reported success but ${tool} is still not available"
        fi
        record "${tool}" "$("version_${tool}")" "installed"
        INSTALLED_ANY=1
    done
}

print_summary() {
    printf '\n%-9s %-24s %s\n' "TOOL" "VERSION" "STATUS"
    printf '%s' "${SUMMARY}" | while IFS='|' read -r tool version status; do
        [ -n "${tool}" ] || continue
        printf '%-9s %-24s %s\n' "${tool}" "${version}" "${status}"
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
    printf '\n%s\n%s\n' \
        "Open a new shell so the freshly installed tools are on your PATH:" \
        "    exec \$SHELL -l"
}

main() {
    parse_args "$@"
    preflight
    provision
    print_summary
    print_next_steps
}

main "$@"
