# Review retros

One entry per pull request. Which rows it gets and when each part is committed is in [`review.md`](review.md) (Rounds step 3, CodeRabbit steps 6 to 9). Together with [`coderabbit-findings.md`](coderabbit-findings.md), these show why reviews take the rounds they do.

Each entry has:
- **A heading:** the pull request, its title and the date it opened.
- **Planned rounds** and what ran: blind rounds, direct reviews, CodeRabbit reviews.
- **A table, one row per review:** the review (blind round number, `direct`, or `CodeRabbit`), the reviewer's model, the findings by severity (the pr-review skill's `Critical`, `High`, `Medium`, `Low` and `Minor`, or `unrated` for a finding without one, such as its `Discussion`; CodeRabbit's `Major`, `Minor` and `Trivial` as given), and the origin of each finding.
- **Retro:** why the review took the rounds it did, what the extra rounds caught that earlier ones did not, and the changes it led to (a rule, a check, a doc), or "none".

Origins, most specific first; use the first that fits:
- `fix regression`: came in with a fix for an earlier finding.
- `new evidence`: shown by running or observing the real thing (a tool, a service, the app), which no reading of the diff could show.
- `unclear requirement`: the requirement or the task allowed more than one reading.
- `missed earlier`: in code or text an earlier review already saw.
- `first look`: found in the first review that could see it.

## [#9](https://github.com/AboulEinein/soroband/pull/9) docs(review): add CodeRabbit after the blind loop and log its findings (2026-10-28)

Planned rounds: 1. Ran: 5 blind reviews, 1 direct review, 2 CodeRabbit reviews. The blind reviews ran unposted, so under `review.md` Rounds step 3 they were not rounds; they are kept below as reviews.

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

