# Review rules

Rules for any reviewer of this repository, read by the `pr-review` skill with `CLAUDE.md`. How reviews run is in [`docs/review.md`](docs/review.md).

- **Nit cap: none.** Post every finding you verified, at its severity. A Low or Minor finding about behavior, data or a boundary is never held back; only style and wording nits may be grouped in one comment.
- **What the diff reaches.** For every changed function, read its callers. For every value, state or enum case the diff adds or widens (a new empty state, a new range of values, a new setting), read every function that can now receive it, changed or not, including the UI process and anything that keeps a copy (the snapshot the UI process mirrors, a cached registry, a drawn image). A defect the PR makes reachable is the PR's finding, not `[Pre-existing]`.
- **Paths into state.** For every piece of state the diff changes (a queue's bookkeeping, a loop's exit, a cache), find every path into it and check each against the code and a test, not only the path the task or finding names.
- **Boundaries.** For every entry point the diff adds or changes (a C function in `ffi.rs`, a `soroband` argument, a setting, a debug URL), check its limits and one past them against the code and the tests.
- **Reach list.** The PR's Reach section lists the callers, consumers, paths and boundaries the developer found by the three rules above ([`docs/checklist.md`](docs/checklist.md), step 2). Check it against the diff: each one missing from it is a finding against the Reach list, at the severity of what it misses.
- **Siblings.** Every fix names its defect class and ends its commit message, and its reply on the finding's thread, with `Siblings checked: <search>, <result>` ([`docs/checklist.md`](docs/checklist.md), step 3). A fix without it, or a sibling that search should have found and did not, is a finding.
- **CI.** Read `gh pr checks`. A failing check is a finding. While a check is pending, wait for it (`gh pr checks --watch`, at most 15 minutes) before the verdict, or say in the verdict line that it holds only if CI passes.
