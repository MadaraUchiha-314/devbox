"""Test harness for `scripts/setup.sh` and `scripts/setup-arch.sh`.

The script under test exists to mutate the machine it runs on, so the tests must
exercise it without installing anything. Every test therefore runs it inside a **PATH
sandbox**: a temporary `bin/` holding symlinks to just the utilities the script is
allowed to depend on, plus stub executables for whichever tools that scenario wants to
look "installed", with `HOME` pointed at a throwaway directory.

`PATH` is set to the sandbox `bin/` *alone*, so nothing from the developer's real
machine leaks in — most importantly the macOS `/usr/bin/python3` shim, which would
otherwise make a bare box look provisioned.
"""

from __future__ import annotations

import os
import re
import shutil
import subprocess
from dataclasses import dataclass
from pathlib import Path

import pytest

REPO_ROOT = Path(__file__).resolve().parents[2]
SCRIPT = REPO_ROOT / "scripts" / "setup.sh"

#: The only external commands the setup scripts may rely on. Keeping this list short is
#: itself a design constraint: a new entry here means a script grew a dependency, which
#: is a thing to notice in review rather than discover on a bare machine. Everything
#: past `uname` is POSIX coreutils/grep/sed, used to write ~/.vimrc, ~/.zshrc and its
#: managed block.
SANDBOX_UTILS = (
    "id",
    "curl",
    "mktemp",
    "rm",
    "uname",
    "dirname",
    "cat",
    "touch",
    "grep",
    "sed",
    "mv",
    "head",
    "mkdir",
    "ln",
    "cut",
    "chown",
)

#: Resolved once against the *real* PATH, before any sandboxing.
BASH = shutil.which("bash") or "/bin/bash"

#: The-loop pin, read from the script so the stubs below track a bump.
THE_LOOP_VERSION = re.search(
    r'^THE_LOOP_VERSION="([^"]+)"', SCRIPT.read_text(), re.MULTILINE
).group(1)  # type: ignore[union-attr]


@dataclass
class Sandbox:
    """A throwaway machine: an isolated `PATH`, an isolated `HOME`."""

    root: Path
    bin: Path
    home: Path

    def stub(self, name: str, *, stdout: str = "", exit_code: int = 0) -> Path:
        """Put a fake executable named `name` on the sandbox PATH.

        Unlinks first: several of the allow-listed utilities are already present as
        symlinks to the real binary, and writing through a symlink would try to
        overwrite `/usr/bin/id` rather than shadow it.
        """
        path = self.bin / name
        if path.exists() or path.is_symlink():
            path.unlink()
        body = f'#!/bin/sh\nprintf "%s\\n" "{stdout}"\nexit {exit_code}\n'
        path.write_text(body)
        path.chmod(0o755)
        return path

    def script_stub(self, name: str, body: str) -> Path:
        """Put an arbitrary `/bin/sh` script on the sandbox PATH, shadowing any real one."""
        path = self.bin / name
        if path.exists() or path.is_symlink():
            path.unlink()
        path.write_text(body)
        path.chmod(0o755)
        return path

    def install_nvm_stub(self, version: str = "0.40.6") -> Path:
        """nvm is a shell function, not a binary — fake it the way nvm itself ships."""
        nvm_dir = self.home / ".nvm"
        nvm_dir.mkdir(parents=True, exist_ok=True)
        nvm_sh = nvm_dir / "nvm.sh"
        nvm_sh.write_text(
            "nvm() {\n"
            '  if [ "$1" = "--version" ]; then\n'
            f'    printf "%s\\n" "{version}"\n'
            "  fi\n"
            "}\n"
        )
        return nvm_sh

    def stub_all_tools(self) -> None:
        """Make every tool the scripts provision look already installed."""
        self.stub("python3", stdout="Python 3.13.1")
        self.stub("node", stdout="v22.20.0")
        self.stub("npm", stdout="10.9.4")
        self.stub("bun", stdout="1.3.14")
        self.install_nvm_stub()
        for name in (
            "zsh", "wget", "vim", "cc", "make", "git", "yarn", "pnpm", "the-loop",
            "poetry", "go", "gh", "podman", "shellcheck", "ttyd", "claude", "cursor",
        ):  # fmt: skip
            self.stub(name, stdout=f"{name} 1.0.0")
        (self.home / ".oh-my-zsh").mkdir(exist_ok=True)

        # the-loop counts as installed only at the pinned version, read from the uv tool
        # venv's receipt; `uv tool dir` says where that venv lives.
        tool_dir = self.root / "uv-tools"
        receipt = tool_dir / "the-loopy-one" / "uv-receipt.toml"
        receipt.parent.mkdir(parents=True, exist_ok=True)
        receipt.write_text(
            f'requirements = [{{ name = "the-loopy-one", specifier = "=={THE_LOOP_VERSION}" }}]\n'
        )
        self.script_stub(
            "uv",
            "#!/bin/sh\n"
            f'if [ "$1 $2" = "tool dir" ]; then printf "%s\\n" "{tool_dir}"; exit 0; fi\n'
            'printf "%s\\n" "uv 0.12.0"\n',
        )

        plugins = self.home / ".claude" / "plugins"
        plugins.mkdir(parents=True, exist_ok=True)
        (plugins / "installed_plugins.json").write_text(
            '{"plugins": {"the-loop@the-loop": []}}'
        )

    def run(
        self,
        *args: str,
        env: dict[str, str] | None = None,
        script: Path | None = None,
    ) -> subprocess.CompletedProcess[str]:
        """Run the script with `PATH` and `HOME` confined to this sandbox."""
        environment = {
            "PATH": str(self.bin),
            "HOME": str(self.home),
            "TMPDIR": str(self.root / "tmp"),
            # Never the host's own /workspace or /usr/local/go.
            "DEVBOX_WORKSPACE": str(self.root / "workspace"),
            "DEVBOX_GO_ROOT": str(self.root / "go"),
        }
        if env:
            environment.update(env)
        return subprocess.run(
            [BASH, str(script or SCRIPT), *args],
            env=environment,
            capture_output=True,
            text=True,
            timeout=120,
            check=False,
        )

    def home_tree(self) -> set[str]:
        """Every path under HOME, relative — for asserting nothing was touched."""
        return {str(p.relative_to(self.home)) for p in self.home.rglob("*")}


@pytest.fixture
def sandbox(tmp_path: Path) -> Sandbox:
    """A bare machine: allow-listed utilities only, no tools installed."""
    bin_dir = tmp_path / "bin"
    home_dir = tmp_path / "home"
    tmp_dir = tmp_path / "tmp"
    for directory in (bin_dir, home_dir, tmp_dir):
        directory.mkdir(parents=True)

    for util in SANDBOX_UTILS:
        real = shutil.which(util)
        assert real is not None, f"sandbox utility {util!r} not found on this machine"
        os.symlink(real, bin_dir / util)

    sandbox = Sandbox(root=tmp_path, bin=bin_dir, home=home_dir)
    # A full run ends by setting the login shell: never let it reach the real chsh.
    sandbox.stub("chsh")
    # Root-only steps (/workspace) go through sudo when not root: let it pass through.
    sandbox.script_stub("sudo", '#!/bin/sh\nexec "$@"\n')
    return sandbox


@pytest.fixture(scope="session")
def script_source() -> str:
    """The script's own text, for assertions made against the source rather than a run."""
    return SCRIPT.read_text()
