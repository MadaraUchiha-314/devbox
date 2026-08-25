# devbox

My devbox!

## Setup

Provision a fresh machine with the whole toolchain — **nvm, node, npm, bun, python3, uv**
— in one command. Pick the script that matches the box:

```sh
./scripts/setup.sh               # macOS and other Linux — vendor installers into $HOME
./scripts/setup-arch.sh          # Arch and derivatives — pacman
```

Both take the same flags:

```sh
./scripts/setup.sh --dry-run     # show the plan, change nothing
./scripts/setup.sh --only uv     # one tool
```

They are idempotent: anything already installed is reported and left alone, so re-running
one to top up a partially provisioned box is safe. Neither edits your shell profiles, so
open a new shell afterwards to pick up whatever is new.

`setup.sh` installs only under `$HOME`, never uses `sudo`, and refuses to run as root.
`setup-arch.sh` installs uv, python, nvm and bun as system packages, so it does use
`sudo` — for `pacman -S --needed` and nothing else. Node comes from nvm either way.

macOS is `setup.sh`'s tested target; other Linux runs the same code path. See
[docs/capabilities/devbox-provisioning.md](docs/capabilities/devbox-provisioning.md) for
the full behaviour, the pinned vendor versions and how to bump them.

## Development

```sh
uv run pytest                                             # tests
uv run pre-commit run --all-files --hook-stage pre-push   # everything CI runs
```
