# CodeRabbit findings

Every finding CodeRabbit makes on a pull request, one row each, recorded as [`review.md`](review.md#coderabbit) describes. The valid ones show what the blind review loop misses.

Columns:
- **Category:** `correctness`, `error handling`, `concurrency`, `tests`, `docs drift`, `security and privacy`, `performance`, `build and CI`, or `style`. Add a category only when none fits.
- **Verdict:** `valid` (fixed) or `not valid` (answered with evidence).
- **Missed because** (valid findings only): `not checked` (the reviewer did not look for this kind of problem), `judged fine` (a reviewer saw it and accepted it), `outside the diff` (the problem is in code the PR did not change), or `not in the requirements` (`plan.md` did not ask for it).
- **Follow-up:** the rule, check or skill proposal it led to, or `–`.

| Date | PR | Finding | Category | Verdict | Missed because | Follow-up |
| --- | --- | --- | --- | --- | --- | --- |
