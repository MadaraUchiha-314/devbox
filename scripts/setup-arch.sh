#!/usr/bin/env bash
#
# devbox setup, Arch edition — provision this machine with the toolchain it is built on:
#
#     nvm · node · npm · bun · python3 · uv
#
# The sibling scripts/setup.sh downloads a vendor installer per tool into $HOME, which is
# the only option on macOS. On Arch every one of those tools is a package in the official
# repositories, so this script installs them with pacman instead: one source of truth for
# what is on the box, one `pacman -Syu` to upgrade them, no curl-to-shell at all.
#
#     scripts/setup-arch.sh --dry-run     # show the plan, change nothing
#     scripts/setup-arch.sh               # provision
#     scripts/setup-arch.sh --only uv     # one tool
#
# Six names, two installers: pacman provides uv, python, nvm and bun; nvm then provides
# node, and every Node.js distribution bundles npm. Tools are walked in dependency order
# and each one is detected before it is installed, so re-running this is safe and boring.
#
# Spec: docs/specs/issue-2/  ·  sibling: scripts/setup.sh

set -euo pipefail

# --- Packages -------------------------------------------------------------------------
#
# No version pins live here, and that is the point of using pacman: the repositories
# decide the version, `pacman -Syu` moves it forward with the rest of the system, and
# `pacman -Qo` can always say where a binary came from. The one thing this script does
# assert is a floor for python3, matching this repo's pyproject.toml requires-python.
#
#   uv     extra/uv        node  installed by nvm (--lts), not packaged per-version
#   bun    extra/bun       npm   bundled inside every Node.js distribution
#   nvm    extra/nvm       python3  core/python
#
# node deliberately comes from nvm rather than extra/nodejs: nvm is what lets this box
# hold several Node versions, and a pacman-owned /usr/bin/node would shadow them.

PACKAGE_uv="uv"
PACKAGE_python3="python"
PACKAGE_nvm="nvm"
PACKAGE_bun="bun"

PYTHON_MIN_MINOR=11

# Where the Arch nvm package puts its files. A user-installed nvm (from the upstream
# installer, e.g. left over from scripts/setup.sh) lives in $NVM_DIR instead.
#
# The two are not interchangeable. `nvm.sh` is the function library and sourcing it has no
# side effects; `init-nvm.sh` is the packaged convenience script, and it *also* creates
# $NVM_DIR and symlinks nvm.sh and nvm-exec into it — which `nvm exec` and a good deal of
# third-party tooling expect to find there. So: nvm.sh to ask a question, init-nvm.sh to
# install with.
NVM_SYSTEM_SH="/usr/share/nvm/nvm.sh"
NVM_SYSTEM_INIT="/usr/share/nvm/init-nvm.sh"

# Dependency order: pacman provides python3 and uv outright, nvm provides node, node
# brings npm.
TOOLS="uv python3 nvm node npm bun"

readonly PACKAGE_uv PACKAGE_python3 PACKAGE_nvm PACKAGE_bun PYTHON_MIN_MINOR
readonly NVM_SYSTEM_SH NVM_SYSTEM_INIT TOOLS

# --- Environment ----------------------------------------------------------------------
#
# nvm installs Node under $NVM_DIR whichever way nvm itself was installed, so this is
# still a $HOME path even though nvm came from a system package. The operator's shell
# profiles are never touched: pacman does not add nvm's init line and neither does this
# script — print_next_steps says what to add, and the operator decides.
#
# The default is copied from the packaged /usr/share/nvm/init-nvm.sh rather than from
# upstream nvm, XDG branch and all. Get this wrong and the box ends up with Node under
# ~/.nvm while every later shell looks in $XDG_CONFIG_HOME/nvm and finds nothing.

: "${HOME:?HOME is not set — nvm installs Node into your home directory}"

if [ -z "${NVM_DIR:-}" ]; then
    NVM_DIR="${HOME}/.nvm"
    if [ -n "${XDG_CONFIG_HOME:-}" ]; then
        NVM_DIR="${XDG_CONFIG_HOME}/nvm"
    fi
fi
export NVM_DIR

# The distribution's identity file. Overridable for one reason only: the test suite runs
# on a non-Arch CI runner and still has to exercise the guard that reads it.
OS_RELEASE="${DEVBOX_OS_RELEASE:-/etc/os-release}"
readonly OS_RELEASE

