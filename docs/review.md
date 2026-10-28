# Review

Every pull request goes through this loop, and so does any other work that needs a second opinion (a design change, a migration plan, a release checklist). A pull request then gets a CodeRabbit review (below).

## Blind reviewer

The reviewer judges the work against the requirements, never against the implementer's account of it.

- **A fresh agent every round.** Never the implementer, never a continuation of an earlier reviewer.
- **The brief carries only the work and its requirements:** the PR, the milestone ID, and where its requirements and evidence rules live. The implementer's reasoning, worries, history of attempts and suggested focus areas stay out of it.
- **Pull requests use the `pr-review` skill with `--no-story --submit`.** Requirements come from `docs/plan.md`, not a task tracker. `--submit` publishes the review with its inline comments on the PR; without it the review stays an unsubmitted draft. Because the PR author and the reviewer share one GitHub account, GitHub accepts the review only as a comment, not "request changes"; the skill handles that. The posted review is the record across rounds, and from round 2 the skill's re-review mode checks every earlier finding.
- **The reviewer resolves what it verifies.** Each earlier blind-review thread it confirms as handled (fixed, or answered with evidence it accepts) it resolves on the PR. Threads it does not confirm stay open, with a reply saying what is still missing. Open threads are then exactly the findings still to act on.
- **Other work:** the reviewer gets the file paths and the question, with the same limits on the brief.

Brief for a pull request, used word for word:

```text
Review PR #<number> in AboulEinein/soroband with the pr-review skill, using --no-story --submit.
The PR implements milestone <ID>. Its requirements are in docs/plan.md under <ID>, and the evidence it must show is in docs/verification.md under <ID>.
Resolve each earlier blind-review thread you confirm as handled; reply on any you do not, saying what is still missing. Leave CodeRabbit's threads alone.
```

## Rounds

1. **Open the pull request as a draft** (`gh pr create --draft`). CodeRabbit skips drafts (`.coderabbit.yaml`), so it does not review each round's commits.
2. **Plan the rounds before round 1** and write the number in the PR description: 1 for a small fix, 2 for a typical change, 3 for a milestone or a risky change. The plan is a budget for judgment, not a stop: what ends the loop is below.
3. **Each round:**
   - Push all commits first; nothing is pushed while the review runs. If the branch moves mid-review, the skill keeps its review as a draft instead of posting it.
   - Run the blind review.
   - Confirm the review is posted: `gh api repos/AboulEinein/soroband/pulls/<number>/reviews` lists it with a state other than `PENDING`. A draft or missing review means the round did not happen; run it again.
   - Answer every finding in its PR thread, either with the fix (the commit) or with evidence for why it should stay as it is.
   - Add the round to the pull request's entry in [`review-retros.md`](review-retros.md): the reviewer's model, its findings by severity, and the origin of each finding.
