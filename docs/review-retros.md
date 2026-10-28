# Review retros

One entry per pull request, as [`review.md`](review.md) describes: a row for each blind round and direct review as it runs while the pull request is a draft, then, in one final commit, the rows for every review after it is ready and the retro. A session that stops blocked commits what it has so far, and the session that resumes completes it. Together with [`coderabbit-findings.md`](coderabbit-findings.md), these show why reviews take the rounds they do.

Each entry has:
- **A heading:** the pull request, its title and the date it opened.
- **Planned rounds** and what ran: blind rounds, direct reviews, CodeRabbit reviews.
- **A table, one row per review:** the review (blind round number, `direct`, or `CodeRabbit`), the reviewer's model, the findings by severity (`unrated` where the reviewer gave none), and the origin of each finding.
- **Retro:** why the review took the rounds it did, what the extra rounds caught that earlier ones did not, and the changes it led to (a rule, a check, a doc), or "none".

Origins, most specific first; use the first that fits:
- `fix regression`: came in with a fix for an earlier finding.
- `new evidence`: shown by running or observing the real thing (a tool, a service, the app), which no reading of the diff could show.
- `unclear requirement`: the requirement or the task allowed more than one reading.
- `missed earlier`: in code or text an earlier review already saw.
- `first look`: found in the first review that could see it.

## [#9](https://github.com/AboulEinein/soroband/pull/9) docs(review): add CodeRabbit after the blind loop and log its findings (2026-10-28)

Planned rounds: 1. Ran: 5 blind rounds, 1 direct review, 2 CodeRabbit reviews. The blind rounds ran unposted, against `review.md` step 3.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 4 Medium, 1 Low, 1 Minor | `new evidence`: the draft's `SKIPPED` check ends `gh pr checks --watch` at once. `first look`: findings without a thread, unresolved valid threads, `plan.md` ending sessions before CodeRabbit, no end condition, no `accepted` verdict. |
| 2 | Opus | 1 High, 3 Medium, 2 Low | `new evidence`: CodeRabbit skips PRs whose base is not `main`, so stacked PRs were never reviewed. `fix regression`: the round-1 wait loop never exits on a skipped check. `missed earlier`: undefined grounds for accepting a finding, no miss cause for fixes made after the loop, "loop" used for two things, blind reviewers resolving CodeRabbit threads. |
| 3 | Opus | 1 High, 2 Medium, 3 Low | `new evidence`: CodeRabbit reads its config from the head branch, and #9 targeted `main` while the work lives on the stack; a foreground `sleep` is blocked and a review takes about 10 minutes; CodeRabbit pauses after 5 commits; its docstring check warns on every PR. `missed earlier`: no wait for reviews of fixes, a stale line about thread resolution, no glossary entry. |
| 4 | Sonnet | 1 Medium, 6 unrated | `fix regression`: the wait loop could read the previous commit's check, and the nudge could not run inside a background loop. `missed earlier`: the blind loop definition, the `not valid` miss cause, the blocked reason in `plan.md`, the handover. |
| 5 | Fable | 1 Low, 1 Minor | `fix regression`: the nudge fired at 90 s while the text said 2 minutes, and the loop could outlive the 30-minute background limit. |
| direct | Haiku | 1 unrated | `fix regression`: 56 polls plus API calls left almost no room under 30 minutes. |
| CodeRabbit | CodeRabbit | 1 Major | `new evidence`: by default a review that errors still reports `SUCCESS` (`fail_commit_status`). |
| CodeRabbit | CodeRabbit | none | |

**Retro.** Five rounds instead of one, for two reasons:
- **New evidence came late.** Most of the High and Medium findings came from how CodeRabbit, GitHub and the agent harness actually behave, learned one round at a time: the skipped check, the default branch only, the config read from the head branch, the pause after 5 commits, the background limit. The workflow was written from assumptions before any of it was observed. Running the flow once on a throwaway PR before the first round would have shown most of it.
- **Each fix to the wait loop brought the next finding.** The loop changed in rounds 1, 2, 3, 4 and 5, and rounds 2, 4 and 5 and the direct review each found a problem with the previous version. A shell loop in a doc was never run until round 5.

Changes it led to: none. Candidate rules, if a later retro gives the same origins for the same reasons: test any instruction that depends on an outside service or the harness against the real thing before round 1, and run any command a doc tells agents to run before the first review.

## [#10](https://github.com/AboulEinein/soroband/pull/10) docs(review): record each review round and a retro per PR (2026-10-28)

Planned rounds: 2.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Sonnet | 2 Medium, 3 Low, 1 Minor | `first look`: the commits that add the retro came after the review ended; no step created the entry or added direct and CodeRabbit rows; the glossary said rounds only; no threshold for a pattern; #9's entry broke its own format twice. |
| 2 | Fable | 1 Medium, 1 Low, 1 Minor | `fix regression`: the round-1 exemption left CodeRabbit's review of the retro commit with no owner. `missed earlier`: "round" still meant every review in three places; the handover's pattern test was looser than `review.md`'s. |
| 3 | Sonnet | 2 Medium, 2 Low | `fix regression`: a row per CodeRabbit review is a commit CodeRabbit reviews, so the review never ends; a blocked session never reaches the retro. `missed earlier`: no tie-break between origins; "round" in two handover lines. Reassessed: [retrospective](https://github.com/AboulEinein/soroband/pull/10#issuecomment-6460011527) as a PR comment. |
| 4 | Opus | 1 Medium, 1 Low | `fix regression`: a blocked session committed the retro but not the records noted outside the branch; the file's opening line still had CodeRabbit rows committed as they came. |
| direct | Haiku | none | |
