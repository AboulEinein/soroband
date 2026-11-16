# Developer checklist

What a change needs before its pull request opens, and before each later push, so the owner completes the project checks and evidence. Work through it in order; each step ends on its **Done when**. The full rules sit behind the links, as reference.

## 1. Tests go red first

Write the test for each behavior the change adds or fixes, and see it fail before the code that makes it pass. Its expected value comes from outside the code under test ([`verification.md`](verification.md#tests)).

**Done when** every new behavior has a test you have watched go red on broken code, and the PR's Evidence names it.

## 2. Reach list

Apply [`REVIEW.md`](../REVIEW.md)'s reach rules (What the diff reaches, Paths into state, Boundaries) to your own diff, as the reviewer will, and write what you find in the PR's **Reach** section, in four groups: **Callers**, **Consumers** (copies included), **Paths** and **Boundaries**. One line per item, each with how it is covered: a test name, or `read:` and why it is safe.

**Done when** every changed function, new or widened value, changed state and changed entry point in `git diff <base>` has its line. The reviewer checks the list against the diff (`REVIEW.md`, Reach list).

## 3. Fix the class

Every fix, to your own bug or to a review finding:

1. Name the defect class in one phrase ("a path into `MomentQueue`'s state that skips the gap guard", "a doc restating a requirement from `plan.md`").
2. Search the repository for its siblings: the same pattern elsewhere (`git grep`, the callers, the other paths into the state).
3. Add a test per sibling that is wrong and see it go red, then fix them all in the same commit.
4. Write `Siblings checked: <search>, <result>` in the commit message body, and in the reply on the finding's thread when it has one (a finding outside a PR has no thread; the commit message is its record).

**Done when** the commit, and the reply where there is a thread, carry the `Siblings checked` line, and every sibling found has its red-then-green test.

## 4. One home per fact

A requirement, rule, number or command lives in one doc; every other doc links to it. Requirements are in [`plan.md`](plan.md), how they are proven in [`verification.md`](verification.md), how reviews run in [`review.md`](review.md), the domain terms in [`GLOSSARY.md`](../GLOSSARY.md). A number or a "within budget" claim is copied from the measurement that produced it.

**Done when** the change states each fact in its home only, and a term it renames or retires is updated in `GLOSSARY.md` and no longer named in the docs outside the places `docs/review.md`'s Retired terms line exempts.

## 5. Pre-push checks

Run `scripts/verify/prepush.sh`; [`verification.md`](verification.md#before-pushing) says what it covers and what only CI runs.

**Done when** it ends with `prepush: all checks passed`.

## 6. Requested reviews

Use Council only when the user explicitly requests a review, as [`review.md`](review.md#explicit-review-requests) describes. This step does not start a reviewer or require a review when none was requested.

Then open the pull request with the template's sections filled, Reach included. Preserve the required project checks and human approvals.
