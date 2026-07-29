# devbox

My devbox!

## Setup

Provision a fresh machine with the whole toolchain — **nvm, node, npm, bun, python3, uv**
— in one command:

```sh
./scripts/setup.sh --dry-run     # show the plan, change nothing
./scripts/setup.sh               # provision
./scripts/setup.sh --only uv     # one tool
```

The script is idempotent: anything already installed is reported and left alone, so
re-running it to top up a partially provisioned box is safe.

It installs only under `$HOME`, never uses `sudo` (and refuses to run as root), and never
edits your shell profiles — the vendor installers already append their own lines, so open
a new shell afterwards to pick up whatever is new.

macOS is the tested target; Linux runs the same code path. See
[docs/capabilities/devbox-provisioning.md](docs/capabilities/devbox-provisioning.md) for
the full behaviour, the pinned vendor versions and how to bump them.

## Development

```sh
uv run pytest                                             # tests
uv run pre-commit run --all-files --hook-stage pre-push   # everything CI runs
```
