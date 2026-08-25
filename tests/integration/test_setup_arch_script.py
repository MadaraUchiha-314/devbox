"""Integration tests for `scripts/setup-arch.sh`.

Feature: devbox provisioning on Arch — pacman installs the toolchain instead of a
vendor installer per tool.

Every scenario runs the real script inside the PATH sandbox from `conftest.py`, with
`pacman` and `sudo` replaced by stubs, so the suite installs nothing and needs no root.
The distribution guard reads `$DEVBOX_OS_RELEASE`, which is what lets these tests run on
a non-Arch CI runner.
"""

from __future__ import annotations

import re
import stat
import subprocess
from pathlib import Path

import pytest
from conftest import BASH, REPO_ROOT, Sandbox

SCRIPT = REPO_ROOT / "scripts" / "setup-arch.sh"

TOOLS = ("nvm", "node", "npm", "bun", "python3", "uv")

#: Every package the script may ask pacman for, and the tool each one provides.
PACKAGES = {"uv": "uv", "python3": "python", "nvm": "nvm", "bun": "bun"}

URL_RE = re.compile(r"""https?://[^\s"'`)]+""")

#: An escalation and the command it runs. Applied to code with string literals blanked,
#: so `sudo` inside an error message is not mistaken for one being invoked; the second
#: lookbehind spares the preflight's `command -v sudo`, which asks after it rather than
#: using it.
ESCALATION_RE = re.compile(r"(?<![\w-])(?<!command -v )(sudo|doas)\s+(?P<rest>[^\n]*)")

STRING_LITERAL_RE = re.compile(r"\"[^\"\n]*\"|'[^'\n]*'")


def executable_lines(source: str) -> str:
    """The script with comment lines removed.

    The assertions below are about what the script *does*, so `pacman -Syu` named in a
    comment or an error message is not a finding — a `pacman -Sy` that actually runs is.
    """
    return "\n".join(
        line for line in source.splitlines() if not line.lstrip().startswith("#")
    )


def without_string_literals(source: str) -> str:
    """Executable lines with every quoted literal blanked out.

    Two of this script's error messages talk *about* sudo and `pacman -Syu` — telling
    the operator what it will not do for them. Blanking literals is what separates those
    from a command the script actually runs.
    """
    return STRING_LITERAL_RE.sub('""', executable_lines(source))


@pytest.fixture(scope="session")
def script_source() -> str:
    """The script's own text, for assertions made against the source rather than a run."""
    return SCRIPT.read_text()


@pytest.fixture
def arch(sandbox: Sandbox) -> Sandbox:
    """The bare-machine sandbox, dressed up as an Arch box.

    `sudo` execs its arguments rather than escalating, and `pacman` succeeds while
    installing nothing — which is also the shape of the "installer lied" failure path.
    """
    (sandbox.root / "os-release").write_text("ID=omarchy\nID_LIKE=arch\n")
    sandbox.script_stub("sudo", '#!/bin/sh\nexec "$@"\n')
    sandbox.stub("pacman")
    return sandbox


def run(sandbox: Sandbox, *args: str, **env: str) -> subprocess.CompletedProcess[str]:
    """Run `scripts/setup-arch.sh` in the sandbox, pointed at its fake os-release."""
    environment = {"DEVBOX_OS_RELEASE": str(sandbox.root / "os-release")}
    environment.update(env)
    return sandbox.run(*args, env=environment, script=SCRIPT)


def recording_pacman(sandbox: Sandbox) -> Path:
    """Replace the pacman stub with one that appends its argv to a file."""
    transcript = sandbox.root / "pacman.log"
    sandbox.script_stub(
        "pacman",
        f'#!/bin/sh\nprintf "%s\\n" "$*" >> {transcript}\nexit 0\n',
    )
    return transcript


# --------------------------------------------------------------------------------------
# Shape of the script itself
# --------------------------------------------------------------------------------------


