"""Integration tests for `scripts/setup.sh`.

Feature: devbox provisioning — one command installs nvm, node, npm, bun, python3 and uv

Every scenario runs the real script inside the PATH sandbox from `conftest.py`, so the
whole suite is offline and hermetic: the dry-run scenarios never reach the network, and
the one failure-path scenario stubs `curl` itself.
"""

from __future__ import annotations

import re
import stat
import subprocess
from pathlib import Path

from conftest import BASH, SCRIPT, Sandbox

TOOLS = ("nvm", "node", "npm", "bun", "python3", "uv")

#: Hosts the script is allowed to download from. Anything else is a finding, not a nit.
ALLOWED_HOSTS = {
    "raw.githubusercontent.com",  # nvm — tag-versioned installer
    "astral.sh",  # uv — version-scoped installer
    "bun.sh",  # bun — vendor installer (not itself versioned)
}

URL_RE = re.compile(r"""https?://[^\s"'`)]+""")


def executable_lines(source: str) -> str:
    """The script with comment lines removed.

    The security assertions below are about what the script *does*, so a vendor
    release page linked in a comment is not a finding — but a URL or a `sudo` on a
    line that actually runs is.
    """
    return "\n".join(
        line for line in source.splitlines() if not line.lstrip().startswith("#")
    )


# --------------------------------------------------------------------------------------
# Shape of the script itself
# --------------------------------------------------------------------------------------


def test_script_is_valid_bash() -> None:
    """
    Requirement: docs/specs/issue-2/requirements.md (NFR — bash 3.2 target)

    Scenario: The script parses under the system bash
        Given the checked-in scripts/setup.sh
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
    Requirement: docs/specs/issue-2/requirements.md#R1

    Scenario: The script can be invoked directly
        Given the checked-in scripts/setup.sh
        When its file mode is inspected
        Then the owner-execute bit is set
    """
    assert SCRIPT.stat().st_mode & stat.S_IXUSR, "scripts/setup.sh is not executable"


def test_all_urls_are_https_and_vendor_hosted(script_source: str) -> None:
    """
    Requirement: docs/specs/issue-2/requirements.md#security-considerations (abuse case 2)

    Scenario: No download can be introduced over plaintext or from a third party
        Given the script source
        When every URL literal in it is extracted
        Then each one uses https and points at an official vendor host
    """
    urls = URL_RE.findall(executable_lines(script_source))
    assert urls, "expected the script to contain installer URLs"
    for url in urls:
        assert url.startswith("https://"), f"non-HTTPS URL in setup.sh: {url}"
        host = url.split("/")[2]
        assert host in ALLOWED_HOSTS, f"URL points at an unapproved host: {url}"


def test_installer_urls_are_version_pinned(script_source: str) -> None:
    """
    Requirement: docs/specs/issue-2/requirements.md#security-considerations (abuse case 2)

    Scenario: A compromised "latest" cannot silently change what executes
        Given the script source
        When the pin constants are read
        Then nvm and uv are pinned to an exact version and bun pins the version it installs
    """
    assert re.search(r'^NVM_TAG="v\d+\.\d+\.\d+"$', script_source, re.MULTILINE), (
        "NVM_TAG unpinned"
    )
    assert re.search(r'^UV_VERSION="\d+\.\d+\.\d+"$', script_source, re.MULTILINE), (
        "UV_VERSION unpinned"
    )
    assert re.search(
        r'^BUN_VERSION="bun-v\d+\.\d+\.\d+"$', script_source, re.MULTILINE
    ), "BUN_VERSION unpinned"
    # ...and the pins are actually used in the URLs, not decorative.
    assert "${NVM_TAG}" in script_source
    assert "${UV_VERSION}" in script_source


def test_script_never_uses_sudo(script_source: str) -> None:
    """
    Requirement: docs/specs/issue-2/requirements.md#security-considerations (boundary 3)

    Scenario: The script never escalates privileges
        Given the script source
        When it is searched for privilege-escalation commands
        Then neither sudo nor doas is ever invoked

    Matched at command position only: the preflight guard *mentions* sudo when telling
    the operator not to use it, which is the opposite of a finding.
    """
    code = executable_lines(script_source)
    invocation = re.compile(r"(?m)(?:^|[;&|]\s*|\$\(\s*)\s*(sudo|doas)\b")
    assert not invocation.search(code), "setup.sh escalates privileges"


