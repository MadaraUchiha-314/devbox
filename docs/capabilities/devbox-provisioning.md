# Capability: devbox provisioning

> Turning a bare machine into a working devbox with one command.

## What it is

Two scripts clone the owner's laptop setup onto a machine — a remote cloud workspace or
a fresh laptop — in one command. They install the toolchain:

| Group  | Tools                                       |
|--------|---------------------------------------------|
| shell  | zsh, oh-my-zsh, wget, curl, build tools     |
| node   | nvm, node, npm, bun, yarn, pnpm             |
| python | uv, python3 (+ pip), the-loop (CLI), poetry |
| system | go, gh, podman, shellcheck, ttyd            |
| agents | claude, the-loop (claude plugin), cursor    |

and then configure the box: `~/.vimrc`, `~/.zshrc` with a managed PATH/env block, zsh as
the login shell, `/workspace` with the `<host>/<org>/<repo>` clone layout (`clone_repo`),
and the startup commands (`claude --upgrade`, `cursor --upgrade`, keepalive).

| Script                  | For                      | System packages from | Vendor installers for                                                    |
|-------------------------|--------------------------|----------------------|--------------------------------------------------------------------------|
| `scripts/setup.sh`      | Debian/Ubuntu, macOS     | apt / Homebrew       | nvm, bun, uv, go, gh (apt repo), ttyd, oh-my-zsh, poetry, claude, cursor |
| `scripts/setup-arch.sh` | Arch and its derivatives | pacman               | oh-my-zsh, poetry, claude, cursor                                        |

They share a user interface, a tool registry (`TOOLS`, in the same order), the same
`main`, the same `~/.zshrc` markers and a summary table; they differ only in where a tool
comes from. Both walk the tools in dependency order, detect each one before touching it,
and verify it after installing.

The tool list and the configuration steps come from the owner's provisioning gist; the
framework around them (flags, detection, verification, pinned and hardened downloads)
is the one introduced in issue-2.

## Current behaviour

### Shared by both scripts

- The system SHALL install every tool in `TOOLS` when it is absent.
- WHEN a tool is already present THEN the system SHALL skip it and report it as
  `already present` — re-running the script is safe.
- WHEN the run finishes THEN the system SHALL print one summary line per tool: name,
  resolved version, and status (`installed` · `already present` · `planned` ·
  `failed (optional)`).
- WHEN invoked with `--dry-run` THEN the system SHALL print the plan and perform no
  download, installation or filesystem write.
- WHEN invoked with `--only <tool>` THEN the system SHALL act on that tool alone (and
  refresh the `~/.zshrc` block); the value is matched against a fixed allow-list.
- WHEN invoked with an unrecognised flag or `--only` value THEN the system SHALL print
  usage to stderr and exit `2` without installing anything.
- WHEN a required tool is missing after its installer reported success THEN the system
  SHALL exit non-zero naming that tool. yarn, pnpm, the-loop plugin and cursor are
  optional: a failure is reported in the summary and the run continues.
- WHEN nothing was installed THEN the system SHALL say the box is already provisioned
  rather than asking the operator to open a new shell.
- The system SHALL write `~/.vimrc`, create `~/.zshrc` if absent, and keep every PATH/env
  line it needs inside one marked block in `~/.zshrc` that a re-run replaces, never
  duplicates. Lines outside the markers are never touched; no other profile is written.
- On a full run (not `--only`, not `--dry-run`) the system SHALL set zsh as the login
  shell, create `/workspace` (pre-trusting it for Claude Code when
  `scripts/seed-claude-trust.py` exists), and run the startup commands.
- Root-privileged commands SHALL go through `maybe_sudo` alone: run directly as root (a
  cloud container), via `sudo` otherwise. Vendor installers never run as root.
- WHEN a download fails, returns a non-success status, or cannot use HTTPS THEN the
  system SHALL abort without executing the payload. Every download goes through one
  `curl` call (`fetch`) that pins HTTPS on every redirect hop and writes to a private
  temp directory before anything runs; nothing is piped to a shell.
- WHEN sourced (`. scripts/setup.sh`) THEN the system SHALL define `clone_repo` and its
  other helpers without provisioning anything.

### `scripts/setup.sh` only

- System packages SHALL come from apt (one `apt-get update` per run) or, on macOS,
  Homebrew. go comes from the go.dev tarball into `/usr/local/go`, gh from GitHub's apt
  repository, ttyd from its release binary — the distro versions lag or are absent.
- python3 SHALL come from apt when that one meets the 3.11 floor, otherwise from uv's
  managed CPython.

### `scripts/setup-arch.sh` only

- Every tool the official Arch repositories carry (zsh, wget, curl, base-devel, uv,
  python + python-pip, nvm, bun, go, github-cli, podman, shellcheck, ttyd) SHALL come
  from pacman. `node` SHALL come from nvm rather than `extra/nodejs` — a pacman-owned
  `/usr/bin/node` would shadow every version nvm manages.
