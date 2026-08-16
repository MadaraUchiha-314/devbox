# Learning 001: A confidently-worded comment can hide the gap it describes

- **Date:** 2026-07-29
- **Source:** system-feedback (security-review gate)
- **Work item:** [issue-2](https://github.com/MadaraUchiha-314/devbox/issues/2)

## What happened

`scripts/setup.sh` downloads vendor installers and executes them. The fetch was written as:

```bash
curl --fail --location --proto '=https' --tlsv1.2 …
```

with the comment `--proto '=https' — a redirect may not downgrade the connection to
plaintext`, and `design.md` carried the matching claim ("HTTPS only … redirects
included"). Both were **false**: `--proto` governs only the initial request, while
redirects are governed by `--proto-redir`, whose curl default permits `http`. The pinned
installer URLs are redirectors, so the downgrade path was live.

The requirements, the design's Security-design section, and two self-review rounds all
passed over it. What made it invisible was not the missing flag — it was the comment
*asserting the property was already handled*. A reviewer reading `--proto '=https' —
redirects may not downgrade` has been told the question is answered, so they stop asking
it. The security-review gate caught it only because it re-derived the behaviour from the
flag semantics instead of reading the prose.

## Learning

**A comment that asserts a security property is a claim to verify, not evidence.** The
more confidently a line documents a guarantee, the more it suppresses scrutiny of whether
the mechanism actually delivers it — so those are the lines to check hardest, not skim.

Corollary: when a security control is a **flag, option or config key**, confirm its exact
scope in the tool's own documentation. Flags that *sound* comprehensive frequently are
not (`--proto` vs `--proto-redir` is the archetype: same noun, different phase, silently
permissive default).

## Action

- When reviewing (self, critic or security), treat every comment or design sentence that
  states a security guarantee as an **unverified claim**, and check the mechanism against
  the tool's documented semantics before accepting it.
- When a finding proves a comment wrong, **fix the comment and the design doc in the same
  commit as the code** — a stale-but-confident comment re-creates the blind spot for the
  next reader. Done here in `47fab8a`.
- Prefer locking a security control in place with a **source-level assertion**
  (`test_https_is_enforced_on_redirects_too`) over a comment. A test cannot be
  confidently wrong for long.
