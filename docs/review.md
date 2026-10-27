# Review

Every pull request goes through this loop, and so does any other work that needs a second opinion (a design change, a migration plan, a release checklist). A pull request then gets a CodeRabbit review (below).

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

1. **Open the pull request as a draft** (`gh pr create --draft`). CodeRabbit skips drafts, so it does not review each round's commits.
2. **Plan the rounds before round 1** and write the number in the PR description: 1 for a small fix, 2 for a typical change, 3 for a milestone or a risky change. The plan is a budget for judgment, not a stop: what ends the loop is below.
3. **Each round:**
   - Push all commits first; nothing is pushed while the review runs. If the branch moves mid-review, the skill keeps its review as a draft instead of posting it.
   - Run the blind review.
   - Confirm the review is posted: `gh api repos/AboulEinein/soroband/pulls/<number>/reviews` lists it with a state other than `PENDING`. A draft or missing review means the round did not happen; run it again.
   - Answer every finding in its PR thread, either with the fix (the commit) or with evidence for why it should stay as it is.
4. **No fix leaves the loop unreviewed.** A PR is never handed over with commits that no reviewer has seen.
5. **After each round, judge whether another one adds value.** The session lead judges, and may consult an advisor agent (below) on the question. In an unattended run the conductor checks that judgment after the session stops (see [`plan.md`](plan.md#unattended-runs)).
   - **Run another round** after a round whose fixes change behavior or a documented rule, as long as the findings shrink: from round 2 on, fewer or less severe than the last round's, and of a different kind. This holds past the planned number.
   - **Review the last fixes directly** when they are comments or wording only, with no change to behavior or to a documented rule. Someone other than the implementer reads the diff: a fresh agent the lead spawns with the diff and the findings it answers. The reviewer posts its verdict as a PR comment naming the commit, resolves each thread it confirms as handled and replies on any it does not, and the handover links to the comment. A full round on such a diff adds nothing.
   - **Reassess** (below) when a fixed finding comes back, when findings repeat in kind, or when they stop shrinking.
6. **The loop ends** when a round finds nothing to act on, or a direct review of its fixes finds nothing to act on.

## CodeRabbit

CodeRabbit reviews each pull request once the blind loop has ended. Its `CodeRabbit` check is required to merge into `main`; it passes when the review is done, whatever the review found. The `main` ruleset also requires every review thread to be resolved, so no finding is left unanswered.

1. **Mark the pull request ready:** `gh pr ready <number>`. CodeRabbit starts a full review.
2. **Wait for the review to finish.** On the draft, the `CodeRabbit` check was left `SKIPPED`, which `gh pr checks --watch` counts as done, so wait for it to pass instead:
   ```sh
   until gh pr checks <number> --json name,state --jq '.[] | select(.name == "CodeRabbit") | .state' | grep -qx SUCCESS; do sleep 30; done
   ```
3. **Judge every finding:**
   - **Valid:** fix it, and reply on its thread naming the commit.
   - **Valid, but left as it is:** reply with the reason. This needs the same grounds as accepting a finding in a reassessment (below).
   - **Not valid:** reply with the evidence.
   - **Findings without a thread** (the nitpicks and the comments outside the diff that CodeRabbit lists in its review body) get one PR comment listing each with its verdict and the fix commit or the evidence.
4. **Fixes are reviewed too.** The pull request stays ready, so CodeRabbit reviews each new commit on its own, and its new findings go through step 3. That is enough for a fix to comments or wording. A fix that changes behavior or a documented rule also gets a blind round, or a direct review if it qualifies (see Rounds).
5. **Resolve each thread** once its finding is handled: a valid one after the review of its fix (CodeRabbit's, or the blind round's) raises nothing about it, the others after the reply. The session lead resolves CodeRabbit's threads, because CodeRabbit is not briefed to check replies.
6. **Record every finding** in [`coderabbit-findings.md`](coderabbit-findings.md), valid or not, with why the blind loop missed each valid one.
7. **The CodeRabbit review ends** when CodeRabbit's review of the last commit raises nothing to act on and every thread is resolved. Only then has the review loop ended.

### Learning from the findings

The findings show what the blind loop misses. When a valid finding repeats a category and a miss cause already in the log, it is a pattern; turn it into a rule where the miss happened, and name the rule in the follow-up column of every row it covers:

- **The reviewer did not check for it:** a line in a `## Checklist` section of this file, and a line in the brief above telling the reviewer to go through that checklist. Add both with the first pattern.
- **The implementer keeps making it:** a rule in `AGENTS.md`, or in the doc that covers the area (`verification.md` for tests, `design.md` for architecture).
- **A tool can find it:** a lint or CI check, which beats a written rule.
- **It applies to any project, not just Soroband:** a proposal to the user for the `pr-review` skill, which lives outside this repository.

Read the log for patterns when a milestone ends, before updating the handover.

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