4. **No fix leaves the loop unreviewed.** A PR is never handed over with commits that no reviewer has seen.
5. **After each round, judge whether another one adds value.** The session lead judges, and may consult an advisor agent (below) on the question. In an unattended run the conductor checks that judgment after the session stops (see [`plan.md`](plan.md#unattended-runs)).
   - **Run another round** after a round whose fixes change behavior or a documented rule, as long as the findings shrink: from round 2 on, fewer or less severe than the last round's, and of a different kind. This holds past the planned number.
   - **Review the last fixes directly** when they are comments or wording only, with no change to behavior or to a documented rule. Someone other than the implementer reads the diff: a fresh agent the lead spawns with the diff and the findings it answers. The reviewer posts its verdict as a PR comment naming the commit, resolves each thread it confirms as handled and replies on any it does not, and the handover links to the comment. A full round on such a diff adds nothing.
   - **Reassess** (below) when a fixed finding comes back, when findings repeat in kind, or when they stop shrinking.
6. **The blind loop ends** when a round finds nothing to act on, or a direct review of its fixes finds nothing to act on. CodeRabbit's review follows (below).

## CodeRabbit

CodeRabbit reviews each pull request, whatever its base, once the blind loop has ended. It reads `.coderabbit.yaml` from the pull request's head branch, so a branch made before that file existed, with a base other than `main`, gets no review until it has it. The `CodeRabbit` check is required to merge into `main`, but it passes when a review is done, whatever the review found, and GitHub also lets a skipped check through; this flow is what makes sure the review happens. The `main` ruleset requires every review thread to be resolved, so no finding with a thread is left unanswered.

1. **Mark the pull request ready:** `gh pr ready <number>`. CodeRabbit starts a full review.
2. **Wait for the review to pass.** `gh pr checks` reports the checks of the pull request's latest commit. The `CodeRabbit` check left on the draft reads `SKIPPED`, which `gh pr checks --watch` counts as done, so poll until it reads `SUCCESS`, for at most 25 minutes. If it still reads `SKIPPED`, or is missing, after 2 minutes, the loop asks CodeRabbit once with `@coderabbitai review`. A review takes about 10 minutes, so run the loop in the background (in Claude Code, `run_in_background`) and wait for it to exit:
   ```zsh
   for i in {1..50}; do
     state=$(gh pr checks <number> --json name,state --jq 'map(select(.name == "CodeRabbit")) | last | .state // ""')
     [[ $state == SUCCESS ]] && exit 0
     (( i == 5 )) && [[ -z $state || $state == SKIPPED ]] && gh pr comment <number> --body '@coderabbitai review'
     sleep 30
   done; exit 1
   ```
   If it does not exit 0, read CodeRabbit's latest comment on the pull request. Unless it says how to go on (a rate limit to wait out, a command to post), stop as `blocked (review: CodeRabbit did not review)`.
3. **Judge every finding:**
   - **Valid:** fix it, and reply on its thread naming the commit.
   - **Valid, but left as it is:** only when fixing it would contradict a decision recorded in `design.md`, `plan.md` or the handover, or when it is outside the pull request's scope and becomes a follow-up in the handover. The reply quotes the decision or names the follow-up.
   - **Not valid:** reply with the evidence.
   - **Findings without a thread** (the nitpicks and the comments outside the diff that CodeRabbit lists in its review body, and the warnings of its pre-merge checks in its summary comment) get one PR comment listing each with its verdict and the fix commit or the evidence.
4. **Fixes are reviewed too.** The pull request stays ready, so CodeRabbit reviews each new commit on its own; wait for that review as in step 2, then take its new findings through step 3. That is enough for a fix to comments or wording. A fix that changes behavior or a documented rule also gets a blind round, or a direct review if it qualifies (see Rounds).
5. **Resolve each thread** once its finding is handled: a valid one after the review of its fix (CodeRabbit's, or the blind round's) raises nothing about it, the others after the reply. The session lead resolves CodeRabbit's threads, because CodeRabbit is not briefed to check replies.
6. **Record every finding** in [`coderabbit-findings.md`](coderabbit-findings.md), valid or not, with why the blind loop missed each valid one.
7. **CodeRabbit's review ends** when its review of the last commit raises nothing to act on and every thread is resolved. Only then has the review ended.
8. **Write the retro** in the pull request's entry in [`review-retros.md`](review-retros.md), before the session stops: why the review took the rounds it did, and what to change so the next pull request needs fewer.

### Learning from reviews

Two logs record how reviews go: [`coderabbit-findings.md`](coderabbit-findings.md) shows what the blind loop misses, and [`review-retros.md`](review-retros.md) shows why a pull request needed the rounds it did. In the findings log, when a valid finding repeats a category and a miss cause already in the log, it is a pattern (for `after the loop`, the pattern is in how fixes are made after the loop, not in the blind review); turn it into a rule where the miss happened, and name the rule in the follow-up column of every row it covers:

- **The reviewer did not check for it:** a line in a `## Checklist` section of this file, and a line in the brief above telling the reviewer to go through that checklist. Add both with the first pattern.
- **The implementer keeps making it:** a rule in `AGENTS.md`, or in the doc that covers the area (`verification.md` for tests, `design.md` for architecture).
- **A tool can find it:** a lint or CI check, which beats a written rule.
- **It applies to any project, not just Soroband:** a proposal to the user for the `pr-review` skill, which lives outside this repository.

In the retros, an origin that keeps coming back across pull requests is a pattern too, and turns into a rule the same way: `fix regression` points at how fixes are made, `missed earlier` at the reviewer brief or the checklist, `new evidence` at checking real behavior before the first round, `unclear requirement` at `plan.md`.

Read both logs for patterns when a milestone ends, before updating the handover, and again once parallel milestones have both merged. Entries are only ever appended, so a merge conflict in a log keeps both sides.

## Reassess instead of another round

The approach is in question, not the last fix, when a fixed finding comes back, when rounds keep turning up problems of the same kind, or when the findings stop shrinking.

1. **Stop fixing.** No further fixes until the way forward is chosen; a round that only reviews fixes already pushed is allowed (step 5 below).
2. **Get an independent second opinion** unless the root cause is already plain, in which case the retrospective says why none was sought. Spawn an advisor agent, preferably on a different model from the implementer, briefed with the PR, its requirements, and the open findings with links to their review threads, but not the implementer's reasoning. It judges the root cause for itself, may propose a different approach, and may implement it on a local branch in its own worktree. It does not push or comment on the PR. The lead reviews what it returns before adopting any of it.
3. **Write a retrospective** as a PR comment, and link it from the handover:
   - each open finding and the rounds it appeared in;
   - what the findings have in common;
   - the root cause, as one of: the requirement is unclear or wrong (`plan.md`); the approach is wrong (`design.md`); the verification cannot show the behavior (tests or harness); a judgment call the reviewer and implementer disagree on.
   - where the advisor agrees or disagrees with the lead.
4. **Propose the way forward**, with a recommendation: revise the requirement, rethink the approach from scratch, add the missing verification, or accept the finding with a recorded reason.
5. **If the way forward needs no decision from the user** (a fix within the milestone's requirements and design), apply it and go back to the rounds. A second reassessment on the same root cause counts as needing a decision. Otherwise, first have any fixes already pushed reviewed (a round, or a direct review if they qualify), then set the ledger to `blocked (review: <cause>)` and stop the session; the user decides the next step.
