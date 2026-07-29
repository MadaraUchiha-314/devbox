# Learning 002: Post the PR briefing before the PR is approvable, not after

- **Date:** 2026-07-29
- **Source:** user-feedback (approval-ordering on PR #3)
- **Work item:** [issue-2](https://github.com/MadaraUchiha-314/devbox/issues/2)

## What happened

PR #3 was opened as soon as the implementation was done, with a placeholder body saying
*"Reviewer briefing is posted below once the review gates complete (self → critic →
security)."* The reviewer approved it **fifteen minutes before those gates finished** —
reasonably, since an open PR with green-looking CI reads as ready.

The security gate then found a MEDIUM issue and changed the code. The approval on record
now applied to a diff that no longer existed, so it could not stand as the tier-3
`human-approves-pr` sign-off, and re-confirmation had to be requested. The reviewer did
nothing wrong; the loop had put an approvable-looking artifact in front of them before it
was approvable.

## Learning

**An open PR is an invitation to approve, regardless of what its body says.** A
placeholder promising a briefing "later" does not hold the gate — reviewers act on the
PR's existence and its check status, not on a note asking them to wait. The ready-to-ship
gate ordering (reviews → security → evidence → briefing → *then* human approval) is not
merely bookkeeping: it exists so the human's approval attaches to a stable diff.

## Action

- **Open the PR as a draft** when the review gates have not yet run, and mark it ready
  for review only once the briefing is posted. A draft cannot be approved by accident;
  a note in the body can.
- If an approval nevertheless arrives before the gates finish, **do not consume it**.
  State the sequence plainly, show the delta, and request re-confirmation — a stale
  approval silently reused is worse than an extra round trip.
- Keep the PR's own timeline honest: the briefing said which commit landed after the
  approval, so the reviewer could re-confirm by reading one diff rather than the whole PR
  again.