DRY_RUN=0
NOCONFIRM=0
SELECTED="${TOOLS}"
SUMMARY=""
INSTALLED_ANY=0
NVM_FROM_PACMAN=0

# --- Output ---------------------------------------------------------------------------

log() { printf '==> %s\n' "$*"; }

die() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

usage() {
    printf '%s\n' \
        "Usage: scripts/setup-arch.sh [--dry-run] [--only <tool>] [--noconfirm] [--help]" \
        "" \
        "Provision this Arch devbox with: ${TOOLS}" \
        "" \
        "  --dry-run        Print the planned action for every tool; change nothing." \
        "  --only <tool>    Act on one tool only. One of: ${TOOLS}" \
        "  --noconfirm      Pass --noconfirm to pacman, for an unattended run." \
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

# --- The privilege chokepoint ----------------------------------------------------------
#
# Every command this script runs with root privileges passes through here, so there is
# exactly one place to read to know what it can do to the system:
#
#   sudo pacman -S --needed -- <package>
#
# Notes on what is deliberately absent:
#
#   -Sy       never. `pacman -Sy <pkg>` is the classic Arch footgun: it refreshes the
#             package database without upgrading, so the next install pulls a package
#             built against libraries this box does not have yet. If the database is
#             stale enough that a target is not found, that is the operator's call to
#             make with a full `pacman -Syu`, and the error below says so.
#   -Syu      never either: upgrading the whole system is not what "install my toolchain"
#             asked for, and doing it unasked is how a provisioning script becomes the
#             thing that broke your box.
#   --        ends option parsing, so a package name can never be read as a flag.

pacman_install() {
    local package="$1"
    local -a args
    args=(-S --needed)
    if [ "${NOCONFIRM}" -eq 1 ]; then
        args+=(--noconfirm)
    fi

    log "pacman: installing ${package}"
    if ! sudo pacman "${args[@]}" -- "${package}"; then
        die "pacman could not install '${package}'. If it reported 'target not found', this box's package database is older than the mirrors — run 'sudo pacman -Syu' (a full upgrade, never a bare -Sy) and re-run this script."
    fi
}

# --- Preflight ------------------------------------------------------------------------

# Matches Arch itself and its derivatives (Omarchy, EndeavourOS, CachyOS, Manjaro …),
# which all carry ID_LIKE=arch and ship pacman with the same repositories.
is_arch_family() {
    [ -r "${OS_RELEASE}" ] || return 1

    local id id_like
    # Sourced in a command substitution, so the file's assignments land in a subshell
    # and cannot overwrite anything in this one.
    # shellcheck disable=SC1090
    id="$(. "${OS_RELEASE}" && printf '%s' "${ID:-}")"
    # shellcheck disable=SC1090
    id_like="$(. "${OS_RELEASE}" && printf '%s' "${ID_LIKE:-}")"

    case " ${id} ${id_like} " in
        *" arch "*) return 0 ;;
    esac
    return 1
}

preflight() {
    if [ "$(id -u)" -eq 0 ]; then
        die "refusing to run as root: nvm installs Node under \$HOME, and as root that would be /root. Re-run as your own user — the script calls sudo for the pacman steps and only those."
    fi

    if ! command -v pacman >/dev/null 2>&1; then
        die "pacman is required but was not found on PATH — this script is the Arch edition; on any other distribution or on macOS use scripts/setup.sh instead"
    fi

    if ! is_arch_family; then
        die "this machine does not report itself as Arch or an Arch derivative (${OS_RELEASE} ID/ID_LIKE) — use scripts/setup.sh instead"
    fi

    if ! command -v sudo >/dev/null 2>&1; then
        die "sudo is required but was not found on PATH — pacman needs root to install packages"
    fi

    case "$(uname -m)" in
        aarch64 | x86_64) ;;
        *) die "unsupported architecture: $(uname -m) (supported: aarch64, x86_64)" ;;
    esac
}

# --- Tool registry: detect ------------------------------------------------------------

detect_uv() { command -v uv >/dev/null 2>&1; }
detect_bun() { command -v bun >/dev/null 2>&1; }
detect_node() { command -v node >/dev/null 2>&1; }
detect_npm() { command -v npm >/dev/null 2>&1; }

