---
type: requirements
phase: requirements-definition
workItem: "github:MadaraUchiha-314/devbox#2"
status: in-review           # draft | in-review | approved
approvedBy: []              # handles/roles who approved this phase (paper trail)
collaborators: [engineer, reviewer, approver]
riskTier: 3                 # executes vendor install scripts on the operator's own machine, no privileged/system-wide writes
overrides: {}
---

# Requirements: devbox setup script (`scripts/setup.sh`)

> Phase 1 of 3 (requirements → design → tasks). Following the
> [Kiro spec approach](https://kiro.dev/docs/specs/). This phase MUST be reviewed and
> approved by the required collaborators before moving to design.

## Introduction

[Issue #2](https://github.com/MadaraUchiha-314/devbox/issues/2) asks for an install
script at `scripts/setup.sh` that provisions a fresh development box with:

`nvm` · `node` · `npm` · `bun` · `python3` · `uv`

This repository *is* the devbox: its purpose is to make a new machine (or a rebuilt one)
usable with a single command, without hand-following six vendor READMEs. The script is
run **manually by the machine's owner**, from the repository root, on a machine they
control.

Scope note on the six items: `node` and `npm` are not installed independently — `npm`
ships inside every Node.js distribution, and `nvm` is the Node version manager that
installs Node. So the six names map onto **four installers** (nvm, bun, uv, and a Python
interpreter), and the script must still *verify* all six are present and report each one.

## Requirements

### Requirement 1 — One command provisions the whole toolchain

**User story:** As the owner of this devbox, I want a single script that installs nvm,
node, npm, bun, python3 and uv, so that a fresh machine is ready to work on without me
following six separate vendor guides.

#### Acceptance criteria (EARS)

1. WHEN the operator runs `scripts/setup.sh` on a machine with none of the tools present
   THEN the system SHALL install nvm, a Node.js LTS release (providing `node` and `npm`),
   bun, uv, and a `python3` interpreter.
2. WHEN the script finishes successfully THEN the system SHALL print a summary line for
   **each of the six tools** naming the tool, its resolved version, and whether it was
   `installed` or `already present`.
3. WHEN every requested tool is installed THEN the system SHALL exit with status `0`.
4. IF any requested tool could not be installed or verified THEN the system SHALL exit
   with a non-zero status and name the failing tool on stderr.

### Requirement 2 — Idempotent and re-runnable

**User story:** As the owner of this devbox, I want to re-run the script safely at any
time, so that I can top up a partially provisioned machine without damaging what is
already installed.

#### Acceptance criteria (EARS)

1. WHEN a tool is already present on `PATH` (or, for nvm, already installed at
   `$NVM_DIR`) THEN the system SHALL skip its installation and report it as
   `already present`.
2. WHEN the script is run twice in succession THEN the second run SHALL install nothing
   and SHALL still exit `0`.
3. WHILE the script runs it SHALL NOT modify, truncate or delete an existing tool
   installation, and SHALL NOT rewrite the operator's shell profile files itself.

### Requirement 3 — Inspectable before it acts

**User story:** As the owner of this devbox, I want to see exactly what the script would
do before it does it, so that I can trust running it on a machine that already has state.

#### Acceptance criteria (EARS)

1. WHEN the script is invoked with `--dry-run` THEN the system SHALL print the planned
   action (`install` or `skip`) for every tool, SHALL perform no download, no
   installation and no filesystem mutation, and SHALL exit `0`.
2. WHEN the script is invoked with `--help` THEN the system SHALL print usage including
   every supported flag and every supported tool name, and SHALL exit `0`.
3. WHEN the script is invoked with `--only <tool>` THEN the system SHALL act on that tool
   alone and SHALL leave all other tools untouched.
4. IF the script is invoked with an unrecognised flag or an unknown `--only` value THEN
   the system SHALL print usage to stderr and SHALL exit non-zero **without installing
   anything** (fail closed).

### Requirement 4 — Honest, readable progress output

**User story:** As the owner of this devbox, I want to see what the script is doing while
it runs, so that a long vendor download does not look like a hang and a failure is
obvious.

#### Acceptance criteria (EARS)

1. WHILE the script installs a tool it SHALL log the step it is on to stdout, using the
   same message format at every step.
2. WHEN a step fails THEN the system SHALL surface the failing command's own error output
   rather than swallowing it, and SHALL stop rather than continuing to the next tool.
3. WHEN the script needs the operator to do something afterwards (e.g. open a new shell,
   or `source` a profile so a freshly installed tool is on `PATH`) THEN the system SHALL
   print that instruction explicitly at the end.

## Non-functional requirements

- **Platform:** macOS (Apple Silicon and Intel) is the supported target — the operator's
  devbox. The script SHALL additionally run unchanged on x86-64/arm64 Linux where the
  same vendor installers are supported; where a platform is unsupported it SHALL fail
  closed with a clear message rather than guess.
- **Shell:** `bash` (the interpreter guaranteed present on macOS as `/bin/bash` 3.2), run
  as `scripts/setup.sh` or `bash scripts/setup.sh`. It SHALL NOT require bash 4+ features
  or a package manager (Homebrew) to be present.
- **Network:** the script requires outbound HTTPS. Offline execution is expected to fail
  closed, not to half-install.
- **Runtime:** a cold run on a fast connection should complete in a few minutes; no step
  may block waiting on interactive input.
- **Observability:** identical at dev-time and runtime (`observability.devLevel: debug`)
  — the script's own step logging is the only channel, with `--dry-run` as the debug
  view. Vendor installer output is passed through, not hidden.

## Security considerations

> Threat-model-lite (`security.threatModel.required`). This work item **does add attack
> surface** — it downloads and executes third-party code — so the section below is stated
> concretely rather than waved through.

- **Actors & trust:**
  - *Trusted:* the operator running the script on their own machine (they already have
    full control of that machine; the script grants them nothing new).
  - *Untrusted:* **everything fetched over the network** — the nvm, bun and uv installer
    scripts, the Node.js and Python distributions they pull, and any DNS/TLS
    intermediary. This is the core exposure: `curl … | bash` executes remote code with
    the operator's own privileges.
  - *Untrusted:* the script's own **command-line arguments** and the ambient
    **environment** (`PATH`, `NVM_DIR`, `HOME`, `TMPDIR`) — a poisoned `PATH` or a
    writable `TMPDIR` entry is the classic local escalation route for an install script.
- **Trust boundaries & data:**
  1. *Network → local execution.* Remote installer scripts crossing into a local `bash`
     process. Enforcement must be: HTTPS only, official vendor hosts only, and versions
     pinned so a run is reproducible and a compromised "latest" cannot silently change
     what executes.
  2. *Arguments → control flow.* `--only <tool>` selects an installer; it must resolve
     against a fixed allow-list, never be interpolated into a command or a URL.
  3. *Environment → filesystem writes.* All writes stay under the invoking user's `$HOME`
     (`$NVM_DIR`, `~/.bun`, `~/.local`); no system-wide paths, no `sudo`, no privileged
     escalation anywhere in the script.
  - **Sensitive data:** none. The script handles no secrets, tokens or PII, reads no
    credential files, and sends nothing anywhere — it only fetches.
- **Abuse cases (EARS):**
  1. WHEN the script is invoked as `root` (uid 0, or via `sudo`) THEN the system SHALL
     refuse to run and exit non-zero, so a compromised vendor installer never executes
     with system privileges.
  2. WHEN an installer URL in the script is not `https://` on the tool's official vendor
     host THEN the system SHALL be considered defective — this is asserted by a test over
     the script source, so a later edit cannot quietly introduce a plaintext or
     third-party download.
  3. WHEN a download fails, is truncated, or returns a non-success HTTP status THEN the
     system SHALL abort with a non-zero exit **without executing the partial payload**.
  4. WHEN `--only` is given a value outside the allow-list (including shell metacharacters
     such as `; rm -rf ~`) THEN the system SHALL reject it and exit non-zero without
     executing anything.
  5. WHEN the script writes a temporary file THEN it SHALL do so in a private,
     freshly-created temporary directory owned by the user, and SHALL remove it on exit,
     so a pre-planted symlink in a shared `/tmp` path cannot be followed.
- **Fail closed:** unknown flag, unknown `--only` value, unsupported OS/architecture,
  missing `curl`, uid 0, failed download, or failed post-install verification — every one
  of these aborts with a non-zero exit and no further installation. The script never
  "continues anyway".
- **Residual risk (accepted, to be confirmed at approval):** pinning and HTTPS reduce, but
  do not eliminate, the trust placed in nvm/bun/uv/Node.js/Python upstream — installing a
  toolchain *is* trusting its vendors. Checksum verification of the installer scripts is
  considered in the design phase; it is only meaningful if the pinned artefact is
  immutable.

## Out of scope

- Installing anything not named in the issue (no Docker/podman, no editors, no shells, no
  git config, no dotfiles management).
- Managing shell profiles/rc files: the vendor installers append their own lines; this
  script does not edit `~/.zshrc`/`~/.bashrc` on the operator's behalf.
- Uninstall, upgrade-in-place, or version-switching workflows (`nvm install <v>` and
  `uv python install <v>` already cover those directly).
- Windows support (including WSL as an explicitly tested target).
- Running the script in CI as a provisioning step for this repo's own workflows.

## Open questions

Raised on the ticket (paper trail) with the approval request:

1. **Python provider.** Preference is to install `python3` via **uv** (`uv python
   install`) rather than Homebrew, so the script needs no package manager and behaves the
   same on macOS and Linux — at the cost of `python3` being a uv-managed interpreter
   rather than a system one. Alternative: accept a pre-existing system `python3` when
   present and only fall back to uv. **Assumed default:** prefer an existing `python3`
   (≥ 3.11, matching `pyproject.toml`), else install via uv.
2. **Node version.** **Assumed default:** `nvm install --lts` and make it the default
   alias, rather than pinning an exact Node version in the script.
3. **Linux breadth.** **Assumed default:** best-effort — the same vendor installers run on
   Linux and are exercised by the same code path, but macOS is the only platform tested.

Each assumption is recorded in `docs/decisions/conflicts.md` and is cheap to reverse at
this gate.

## Review comments

> Appended by the-loop's `record-feedback` hook when a human gate approves with
> comments (issue-109).