def test_script_is_valid_bash() -> None:
    """
    Scenario: The script parses under the system bash
        Given the checked-in scripts/setup-arch.sh
        When bash parses it without executing (bash -n)
        Then it reports no syntax errors
    """
    result = subprocess.run(
        [BASH, "-n", str(SCRIPT)],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    assert result.returncode == 0, result.stderr


def test_script_is_executable() -> None:
    """
    Scenario: The script can be invoked directly
        Given the checked-in scripts/setup-arch.sh
        When its file mode is inspected
        Then the owner-execute bit is set
    """
    assert SCRIPT.stat().st_mode & stat.S_IXUSR, (
        "scripts/setup-arch.sh is not executable"
    )


def test_nothing_is_downloaded(script_source: str) -> None:
    """
    Scenario: The Arch edition has no network surface at all
        Given the script source
        When it is searched for downloads
        Then no URL is fetched and no downloader is invoked

    This is the whole reason the pacman edition exists: packages are signed, verified
    and recorded by the package manager, so there is no curl-to-shell to harden.
    """
    code = executable_lines(script_source)
    assert not URL_RE.findall(code), "setup-arch.sh downloads something"
    for downloader in ("curl", "wget"):
        assert not re.search(rf"(?m)^\s*{downloader}\s", code), (
            f"setup-arch.sh invokes {downloader}"
        )


def test_privileges_are_escalated_only_for_pacman(script_source: str) -> None:
    """
    Scenario: sudo is confined to one command
        Given the script source
        When every command-position sudo is inspected
        Then each one runs pacman and nothing else

    The sibling scripts/setup.sh never escalates at all. This script has to, so the
    guarantee it can offer instead is that root only ever runs the package manager.
    """
    matches = list(ESCALATION_RE.finditer(without_string_literals(script_source)))
    assert matches, "expected the script to escalate for pacman"
    for match in matches:
        assert match.group(1) == "sudo", "doas is not the escalation path in use"
        assert match.group("rest").lstrip().startswith("pacman"), (
            f"sudo runs something other than pacman: sudo{match.group('rest')}"
        )


def test_pacman_is_never_asked_for_a_partial_upgrade(script_source: str) -> None:
    """
    Scenario: The script cannot leave the box in a partial-upgrade state
        Given the script source
        When its pacman invocations are inspected
        Then none of them refreshes the database (-Sy/-Syu); they only install with --needed

    `pacman -Sy <pkg>` refreshes the package database without upgrading, so the package
    it then installs can be linked against libraries this box does not have yet. That
    call belongs to the operator, not to a provisioning script.
    """
    code = without_string_literals(script_source)
    assert not re.search(r"pacman\s+-Sy", code), (
        "setup-arch.sh refreshes the package database"
    )
    assert "args=(-S --needed)" in code, "pacman is invoked without --needed"


def test_package_names_cannot_be_read_as_flags(script_source: str) -> None:
    """
    Scenario: The package name is passed after an end-of-options marker
        Given the script source
        When the pacman invocation is inspected
        Then the package is passed after `--`
    """
    assert 'pacman "${args[@]}" -- "${package}"' in executable_lines(script_source)


def test_never_writes_to_shell_profiles(script_source: str) -> None:
    """
    Scenario: The operator's shell profiles stay the operator's
        Given the script source
        When it is searched for profile writes
        Then it never appends to .zshrc, .bashrc, .bash_profile or .profile

    The packaged nvm writes no init line either, so the script prints the line to add
    rather than adding it.
    """
    for profile in (".zshrc", ".bashrc", ".bash_profile", ".profile"):
        assert not re.search(rf">>\s*[^\n]*{re.escape(profile)}", script_source), (
            f"setup-arch.sh writes to {profile}"
        )


# --------------------------------------------------------------------------------------
# Usage, argument handling, fail-closed behaviour
# --------------------------------------------------------------------------------------


def test_help_lists_every_tool_and_flag(arch: Sandbox) -> None:
    """
    Scenario: --help documents the whole contract
        Given a bare machine
        When the script is run with --help
        Then it exits 0 and its usage names every supported tool and flag
    """
    result = run(arch, "--help")
    assert result.returncode == 0, result.stderr
    for token in (*TOOLS, "--dry-run", "--only", "--noconfirm", "--help"):
        assert token in result.stdout, f"--help does not mention {token}"


def test_help_runs_via_shebang() -> None:
    """
    Scenario: The script runs as scripts/setup-arch.sh, not only as `bash setup-arch.sh`
        Given the checked-in script with its shebang
        When it is executed directly with --help
        Then it exits 0
    """
    result = subprocess.run(
        [str(SCRIPT), "--help"],
        capture_output=True,
        text=True,
        timeout=30,
        check=False,
    )
    assert result.returncode == 0, result.stderr


def test_unknown_flag_fails_closed(arch: Sandbox) -> None:
    """
    Scenario: An unrecognised flag installs nothing
        Given a bare machine
        When the script is run with --wat
        Then it exits non-zero, prints usage to stderr, and installs nothing
    """
    before = arch.home_tree()
    result = run(arch, "--wat")
    assert result.returncode != 0
    assert "usage" in result.stderr.lower()
    assert arch.home_tree() == before


def test_unknown_only_value_fails_closed(arch: Sandbox) -> None:
    """
    Scenario: --only rejects a tool it does not know
        Given a bare machine
        When the script is run with --only rustc
        Then it exits non-zero and names the accepted tools
    """
    result = run(arch, "--only", "rustc")
    assert result.returncode != 0
    assert "rustc" in result.stderr


def test_only_requires_a_value(arch: Sandbox) -> None:
    """
    Scenario: A dangling --only is a usage error, not a silent default
        Given a bare machine
        When the script is run with a trailing --only
        Then it exits non-zero
    """
    assert run(arch, "--only").returncode != 0


def test_rejects_injection_in_only_flag(arch: Sandbox) -> None:
    """
    Scenario: --only cannot be used to smuggle a command into a privileged call
        Given a bare machine with a canary file in HOME
        When the script is run with --only "; rm -rf $HOME/canary"
        Then it exits non-zero and the canary survives

    The value is matched against a fixed allow-list before it can reach the package
    name that pacman is handed under sudo.
    """
    canary = arch.home / "canary"
    canary.write_text("intact")
    result = run(arch, "--only", f"; rm -rf {arch.home}/canary")
    assert result.returncode != 0
    assert canary.read_text() == "intact"


# --------------------------------------------------------------------------------------
# Preflight guards
# --------------------------------------------------------------------------------------


def test_refuses_to_run_as_root(arch: Sandbox) -> None:
    """
    Scenario: Node is never installed into /root
        Given a machine where `id -u` reports 0
        When the script is run
        Then it exits non-zero and says it refuses to run as root
    """
    arch.stub("id", stdout="0")
    result = run(arch, "--dry-run")
    assert result.returncode != 0
    assert "root" in result.stderr.lower()


def test_fails_closed_without_pacman(arch: Sandbox) -> None:
    """
    Scenario: The Arch edition refuses a machine that is not Arch
        Given a machine without pacman on PATH
        When the script is run
        Then it exits non-zero, names pacman, and points at scripts/setup.sh
    """
    (arch.bin / "pacman").unlink()
    result = run(arch, "--dry-run")
    assert result.returncode != 0
    assert "pacman" in result.stderr
    assert "setup.sh" in result.stderr


def test_fails_closed_on_a_non_arch_distribution(arch: Sandbox) -> None:
    """
    Scenario: A pacman on PATH is not on its own proof of an Arch box
        Given a machine whose os-release reports Debian
        When the script is run
        Then it exits non-zero and points at scripts/setup.sh
    """
    (arch.root / "os-release").write_text('ID=debian\nID_LIKE=""\n')
    result = run(arch, "--dry-run")
    assert result.returncode != 0
    assert "setup.sh" in result.stderr


def test_accepts_an_arch_derivative(arch: Sandbox) -> None:
    """
    Scenario: Derivatives count as Arch
        Given a machine whose os-release reports ID=cachyos with ID_LIKE=arch
        When the script is run with --dry-run
        Then it exits 0

    Omarchy, EndeavourOS, CachyOS and Manjaro all ship pacman and the same repositories;
    matching only ID=arch would lock every one of them out.
    """
    (arch.root / "os-release").write_text("ID=cachyos\nID_LIKE=arch\n")
    result = run(arch, "--dry-run")
    assert result.returncode == 0, result.stderr


def test_fails_closed_when_sudo_is_missing(arch: Sandbox) -> None:
    """
    Scenario: A missing prerequisite is reported, not worked around
        Given a machine without sudo on PATH
        When the script is run
        Then it exits non-zero and names sudo
    """
    (arch.bin / "sudo").unlink()
    result = run(arch, "--dry-run")
    assert result.returncode != 0
    assert "sudo" in result.stderr


def test_fails_closed_when_home_is_unset(arch: Sandbox) -> None:
    """
    Scenario: A missing HOME is named, not stumbled over
        Given a machine where HOME is empty
        When the script is run
        Then it exits non-zero and says HOME is not set
    """
    result = run(arch, "--dry-run", HOME="")
    assert result.returncode != 0
    assert "HOME" in result.stderr


# --------------------------------------------------------------------------------------
# Planning (dry run) and idempotency
# --------------------------------------------------------------------------------------


def test_dry_run_on_bare_machine_plans_every_install(arch: Sandbox) -> None:
    """
    Scenario: A bare machine plans a full provision
        Given a machine with none of the six tools
        When the script is run with --dry-run
        Then it exits 0 and reports a planned install for every tool
    """
    result = run(arch, "--dry-run")
    assert result.returncode == 0, result.stderr
    for tool in TOOLS:
        assert re.search(
            rf"^{re.escape(tool)}\s+.*planned", result.stdout, re.MULTILINE
        ), f"{tool} missing from the plan:\n{result.stdout}"


def test_dry_run_calls_no_package_manager(arch: Sandbox) -> None:
    """
    Scenario: Planning is free of side effects
        Given a machine with none of the six tools
        When the script is run with --dry-run
        Then pacman is never invoked and HOME is unchanged
    """
    transcript = recording_pacman(arch)
    before = arch.home_tree()
    result = run(arch, "--dry-run")
    assert result.returncode == 0, result.stderr
    assert not transcript.exists(), transcript.read_text()
    assert arch.home_tree() == before


def test_dry_run_with_everything_present_plans_only_skips(arch: Sandbox) -> None:
    """
    Scenario: A provisioned machine is left alone (idempotency)
        Given a machine where all six tools are already installed
        When the script is run with --dry-run
        Then every tool is reported as already present, with its version, and nothing is planned
    """
    arch.stub_all_tools()
    result = run(arch, "--dry-run")
    assert result.returncode == 0, result.stderr
    assert "planned" not in result.stdout, result.stdout
    for tool in TOOLS:
        assert re.search(
            rf"^{re.escape(tool)}\s+\S+\s+already present", result.stdout, re.MULTILINE
        ), f"{tool} not reported as already present:\n{result.stdout}"


def test_provisioned_box_is_not_told_to_open_a_new_shell(arch: Sandbox) -> None:
    """
    Scenario: A re-run on a provisioned box hands out no busywork
        Given a machine where all six tools are already installed
        When the script is run for real
        Then it exits 0, says there is nothing to do, and does not ask for a new shell
    """
    arch.stub_all_tools()
    result = run(arch)
    assert result.returncode == 0, result.stderr
    assert "already provisioned" in result.stdout
    assert "exec $SHELL" not in result.stdout


def test_a_node_from_any_manager_counts_as_installed(arch: Sandbox) -> None:
    """
    Scenario: An existing node is not replaced by a second version manager
        Given a machine with node and npm on PATH but no nvm
        When the script is run with --dry-run
        Then node and npm are already present and only nvm is planned

    Arch boxes routinely get node from mise, pacman or asdf. Detection is by PATH, so
    whichever manager put it there, nvm is not stacked on top of it.
    """
    arch.stub("node", stdout="v26.7.0")
    arch.stub("npm", stdout="11.19.0")
    result = run(arch, "--dry-run")
    assert result.returncode == 0, result.stderr
    for tool in ("node", "npm"):
        assert re.search(
            rf"^{re.escape(tool)}\s+\S+\s+already present", result.stdout, re.MULTILINE
        ), result.stdout
    assert re.search(r"^nvm\s+.*planned", result.stdout, re.MULTILINE), result.stdout


def test_stale_python3_is_not_accepted(arch: Sandbox) -> None:
    """
    Scenario: A too-old interpreter does not count as provisioned
        Given a machine whose python3 reports 3.9
        When the script is run with --dry-run --only python3
        Then it plans an install rather than reporting it as already present
    """
    arch.stub("python3", stdout="Python 3.9.6")
    result = run(arch, "--dry-run", "--only", "python3")
    assert result.returncode == 0, result.stderr
    assert "planned" in result.stdout, result.stdout


def test_only_acts_on_a_single_tool(arch: Sandbox) -> None:
    """
    Scenario: --only narrows the run to one tool
        Given a machine with none of the six tools
        When the script is run with --dry-run --only bun
        Then bun is the only tool in the summary
    """
    result = run(arch, "--dry-run", "--only", "bun")
    assert result.returncode == 0, result.stderr
    assert re.search(r"^bun\s", result.stdout, re.MULTILINE)
    for tool in ("nvm", "node", "npm", "python3", "uv"):
        assert not re.search(rf"^{re.escape(tool)}\s", result.stdout, re.MULTILINE), (
            f"--only bun still touched {tool}"
        )


# --------------------------------------------------------------------------------------
# What actually reaches pacman
# --------------------------------------------------------------------------------------


@pytest.mark.parametrize(("tool", "package"), sorted(PACKAGES.items()))
def test_each_tool_maps_to_its_official_package(
    arch: Sandbox, tool: str, package: str
) -> None:
    """
    Scenario: Every packaged tool is installed from the official repositories
        Given a machine with none of the six tools
        When the script is run for real with --only <tool>
        Then pacman is asked for that tool's package, with --needed and an end-of-options marker
    """
    transcript = recording_pacman(arch)
    run(arch, "--only", tool)
    assert transcript.exists(), f"pacman was never called for {tool}"
    assert transcript.read_text().strip() == f"-S --needed -- {package}"


def test_pacman_prompts_unless_noconfirm_is_asked_for(arch: Sandbox) -> None:
    """
    Scenario: An unattended run is opt-in
        Given a machine with none of the six tools
        When the script is run with and without --noconfirm
        Then --noconfirm reaches pacman only when it was asked for
    """
    transcript = recording_pacman(arch)
    run(arch, "--only", "uv")
    assert "--noconfirm" not in transcript.read_text()

    transcript.unlink()
    run(arch, "--noconfirm", "--only", "uv")
    assert "--noconfirm" in transcript.read_text()


def test_failed_package_install_aborts(arch: Sandbox) -> None:
    """
    Scenario: A pacman failure stops the run and explains the likely cause
        Given a machine whose pacman always fails
        When the script is run for real with --only uv
        Then it exits non-zero and points at a full -Syu rather than a bare -Sy
    """
    arch.stub("pacman", stdout="error: target not found: uv", exit_code=1)
    result = run(arch, "--only", "uv")
    assert result.returncode != 0
    assert "-Syu" in result.stderr
    assert "installed" not in result.stdout.lower()


def test_verification_failure_is_reported(arch: Sandbox) -> None:
    """
    Scenario: A package manager that claims success but delivers nothing is caught
        Given a machine whose pacman exits 0 without installing anything
        When the script is run for real with --only uv
        Then it exits non-zero and names uv as unverified
    """
    result = run(arch, "--only", "uv")
    assert result.returncode != 0
    assert "uv" in result.stderr


# --------------------------------------------------------------------------------------
# nvm: two install layouts, one $NVM_DIR
# --------------------------------------------------------------------------------------


def test_nvm_is_found_in_either_layout(script_source: str) -> None:
    """
    Scenario: A packaged nvm counts as installed
        Given the script source
        When nvm's lookup is inspected
        Then it checks $NVM_DIR first and /usr/share/nvm second

    pacman's nvm never lands on PATH and never lands in $NVM_DIR either — it is a
    library under /usr/share. Looking only where the upstream installer puts things
    would make an installed nvm invisible and reinstall it on every run.
    """
    code = executable_lines(script_source)
    assert 'NVM_SYSTEM_SH="/usr/share/nvm/nvm.sh"' in code
    assert '[ -s "${NVM_DIR}/nvm.sh" ]' in code


def test_installing_node_uses_the_packaged_init_script(script_source: str) -> None:
    """
    Scenario: A packaged nvm still populates $NVM_DIR before Node is installed
        Given the script source
        When the source-then-install paths are compared
        Then detection sources nvm.sh and install_node sources nvm_install_script

    /usr/share/nvm/init-nvm.sh is the packaged script that creates $NVM_DIR and symlinks
    nvm.sh and nvm-exec into it, which `nvm exec` and third-party tooling expect. It also
    writes to disk, which is why detection and version reporting must not go near it: a
    --dry-run has to leave the box untouched.
    """
    code = executable_lines(script_source)
    assert 'script="$(nvm_install_script)"' in code, (
        "install_node does not use the install-time script"
    )
    assert 'NVM_SYSTEM_INIT="/usr/share/nvm/init-nvm.sh"' in code

    lookup = re.search(r"(?ms)^nvm_script\(\) \{.*?^\}", code)
    assert lookup, "nvm_script() not found"
    assert "NVM_SYSTEM_INIT" not in lookup.group(), (
        "the side-effect-free lookup can reach init-nvm.sh, so --dry-run could write to disk"
    )


def test_nvm_dir_follows_the_packaged_default(arch: Sandbox) -> None:
    """
    Scenario: XDG_CONFIG_HOME moves $NVM_DIR, exactly as the packaged init script does
        Given a machine with XDG_CONFIG_HOME set and an nvm installed under it
        When the script is run with --dry-run --only nvm
        Then nvm is reported as already present

    /usr/share/nvm/init-nvm.sh defaults NVM_DIR to $XDG_CONFIG_HOME/nvm when that is set.
    A script that hardcoded ~/.nvm would install Node somewhere the operator's later
    shells never look.
    """
    xdg = arch.home / "config"
    nvm_dir = xdg / "nvm"
    nvm_dir.mkdir(parents=True)
    (nvm_dir / "nvm.sh").write_text(
        'nvm() { [ "$1" = "--version" ] && printf "%s\\n" "0.40.5"; }\n'
    )

    result = run(arch, "--dry-run", "--only", "nvm", XDG_CONFIG_HOME=str(xdg))
    assert result.returncode == 0, result.stderr
    assert re.search(
        r"^nvm\s+0\.40\.5\s+already present", result.stdout, re.MULTILINE
    ), result.stdout


def test_explicit_nvm_dir_still_wins(arch: Sandbox) -> None:
    """
    Scenario: An operator who set NVM_DIR keeps it
        Given a machine with NVM_DIR and XDG_CONFIG_HOME both set, and nvm under NVM_DIR
        When the script is run with --dry-run --only nvm
        Then nvm is reported as already present
    """
    nvm_dir = arch.home / "elsewhere"
    nvm_dir.mkdir()
    (nvm_dir / "nvm.sh").write_text(
        'nvm() { [ "$1" = "--version" ] && printf "%s\\n" "0.40.6"; }\n'
    )

    result = run(
        arch,
        "--dry-run",
        "--only",
        "nvm",
        NVM_DIR=str(nvm_dir),
        XDG_CONFIG_HOME=str(arch.home / "config"),
    )
    assert result.returncode == 0, result.stderr
    assert re.search(
        r"^nvm\s+0\.40\.6\s+already present", result.stdout, re.MULTILINE
    ), result.stdout


def test_sourcing_nvm_survives_a_failing_short_circuit(arch: Sandbox) -> None:
    """
    Scenario: A non-zero last line in nvm's own script does not abort the run
        Given an nvm script that ends on a failing short-circuit
        When the script is run for real with --only node
        Then `nvm install` is still reached

    A sourced file returns its last command's status, and under `set -e` a non-zero there
    takes the *sourcing* script down with it — before a single nvm call is made. (A
    mid-file `[ ! -e x ] && ...` is exempt from errexit; a trailing one is not, which is
    what this stub reproduces.) `/usr/share/nvm/init-nvm.sh` is three short-circuits and
    two sources of files this script does not control, so the source runs with errexit
    off and the nvm calls that follow run with it back on.
    """
    marker = arch.root / "nvm-install-ran"
    nvm_dir = arch.home / ".nvm"
    nvm_dir.mkdir()
    (nvm_dir / "nvm.sh").write_text(
        "nvm() {\n"
        f'  printf "%s\\n" "$*" >> {marker}\n'
        "}\n"
        '[ ! -e "$NVM_DIR" ] && mkdir -p "$NVM_DIR"\n'
    )

    result = run(arch, "--only", "node")
    assert marker.exists(), (
        f"the run died while sourcing nvm.sh:\n{result.stdout}{result.stderr}"
    )
    assert "install --lts" in marker.read_text()
    # node is still not on PATH afterwards — this stub installs nothing — so the run
    # ends at the post-install verification, naming node. That is the correct failure.
    assert result.returncode != 0
    assert "node" in result.stderr
