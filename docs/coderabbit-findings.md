# CodeRabbit findings

Every finding CodeRabbit makes on a pull request, one row each, recorded as [`review.md`](review.md#coderabbit) describes. The valid ones show what the blind review loop misses.

Columns:
- **Category:** `correctness`, `error handling`, `concurrency`, `tests`, `docs drift`, `security and privacy`, `performance`, `build and CI`, or `style`. Add a category only when none fits.
- **Verdict:** `valid` (fixed), `accepted` (valid, left as it is, with the reason in the Finding column) or `not valid` (answered with evidence).
- **Missed because** (`valid` and `accepted` findings): `not checked` (the reviewer did not look for this kind of problem), `judged fine` (a reviewer saw it and accepted it), `outside the diff` (the problem is in code the PR did not change), `not in the requirements` (`plan.md` did not ask for it), or `after the loop` (the problem came in with a fix made after the blind loop ended, which only CodeRabbit reviewed). `–` for `not valid` findings.
- **Follow-up:** the rule, check or skill proposal it led to, or `–`.

| Date | PR | Finding | Category | Verdict | Missed because | Follow-up |
| --- | --- | --- | --- | --- | --- | --- |
| 2026-10-28 | [#9](https://github.com/AboulEinein/soroband/pull/9#discussion_r4396375602) | The wait loop reads only the `CodeRabbit` state, and by default (`fail_commit_status: false`) a review that errors still reports `SUCCESS`. | build and CI | valid | not checked | – |