def test_single_curl_invocation(script_source: str) -> None:
    """
    Requirement: docs/specs/issue-2/requirements.md#security-considerations (boundary 1)

    Scenario: All third-party code passes through one hardened chokepoint
        Given the script source
        When curl invocations are counted
        Then there is exactly one, and it downloads to a file rather than piping to a shell
    """
    code = executable_lines(script_source)
    assert len(re.findall(r"^\s*curl ", code, re.MULTILINE)) == 1, (
        "more than one fetch path"
    )
    assert "curl" in code and "| bash" not in code and "| sh" not in code


def test_installer_runs_under_the_current_interpreter(script_source: str) -> None:
    """
    Requirement: docs/specs/issue-2/requirements.md#security-considerations (boundary 3)

    Scenario: A poisoned PATH cannot choose the interpreter for downloaded code
        Given the script source
        When the line that executes a downloaded installer is inspected
        Then it invokes "${BASH}" — the interpreter already running — not a PATH lookup

    Found by test_verification_failure_is_reported, which ran the script with a PATH that
    had no `bash` on it: a bare `bash "$installer"` is a PATH lookup, and PATH is one of
    the untrusted inputs named in the threat model.
    """
    code = executable_lines(script_source)
    assert '"${BASH}" "${installer}"' in code, "installer is executed via a PATH lookup"
    assert not re.search(r'(?m)^\s*bash\s+"\$\{installer\}"', code)


def test_uses_private_tempdir(script_source: str) -> None:
    """
    Requirement: docs/specs/issue-2/requirements.md#security-considerations (abuse case 5)

    Scenario: Downloads land in a private directory that is cleaned up
        Given the script source
        When its temp-file handling is inspected
        Then it creates a directory with mktemp -d and removes it via an EXIT trap
    """
    assert "mktemp -d" in script_source
    assert re.search(r"^trap .* EXIT$", script_source, re.MULTILINE), (
        "no EXIT cleanup trap"
    )


def test_never_writes_to_shell_profiles(script_source: str) -> None:
    """
    Requirement: docs/specs/issue-2/requirements.md#R2

    Scenario: The operator's shell profiles are left to the vendor installers
        Given the script source
        When it is searched for profile writes
        Then it never appends to .zshrc, .bashrc, .bash_profile or .profile
    """
    for profile in (".zshrc", ".bashrc", ".bash_profile", ".profile"):
        assert not re.search(rf">>\s*[^\n]*{re.escape(profile)}", script_source), (
            f"setup.sh writes to {profile}"
        )


# --------------------------------------------------------------------------------------
# Usage, argument handling, fail-closed behaviour
# --------------------------------------------------------------------------------------


def test_help_lists_every_tool_and_flag(sandbox: Sandbox) -> None:
    """
    Requirement: docs/specs/issue-2/requirements.md#R3

    Scenario: --help documents the whole contract
        Given a bare machine
        When the script is run with --help
        Then it exits 0 and its usage names every supported tool and flag
    """
    result = sandbox.run("--help")
    assert result.returncode == 0, result.stderr
    for token in (*TOOLS, "--dry-run", "--only", "--help"):
        assert token in result.stdout, f"--help does not mention {token}"


