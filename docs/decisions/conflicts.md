# Conflict & assumption log

Append-only log of ambiguities and conflicts hit **mid-flight** during a run (distinct
from the deliberate decisions in `decisions.md`). Rule: resolvable with a reasonable
default → **assume and continue**; genuinely blocked → **log, escalate once, move on**.

| Timestamp  | Phase                   | Conflict / assumption                                                                                                                                                                            | Status  |
|------------|-------------------------|--------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------|
| 2026-07-29 | requirements-definition | issue-2: `python3` provider unspecified — assumed "reuse an existing python3 ≥ 3.11 if present, else install via uv", so the script needs no Homebrew and behaves identically on macOS and Linux | assumed |
| 2026-07-29 | requirements-definition | issue-2: Node version unspecified — assumed `nvm install --lts` + set as the default alias, rather than pinning an exact Node version                                                            | assumed |
| 2026-07-29 | requirements-definition | issue-2: platform breadth unspecified — assumed macOS is the tested target and Linux is best-effort via the same vendor installers                                                               | assumed |

_Status: `assumed` (default taken, continuing) · `escalated` (raised once, moved on) ·
`resolved` (later settled)._
