"""Integration tests for behaviour `scripts/setup.sh` and `scripts/setup-arch.sh` share.

Feature: beyond installing tools, both scripts configure the box the same way — a
managed block in ~/.zshrc, ~/.vimrc, the /workspace clone layout — and can be sourced
for their helpers (clone_repo) without provisioning anything.

Every scenario runs in the PATH sandbox from `conftest.py`; `/workspace` is redirected
into it through DEVBOX_WORKSPACE.
"""

from __future__ import annotations

import re
import shlex
import shutil
import subprocess
from pathlib import Path

import pytest
from conftest import BASH, REPO_ROOT, Sandbox

SETUP = REPO_ROOT / "scripts" / "setup.sh"
SETUP_ARCH = REPO_ROOT / "scripts" / "setup-arch.sh"

BEGIN = "# >>> devbox setup.sh managed block >>>"

by_script = pytest.mark.parametrize("script", (SETUP, SETUP_ARCH), ids=lambda p: p.name)


def run(sandbox: Sandbox, script: Path, *args: str) -> subprocess.CompletedProcess[str]:
    """Run either script; the Arch one also gets a fake os-release and pacman."""
    env: dict[str, str] = {}
    if script == SETUP_ARCH:
        os_release = sandbox.root / "os-release"
        os_release.write_text("ID=arch\n")
        env["DEVBOX_OS_RELEASE"] = str(os_release)
        if not (sandbox.bin / "pacman").exists():
            sandbox.stub("pacman")
    return sandbox.run(*args, env=env, script=script)


def source(
    sandbox: Sandbox, script: Path, snippet: str
) -> subprocess.CompletedProcess[str]:
    """Source `script` in the sandbox, then run `snippet` against its helpers."""
    return subprocess.run(
        [BASH, "-c", f". {shlex.quote(str(script))}\n{snippet}"],
        env={"PATH": str(sandbox.bin), "HOME": str(sandbox.home)},
        capture_output=True,
        text=True,
        timeout=60,
        check=False,
    )


def main_steps(script: Path) -> list[str]:
    body = script.read_text().split("\nmain() {\n", 1)[1].split("\n}\n", 1)[0]
    return [line.strip() for line in body.splitlines() if line.strip()]


# --------------------------------------------------------------------------------------
# Parity
# --------------------------------------------------------------------------------------


def test_both_scripts_provision_the_same_tools_in_the_same_order() -> None:
    """
    Scenario: The Arch edition differs in where tools come from, never in which
        Given both scripts
        When their TOOLS lists and main() bodies are compared
        Then they are identical
    """
    tools = re.compile(r'^TOOLS="([^"]+)"', re.M)
    assert tools.findall(SETUP.read_text()) == tools.findall(SETUP_ARCH.read_text())
    assert main_steps(SETUP) == main_steps(SETUP_ARCH)


def code(script: Path) -> str:
    """The script without its comment lines."""
    lines = script.read_text().splitlines()
    return "\n".join(line for line in lines if not line.lstrip().startswith("#"))


def test_setup_never_calls_pacman_and_arch_never_calls_apt() -> None:
    assert "pacman" not in code(SETUP)
    assert "apt-get" in code(SETUP)
    assert not re.search(r"\b(apt-get|dpkg|brew)\b", code(SETUP_ARCH))


# --------------------------------------------------------------------------------------
# A full run configures the box
# --------------------------------------------------------------------------------------


@by_script
def test_full_run_writes_dotfiles_and_one_managed_block(
    sandbox: Sandbox, script: Path
) -> None:
    """
    Scenario: Re-running replaces the managed block instead of stacking it
        Given a provisioned machine whose ~/.zshrc already has the operator's own lines
        When the script is run twice
        Then ~/.vimrc is written, the operator's lines survive
        And ~/.zshrc holds exactly one managed block with each PATH entry once
    """
    sandbox.stub_all_tools()
    zshrc = sandbox.home / ".zshrc"
    zshrc.write_text("# mine\nalias ll='ls -l'\n")

    for _ in range(2):
        result = run(sandbox, script)
        assert result.returncode == 0, result.stderr

    text = zshrc.read_text()
    assert text.startswith("# mine\nalias ll='ls -l'\n")
    assert text.count(BEGIN) == 1
    assert text.count('export PATH="' + str(sandbox.home) + '/.local/bin:$PATH"') == 1
    assert "oh-my-zsh.sh" in text
    assert (sandbox.home / ".vimrc").read_text() == "set nu\nsy on\n"
    assert (sandbox.root / "workspace").is_dir()