# nvm is a shell function, not a binary — it is never on PATH, so look for its script.
# Two places can hold it: $NVM_DIR for an nvm installed from upstream, and /usr/share/nvm
# for the packaged one. A user-installed nvm wins, because that is the one whose init
# line is already in the operator's profile.
#
# Side-effect free, which is why detection and `nvm --version` go through here and
# installing does not: sourcing this during a --dry-run must leave the disk alone.
nvm_script() {
    if [ -s "${NVM_DIR}/nvm.sh" ]; then
        printf '%s' "${NVM_DIR}/nvm.sh"
    elif [ -s "${NVM_SYSTEM_SH}" ]; then
        printf '%s' "${NVM_SYSTEM_SH}"
    fi
}

# What to source before actually running `nvm install`. For a packaged nvm this is
# init-nvm.sh, which populates $NVM_DIR the way the rest of the ecosystem expects; doing
# it by hand here would be a second copy of a file Arch already ships.
nvm_install_script() {
    if [ -s "${NVM_DIR}/nvm.sh" ]; then
        printf '%s' "${NVM_DIR}/nvm.sh"
    elif [ -s "${NVM_SYSTEM_INIT}" ]; then
        printf '%s' "${NVM_SYSTEM_INIT}"
    elif [ -s "${NVM_SYSTEM_SH}" ]; then
        printf '%s' "${NVM_SYSTEM_SH}"
    fi
}

detect_nvm() { [ -n "$(nvm_script)" ]; }

# The floor matches this repo's own pyproject.toml requires-python. Arch's `python` is
# always well past it, but a box can also be reached through a pyenv/mise shim, and
# "python3 is on PATH" is not the question being asked.
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
    local script
    script="$(nvm_script)"
    if [ -z "${script}" ]; then
        printf 'unknown'
        return 0
    fi
    # nvm's scripts are not written against `set -eu`; see install_node for why both come
    # off around a source. This is a subshell (a command substitution), so the relaxed
    # options die with it.
    set +eu
    # shellcheck disable=SC1090
    . "${script}"
    set -eu
    nvm --version 2>/dev/null || printf 'unknown'
}

# --- Tool registry: install -----------------------------------------------------------

install_uv() { pacman_install "${PACKAGE_uv}"; }

install_bun() { pacman_install "${PACKAGE_bun}"; }

install_python3() { pacman_install "${PACKAGE_python3}"; }

install_nvm() {
    pacman_install "${PACKAGE_nvm}"
    # Remembered so print_next_steps can hand over the one line pacman does not write:
    # the packaged nvm ships an init script and leaves sourcing it to the operator.
    NVM_FROM_PACMAN=1
}

install_node() {
    detect_nvm || die "cannot install node: nvm is not available (it is node's installer)"
    log "installing the current Node.js LTS via nvm"
    local script
    script="$(nvm_install_script)"

    # errexit comes off for the source itself, because sourcing someone else's file under
    # it makes this script's survival depend on that file's last line. init-nvm.sh ends by
    # sourcing nvm's bash_completion, and a sourced file that ends on a failing command
    # takes the sourcing script down with it — a mid-file `[ ! -e x ] && ...` is exempt,
    # a trailing one is not. Then errexit goes straight back on for the nvm calls, whose
    # failure this script does want to act on. `set -u` stays off across both: nvm's own
    # functions are not written against it.
    set +eu
    # shellcheck disable=SC1090
    . "${script}"
    set -e
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
            --noconfirm) NOCONFIRM=1 ;;
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
        printf '\n%s\n' "Dry run — nothing was installed and no package database was touched."
        return 0
    fi
    # Only ask for a new shell when there is actually something new to pick up:
    # a re-run on a provisioned box should say so, not hand out busywork.
    if [ "${INSTALLED_ANY}" -eq 0 ]; then
        printf '\n%s\n' "Nothing to do — this box is already provisioned."
        return 0
    fi

    # Unlike the upstream installer, the packaged nvm writes nothing to a shell profile —
    # so this is the one manual step, and it stays the operator's to make.
    if [ "${NVM_FROM_PACMAN}" -eq 1 ]; then
        printf '\n%s\n%s\n' \
            "nvm came from pacman, which does not touch shell profiles. Add this to your ~/.bashrc (or ~/.zshrc) to get the nvm function in new shells:" \
            "    source ${NVM_SYSTEM_INIT}"
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
