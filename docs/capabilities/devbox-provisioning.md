# Capability: devbox provisioning

> Turning a bare machine into a working devbox with one command.

## What it is

`scripts/setup.sh` installs the toolchain this box is built on — **nvm, node, npm, bun,
python3, uv** — so a fresh or rebuilt machine is usable without following six vendor
guides by hand. It is run manually by the machine's owner, from the repository root.

Six names, **four installers**: `npm` ships inside every Node.js distribution, and `nvm`
is what installs Node. The script walks the tools in dependency order
(`uv → python3 → nvm → node → npm → bun`), detects each one before touching it, and
reports all six either way.

## Current behaviour

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
- WHEN run as root (uid 0) THEN the system SHALL refuse to run, so a vendor installer
  never executes with system privileges.
- WHEN a download fails, returns a non-success status, or cannot use HTTPS THEN the system
  SHALL abort without executing the payload.
- WHEN a tool is missing after its installer reported success THEN the system SHALL exit
  non-zero naming that tool.
- WHEN nothing was installed THEN the system SHALL say the box is already provisioned
  rather than asking the operator to open a new shell.
- The system SHALL write only under `$HOME` (`$NVM_DIR`, `~/.bun`, `~/.local`), SHALL NOT
  use `sudo`, and SHALL NOT edit the operator's shell profiles — the vendor installers
  already append their own lines.

### Supported platforms

macOS (Apple Silicon and Intel) is the tested target; x86-64/arm64 Linux runs the same
code path. Any other OS or architecture fails closed with a named reason. The script
targets **bash 3.2**, the version macOS ships as `/bin/bash`.

### Pinned versions

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

## History

| Work item | What changed                                                                                                                                                                         | Links                                                                                      |
|-----------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|--------------------------------------------------------------------------------------------|
| issue-2   | Introduced `scripts/setup.sh`: installs nvm/node/npm/bun/python3/uv, idempotent, `--dry-run`/`--only`, root refusal, pinned HTTPS-only vendor installers downloaded before execution | [spec](../specs/issue-2/), [issue #2](https://github.com/MadaraUchiha-314/devbox/issues/2) |