- The system SHALL invoke pacman only as `pacman -S --needed [--noconfirm] -- <pkgs>`,
  and SHALL NOT refresh the package database: `pacman -Sy <pkg>` leaves the box in a
  partial-upgrade state, and a full `pacman -Syu` is the operator's call. WHEN pacman
  fails THEN the system SHALL say so and name `-Syu` as the likely remedy.
- WHEN `pacman` is absent, or `/etc/os-release` reports neither `ID` nor `ID_LIKE` in the
  arch family, THEN the system SHALL refuse to run and point at `scripts/setup.sh`.
- WHEN invoked with `--noconfirm` THEN the system SHALL pass it to pacman; otherwise
  pacman prompts. Pass it for an unattended run.
- The managed `~/.zshrc` block SHALL load a user-installed nvm when present, otherwise
  the packaged `/usr/share/nvm/init-nvm.sh`.

### Supported platforms

| Script                  | Targets                                      | Elsewhere           |
|-------------------------|----------------------------------------------|---------------------|
| `scripts/setup.sh`      | Debian/Ubuntu (x86-64, arm64), macOS         | fails closed, named |
| `scripts/setup-arch.sh` | Arch, Omarchy, EndeavourOS, CachyOS, Manjaro | fails closed, named |

`setup.sh` targets **bash 3.2**, the version macOS ships as `/bin/bash`.

### Pinned versions

pacman packages are not pinned: the repositories decide the version and `pacman -Syu`
moves it forward. The pins below are `setup.sh`'s, except `THE_LOOP_VERSION`, which both
scripts share and which tracks `.the-loop/manifest.yaml`.

| Constant           | Value         | Notes                                                            |
|--------------------|---------------|------------------------------------------------------------------|
| `NVM_TAG`          | `v0.40.6`     | tag-versioned installer URL                                      |
| `UV_VERSION`       | `0.12.0`      | version-scoped installer URL                                     |
| `BUN_VERSION`      | `bun-v1.3.14` | pins the bun installed; `bun.sh/install` is not itself versioned |
| `GO_VERSION`       | `1.22.5`      | go.dev release tarball                                           |
| `TTYD_VERSION`     | `1.7.7`       | GitHub release binary                                            |
| `THE_LOOP_VERSION` | `19.27.0`     | `the-loopy-one` on PyPI; a bump can carry a config migration     |
| `PYTHON_VERSION`   | `3.13`        | uv fallback only; pinned minor, patch floats                     |
| node               | —             | deliberately unpinned (`nvm install --lts`)                      |

The oh-my-zsh, poetry, claude and cursor installers are not versioned. Bump a pin by
editing the block at the top of the script; the tests assert the constants stay
version-shaped and the URLs stay HTTPS on an approved vendor host.

## Design

Pointers, not copies:

- [`docs/specs/issue-2/design.md`](../specs/issue-2/design.md) — architecture, the
  `fetch_and_run` chokepoint, security design, testing strategy.
- [`docs/specs/issue-2/requirements.md`](../specs/issue-2/requirements.md) — EARS
  acceptance criteria and the threat model.
- `tests/integration/test_setup_script.py` + `conftest.py` — the PATH sandbox that lets
  the suite exercise an installer offline, without installing anything.
- `tests/integration/test_setup_shared.py` — what both scripts share: parity, the
  managed `~/.zshrc` block, `clone_repo`, shellcheck. The sandbox redirects
  `/workspace` and `/usr/local/go` through `$DEVBOX_WORKSPACE` and `$DEVBOX_GO_ROOT`.
- `tests/integration/test_setup_arch_script.py` — the same sandbox with `pacman` and
  `sudo` stubbed. `setup-arch.sh` reads `$DEVBOX_OS_RELEASE` instead of `/etc/os-release`
  when it is set, which exists for one reason: CI runs on Ubuntu and still has to
  exercise the distribution guard.

## History

| Work item | What changed                                                                                                                                                                                                                                                                                                                                            | Links                                                                                      |
|-----------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------|
| issue-2   | Introduced `scripts/setup.sh`: installs nvm/node/npm/bun/python3/uv, idempotent, `--dry-run`/`--only`, root refusal, pinned HTTPS-only vendor installers downloaded before execution                                                                                                                                                                    | [spec](../specs/issue-2/), [issue #2](https://github.com/MadaraUchiha-314/devbox/issues/2) |
| —         | Added `scripts/setup-arch.sh`: the same contract on Arch and its derivatives, installing uv/python/nvm/bun with `sudo pacman -S --needed` and no downloads at all; node still from nvm                                                                                                                                                                  | —                                                                                          |
| —         | Merged in the provisioning gist: zsh/oh-my-zsh, wget, build tools, yarn, pnpm, the-loop (CLI + plugin), poetry, go, gh, podman, shellcheck, ttyd, claude, cursor; dotfiles, managed `~/.zshrc` block, login shell, `/workspace` + `clone_repo`, startup commands. Root is now allowed (cloud containers) and system steps escalate through `maybe_sudo` | —                                                                                          |
