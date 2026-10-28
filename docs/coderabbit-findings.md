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
| 2026-10-28 | [#10](https://github.com/AboulEinein/soroband/pull/10#discussion_r4396705957) | `review-retros.md`'s opening line left out the blocked session's early records commit. | docs drift | valid | not checked | – |
| 2026-10-28 | [#10](https://github.com/AboulEinein/soroband/pull/10#discussion_r4396705959) | A `not valid` or `accepted` finding on the final records commit had no fix commit to be recorded in. | correctness | valid | not checked | – |
| 2026-10-28 | [#10](https://github.com/AboulEinein/soroband/pull/10#discussion_r4396705964) | "Entries are only ever appended" conflicted with a resumed session completing its entry. | docs drift | valid | not checked | – |
| 2026-10-28 | [#10](https://github.com/AboulEinein/soroband/pull/10) | Review body: #10's entry had no retro yet. The retro belongs in the final records commit, which had not been made. | docs drift | not valid | – | – |
| 2026-10-28 | [#10](https://github.com/AboulEinein/soroband/pull/10) | Review body: #9's entry counted unposted reviews as rounds, which `review.md` says did not happen. | docs drift | valid | not checked | – |
| 2026-10-28 | [#10](https://github.com/AboulEinein/soroband/pull/10#discussion_r4396769973) | `review-retros.md` asked a row for every review after ready, including a clean records-commit review, so the review could never end. | correctness | valid | after the loop | – |
| 2026-10-28 | [#10](https://github.com/AboulEinein/soroband/pull/10#discussion_r4396826455) | `review-retros.md`'s opening line said one final commit, leaving out the further records commit a finding on it needs. | docs drift | valid | after the loop | – |
| 2026-10-28 | [#10](https://github.com/AboulEinein/soroband/pull/10#discussion_r4396826455) | The same line said a blocked session commits "what it has so far" without naming the retro, held records and handover. | docs drift | valid | after the loop | – |
| 2026-10-28 | [#10](https://github.com/AboulEinein/soroband/pull/10#discussion_r4396860240) | Two rows named a doc fix in the Follow-up column, which is for a rule, check or skill proposal, or `–`. | docs drift | valid | after the loop | – |
| 2026-10-28 | [#12](https://github.com/AboulEinein/soroband/pull/12#discussion_r4397192294) | #12's entry in `review-retros.md` had no "Ran" line or retro. Both belong in the final records commit, which had not been made. | docs drift | not valid | – | – |