def test_help_runs_via_shebang() -> None:
    """
    Requirement: docs/specs/issue-2/requirements.md#R3

    Scenario: The script runs as scripts/setup.sh, not only as `bash setup.sh`
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


def test_unknown_flag_fails_closed(sandbox: Sandbox) -> None:
    """
    Requirement: docs/specs/issue-2/requirements.md#R3

    Scenario: An unrecognised flag installs nothing
        Given a bare machine
        When the script is run with --wat
        Then it exits non-zero, prints usage to stderr, and installs nothing
    """
    before = sandbox.home_tree()
    result = sandbox.run("--wat")
    assert result.returncode != 0
    assert "usage" in result.stderr.lower()
    assert sandbox.home_tree() == before


def test_unknown_only_value_fails_closed(sandbox: Sandbox) -> None:
    """
    Requirement: docs/specs/issue-2/requirements.md#R3

    Scenario: --only rejects a tool it does not know
        Given a bare machine
        When the script is run with --only rustc
        Then it exits non-zero and names the accepted tools
    """
    result = sandbox.run("--only", "rustc")
    assert result.returncode != 0
    assert "rustc" in result.stderr


def test_only_requires_a_value(sandbox: Sandbox) -> None:
    """
    Requirement: docs/specs/issue-2/requirements.md#R3

    Scenario: A dangling --only is a usage error, not a silent default
        Given a bare machine
        When the script is run with a trailing --only
        Then it exits non-zero
    """
    result = sandbox.run("--only")
    assert result.returncode != 0


def test_rejects_injection_in_only_flag(sandbox: Sandbox) -> None:
    """
    Requirement: docs/specs/issue-2/requirements.md#security-considerations (abuse case 4)

    Scenario: --only cannot be used to smuggle a command
        Given a bare machine with a canary file in HOME
        When the script is run with --only "; rm -rf $HOME/canary"
        Then it exits non-zero and the canary survives
    """
    canary = sandbox.home / "canary"
    canary.write_text("intact")
    result = sandbox.run("--only", f"; rm -rf {sandbox.home}/canary")
    assert result.returncode != 0
    assert canary.read_text() == "intact"


# --------------------------------------------------------------------------------------
# Preflight guards
# --------------------------------------------------------------------------------------


def test_refuses_to_run_as_root(sandbox: Sandbox) -> None:
    """
    Requirement: docs/specs/issue-2/requirements.md#security-considerations (abuse case 1)

    Scenario: A vendor installer never gets system privileges
        Given a machine where `id -u` reports 0
        When the script is run
        Then it exits non-zero and says it refuses to run as root
    """
    sandbox.stub("id", stdout="0")
    result = sandbox.run("--dry-run")
    assert result.returncode != 0
    assert "root" in result.stderr.lower()


def test_fails_closed_when_home_is_unset(sandbox: Sandbox) -> None:
    """
    Requirement: docs/specs/issue-2/requirements.md#R1

    Scenario: A missing HOME is named, not stumbled over
        Given a machine where HOME is empty
        When the script is run
        Then it exits non-zero and says HOME is not set

    Without the guard this fails deep inside `${NVM_DIR:-${HOME}/.nvm}` under `set -u`,
    which tells the operator nothing useful.
    """
    result = sandbox.run("--dry-run", env={"HOME": ""})
    assert result.returncode != 0
    assert "HOME" in result.stderr


def test_fails_closed_when_curl_is_missing(sandbox: Sandbox) -> None:
    """
    Requirement: docs/specs/issue-2/requirements.md#R1

    Scenario: A missing prerequisite is reported, not worked around
        Given a machine without curl on PATH
        When the script is run
        Then it exits non-zero and names curl
    """
    (sandbox.bin / "curl").unlink()
    result = sandbox.run()
    assert result.returncode != 0
    assert "curl" in result.stderr


# --------------------------------------------------------------------------------------
# Planning (dry run) and idempotency
# --------------------------------------------------------------------------------------


def test_dry_run_on_bare_machine_plans_every_install(sandbox: Sandbox) -> None:
    """
    Requirement: docs/specs/issue-2/requirements.md#R3

    Scenario: A bare machine plans a full provision
        Given a machine with none of the six tools
        When the script is run with --dry-run
        Then it exits 0 and reports a planned install for every tool
    """
    result = sandbox.run("--dry-run")
    assert result.returncode == 0, result.stderr
    for tool in TOOLS:
        assert re.search(
            rf"^{re.escape(tool)}\s+.*planned", result.stdout, re.MULTILINE
        ), f"{tool} missing from the plan:\n{result.stdout}"


def test_dry_run_changes_nothing_on_disk(sandbox: Sandbox) -> None:
    """
    Requirement: docs/specs/issue-2/requirements.md#R3

    Scenario: Planning is free of side effects
        Given a machine with none of the six tools
        When the script is run with --dry-run
        Then HOME contains exactly what it contained before
    """
    before = sandbox.home_tree()
    result = sandbox.run("--dry-run")
    assert result.returncode == 0, result.stderr
    assert sandbox.home_tree() == before


def test_dry_run_with_everything_present_plans_only_skips(sandbox: Sandbox) -> None:
    """
    Requirement: docs/specs/issue-2/requirements.md#R2

    Scenario: A provisioned machine is left alone (idempotency)
        Given a machine where all six tools are already installed
        When the script is run with --dry-run
        Then every tool is reported as already present, with its version, and nothing is planned
    """
    sandbox.stub_all_tools()
    result = sandbox.run("--dry-run")
    assert result.returncode == 0, result.stderr
    assert "planned" not in result.stdout, result.stdout
    for tool in TOOLS:
        assert re.search(
            rf"^{re.escape(tool)}\s+\S+\s+already present", result.stdout, re.MULTILINE
        ), f"{tool} not reported as already present:\n{result.stdout}"


def test_provisioned_box_is_not_told_to_open_a_new_shell(sandbox: Sandbox) -> None:
    """
    Requirement: docs/specs/issue-2/requirements.md#R4

    Scenario: A re-run on a provisioned box hands out no busywork
        Given a machine where all six tools are already installed
        When the script is run for real
        Then it exits 0, says there is nothing to do, and does not ask for a new shell
    """
    sandbox.stub_all_tools()
    result = sandbox.run()
    assert result.returncode == 0, result.stderr
    assert "already provisioned" in result.stdout
    assert "exec $SHELL" not in result.stdout


def test_stale_python3_is_not_accepted(sandbox: Sandbox) -> None:
    """
    Requirement: docs/specs/issue-2/requirements.md#R1

    Scenario: A too-old interpreter does not count as provisioned
        Given a machine whose python3 reports 3.9
        When the script is run with --dry-run --only python3
        Then it plans an install rather than reporting it as already present
    """
    sandbox.stub("python3", stdout="Python 3.9.6")
    result = sandbox.run("--dry-run", "--only", "python3")
    assert result.returncode == 0, result.stderr
    assert "planned" in result.stdout, result.stdout


def test_only_acts_on_a_single_tool(sandbox: Sandbox) -> None:
    """
    Requirement: docs/specs/issue-2/requirements.md#R3

    Scenario: --only narrows the run to one tool
        Given a machine with none of the six tools
        When the script is run with --dry-run --only bun
        Then bun is the only tool in the summary
    """
    result = sandbox.run("--dry-run", "--only", "bun")
    assert result.returncode == 0, result.stderr
    assert re.search(r"^bun\s", result.stdout, re.MULTILINE)
    for tool in ("nvm", "node", "npm", "python3", "uv"):
        assert not re.search(rf"^{re.escape(tool)}\s", result.stdout, re.MULTILINE), (
            f"--only bun still touched {tool}"
        )


# --------------------------------------------------------------------------------------
# Failure paths that involve the network chokepoint
# --------------------------------------------------------------------------------------


def test_failed_download_aborts_without_executing(sandbox: Sandbox) -> None:
    """
    Requirement: docs/specs/issue-2/requirements.md#security-considerations (abuse case 3)

    Scenario: A failed download never executes a partial payload
        Given a machine whose curl always fails
        When the script is run for real with --only uv
        Then it exits non-zero and never reports running an installer
    """
    sandbox.stub("curl", stdout="curl: (22) HTTP 404", exit_code=22)
    result = sandbox.run("--only", "uv")
    assert result.returncode != 0
    assert "running installer" not in result.stdout.lower()
    assert "installed" not in result.stdout.lower()


def test_verification_failure_is_reported(sandbox: Sandbox) -> None:
    """
    Requirement: docs/specs/issue-2/requirements.md#R1

    Scenario: An installer that claims success but delivers nothing is caught
        Given a machine whose curl writes an installer that does nothing
        When the script is run for real with --only uv
        Then it exits non-zero and names uv as unverified
    """
    sandbox.script_stub(
        "curl",
        "#!/bin/sh\n"
        "# emulate `curl … -o <file>`, writing an installer that succeeds but installs nothing\n"
        'for arg in "$@"; do\n'
        '  if [ "$prev" = "-o" ]; then printf "exit 0\\n" > "$arg"; fi\n'
        '  prev="$arg"\n'
        "done\n"
        "exit 0\n",
    )
    result = sandbox.run("--only", "uv")
    assert result.returncode != 0
    assert "uv" in result.stderr


def test_installer_is_downloaded_before_it_is_executed(sandbox: Sandbox) -> None:
    """
    Requirement: docs/specs/issue-2/requirements.md#security-considerations (abuse case 3)

    Scenario: The installer runs from a file on disk, not from a pipe
        Given a machine whose curl writes a marker installer
        When the script is run for real with --only uv
        Then the installer executed is the downloaded file
    """
    marker = sandbox.root / "installer-ran"
    sandbox.script_stub(
        "curl",
        "#!/bin/sh\n"
        'for arg in "$@"; do\n'
        '  if [ "$prev" = "-o" ]; then\n'
        f'    printf "printf ran > {marker}\\n" > "$arg"\n'
        "  fi\n"
        '  prev="$arg"\n'
        "done\n"
        "exit 0\n",
    )
    sandbox.run("--only", "uv")
    assert marker.exists(), "the downloaded installer file was never executed"


def test_tempdir_is_cleaned_up(sandbox: Sandbox, tmp_path: Path) -> None:
    """
    Requirement: docs/specs/issue-2/requirements.md#security-considerations (abuse case 5)

    Scenario: No downloaded installer is left lying around
        Given a machine whose curl always fails
        When the script is run for real with --only uv and aborts
        Then no installer file remains under TMPDIR
    """
    sandbox.stub("curl", stdout="curl: (22)", exit_code=22)
    sandbox.run("--only", "uv")
    leftovers = list((sandbox.root / "tmp").rglob("installer.sh"))
    assert leftovers == [], f"temp installers left behind: {leftovers}"
