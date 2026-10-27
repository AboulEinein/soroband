# Review

Every pull request goes through this loop, and so does any other work that needs a second opinion (a design change, a migration plan, a release checklist).

## Blind reviewer

The reviewer judges the work against the requirements, never against the implementer's account of it.

- **A fresh agent every round.** Never the implementer, never a continuation of an earlier reviewer.
- **The brief carries only the work and its requirements:** the PR, the milestone ID, and where its requirements and evidence rules live. The implementer's reasoning, worries, history of attempts and suggested focus areas stay out of it.
- **Pull requests use the `pr-review` skill with `--no-story --submit`.** Requirements come from `docs/plan.md`, not a task tracker. `--submit` publishes the review with its inline comments on the PR; without it the review stays an unsubmitted draft. Because the PR author and the reviewer share one GitHub account, GitHub accepts the review only as a comment, not "request changes"; the skill handles that. The posted review is the record across rounds, and from round 2 the skill's re-review mode checks every earlier finding.
- **The reviewer resolves what it verifies.** Each earlier review thread it confirms as handled (fixed, or answered with evidence it accepts) it resolves on the PR. Threads it does not confirm stay open, with a reply saying what is still missing. Open threads are then exactly the findings still to act on.
- **Other work:** the reviewer gets the file paths and the question, with the same limits on the brief.

Brief for a pull request, used word for word:

```text
Review PR #<number> in AboulEinein/soroband with the pr-review skill, using --no-story --submit.
The PR implements milestone <ID>. Its requirements are in docs/plan.md under <ID>, and the evidence it must show is in docs/verification.md under <ID>.
Resolve each earlier review thread you confirm as handled; reply on any you do not, saying what is still missing.
```

## Rounds

1. **Plan the rounds before round 1** and write the number in the PR description: 1 for a small fix, 2 for a typical change, 3 for a milestone or a risky change. The plan is a budget for judgment, not a stop: what ends the loop is below.
2. **Each round:**
   - Push all commits first; nothing is pushed while the review runs. If the branch moves mid-review, the skill keeps its review as a draft instead of posting it.
   - Run the blind review.
   - Confirm the review is posted: `gh api repos/AboulEinein/soroband/pulls/<number>/reviews` lists it with a state other than `PENDING`. A draft or missing review means the round did not happen; run it again.
   - Answer every finding in its PR thread, either with the fix (the commit) or with evidence for why it should stay as it is.
3. **No fix leaves the loop unreviewed.** A PR is never handed over with commits that no reviewer has seen.
4. **After each round, judge whether another one adds value.** The session lead judges, and may consult an advisor agent (below) on the question. In an unattended run the conductor checks that judgment after the session stops (see [`plan.md`](plan.md#unattended-runs)).
   - **Run another round** after a round whose fixes change behavior or a documented rule, as long as the findings shrink: from round 2 on, fewer or less severe than the last round's, and of a different kind. This holds past the planned number.
   - **Review the last fixes directly** when they are comments or wording only, with no change to behavior or to a documented rule. Someone other than the implementer reads the diff: a fresh agent the lead spawns with the diff and the findings it answers. The reviewer posts its verdict as a PR comment naming the commit, resolves each thread it confirms as handled and replies on any it does not, and the handover links to the comment. A full round on such a diff adds nothing.
   - **Reassess** (below) when a fixed finding comes back, when findings repeat in kind, or when they stop shrinking.
5. **The loop ends** when a round finds nothing to act on, or a direct review of its fixes finds nothing to act on.

## Reassess instead of another round

The approach is in question, not the last fix, when a fixed finding comes back, when rounds keep turning up problems of the same kind, or when the findings stop shrinking.

1. **Stop fixing.** No further fixes until the way forward is chosen; a round that only reviews fixes already pushed is allowed (step 5).
2. **Get an independent second opinion** unless the root cause is already plain, in which case the retrospective says why none was sought. Spawn an advisor agent, preferably on a different model from the implementer, briefed with the PR, its requirements, and the open findings with links to their review threads, but not the implementer's reasoning. It judges the root cause for itself, may propose a different approach, and may implement it on a local branch in its own worktree. It does not push or comment on the PR. The lead reviews what it returns before adopting any of it.
3. **Write a retrospective** as a PR comment, and link it from the handover:
   - each open finding and the rounds it appeared in;
   - what the findings have in common;
   - the root cause, as one of: the requirement is unclear or wrong (`plan.md`); the approach is wrong (`design.md`); the verification cannot show the behavior (tests or harness); a judgment call the reviewer and implementer disagree on.
   - where the advisor agrees or disagrees with the lead.
4. **Propose the way forward**, with a recommendation: revise the requirement, rethink the approach from scratch, add the missing verification, or accept the finding with a recorded reason.
5. **If the way forward needs no decision from the user** (a fix within the milestone's requirements and design), apply it and go back to the rounds. A second reassessment on the same root cause counts as needing a decision. Otherwise, first have any fixes already pushed reviewed (a round, or a direct review if they qualify), then set the ledger to `blocked (review: <cause>)` and stop the session; the user decides the next step.
