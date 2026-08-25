# Capability: devbox provisioning

> Turning a bare machine into a working devbox with one command.

## What it is

Two scripts install the toolchain this box is built on — **nvm, node, npm, bun, python3,
uv** — so a fresh or rebuilt machine is usable without following six vendor guides by
hand. Each is run manually by the machine's owner, from the repository root.

| Script                  | For                      | How it installs                                                         |
|-------------------------|--------------------------|-------------------------------------------------------------------------|
| `scripts/setup.sh`      | macOS, non-Arch Linux    | pinned vendor installers, downloaded over HTTPS into `$HOME`, no `sudo` |
| `scripts/setup-arch.sh` | Arch and its derivatives | `sudo pacman -S --needed` for uv, python, nvm and bun; no downloads     |

They share a user interface, a tool registry and a summary table; they differ only in
where a tool comes from. Both walk the tools in dependency order
(`uv → python3 → nvm → node → npm → bun`), detect each one before touching it, and report
all six either way.

Six names, **four installers** on macOS: `npm` ships inside every Node.js distribution,
and `nvm` is what installs Node. On Arch it is **two**: pacman, then nvm for node.

**Why a second script rather than a branch inside the first.** The two have different
invariants, and one script cannot hold both honestly. `setup.sh` promises it never
escalates and writes only under `$HOME`; the pacman path exists precisely to install
system packages, so it must escalate. Keeping them apart means each one's guarantee is
checkable by reading it — and the test suites assert exactly those opposite properties
(`test_script_never_uses_sudo` against one, `test_privileges_are_escalated_only_for_pacman`
against the other).

## Current behaviour

### Shared by both scripts

- The system SHALL install nvm, a Node.js LTS release (providing `node` and `npm`), bun,
  uv, and a `python3` interpreter, when they are absent.
- WHEN a tool is already present THEN the system SHALL skip it and report it as
  `already present` — re-running the script is safe and installs nothing.
- WHEN the run finishes THEN the system SHALL print one summary line per tool: name,
  resolved version, and status (`installed` · `already present` · `planned`).
- WHEN invoked with `--dry-run` THEN the system SHALL print the plan and perform no
  download, installation or filesystem write.
- WHEN invoked with `--only <tool>` THEN the system SHALL act on that tool alone; the
  value is matched against a fixed allow-list.
- WHEN invoked with an unrecognised flag or `--only` value THEN the system SHALL print
  usage to stderr and exit `2` without installing anything.
- WHEN run as root (uid 0) THEN the system SHALL refuse to run.
- WHEN a tool is missing after its installer reported success THEN the system SHALL exit
  non-zero naming that tool.
- WHEN nothing was installed THEN the system SHALL say the box is already provisioned
  rather than asking the operator to open a new shell.
- The system SHALL NOT edit the operator's shell profiles.

### `scripts/setup.sh` only

- WHEN a download fails, returns a non-success status, or cannot use HTTPS THEN the system
  SHALL abort without executing the payload.
- The system SHALL write only under `$HOME` (`$NVM_DIR`, `~/.bun`, `~/.local`) and SHALL
  NOT use `sudo` — the vendor installers already append their own profile lines.

### `scripts/setup-arch.sh` only

- The system SHALL install uv, python, nvm and bun from the official Arch repositories,
  and SHALL obtain `node` from nvm rather than from `extra/nodejs` — a pacman-owned
  `/usr/bin/node` would shadow every version nvm manages.
- The system SHALL escalate privileges for `pacman -S --needed -- <package>` and for
  nothing else.
- The system SHALL NOT refresh the package database: `pacman -Sy <pkg>` leaves the box in
  a partial-upgrade state, and a full `pacman -Syu` is the operator's call. WHEN pacman
  fails THEN the system SHALL say so and name `-Syu` as the likely remedy.
- WHEN `pacman` is absent, or `/etc/os-release` reports neither `ID` nor `ID_LIKE` in the
  arch family, THEN the system SHALL refuse to run and point at `scripts/setup.sh`.
- WHEN invoked with `--noconfirm` THEN the system SHALL pass it to pacman; otherwise
  pacman prompts.
- WHEN nvm was installed by pacman THEN the system SHALL print the
  `source /usr/share/nvm/init-nvm.sh` line to add to a shell profile, since the packaged
  nvm writes no init line and this script does not edit profiles.

### Supported platforms

| Script                  | Tested target                | Also runs on                        | Elsewhere           |
|-------------------------|------------------------------|-------------------------------------|---------------------|
| `scripts/setup.sh`      | macOS (Apple Silicon, Intel) | x86-64/arm64 Linux, same code path  | fails closed, named |
| `scripts/setup-arch.sh` | Omarchy (`ID_LIKE=arch`)     | Arch, EndeavourOS, CachyOS, Manjaro | fails closed, named |

`setup.sh` targets **bash 3.2**, the version macOS ships as `/bin/bash`. `setup-arch.sh`
keeps to the same dialect for the sake of the reader, though Arch ships bash 5.

### Pinned versions

`setup-arch.sh` pins nothing, and that is the point of using pacman: the repositories
decide the version, `pacman -Syu` moves it forward with the rest of the system, and
`pacman -Qo` can say where any binary came from. The pins below are `setup.sh`'s.

| Constant         | Value         | Notes                                                            |
|------------------|---------------|------------------------------------------------------------------|
| `NVM_TAG`        | `v0.40.6`     | tag-versioned installer URL                                      |
| `UV_VERSION`     | `0.12.0`      | version-scoped installer URL                                     |
| `BUN_VERSION`    | `bun-v1.3.14` | pins the bun installed; `bun.sh/install` is not itself versioned |
| `PYTHON_VERSION` | `3.13`        | pinned minor; patch floats                                       |
| node             | —             | deliberately unpinned (`nvm install --lts`)                      |

Bump by editing the Pins block at the top of `scripts/setup.sh`; the tests assert the
constants stay version-shaped and the URLs stay HTTPS on a vendor host.

## Design

Pointers, not copies:

- [`docs/specs/issue-2/design.md`](../specs/issue-2/design.md) — architecture, the
  `fetch_and_run` chokepoint, security design, testing strategy.
- [`docs/specs/issue-2/requirements.md`](../specs/issue-2/requirements.md) — EARS
  acceptance criteria and the threat model.
- `tests/integration/test_setup_script.py` + `conftest.py` — the PATH sandbox that lets
  the suite exercise an installer offline, without installing anything.
- `tests/integration/test_setup_arch_script.py` — the same sandbox with `pacman` and
  `sudo` stubbed. `setup-arch.sh` reads `$DEVBOX_OS_RELEASE` instead of `/etc/os-release`
  when it is set, which exists for one reason: CI runs on Ubuntu and still has to
  exercise the distribution guard.

## History

| Work item | What changed                                                                                                                                                                           | Links                                                                                      |
|-----------|----------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------|
| issue-2   | Introduced `scripts/setup.sh`: installs nvm/node/npm/bun/python3/uv, idempotent, `--dry-run`/`--only`, root refusal, pinned HTTPS-only vendor installers downloaded before execution   | [spec](../specs/issue-2/), [issue #2](https://github.com/MadaraUchiha-314/devbox/issues/2) |
| —         | Added `scripts/setup-arch.sh`: the same contract on Arch and its derivatives, installing uv/python/nvm/bun with `sudo pacman -S --needed` and no downloads at all; node still from nvm | —                                                                                          |