@by_script
def test_only_run_skips_the_box_wide_steps(sandbox: Sandbox, script: Path) -> None:
    """
    Scenario: --only installs one tool and refreshes the block, nothing else
        Given a provisioned machine
        When the script is run with --only uv
        Then the managed block is written, but /workspace is not created
    """
    sandbox.stub_all_tools()
    result = run(sandbox, script, "--only", "uv")
    assert result.returncode == 0, result.stderr
    assert BEGIN in (sandbox.home / ".zshrc").read_text()
    assert not (sandbox.root / "workspace").exists()


@by_script
def test_optional_tool_failure_does_not_abort(sandbox: Sandbox, script: Path) -> None:
    """
    Scenario: A nice-to-have that fails to install is reported, not fatal
        Given a machine with no claude, so the-loop's claude plugin cannot install
        When the script is run with --only the-loop-plugin
        Then it exits zero and the summary marks the plugin as failed (optional)
    """
    result = run(sandbox, script, "--only", "the-loop-plugin")
    assert result.returncode == 0, result.stderr
    assert "failed (optional)" in result.stdout


# --------------------------------------------------------------------------------------
# Sourcing and clone_repo
# --------------------------------------------------------------------------------------


@by_script
def test_sourcing_defines_helpers_without_provisioning(
    sandbox: Sandbox, script: Path
) -> None:
    result = source(sandbox, script, "type clone_repo >/dev/null && echo sourced")
    assert result.returncode == 0, result.stderr
    assert result.stdout == "sourced\n"
    assert list(sandbox.home.iterdir()) == []


@by_script
@pytest.mark.parametrize(
    ("url", "layout"),
    [
        ("https://github.com/acme/widget.git", "github.com/acme/widget"),
        ("https://github.com/acme/widget", "github.com/acme/widget"),
        ("git@gitlab.example.com:acme/widget.git", "gitlab.example.com/acme/widget"),
    ],
)
def test_clone_repo_uses_host_org_repo_layout(
    sandbox: Sandbox, script: Path, url: str, layout: str
) -> None:
    """
    Scenario: Repos land at /workspace/<host>/<org>/<repo>
        Given an https or ssh git URL
        When clone_repo is called
        Then git clones it into the host/org/repo path under the workspace
    """
    transcript = sandbox.root / "git.log"
    sandbox.script_stub("git", f'#!/bin/sh\nprintf "%s\\n" "$*" >> {transcript}\n')
    workspace = sandbox.root / "workspace"
    result = source(sandbox, script, f"WORKSPACE={workspace}; clone_repo {url}")
    assert result.returncode == 0, result.stderr
    assert transcript.read_text().splitlines() == [f"clone {url} {workspace / layout}"]


@by_script
def test_clone_repo_skips_an_existing_checkout(sandbox: Sandbox, script: Path) -> None:
    sandbox.stub("git", exit_code=1)
    workspace = sandbox.root / "workspace"
    (workspace / "github.com/acme/widget/.git").mkdir(parents=True)
    result = source(
        sandbox,
        script,
        f"WORKSPACE={workspace}; clone_repo https://github.com/acme/widget",
    )
    assert result.returncode == 0, result.stderr


@by_script
def test_script_passes_shellcheck(script: Path) -> None:
    """
    Scenario: The scripts stay lint-clean
        Given either script
        When shellcheck (from the shellcheck-py dev dependency) inspects it
        Then it reports nothing
    """
    shellcheck = shutil.which("shellcheck")
    assert shellcheck is not None, "shellcheck missing — run `uv sync`"
    result = subprocess.run(
        [shellcheck, str(script)], capture_output=True, text=True, check=False
    )
    assert result.returncode == 0, result.stdout
