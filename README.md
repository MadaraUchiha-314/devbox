# devbox

My devbox!

## Setup

Clone this laptop's setup onto a machine — a cloud workspace or a fresh laptop — in one
command. It installs zsh + oh-my-zsh, nvm/node/npm, bun, yarn, pnpm, uv, python3,
the-loop, poetry, go, gh, podman, shellcheck, ttyd, claude and cursor, then writes
`~/.vimrc` and `~/.zshrc`, creates `/workspace` and runs the startup commands. Pick the
script that matches the box:

```sh
./scripts/setup.sh               # Debian/Ubuntu (apt) and macOS (Homebrew)
./scripts/setup-arch.sh          # Arch and derivatives (pacman)
```

Both take the same flags (`setup-arch.sh` also takes `--noconfirm` for unattended runs):

```sh
./scripts/setup.sh --dry-run     # show the plan, change nothing
./scripts/setup.sh --only uv     # one tool
```

They are idempotent: anything already installed is reported and left alone, so re-running
one to top up a partially provisioned box is safe. PATH and env lines go into one marked
block in `~/.zshrc` that each run replaces; open a new shell (`exec zsh -l`) afterwards.

System packages, `/workspace` and the login shell need root: the scripts run those
through `sudo`, or directly when already root (a cloud container). Vendor installers
never run as root. To clone a repo into `/workspace/<host>/<org>/<repo>`:

```sh
. scripts/setup.sh && clone_repo https://github.com/<org>/<repo>.git
```

See [docs/capabilities/devbox-provisioning.md](docs/capabilities/devbox-provisioning.md)
for the full behaviour, the pinned versions and how to bump them.

## Development

```sh
uv run pytest                                             # tests
uv run pre-commit run --all-files --hook-stage pre-push   # everything CI runs
```
