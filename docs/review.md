# Review

No review runs automatically. Code changes, commits, pushes, pull requests and unattended milestone work do not start reviewers.

## Explicit review requests

Use Council only when the user explicitly requests a review. Give it the requested work, the requirements in `docs/plan.md` or the PR Summary, and the evidence rules in `docs/verification.md`. Apply the project criteria in `REVIEW.md` and the checklist below. Report findings against the actual source commit and distinguish source findings from application evidence.

Do not start the former blind-review loop, the `pr-review` workflow, CodeRabbit CLI or hosted CodeRabbit reviews. Do not schedule extra rounds, request reviews through comments, publish findings, or resolve review threads without the corresponding user authority. A requested review does not replace owner verification or required human approval.

## Publication and completion

Work through [`checklist.md`](checklist.md) before opening a pull request and before later pushes. Preserve Core and App CI, performance evidence, privacy rules and actual human approvals. Do not report a pending or missing check as passed. If a retired automated-review status still blocks a merge, report that exact blocker; do not bypass branch protections.

Keep existing review records in [`review-retros.md`](review-retros.md) and [`coderabbit-findings.md`](coderabbit-findings.md). Their existing lint and historical evidence stay in place. A PR does not need a new review record when no review was requested. For an authorized review, record only reviews that actually ran and evidence that was observed.

## Reassess instead of another round

When findings repeat, fixes regress or the evidence cannot establish behavior, stop the affected operation and identify the defect class. Continue an in-scope fix when its cause is established. Ask the user only for a decision or authority that is missing. Do not launch another reviewer or advisor automatically.

## Checklist

- **Timing claims.** A latency the user sees (a window or popover opening, a menu bar update) is timed until the result is on screen, not until the code returns, and two builds are compared in paired, interleaved runs in one session, not against an earlier session's numbers. A latency claim measured otherwise is a finding. Durations that are limits or windows (a download's deadline, a 10-minute CPU sample) are not latency claims.
- **Retired terms.** When the pull request renames or retires a term (in `GLOSSARY.md`'s _Avoid_ lists, or a setting, type or view it removes), search the whole repository for the old words, docs included; each hit outside the glossary's _Avoid_ list, the review logs, dated decisions and `docs/mockups/` (frozen designs) is a finding.
