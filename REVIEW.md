# Review rules

Rules for any reviewer of this repository, read by the `pr-review` skill with `CLAUDE.md`. How reviews run is in [`docs/review.md`](docs/review.md).

- **Nit cap: none.** Post every finding you verified, at its severity. A Low or Minor finding about behavior, data or a boundary is never held back; only style and wording nits may be grouped in one comment.
- **What the diff reaches.** For every changed function, read its callers. For every value, state or enum case the diff adds or widens (a new empty state, a new range of values, a new setting), read every function that can now receive it, changed or not, including the History process and anything that keeps a copy (a cached registry, a drawn image). A defect the PR makes reachable is the PR's finding, not `[Pre-existing]`.
- **Boundaries.** For every entry point the diff adds or changes (a C function in `ffi.rs`, a `soroband` argument, a setting, a debug URL), check its limits and one past them against the code and the tests.
- **CI.** Read `gh pr checks`. A failing check is a finding. While a check is pending, wait for it (`gh pr checks --watch`, at most 15 minutes) before the verdict, or say in the verdict line that it holds only if CI passes.