Planned rounds: 2. Ran: 5 blind rounds, 2 direct reviews, 3 CodeRabbit reviews with findings, 1 reassessment.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Sonnet | 2 Medium, 3 Low, 1 Minor | `first look`: the commits that add the retro came after the review ended; no step created the entry or added direct and CodeRabbit rows; the glossary said rounds only; no threshold for a pattern; #9's entry broke its own format twice. |
| 2 | Fable | 1 Medium, 1 Low, 1 Minor | `fix regression`: the round-1 exemption left CodeRabbit's review of the retro commit with no owner. `missed earlier`: "round" still meant every review in three places; the handover's pattern test was looser than `review.md`'s. |
| 3 | Sonnet | 2 Medium, 2 Low | `fix regression`: a row per CodeRabbit review is a commit CodeRabbit reviews, so the review never ends; a blocked session never reaches the retro. `missed earlier`: no tie-break between origins; "round" in two handover lines. Reassessed: [retrospective](https://github.com/AboulEinein/soroband/pull/10#issuecomment-6460011527) as a PR comment. |
| 4 | Opus | 1 Medium, 1 Low | `fix regression`: a blocked session committed the retro but not the records noted outside the branch; the file's opening line still had CodeRabbit rows committed as they came. |
| direct | Haiku | none | |
| CodeRabbit | CodeRabbit | 1 Major, 2 Minor | `first look`: a finding on the final records commit with no fix had nowhere to be recorded; two lines contradicted the blocked-session path. |
| 5 | Sonnet | 1 Medium, 2 Low | `fix regression`: "no row" and "that review's row" in one step. `missed earlier`: blind and direct reviews after ready had no place for their rows; the handover update came after the review ended. |
| CodeRabbit | CodeRabbit | 2 Minor (review body) | `missed earlier`: #9's entry counted unposted reviews as rounds. Not valid: #10's retro was not written yet. |
| direct | Haiku | none | |
| CodeRabbit | CodeRabbit | 1 Major | `fix regression`: the opening line asked a row for every review after ready, including the clean records-commit review the rules exempt. |
| CodeRabbit | CodeRabbit | 2 Minor | `fix regression`: the opening line, which restated `review.md`'s timing, missed the further records commit and the blocked commit's contents. |
| CodeRabbit | CodeRabbit | 1 Minor | `fix regression`: two new log rows put a doc fix in the Follow-up column. |

**Retro.** Planned 2 rounds; ran 5 blind rounds, 2 direct reviews and 3 CodeRabbit reviews with findings. One cause behind almost all of it: the rules had to say when the review's own records are committed, and every record is a commit that CodeRabbit reviews. Rounds 1 to 3 each moved the end of the review and created the next finding (`fix regression` in rounds 2, 3, 4 and 5 and the last CodeRabbit review), until the reassessment after round 3 put all records into one final commit. After that the findings were wording around the new rule. CodeRabbit added what the blind rounds did not trace: the path of a finding with no fix, and its own habit of resolving its threads.

Changes it led to: the records rule itself (one final records commit); step 5 now says CodeRabbit may resolve its own threads; and `review-retros.md`'s opening line points to `review.md` instead of restating it, after three CodeRabbit findings in a row came from that restatement drifting. Candidate rule, if a later retro repeats `fix regression` for the same reason: before writing a rule that ends a loop, trace each path through it, including a finding with no fix, in the PR description, so round 1 reviews the trace.

## [#11](https://github.com/AboulEinein/soroband/pull/11) docs(handover): drop references to the earlier repository and app name (2026-10-28)

Planned rounds: 1. Ran: 1 blind round, 1 CodeRabbit review.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Sonnet | 1 Low | `first look`: the edit deleted the blank line before `## Next action`. |
| CodeRabbit | CodeRabbit | none | |

**Retro.** One round, as planned. The only finding was whitespace from the edit itself; fixing it needed no further round, and CodeRabbit raised nothing. The reviewer also noted that `docs/handover.md` still says the project started "without the earlier development history" in a dated decision-log row; the owner decides whether to reword it.

Changes it led to: none.

## [#12](https://github.com/AboulEinein/soroband/pull/12) docs(verify): send debug URLs with open -g so agents never take focus (2026-10-28)

Planned rounds: 1. Ran: 2 blind rounds, 1 CodeRabbit review.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 1 Medium, 1 Low | `first look`: the capture-status-item gotcha still sent its URL without `-g`; the decision said every `open` of the app passes `-g`, but `scripts/install.sh` opens the installed app in front. |
| 2 | Opus | none | |
| CodeRabbit | CodeRabbit | 1 Minor (not valid) | `first look`: #12's entry had no retro yet, which belongs in the final records commit. |

**Retro.** Two rounds instead of one, because round 1's fixes narrowed a documented rule (the decision now covers Debug builds only), which `review.md` sends to another round; round 2 found nothing. Round 1's Medium was a third `open` of a debug URL without `-g` that the first pass over the docs missed: the change was made by searching for the instructions already known to be wrong, not for every `open` in the docs. Before the first round, the change also dropped two code changes (debug commands that skip `NSApp.activate()`, a test host that cannot be activated) once running the real app showed neither was needed.

Changes it led to: none. CodeRabbit flagged an entry without its retro for the second PR in a row (#10, #12); if it does again, tell it in `.coderabbit.yaml` that an entry is completed by the final records commit.

## [#13](https://github.com/AboulEinein/soroband/pull/13) feat(history): M4 History window (2026-10-28)

Planned rounds: 3. Ran: 4 blind rounds (the first stopped by a pause), 1 direct review, 6 CodeRabbit reviews with an outcome.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 (stopped) | Sonnet | 2 Medium | `first look`: a finished month's comparison span ran into the month shown; All Time after a network switch started at the previous network's first hour. Stopped by the user's pause after it posted these two; its summary was never written. |
| 1 | Sonnet | none | Confirmed both fixes of the stopped review and resolved their threads. Noted outside the diff: the 30 MB criterion read literally, and the ledger and handover still to update. |
| direct | Haiku | none | Checked 0864ba6 (the test fixture split for CI's compiler): the same 168 heatmap cells in the same order. [Comment](https://github.com/AboulEinein/soroband/pull/13#issuecomment-6463010429). |
| CodeRabbit | CodeRabbit | 1 Minor | `first look`: the chart keyed networks by name, so same-named networks shared a color. |
| 2 | Sonnet | 1 Low | `fix regression`: the " (2)" suffix from the CodeRabbit fix could equal another network's real name. |
| CodeRabbit | CodeRabbit | 1 Minor (thread reply) | `fix regression`: the same suffix collision as round 2, already fixed in 25ffc64. |
| 3 | Sonnet | none | |
| CodeRabbit | CodeRabbit | none | |
| CodeRabbit | CodeRabbit | 1 Minor | `first look`: the records commit set M4 `in review`, though `plan.md` makes a milestone waiting on a decision and a hand checklist `blocked`. |
| CodeRabbit | CodeRabbit | 3 Minor | `first look`: the records commits for the user's decisions (M4's memory criterion accepted, M6 added, M5's review experiment) changed requirements in `plan.md` without the session prompt and `verification.md` rows that state them. |
| CodeRabbit | CodeRabbit | 1 Minor | `fix regression`: the new records-commit rule listed three documents for every change, though not every rule is stated in all three. |

**Retro.** Planned 3 rounds; the blind loop ran 2 (the stopped first review and round 1, then a direct review of a test-only fix), and CodeRabbit's single finding brought 2 more. The approach itself changed before any review: History began in the menu bar app's process, measurement showed AppKit, SwiftUI and Charts kept 13–40 MB after the window closed, and the user chose a separate History process; the opening-time work (standby, warm-up, daily sums) followed from measuring it. That evidence came from running the real app before round 1, so no round had to find it. The blind rounds then found two Medium edge cases in date and state logic (a finished month's comparison span, All Time after a network switch), both `first look`. CodeRabbit found what no round checked: a chart keyed by a user-editable name. Its fix introduced a suffix collision that round 2 and CodeRabbit both caught, a `fix regression` from writing the fix for the reported case only.

Changes it led to: the rule for records commits below. The two CodeRabbit rows match earlier `correctness` rows on their miss causes (`not checked` and `after the loop`, both #10), but for unrelated reasons (a doc loop's end condition there, a chart key here), so no rule. Candidate rule, if a later fix after the loop regresses again: before pushing such a fix, test the next case beyond the one reported (here, a suffix that collides).

After the user's decisions, a records commit added M6 and M5's review experiment to `plan.md`, and CodeRabbit found 3 places that state the same requirements and were not changed with it. With the earlier records finding and #10's, `docs drift` after the loop is now a pattern in how records commits are made, so `review.md`'s CodeRabbit step 7 now has records commits change every place that states a requirement.

## [#14](https://github.com/AboulEinein/soroband/pull/14) fix(app): tell a Debug build apart and guard the installed app (2026-10-28)

Planned rounds: 1. Ran: 3 blind rounds, 1 direct review, 4 CodeRabbit reviews with an outcome.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Sonnet | 1 Low | `first look`: nothing failed if the install guard was removed or moved below the replacement. |
| 2 | Sonnet | none | Confirmed `install-guard.sh` and resolved the thread. |
| CodeRabbit | CodeRabbit | 2 Minor | `fix regression`: `verification.md` claimed `install-guard.sh` checks the terminal answers, which it did not. `first look`: two concurrent installs could both pass the replace check. |
| 3 | Sonnet | 1 Low, 1 unrated | `first look`: the guard tells a terminal from a pipe, not the user from an agent; the CI and handover fixes for #3's and #10's threads were not named in the PR body. |
| CodeRabbit | CodeRabbit | none | Reviewed the lock, the terminal checks and the CI change. |
| direct | Haiku | none | Checked 333db49 (the install guide's wording) and the PR body. [Comment](https://github.com/AboulEinein/soroband/pull/14#issuecomment-6467389983). |
| CodeRabbit | CodeRabbit | none | |
| CodeRabbit | CodeRabbit | 1 Minor | `first look`: the records commit rated round 3's discussion as `Discussion`, which is not a severity. |

**Retro.** Planned 1 round; it took 3 and a direct review because the fix for round 1's finding was a new check, which needs its own round, and CodeRabbit then found that check's claim was wider than what it ran, a `fix regression` from describing the intended check instead of the one written. Its race finding was a case no blind round looked for: two runs of a script at once. Before merging the stack, 4 CodeRabbit threads left open on #3 and #10 surfaced through the `main` ruleset's thread rule; their fixes ride in this PR, which merges last.

Changes it led to: none. The `fix regression` repeats #13's origin, but for a different reason (a doc's claim here, a name collision there).


## [#16](https://github.com/AboulEinein/soroband/pull/16) docs: record the merged stack and the CodeRabbit backlog (2026-10-28)

Planned rounds: 1.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Sonnet | 3 Medium, 2 Low, 1 unrated | `first look`: the backlog missed #6's outside-diff finding on the `run-app.sh` gotcha, three backlog paths named the wrong crate or directory, "merged branches are not deleted" was false for most of the stack, and the stopping rule still marked a merged milestone `done` without its hand checklist. |
| direct | Haiku | 3 unrated | `fix regression`: a sentence lost its separator, and the new branch sentence was still false. `first look`: the `SIGPIPE` line was off by one. [Comment](https://github.com/AboulEinein/soroband/pull/16#issuecomment-6477159137). |
| direct | Haiku | 3 unrated | `fix regression`: the retarget sentence claimed GitHub retargets on deletion, contradicting `plan.md`'s stacked-branches rule. `first look`: two backlog lines off by one. [Comment](https://github.com/AboulEinein/soroband/pull/16#issuecomment-6477198246). |
| direct | Haiku | 1 unrated | Asked the docs to say which merged branches get deleted; declined because no step depends on it. [Comment](https://github.com/AboulEinein/soroband/pull/16#issuecomment-6477226820). |
| CodeRabbit | CodeRabbit | 1 Minor | `first look`: round 1's row rated the Discussion finding `Discussion`, which the table does not define, the same slip as #14. |
| CodeRabbit | CodeRabbit | 1 Minor | `fix regression`: the severity list written for the previous finding left out the pr-review skill's `Minor`. |
| CodeRabbit | CodeRabbit | 1 Minor | `first look`: `plan.md`'s stacked-branches rule did not allow a milestone to start from `main` once its predecessor had merged, as the handover tells M5 to. |
| CodeRabbit | CodeRabbit | 1 Minor | `fix regression`: the retarget rule written for round 1's finding retargeted after the merge, not before. |

**Retro.** Planned 1 round; it took 1 blind round and 3 direct reviews, because each fix to a factual claim (a path, a line, what GitHub does) was written from memory and the next reviewer checked it against the repository or GitHub. Writing down state that lives in another system needs the same check at writing time. CodeRabbit found the severity slip #14 already had, so the retro table now lists its severities; the first version of that list was written without reading the skill's scale and needed one more fix. Its last finding is review step 7's rule (a change to a requirement changes every document that states it) missed again: the blind round checked the handover against GitHub, not against `plan.md`.

Changes it led to: `review-retros.md` names the severity values.


## [#17](https://github.com/AboulEinein/soroband/pull/17) fix(app): name Wi-Fi once Location is allowed and choose the menu bar count (2026-10-28)

Planned rounds: 2.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 2 Low, 1 Minor | `first look`: an open popover kept the merged "Wi-Fi" row, `docs/agents/configure.md` did not list `menu_bar_count`, `isAllowed` compared the debug label. |
| 2 | Opus | 1 Medium | `fix regression`: round 1's registry reread waited for the popover, so Settings › Networks still kept the "Wi-Fi" row. |
| 3 | Opus | 2 Low, 1 unrated | `missed earlier`: the Location URL and branch duplicated in `LocationRow`, no glossary term for the merge, and no second look for the name after the 10 s retry. |
| 4 | Opus | none | |

**Retro.** Planned 2 rounds; it took 4 because the fix for round 1's stale row was written for the one view the finding named (the popover), and round 2 found the other view that shows the registry. A fix to a stale view needs every reader of the state it refreshes listed first. Round 3's findings were in the diff from the start; round 1 checked requirements and evidence and did not get to duplication or the glossary.

Changes it led to: none yet; the `fix regression` cause (fixing the named view, not every reader) is new.


## [#18](https://github.com/AboulEinein/soroband/pull/18) feat(ui): redesign the popover and History in the warm direction (2026-10-29)

Planned rounds: 2.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 1 Medium, 4 Low, 2 unrated | `first look`: glossary kept "Network card" with no Hero card or History card, hour bars arrived after opening and never grew, a 25-hour day lost its hour in progress, VoiceOver read no values, the total's split was copied, the History card's number did not follow where it opens, the popover reads the full History result for its bars (deferred to a follow-up). |
| 2 | Opus | 1 Low, 1 Minor | `fix regression`: the 25-hour fix sized the axis with `max(count, 24)`, wrong on the 23-hour day. `missed earlier`: three comments still said "History entry". |
| 3 | Sonnet | 1 Low, 1 unrated | `missed earlier`: the handover's segmented-control follow-up no longer held, and the glossary and `HistoryDetail` comment still said "stat tiles". |
| direct | Haiku | none | Checked fcb1a6c (wording). [Comment](https://github.com/AboulEinein/soroband/pull/18#issuecomment-6487220124). |

**Retro.** Planned 2 rounds; it took 3 and a direct review. Round 1's findings were real gaps in a large UI change, mostly edge days and wording the redesign retired. The regression came from fixing the long day without checking the short one: a fix for one side of a symmetric case needs a test for the other side too. Round 3's findings were text a renamed concept left behind, which a search for the retired words ("Network card", "History entry", "stat tiles") after the rename would have found.

Changes it led to: none yet. A rename that leaves old words behind also happened in #17 (round 3's glossary finding); if it recurs, it becomes a checklist line: search for the retired term before pushing.


## [#19](https://github.com/AboulEinein/soroband/pull/19) feat(ui): redesign Settings with a live menu bar designer (2026-10-29)

Planned rounds: 3 (raised from 2 when the user asked for the Settings redesign on top of the two-line designer).

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 1 Medium, 3 Low, 1 unrated | `first look`: the stacked drawing shipped unmeasured, the snapshot read the test host's real network, two equal lines gave duplicate SwiftUI ids, the combined speed stayed one wide line, design.md kept "mode" wording. Superseded or fixed by the redesign (replies on each thread). |
| 2 | Opus | 5 Low | `first look`: the snapshot read the real Location permission, the preview cut an over-wide item's icon, the chip's help said "swap". `missed earlier`: "menu bar mode" left in plan.md, verification.md and the handover (the rename-leftover pattern #18's retro named). `fix regression`: the handover called the default layout within budget after the measurement said otherwise. |
| 3 | Opus | 2 Low, 1 Minor | `missed earlier`: more retired words (`menu_bar`, `menu_bar_count`, "display modes") that the new checklist line found. `first look`: the preview fell back to the Wi‑Fi icon with no network; the scope's bytes were picked in three places. |
| 4 | Sonnet | 1 Low | `first look`: the order tray's reordering was private and untested. |
| 5 | Sonnet | none | Checked cb31277. |
| CodeRabbit | CodeRabbit | 1 Major, 1 Minor, 2 Minor (review body) | `first look`: a local array shadowed the `texts` helper, which Xcode 26.6 on CI rejects and the local Xcode 27.1 accepted; round 1's row rated a finding `Discussion`; an engine starting again could wait a minute to empty the item. Not valid: the drop position. |
| 6 | Sonnet | none | Checked ce807d3. [Comment](https://github.com/AboulEinein/soroband/pull/19#issuecomment-6495239970). |
| CodeRabbit | CodeRabbit | 1 Minor (review body) | Not valid: the throttle over summed readings (today's counters only grow). |

**Retro.** Planned 3 rounds; the blind loop took 6, and CodeRabbit found 3 valid findings after it. The PR grew from a two-line designer into a full Settings redesign, a settings schema change and two performance changes, so each round met new code. Rounds 2 and 3 found words the rename left behind, which became the checklist line in `review.md`. The test that did not compile on CI passed every local run on a newer Xcode, and every round ran while CI was pending. Two Sonnet rounds approved code CodeRabbit then faulted. [#21](https://github.com/AboulEinein/soroband/pull/21) turns these into rules: rounds wait for green CI and run on Opus, reviewers post every verified finding and check what the diff reaches, the records are linted, and work outside milestones takes one concern per PR.
