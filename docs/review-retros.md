# Review retros

One entry per pull request. Which rows it gets and when each part is committed is in [`review.md`](review.md) (Rounds step 3, CodeRabbit steps 6 to 9). Together with [`coderabbit-findings.md`](coderabbit-findings.md), these show why reviews take the rounds they do.

Each entry has:
- **A heading:** the pull request, its title and the date it opened.
- **Planned rounds** and what ran: blind rounds, direct reviews, CodeRabbit reviews.
- **A table, one row per review:** the review (blind round number, `direct`, or `CodeRabbit`), the reviewer's model, the findings by severity (the pr-review skill's `Critical`, `High`, `Medium`, `Low` and `Minor`, or `unrated` for a finding without one, such as its `Discussion`; CodeRabbit's `Critical`, `Major`, `Minor` and `Trivial` as given), and the origin of each finding.
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
| CodeRabbit | CodeRabbit | 1 Minor | Not valid, on the records commit: `REVIEW.md` read as a miscased `docs/review.md`. |

**Retro.** Planned 3 rounds; the blind loop took 6, and CodeRabbit found 3 valid findings after it. The PR grew from a two-line designer into a full Settings redesign, a settings schema change and two performance changes, so each round met new code. Rounds 2 and 3 found words the rename left behind, which became the checklist line in `review.md`. The test that did not compile on CI passed every local run on a newer Xcode, and every round ran while CI was pending. Two Sonnet rounds approved code CodeRabbit then faulted. [#21](https://github.com/AboulEinein/soroband/pull/21) turns these into rules: rounds wait for green CI and run on Opus, reviewers post every verified finding and check what the diff reaches, the records are linted, and work outside milestones takes one concern per PR.

## [#20](https://github.com/AboulEinein/soroband/pull/20) feat(settings): pick a network's color (2026-10-29)

Planned rounds: 2.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 1 Medium, 1 Low, 1 Minor | `first look`: the color picker was never rendered, the focus fix was not in the PR's evidence, a comment still said registry order. Unposted and fixed: a pick was lost when a router-known network merged into a named one. |
| 2 | Sonnet | 1 Low, 1 unrated | `first look`: History's styles had no test with a picked color; the swatches had no text label and were never seen in light mode. |
| 3 | Sonnet | none | Checked 801ba81. |
| CodeRabbit | CodeRabbit | 1 Minor | `first look`: `soroband_network_set_color` stored slots past the palette and wrapped 256 to Automatic (round 2's reviewer saw it and did not post it). |
| 4 | Sonnet | none | Checked ff0e184. |
| CodeRabbit | CodeRabbit | 1 Minor (review body) | `first look`: History kept the registry it read when it opened, so a picked color showed only after reopening (round 1's reviewer saw it and did not post it). |
| 5 | Opus | 2 Low | `fix regression`: the History fix read the registry on the main thread inside the timed open. `first look`: Automatic had no selected trait for VoiceOver. |
| CodeRabbit | CodeRabbit | 1 Minor, 1 Major (review body) | `fix regression`: the same main-thread read. Not valid: `color` needing an explicit nil default. |
| 6 | Opus | 1 Low | `first look`: no test called `soroband_network_set_color` (found with `cargo mutants`). |
| 7 | Opus | 2 Low | `fix regression`: History read the registry twice on open, once on the main thread; the refresh of an open window had no test. |
| 8 | Opus | none | Checked 9f41f37. |

**Retro.** Planned 2 rounds; it took 8 and three CodeRabbit reviews. Two of CodeRabbit's findings had been seen by blind reviewers and left out under the skill's nit cap. The History fix CodeRabbit asked for then took three rounds of its own, because it moved a database read into a timed path and was tested only on the path that opens the window. The Sonnet rounds found nothing in code where Opus rounds then did. [#21](https://github.com/AboulEinein/soroband/pull/21) and a PR to the `pr-review` skill turn this into rules: no nit cap on behavior, check what the diff reaches, Opus for every round.

## [#21](https://github.com/AboulEinein/soroband/pull/21) chore(review): close the gaps CodeRabbit kept finding after the blind loop (2026-10-29)

Planned rounds: 2.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 1 Medium, 3 Low | `first look`: the small-PRs rule contradicted one milestone, one PR; the lint skipped rows it could not label; prepush.sh left out release clippy and the install guard, and its Xcode check turned off when the sentence it reads changed. |
| 2 | Opus | 2 Low | `fix regression`: the lint's new miss-cause check ran one way only. `first look`: prepush.sh said it runs what CI runs but leaves out the universal Release build. |
| 3 | Opus | 1 Low | `fix regression`: round 2's header fix said "this Mac's architecture" while the script still built arm64 alone. |
| 4 | Opus | 2 Low | `first look`: the lint skipped rows written without a space after the first pipe; nothing checked CI's selected Xcode against the one the doc names. |
| 5 | Opus | 2 Low | `first look`: the lint refused valid separators such as `\|----\|` and split notes that contain a comma. Rounds 3 to 5 each found an edge of the lint's parsing, so the lint gained a self-test of rows it must accept and refuse. |
| 6 | Opus | 2 Low | `first look`: a code span's pipes split round 5's row on GitHub, and the lint did not count a retros row's cells. |
| 7 | Opus | 1 Low | `first look`: the brief used word for word fitted only milestones, while AGENTS.md now makes non-milestone PRs routine. |
| direct | Haiku | 1 unrated | `first look`: the non-milestone brief line pointed at a quoted request that the PR template did not ask for. [Comment](https://github.com/AboulEinein/soroband/pull/21#issuecomment-6497846284). |
| 8 | Opus | none | Checked ebb7c5a. |
| CodeRabbit | CodeRabbit | 1 Minor | `first look`: the lint took either review's severities on any row. |
| 9 | Opus | 2 Minor | `first look`: the lint took impossible dates and zero counts. |
| CodeRabbit | CodeRabbit | 1 Minor | `first look`: the lint allowed `Critical` for CodeRabbit while the retros' header listed only `Major`, `Minor` and `Trivial`; the header now names `Critical`, which CodeRabbit can give. |
| 10 | Opus | 1 Low | `first look`: record rows went into a fix commit after the PR was ready, against `review.md`'s CodeRabbit step 6, leaving the two logs disagreeing until this records commit. |
| CodeRabbit | CodeRabbit | 1 Minor | `first look`, on the records commit: the handover did not say #21's review had ended. |

**Retro.** Planned 2 rounds; the blind loop took 10 and a direct review, and CodeRabbit raised 2 findings. Rounds 3 to 9 each found another edge of the records lint's Markdown parsing (separators, notes with commas, pipes in code spans, impossible dates, zero counts), the kind docs/review.md says to reassess; the self-test added in round 5 pinned each one but did not stop new ones, because the lint parses general Markdown for records that use a narrow form. The CodeRabbit CLI then found one more (a row without its opening pipe), and the user chose to merge the lint as it is. Next time a check meant to guard a narrow format starts drawing edge cases, narrow the check to the format instead of widening it to the general one. Record rows were also committed in fix commits after the PR was ready; `review.md` already says not to.


## [#22](https://github.com/AboulEinein/soroband/pull/22) docs: record the merged #17 to #21 in the handover (2026-10-30)

Planned rounds: 1.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 1 Low | `first look`: the M3 hand checklist that next action 2 sends the user to still named Settings controls removed by #19. |
| direct | Haiku | 1 Low | `fix regression`: the rewritten step said an open History window shows a renamed network at its next refresh, but it rereads the registry only when it loads an answer. [Comment](https://github.com/AboulEinein/soroband/pull/22#issuecomment-6510388632). |
| direct | Haiku | none | Checked 0aaa8d9. [Comment](https://github.com/AboulEinein/soroband/pull/22#issuecomment-6510517127). |
| CodeRabbit | CodeRabbit | none | |

**Retro.** Planned 1 round; it took 1 and two direct reviews, and CodeRabbit found nothing. The round's finding sat outside the diff: the merges made a hand checklist stale, and REVIEW.md's "what the diff reaches" is what found it. The fix then described History's refresh from memory instead of from `HistoryWindow.swift`, the "docs from evidence" rule in `verification.md`.


## [#23](https://github.com/AboulEinein/soroband/pull/23) fix(core): stop a wake after the engine ends from raising SIGPIPE (2026-11-03)

Planned rounds: 1.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 2 Low | `first look`: the handover's Next action 1 and Follow-ups still said one pull request fixes the CodeRabbit backlog; fixed in #24, which owns those lines. `first look`: the PR had no entry here before round 1, as Rounds step 2 asks. |
| CodeRabbit | CodeRabbit | none | |

**Retro.** Planned 1 round; it took 1, and CodeRabbit found nothing. Both findings were about records, not the fix: the orchestrator's brief told the implementer not to touch `review-retros.md`, so no entry was started before round 1. The brief for the backlog PRs now starts the entry.
## [#24](https://github.com/AboulEinein/soroband/pull/24) docs: fix CodeRabbit's docs and license findings (2026-11-03)

Planned rounds: 1.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 2 Low | `first look`: M0 step 2.1 said the Welcome window opens whenever Location is unanswered, but it also needs `onboardingShown` unset, which survives a reinstall. `first look`: the README said earlier versions lose per-app counting, while every version but macOS 27 does. |
| direct | Haiku | 2 unrated | Checked 48c598e; both findings handled, 2 wording nits left as they are. [Comment](https://github.com/AboulEinein/soroband/pull/24#issuecomment-6602658085). |
| CodeRabbit | CodeRabbit | none | |
| CodeRabbit | CodeRabbit | 1 Minor | `first look`, on the records commit: a blank line before #23's row ended the findings table. |

**Retro.** Planned 1 round; it took 1 and a direct review, and CodeRabbit found nothing in the change; on the records commit it found a blank line, carried from #23's records, that split the findings table, which `records-lint.py` does not check. Both findings came from describing app behavior from the UI instead of from the code that decides it (`Onboarding.shouldShow`, `KNOWN_LAYOUTS`), the "docs from evidence" rule in `verification.md`. The implementer also found a stale Location menu in `docs/agents/install.md`, fixed here although no review had raised it.


## [#27](https://github.com/AboulEinein/soroband/pull/27) fix(core/cli): CodeRabbit core and CLI correctness findings (2026-11-03)

Planned rounds: 1.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 1 Low | `first look`: the PR removed the `rust-version` backlog line without a follow-up saying nothing in CI keeps it true. |
| direct | Haiku | none | Checked 3505840. [Comment](https://github.com/AboulEinein/soroband/pull/27#issuecomment-6602598166). |
| CodeRabbit | CodeRabbit | 2 Minor | `first look`: the new unreadable-settings message advised deleting the file, which gives the CLI reset hour 0 while the running app keeps its own and is not told. `first look`: `docs/agents/configure.md` did not say a network's id wins over a network named the same. |
| CodeRabbit | CodeRabbit | none | Checked the fix. |

**Retro.** Planned 1 round; it took 1 and a direct review, and CodeRabbit found 2 more. Both CodeRabbit findings followed a changed behavior one step further than the blind round did: what the advice in a new error message leads to, and what a new matching rule means for the reader of the guide. The first direct review was lost to a network outage and run again.


## [#26](https://github.com/AboulEinein/soroband/pull/26) fix(app): handle the CodeRabbit app Swift findings (2026-11-03)

Planned rounds: 1.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 1 Medium, 1 Low | `first look`: moving the CSV export off the main thread let a window close quit the History process mid-write, leaving a truncated file. `first look`: Settings refreshed an injected `LaunchAtLogin` but showed `.shared`, so the test checked an object the window did not show. |
| 2 | Opus | 1 Low | `first look`: this entry had no rows for the rounds that had run. |
| CodeRabbit | CodeRabbit | 1 Major | `first look`: claimed `replaceItemAt` fails for a new destination and that the Debug export should keep the earlier file; not valid (`replaceItemAt` moves the item into place when none exists, checked on this Mac; the Debug path is removed on purpose so a failed export shows). |

**Retro.** Planned 1 round; it took 2, and CodeRabbit raised one finding that did not hold. Round 1's Medium came from the PR's own fix: moving the export off the main thread made the window close race the write, which the CodeRabbit finding had not foreseen either. The fix took both an atomic replace and a quit that waits for exports in flight. Snapshot tests drifted by 1/255 on this Mac during the PR, the existing follow-up about snapshot colors and the main display.


## [#25](https://github.com/AboulEinein/soroband/pull/25) fix(prototypes): fix CodeRabbit findings in meter-probe and ui-spike (2026-11-03)

Planned rounds: 1.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 2 Low | `first look`: the short-item test used 300 bytes, so a guard weakened to 400 still passed. `first look`: this entry was not started before round 1. |
| 2 | Opus | none | Checked b24e902. |
| CodeRabbit | CodeRabbit | 1 Major, 1 Minor | `first look`: the spike ignored a failed window-list write, so `snapshot.sh` waited forever. `first look`: `snapshot.sh` set its cleanup trap after launching the app. |
| 3 | Opus | 1 Low | `first look`: this entry had no rows for the rounds that had run. |
| CodeRabbit | CodeRabbit | none | Checked the fixes and the merge from `main`. |

**Retro.** Planned 1 round; it took 3, and CodeRabbit found 2 more. Round 2 came from a test that did not pin its limit, and round 3 from CodeRabbit's fixes changing behavior; neither found a defect in the fixes. CodeRabbit's Major was in `Snapshot.swift`, a file the PR did not touch, which the blind rounds did not read. CI did not run on one commit during a GitHub outage; an empty commit started it, after a conflict with `main` turned out to be the real cause.


## [#28](https://github.com/AboulEinein/soroband/pull/28) fix(verify): close false passes and the hang in traffic.sh and budget.sh (2026-11-03)

Planned rounds: 1.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 2 Low | `first look`: `plan.md`'s M1 requirement and `verification.md`'s M1 row named only the duplicates cutoff as the condition for a judged run. `first look`: `GLOSSARY.md` still called the cutoff the whole line between judged and reported runs. |
| direct | Haiku | none | Checked 8e93089 and the added evidence (a clean judged run, why two pids). [Comment](https://github.com/AboulEinein/soroband/pull/28#issuecomment-6604714476). |
| CodeRabbit | CodeRabbit | 1 Minor | `first look`: `/usr/bin/curl` read `~/.curlrc`, whose retry restarts `--max-time` and can run the download past its deadline. |
| 2 | Opus | 1 Low | `first look`: a backlog heading left with no items under it. |
| direct | Haiku | none | Checked 0e42c0f. [Comment](https://github.com/AboulEinein/soroband/pull/28#issuecomment-6605594258). |

**Retro.** Planned 1 round; it took 2 and two direct reviews, and CodeRabbit found 1 more. Round 1's findings were docs that restated the judged-run rule in three places, only one of which the PR updated; the glossary entry was right, the others drifted. The evidence first lacked a clean judged run, which needed a 60 s network run under the measurement lock and waited behind the performance baseline. CodeRabbit's finding came from an environment the script did not control (`~/.curlrc`), which no reading of the diff alone suggested.


## [#29](https://github.com/AboulEinein/soroband/pull/29) fix(core): count local-network bytes as explained in the self-check (2026-11-03)

Planned rounds: 1.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 2 Low | `first look`: `design.md`'s overcount rule and `GLOSSARY.md`'s Overcount still compared apps alone. `first look`: the rule bullets in `check.rs`'s module doc still said "the apps". |
| direct | Haiku | 1 unrated | Checked 1c66078; both findings handled. Raised that the popover's "Other / overhead" row still counts local-network bytes, against `GLOSSARY.md`; left for its own pull request. [Comment](https://github.com/AboulEinein/soroband/pull/29#issuecomment-6605223356). |
| CodeRabbit | CodeRabbit | none | |

**Retro.** Planned 1 round; it took 1 and a direct review, and CodeRabbit found nothing. Both findings were restatements of the self-check rule in other files, which the PR updated in its main paragraph but not in each bullet. The work surfaced a second, larger issue: the stored interface totals, and so the popover's "Other / overhead" row, include local-network bytes, which this PR's scope (the self-check) did not cover.

## [#31](https://github.com/AboulEinein/soroband/pull/31) test(snapshots): render and compare snapshots in a fixed color space (2026-11-03)

Planned rounds: 1.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 1 Low | `first look`: the handover follow-up no longer said the fixed 2x render had never run on a 1x display. |
| direct | Haiku | none | Checked 5866af0. [Comment](https://github.com/AboulEinein/soroband/pull/31#issuecomment-6610598040). |
| CodeRabbit | CodeRabbit | 1 Minor | `first look`: `renderingIgnoresTheDisplayColorSpace` claimed identical renders but compared with the snapshot tolerance. |
| 2 | Opus | none | Checked 3deb662; `scripts/verify/snapshots.sh` passes. |

**Retro.** Planned 1 round; it took 2 and a direct review, and CodeRabbit found 1 more. The implementer found that the brief's premise was wrong: the 6 failing snapshots came from app icons changing by 1/255 and the comparison converting to sRGB, not from the display, and sRGB would have clipped the app's wide-gamut colors; the fix pins Display P3 instead. CodeRabbit's finding was a test whose assertion was weaker than its name, which a blind reviewer reading the name accepted.


## [#33](https://github.com/AboulEinein/soroband/pull/33) fix(cli): wait for notifyd to deliver posts before checking them (2026-11-03)

Planned rounds: 1.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | none | Checked 24e7814; the `config_set` tests passed 200 of 200. |
| CodeRabbit | CodeRabbit | none | |

**Retro.** Planned 1 round; it took 1, and CodeRabbit found nothing. The implementer reproduced the failure first (20 of 1000 runs) before changing anything, which made the fix and its evidence one step. The fix rests on `notifyd` delivering posts in the order they were queued, which `notify(3)` does not document; 0 of 1000 runs is the evidence.


## [#34](https://github.com/AboulEinein/soroband/pull/34) fix(core): coalesce settings-changed notifications and keep tests off the app's name (2026-11-03)

Planned rounds: 1.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 2 Low | `first look`: the coalescing test passed a Coalescer that runs on the first request. `first look`: an empty `SOROBAND_DATA_DIR` was an override in `directory()` but unset in `settings_changed()`. |
| 2 | Opus | 1 Low | `missed earlier`: only the unchanged side of `reloadSettings`' layout guard was tested. |
| 3 | Opus | 1 Low | `first look`: the notification naming was called a second concern; answered as the other half of the same burst problem. |
| CodeRabbit | CodeRabbit | 1 Minor | `first look`: a Release CLI with `SOROBAND_DATA_DIR` set to a Debug app's directory posts the Release name; not a regression and not a supported setup, left as it is. |

**Retro.** Planned 1 round; it took 3, and CodeRabbit raised 1 finding left as it is. Each round found a test that could not fail for one side of a new branch (the coalescer's wait, the layout guard's change path), the "tests verify intent" rule; checking each new branch both ways before round 1 would have saved two rounds. A merge from `main` brought in #33's changes to the same test file, which merged without conflict.


## [#32](https://github.com/AboulEinein/soroband/pull/32) fix(core): keep local-network bytes out of stored interface bytes (2026-11-03)

Planned rounds: 1.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 1 Medium, 1 Low | `first look`: local-network flows' headers and acknowledgements stay in the stored interface bytes, so the docs' "a network's total is its internet traffic" was false. `first look`: eight descriptions still called the value everything that crossed the interfaces. |
| 2 | Opus | 1 Low | `missed earlier`: five more descriptions of the same value outside round 1's list. |
| direct | Haiku | 1 unrated | `missed earlier`: six more stale descriptions after f157c61. [Comment](https://github.com/AboulEinein/soroband/pull/32#issuecomment-6610918610). |
| direct | Sonnet | none | Checked 2f1b14a and a sweep of every description. [Comment](https://github.com/AboulEinein/soroband/pull/32#issuecomment-6610960611). |
| CodeRabbit | CodeRabbit | 1 Minor | `first look`: the `soroband today` help said local-network traffic is left out, which interface-only mode cannot do. |
| CodeRabbit | CodeRabbit | none | Checked the fix and the merge from `main`. |

**Retro.** Planned 1 round; it took 2 and two direct reviews, and CodeRabbit found 1 more. Changing what a stored value means left its description wrong in many files, and each fix covered only the places a reviewer had listed, so three reviews in a row found more; a sweep of every description of the value ended it. Next time a change redefines a value, grep every description of it before the first round. The Medium came from reasoning about what a flow carries (no headers), which the test's numbers had hidden by putting all overhead on the internet flow.


## [#30](https://github.com/AboulEinein/soroband/pull/30) feat(verify): fail records-lint on a broken table or a conflict marker (2026-11-03)

Planned rounds: 1.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 1 Low | `first look`: the self-test did not pin the findings log's conflict-marker check. |
| 2 | Opus | 1 Low | `fix regression`: the handover still said the lint skips rows without an opening pipe, which the new table check made false. |
| direct | Haiku | none | Checked a3fc266. [Comment](https://github.com/AboulEinein/soroband/pull/30#issuecomment-6610499391). |
| CodeRabbit | CodeRabbit | 2 Minor | `first look`: diff3 `\|\|\|\|\|\|\|` markers were missed. `first look`: a `##` heading ended the findings table, which runs to the end of the file. |
| 3 | Opus | 1 Low | `first look`: a table row outside every table passed. |
| CodeRabbit | CodeRabbit | 1 Minor | `first look`: a header row with no separator counted as a table. |
| CodeRabbit | CodeRabbit | 2 Minor | `first look`: a header of the wrong width, and indented table lines, counted as a table. |
| CodeRabbit | CodeRabbit | 1 Minor | `first look`: a header with columns swapped passed. |
| CodeRabbit | CodeRabbit | 1 Minor | `first look`: a second header or separator inside a table passed. |
| 4 | Opus | 2 Low | `fix regression`: a compiled `.pyc` from the orchestrator's before/after checks was committed. `first look`: this entry had no rows. |
| direct | Haiku | 1 unrated | `missed earlier`: the 17:18 CodeRabbit review's second finding (a `##` heading ending the findings table) was neither counted nor fixed; CodeRabbit had resolved its thread. [Comment](https://github.com/AboulEinein/soroband/pull/30#issuecomment-6612949740). |
| 5 | Opus | none | Checked bb1585f, with mutations of every new check. |
| CodeRabbit | CodeRabbit | 1 Minor | `first look`: MD038, a code span with a trailing space in this entry; reworded in the records commit. |

**Retro.** Planned 1 round; it took 5, two direct reviews and seven CodeRabbit reviews, the same pattern #21's retro describes for this lint: each review found another way a Markdown table can be malformed. After the fifth such finding the approach was reassessed on the PR: the lint now accepts only each log's exact form (its header row, its separator, rows from the first character, nothing else), and later findings were all inside that form, so they were fixed rather than declined. Two process slips cost rounds: a `.pyc` swept in by `git add -A` after importing the lint, and a CodeRabbit finding whose thread CodeRabbit resolved without a fix, which only a reviewer counting findings against the record caught. Next time: list every finding of a CodeRabbit review from its review body and threads before replying, and stage named files only.


## [#35](https://github.com/AboulEinein/soroband/pull/35) feat(app): M6a popover and Settings in a UI process (2026-11-03)

Planned rounds: 3.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 3 Low, 1 unrated | `first look`: "History process" still named the retired process in three files; the handover's M4 bullet named the deleted `HistoryProcess.swift`; an earlier `debugState` timeout could end a later request's wait. `unclear requirement`: no stage owned the M6 row's per-layout `budget.sh 10` and Release History run (assigned to M6c). |
| 2 | Opus | 1 Low, 1 unrated | `first look`: the `hover` debug URL took any value but 0 as inside. `unclear requirement`: the side-by-side captures were kept local. |
| direct | Haiku | none | Checked the Settings and History captures on `evidence/pr-35`. [Comment](https://github.com/AboulEinein/soroband/pull/35#issuecomment-6614524153). |
| 3 | Opus | none | Checked b4e50ed. |
| CodeRabbit | CodeRabbit | 2 Minor | `first look`: the app README left out the pointer's hold on the linger; the M4 checklist's `pgrep -fl Soroband` also listed other builds. |
| CodeRabbit | CodeRabbit | 2 Minor | `first look`, in the review body: the handover's start paths and linger described only hover; the handover's date was not refreshed. |
| 4 | Opus | 1 Medium, 2 Low | `new evidence`, after a real-pointer run showed cold opens near 800 ms and the design changed to a 10-minute linger: a window request that opened nothing kept the UI process alive for good; 72.9 MB against the newer 74.3 MB; `capture-window` missed silently. |
| CodeRabbit | CodeRabbit | 2 Minor | `missed earlier`: the same stuck-linger finding as round 4. `first look`: the double-click step started with the popover open. |
| 5 | Opus | 2 Low | `first look`: retired "agent" and "standby" left in current text. |
| CodeRabbit | CodeRabbit | 1 Minor | `first look`, in the review body: a failed reset-hour save left the UI process showing the unsaved hour. |
| direct | Haiku | none | Checked 045fc13. [Comment](https://github.com/AboulEinein/soroband/pull/35#issuecomment-6624751888). |
| CodeRabbit | CodeRabbit | 2 Minor | `first look`, in the review body: keep queued window requests after a failed launch (not valid: it would replay a toggle); the shutdown checks still asked to move the pointer away. |
| 6 | Opus | none | Checked d8731cf. |
| CodeRabbit | CodeRabbit | 2 Minor | `first look`, in the review body: a click queued during startup was lost when the UI process died before `ready`; `export-history` left an old CSV in place. |
| CodeRabbit | CodeRabbit | 1 Minor | `first look`, on the records commit: the retro gave the wrong count of findings found only in review bodies. |
| 7 | Opus | 1 Medium | `fix regression`: the kept request opened the popover at the dead launch's anchor. |
| 8 | Opus | 1 Low | `first look`: a late `ready` from a forgotten UI process stopped every later click. |
| 9 | Opus | none | Checked 688a797. |
| CodeRabbit | CodeRabbit | 3 Minor | `first look`: a click during launch replaced the tab an `open-popover?tab=` request had asked for. `missed earlier`: `writeCSV` with no existing file (not valid, as on #26). `first look`, on the records commit: the retro's last sentence had no main clause. |
| 10 | Opus | none | Checked 249f89a. |

**Retro.** Planned 3 rounds; it took 10, two direct reviews and eight CodeRabbit reviews. The rounds before the pointer run converged; what reopened the PR was new evidence, not review: a run with a real pointer (cliclick, from the menu bar's overflow) and a timer that waits for the popover on screen found cold opens near 800 ms where the in-app metric, which stopped at `displayIfNeeded`, said 250 ms, and found that the hover start never fired. Measuring the pointer monitor that would replace it (about 14% CPU under constant movement) made the user choose a 10-minute linger with no prewarm. Lessons: time what the user sees (on screen), not a step inside the app; test any pointer-driven design with a real pointer before building on it; and read CodeRabbit's review bodies, not only its threads: seven of CodeRabbit's findings on this pull request appeared only in review bodies. Rounds 7 and 8 came from the queue's handling of a UI process that dies during launch; each fix exposed a further edge there, until every message from the UI process was checked against the current process. A last real-pointer run at the head first read warm opens near 360 ms; a paired, interleaved run of `main`, 09c6cf6 and the head in one session put them at medians of 250, 266 and 271 ms, so a single unpaired run is not evidence of a regression.

## [#36](https://github.com/AboulEinein/soroband/pull/36) feat(app): M6b lean menu bar process (2026-11-04)

Planned rounds: 3.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 2 Low, 1 Minor | `first look`: the ⌘, command kept a branch only the menu bar process could take. `first look`: the plan and handover were said not to link #36; they already did at the head. `first look`: the renderer's doc comment named the wrong reference image. |
| 2 | Opus | 1 Low | `fix regression`: `itemImage` and `rasterized` were still described as what the status item draws. |
| direct | Haiku | none | Checked 19f8563. [Comment](https://github.com/AboulEinein/soroband/pull/36#issuecomment-6629056761). |
| CodeRabbit | CodeRabbit | 1 Minor | `first look`: `NSApplication.delegate` is weak, so an optimized build could release the menu bar process's delegate before launch. |
| 3 | Opus | none | Checked c2c57b8. |
| CodeRabbit | CodeRabbit | 1 Minor | `first look`, in the review body: a nil from `MenuBarRenderer.image` left the status item blank. |
| 4 | Opus | 2 Minor | `fix regression`: the fallback's comment overstated when the vector image draws. `first look`: the renderer test's name named Settings' preview, not its reference. |
| direct | Sonnet | 1 unrated | `first look`: the PR body still used the test's old name. [Comment](https://github.com/AboulEinein/soroband/pull/36#issuecomment-6639005535). |

**Retro.** Planned 3 rounds; it took 4 and two direct reviews, and CodeRabbit found 2 more. The blind rounds found only stale comments left by moving the menu bar's drawing to a new renderer; the one real defect, a delegate held only weakly once SwiftUI's app lifecycle no longer kept it, came from CodeRabbit, and shows in an optimized build only, which no local check here runs (a local Release build does not link the arm64-only core). The byte-for-byte renderer test over 9,584 layouts made the drawing change safe to review by reading.

## [#37](https://github.com/AboulEinein/soroband/pull/37) docs: M6c closing measurements (2026-11-04)

Planned rounds: 1.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 1 Medium, 1 Low | `unclear requirement`: M6c became measurements only with no recorded decision while the live-speed CPU criterion was unmet. `first look`: two lines said "Release build" for the Release-optimized measurement. |
| 2 | Opus | 1 Medium, 3 Low, 1 unrated | `fix regression`: M6's deliverable still asked a live speed for headroom under the budget; the exception was a range, not a ceiling; CONTRIBUTING.md lacked it; the handover's Follow-ups still proposed CPU headroom work. `first look`: the PR description was stale. |
| direct | Sonnet | none | Checked 9969013. [Comment](https://github.com/AboulEinein/soroband/pull/37#issuecomment-6642883331). |
| CodeRabbit | CodeRabbit | 3 Minor | `first look`: the live-speed redraw claim contradicted design.md. Not valid: rewrite a dated decision row; a "trailing comma" that is the ⌘, shortcut. |

**Retro.** Planned 1 round; it took 2 and a direct review, and CodeRabbit found 1 valid finding. This was the first PR in the run where the CodeRabbit CLI ran before every push, and the hosted review found one valid finding instead of several pushes' worth. Round 1's finding was a decision the orchestrator had made without recording it (narrowing M6c), which the user then took (the live-speed exception); round 2's findings were the places that still stated the old rule, as on #32: when a rule changes, grep every statement of it before the first round. The orchestrator also dated two decisions a day ahead; the local CLI caught it.

## [#38](https://github.com/AboulEinein/soroband/pull/38) docs: close the CodeRabbit backlog and record the run's review lessons (2026-11-05)

Planned rounds: 1.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 2 Low | `first look`: Current state's first bullet was stale (milestones merged, test counts); M4's ledger row did not record the open History decision. |
| direct | Haiku | none | Checked 5e3785c. [Comment](https://github.com/AboulEinein/soroband/pull/38#issuecomment-6643919801). |
| CodeRabbit | CodeRabbit | 3 Minor | `first look`: the timing rule reached durations that are limits, not latencies; AGENTS.md did not tell the local CLI review from the hosted one. Not valid: complete the retro entry before its records commit. |
| CodeRabbit | CodeRabbit | 1 Minor | `first look`, on the records commit: the Follow-up column for this PR's two fixed findings (not valid: their rule changes are the fixes). |

**Retro.** Planned 1 round; it took 1 and a direct review, and CodeRabbit found 2 valid findings, both on the new rules this PR wrote: a rule written from one run's lesson needs its limits stated (what it does not cover) and every place that states the old rule updated, the same lesson as #32 and #37.

## [#39](https://github.com/AboulEinein/soroband/pull/39) docs: bring the measurement lock and the popover timer into the repo (2026-11-05)

Planned rounds: 1.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 2 Medium, 2 Low | `first look`: clicktime read an already-open popover as a near-zero open; its window match had not run against a real popover; two doc lines still said agents work without the pointer and called the timer external. |
| direct | Sonnet | 1 Low | Checked 0891004. The clicktime row claimed warm and cold timings this PR did not take. [Comment](https://github.com/AboulEinein/soroband/pull/39#issuecomment-6651295676). |
| CodeRabbit | CodeRabbit | none | Not run: the hosted review stayed queued behind the rate limit for over an hour; the user chose to merge without it. |

**Retro.** Planned 1 round; it took 1, a direct review and 6 local CodeRabbit CLI rounds (13 findings, 11 fixed, 1 declined twice because it reversed an earlier one). The cost was out of proportion to a docs-gap PR: moving two working tools into the repo became a rewrite of the measurement lock, and each CLI round found a narrower edge case on a script only agents run, until the CLI quota ran out and the waits outlasted the work. Move a working tool as it is, and on internal tooling fix the findings that would bite in use and stop.

## [#40](https://github.com/AboulEinein/soroband/pull/40) fix(core): name a version-named tool by its directory (2026-11-05)

Planned rounds: 1.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | none | Checked e2845ca. |
| CodeRabbit | CodeRabbit | 1 Minor | `first look`: today's usage read back under the old name keeps that label until the daily reset (accepted). |

**Retro.** Planned 1 round; it took 1. A narrow, tested naming rule with a real `soroband live` run before the first round left the blind round nothing to find; CodeRabbit's one finding was a one-day label effect on the update's day, accepted as the PR had stated it.

## [#43](https://github.com/AboulEinein/soroband/pull/43) fix(app): say the self-check counts local-network traffic with the apps (2026-11-05)

Planned rounds: 1.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | none | Checked 9e25d9c. |
| CodeRabbit | CodeRabbit | 1 Minor | `first look`: the overcount notice's comparison was incomplete ("more than crossed the network"). |
| CodeRabbit | CodeRabbit | 1 Minor | `first look`, on the records commit: the degraded notice's "For 20 minutes" outlasts 20 minutes, because the verdict holds until a judged window passes. |

**Retro.** Planned 1 round; it took 1. The blind round checked the copy against what `check.rs` compares and found nothing; CodeRabbit caught a grammar slip in the new user-facing sentence, fixed and reviewed by CodeRabbit as a wording fix. The local CLI and then the hosted review pointed at the degraded notice's fixed "For 20 minutes", which predates this PR; first recorded as a follow-up, it was fixed here once the hosted review raised it, being the same notice's copy. A copy fix should read the whole sentence it touches against the code, not only the word it was asked to change.

## [#44](https://github.com/AboulEinein/soroband/pull/44) fix(app): give the test host its own data directory (2026-11-05)

Planned rounds: 1.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 1 Low | `first look`: the temporary-directory prefix check failed when a test run supplies its own `SOROBAND_DATA_DIR`. |
| direct | Opus | none | Checked aaa48cf. [Comment](https://github.com/AboulEinein/soroband/pull/44#issuecomment-6656186817). |
| CodeRabbit | CodeRabbit | 1 Minor | `first look`: a supplied directory with a trailing slash failed the environment test's string comparison, present since the first commit. |

**Retro.** Planned 1 round; it took 1 and a direct review, and CodeRabbit found 1 valid finding. Both findings came from one gap: the tests were written for the directory the fix makes, not for one a run supplies, which the fix also supports. A test of an override should cover each way the value can arrive.

## [#41](https://github.com/AboulEinein/soroband/pull/41) ci: build and test the core on its declared rust-version (2026-11-05)

Planned rounds: 1.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 1 Low | `first look`: the version guard rejected a declared version with a patch part ("1.85.0"). |
| direct | Opus | none | Checked afe7d53. [Comment](https://github.com/AboulEinein/soroband/pull/41#issuecomment-6656653435). |
| CodeRabbit | CodeRabbit | 2 Minor | `first look`: "1.85" tested the newest 1.85 patch release instead of 1.85.0; the handover's command needed `--manifest-path core/Cargo.toml` from the root. |
| direct | Opus | none | Checked b7a8610. [Comment](https://github.com/AboulEinein/soroband/pull/41#issuecomment-6657219106). |
| CodeRabbit | CodeRabbit | 1 Minor | Not valid, on the records commit: put the toolchain first on `PATH` before the guard (the runner already has it first). |

**Retro.** Planned 1 round; it took 1 and two direct reviews, and CodeRabbit found 2 valid findings. All three findings were about what a version string means (a patch part, the minimum patch release) or where a command runs; the implementer's own check, that a too-new feature fails, was right, but the guard's inputs were not tested beyond today's "1.85". A check that parses a declared value should be tried on each form the value can take.

## [#42](https://github.com/AboulEinein/soroband/pull/42) test(app): cover the registry-failure fallback (2026-11-05)

Planned rounds: 1.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 1 Low | `first look`: the new enum was named `Booking`, a glossary term with another meaning. |
| direct | Opus | none | Checked 159745e. [Comment](https://github.com/AboulEinein/soroband/pull/42#issuecomment-6657011614). |
| CodeRabbit | CodeRabbit | 1 Trivial | Accepted: monitor-level coverage needs a seam the follow-up chose not to add. |
| CodeRabbit | CodeRabbit | 1 Minor | `first look`, on the records commit: that finding was recorded as not valid rather than accepted. |

**Retro.** Planned 1 round; it took 1 and a direct review. The one finding was a name: a new type reused a glossary word for something else. Checking a new type's name against `GLOSSARY.md` before the first round would have caught it.

## [#46](https://github.com/AboulEinein/soroband/pull/46) docs: record what the popover's summary read costs (2026-11-05)

Planned rounds: 1.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | none | Checked 3d4ccd7. |
| CodeRabbit | CodeRabbit | none | |

**Retro.** Planned 1 round; it took 1. The follow-up said "measure first", and the measurement (a bars-only read would save about 4.7 ms per open, off the main thread) settled it as docs only, so there was little to review.

## [#47](https://github.com/AboulEinein/soroband/pull/47) test(meter): kill the rx_duplicates mutant and record the mutant timeouts (2026-11-05)

Planned rounds: 1.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 1 Medium | `first look`: a commit added before the round (the `/System/Cryptexes/OS` test case and retiring "Unreviewed fix") was missing from the Summary, and the review behind the retirement was not recorded. Answered: same concern, Summary rewritten with the evidence. |
| direct | Opus | none | Accepted the answer; two wording fixes to the PR body. [Comment](https://github.com/AboulEinein/soroband/pull/47#issuecomment-6657484114). |
| CodeRabbit | CodeRabbit | none | |

**Retro.** Planned 1 round; it took 1 and a direct review. The one finding came from the orchestrator adding a commit to a delegate's PR without updating its Summary: whoever adds to a PR updates its description in the same push. The timeouts follow-up could not be fixed by configuration; the evidence (cargo-mutants never counts a timeout as caught, and a lower limit would hide a real miss) replaced it with a gotcha.

## [#48](https://github.com/AboulEinein/soroband/pull/48) test(app): draw fixed app icons in snapshots (2026-11-05)

Planned rounds: 1.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 1 Low | `first look`: History's icon check could not fail, because the popover had already cached every icon. |
| direct | Opus | none | Checked a394355. [Comment](https://github.com/AboulEinein/soroband/pull/48#issuecomment-6657706305). |
| CodeRabbit | CodeRabbit | 1 Trivial | Not valid: restore the icon loader after each test (no other test reads it). |

**Retro.** Planned 1 round; it took 1 and a direct review. The one valid finding was a check made vacuous by a cache: a test that asserts something was asked for must clear any cache between the two things it checks.

## [#49](https://github.com/AboulEinein/soroband/pull/49) fix(app): keep debug URL commands from activating the app (2026-11-05)

Planned rounds: 1.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 1 Low, 1 Minor | `first look`: the window openers defaulted `activates` to true, so a caller that dropped the flag would activate again with every test passing; two doc comments said a Debug URL command is what activates. |
| direct | Opus | none | Checked eb66113. [Comment](https://github.com/AboulEinein/soroband/pull/49#issuecomment-6658590672). |
| CodeRabbit | CodeRabbit | none | |

**Retro.** Planned 1 round; it took 1 and a direct review. The Low finding is a pattern worth keeping: a flag that guards a side effect (here, taking the keyboard) should have no default, so the compiler makes every caller choose, rather than a default that silently restores the bug.

## [#45](https://github.com/AboulEinein/soroband/pull/45) fix(app): close the popover on a click on the empty menu bar (2026-11-05)

Planned rounds: 1.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 1 Medium | `first look`: the monitor closed the popover on the item's mouse-down while the item toggles on mouse-up, so a press held past 0.3 s closed and reopened it. |
| 2 | Opus | none | No new finding; kept the thread open until a real-pointer run showed the fix in the app; the PR description was stale. |
| direct | Opus | none | Accepted the real-pointer run on 7935b7a. [Comment](https://github.com/AboulEinein/soroband/pull/45#issuecomment-6658751838). |
| CodeRabbit | CodeRabbit | 1 Minor | `first look`: the monitor read the pointer's current position, not the click's. |
| direct | Opus | none | Checked 82d7a4f with the real-pointer run on 3362b57. [Comment](https://github.com/AboulEinein/soroband/pull/45#issuecomment-6660163387). |
| CodeRabbit | CodeRabbit | 1 Trivial | Accepted, on the records commit: a unit test of the monitor reading the event's location (the real-pointer run covers it). |

**Retro.** Planned 1 round; it took 2 and two direct reviews, and CodeRabbit found 1 valid finding. Both findings were about when an event is read: the item toggles on mouse-up while the monitor acted on mouse-down, and the monitor read the live pointer instead of the event. cliclick presses and releases at once, so the first real-pointer runs could not show a held press; a pointer test of a click should include a held press. The pointer re-runs waited about an hour because another worktree's island covered the overflow chevron.

## [#51](https://github.com/AboulEinein/soroband/pull/51) fix(app): let the popover take the keyboard when opened from the overflow (2026-11-05)

Planned rounds: 2.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 1 Medium, 1 Low, 1 Minor | `first look`: the keyboard-return decision had no test and two branches no run; the in-bar click was not listed as not checked; a follow-up title. |
| 2 | Opus | 1 Medium | `fix regression`: a flag set only by the popover's buttons gave the keyboard away after ⌘, or a click into an open Soroband window. |
| 3 | Opus | none | No new finding; kept round 2's thread open for a click into a Settings window behind the popover, which a real-pointer run then showed failing. |
| 4 | Opus | 2 Low | `fix regression`: the stale-event guard had no test; the click into another app had no run after #45 merged. |
| direct | Opus | none | Checked a43a737. [Comment](https://github.com/AboulEinein/soroband/pull/51#issuecomment-6661568459). |
| CodeRabbit | CodeRabbit | 1 Minor, 1 Trivial | Not valid: yield activation before `activate()` (verified without it). Accepted: a caller-level test of the window comparison. |

**Retro.** Planned 2 rounds; it took 4 and a direct review. Every finding was about one decision, when to give the keyboard back as the popover closes, and three rounds patched it with a flag before round 2's reassessment moved it to the state at close and the real pointer exposed the click into a window behind the popover. Deciding from state rather than from flags set by each caller, and running every path that closes the popover with the real pointer before round 1, would have saved two rounds. A pointer helper left ⌘ held for 20 minutes on the user's Mac: event-posting tools must release every key they press, and pointer runs stop at the first sign of a changed window layout.

## [#52](https://github.com/AboulEinein/soroband/pull/52) docs(handover): record the follow-up fixes and what they left (2026-11-05)

Planned rounds: 1.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | 1 Low, 1 Minor | `first look`: the Current state list lost its commas. Not changed: a dated decision row still names a retired follow-up (a later row records the change). |
| direct | Opus | none | Checked 1094fbe. [Comment](https://github.com/AboulEinein/soroband/pull/52#issuecomment-6662904321). |
| CodeRabbit | CodeRabbit | none | |

**Retro.** Planned 1 round; it took 1 and a direct review. The run as a whole: 11 PRs for the agent-fixable follow-ups, most in one round. The two that took more (#45, 2 rounds; #51, 4) were the popover's pointer behavior, where each fix reached a case only the real pointer shows; a pointer helper also left ⌘ held on the user's Mac, now a Gotcha. Most of the run's time went to waiting: the CodeRabbit CLI's shared quota, and each merge putting the next branch behind `main`, which `main`'s up-to-date rule then sent back through CI and CodeRabbit.

## [#50](https://github.com/AboulEinein/soroband/pull/50) feat: M5 Dynamic Island moments (2026-11-05)

Planned rounds: 3. Ran: 5 blind rounds (round 1 unposted, the review experiment in `plan.md`, M5), 3 direct reviews, 5 CodeRabbit reviews (round 1's commit on the draft, the ready PR, the records commit 7648b8c, its fixes 7648b8c..9808094, and the records commit 7708512), and the CodeRabbit CLI before each later push but one, which it reviewed after the push.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| CodeRabbit | CodeRabbit CLI | 1 Major, 3 Minor | `first look`: an unbounded wait in `moments.sh`, paused apps reopening while the network was unidentified, a transfer's service label kept after the app moved its own bytes, a watch's first poll rated over 1 s. Fixed before round 1. |
| 1 | Opus | 3 Medium, 8 Low, 2 unrated | Unposted (the experiment). `first look`: background activity counted bytes moved in front, alerts lost with no display, no tests at the C entry points' limits; a transfer turned off stayed shown, the recap repeated on a failed write, the frontmost app named by its own bundle, Pause offered for tools, the 101st ignored app (left), steppers off the schema's ranges, "visit" in copy, per-poll work with no peek; joined at every launch, keep menu bar clear over the menu bar without a notch. |
| CodeRabbit | CodeRabbit | 2 Minor | On round 1's commit. `first look`: whole-second step times in `moments.sh`; Safari's id said to differ by path (not valid on this Mac; the nested-bundle case was round 1's). |
| 2 | Opus | 1 Medium, 4 Low | `fix regression`: keep menu bar clear still crossed the menu bar mid-animation; a transfer whose end never came kept its app marked shown on the ignore and closed-lid paths; the first join after an offline launch opened nothing. `missed earlier`: the 101st ignored app (round 1's, left then); "visit" in a store comment and the prototype. |
| CodeRabbit | CodeRabbit CLI | 1 Major, 3 Minor | `first look`: rebuilt panels kept the queue's hover, `moments.sh`'s curl had no timeout, `verification.md` did not except the recap. Not valid: Safari's id again (the Major). |
| 3 | Opus | 1 Low, 1 Minor | `fix regression`: a transfer held open past 30 s opened again after round 2's silence rule; `watchMoments`'s comment still named top apps. |
| CodeRabbit | CodeRabbit CLI | 1 Minor | `first look`: a style change kept the old outline while a moment or the meter showed. |
| 4 | Opus | 2 Low | `missed earlier`: Ignore and Pause left the app's waiting moments. `fix regression`: `moments.sh`'s transfer-end check, rewritten in round 1's fixes, counted any second transfer moment. |
| CodeRabbit | CodeRabbit CLI | 1 Minor | Not valid: a partial download passing a step (the steps check the moments, which a download over the threshold fires). |
| 5 | Opus | 2 Low | `fix regression`: the end recorded only when it opened a new moment (round 4's `ended`). `missed earlier`: an app id with a comma stored as two ignored names. |
| direct | Sonnet | 1 unrated | Checked 4da00ec. Confirmed the end fix; did not accept the answer on the comma (it misstated what Ignore did). [Comment](https://github.com/AboulEinein/soroband/pull/50#issuecomment-6666512448). |
| direct | Sonnet | 1 Minor | Checked e5ff0b0. `fix regression`: a doc comment moved off its function. [Comment](https://github.com/AboulEinein/soroband/pull/50#issuecomment-6666617813). |
| CodeRabbit | CodeRabbit | none | The ready PR, 364c3a6..d2cd3a4. |
| CodeRabbit | CodeRabbit | 1 Minor, 1 Trivial | On the records commit 7648b8c. `first look`: with the data hog off, a hog that goes nowhere took an app's background-activity alert. `fix regression`: no test for each way a transfer's end is recorded (round 5's fix). |
| CodeRabbit | CodeRabbit CLI | 1 Major, 4 Minor | On 9c860a1. `first look`: the Island pane's switches named their settings keys to VoiceOver; the spike's `run.sh` built outside the lock and missed a failed mode (the Major). `fix regression`: the retro's counts. Not valid: a partial download, a third time. |
| direct | Sonnet | 2 unrated | Checked 9c860a1 and 9808094: both fix their findings; two notes, neither acted on (a moment turned on fires at once by design; the `Watch` is tested with the hog out of reach). [Comment](https://github.com/AboulEinein/soroband/pull/50#issuecomment-6667436587). |
| CodeRabbit | CodeRabbit | none | 7648b8c..9808094. |
| CodeRabbit | CodeRabbit | 1 Minor | On the records commit 7708512. `fix regression`: the entry's "Ran" line still counted the reviews before the records commit. |

**Retro.** Planned 3 rounds; it took 5 and 2 direct reviews. Round 1 was large because it saw a 46-file milestone first, and because the experiment ran it unposted on purpose. After that, 7 of the 11 findings in rounds 2 to 5 were `fix regression` (the other 4 `missed earlier`), and 4 of them in one place: the transfer's bookkeeping (when a transfer counts as shown, when its end is recorded) and `moments.sh`'s check of it. Each fix covered the path the finding named, and the next round found another path into the same state: turning the moment off, then ignoring the app or closing the lid, then the pointer holding it open, then an end landing on the open moment. Round 5's change was to debug state only, so a direct review stood in for round 6, as the user asked that review effort stay proportional. CodeRabbit's review of the records commit then found one more real-use gap the blind loop never looked at: a moment turned off still taking another's alert, the interaction of two settings rather than of code paths. Two process slips: one push went before its CLI review, and an answer to a finding was given from memory of the code and was wrong (the comma); the direct review caught it.

The same origin for the same reason as #9's retro (each fix to the wait loop brought the next finding): a fix to state that several paths reach, made one path at a time. That is now a rule in `verification.md`, Before pushing: list every path into the state a fix touches and test each, not only the one the finding names.

## [#53](https://github.com/AboulEinein/soroband/pull/53) docs: record M5 as merged (2026-11-05)

Planned rounds: 1.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| 1 | Opus | none | Checked fc8d44b; the skill posts no review on no findings, so its verdict is a [PR comment](https://github.com/AboulEinein/soroband/pull/53#issuecomment-6670743076). |
| CodeRabbit | CodeRabbit | none | |

**Retro.** Planned 1 round; it took 1. A docs-only change that a blind reviewer could check line by line against the code and the ledger left nothing to find.

## [#54](https://github.com/AboulEinein/soroband/pull/54) feat: release v0.1.0 (M7) (2026-11-06)

Planned rounds: 3. Ran: 4 blind rounds, 3 direct reviews, 6 CodeRabbit reviews (5 with findings), and the CodeRabbit CLI before each push but one.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| CodeRabbit | CodeRabbit CLI | 3 Minor | `first look`: a reopen failure after a successful swap hid the update's result; the README's "sends nothing anywhere" beside `soroband update`; CHANGELOG's Location placeholder could ship (now refused by the release workflow). |
| 1 | Opus | 2 Medium, 4 Low | `first look`: `quit` matched other users' Soroband (`pgrep` without `-U`); the quit-and-reopen path never ran in a test or the end-to-end; the dry run's paths left out the two files its version check reads; a dated CHANGELOG heading could still ship the Location placeholder; the popover screenshot's alt text named apps it did not show; GLOSSARY's dogfood build read as the new Release. |
| CodeRabbit | CodeRabbit CLI | none | On round 1's fixes. |
| 2 | Opus | 2 Low | `first look`: no test for `update`'s arguments past its limits; install.md told a release install by the optional link. |
| direct | Sonnet | 1 unrated | Checked 33bd0da: both fixed; a nit (`--check` without the full path), declined. [Comment](https://github.com/AboulEinein/soroband/pull/54#issuecomment-6681553678). |
| CodeRabbit | CodeRabbit | 2 Minor | On 33bd0da. `first look`: a core version other than x.y.z would pass; install.md's block unmounted the DMG a failed `ditto` needed. |
| CodeRabbit | CodeRabbit CLI | 3 Minor, 1 Minor | `first look`: README's update needed the optional link; local traffic on interface totals; `$dir` across install.md's blocks. Then: the tag accepted an undated heading. |
| direct | Sonnet | 1 Low | Checked 1d5999b and 04163d6. `fix regression`: install.md attached the DMG by a relative path after `cd`. [Comment](https://github.com/AboulEinein/soroband/pull/54#issuecomment-6681976624). |
| CodeRabbit | CodeRabbit | 1 Minor | On 04163d6. `fix regression`: mount the checked DMG in every shell (already fixed in ed7ddd8). |
| CodeRabbit | CodeRabbit | 1 Major, 1 Minor | On ed7ddd8, outside the diff. `first look`: an account that cannot write to `/Applications` could not update (the Major); overlapping updates (accepted). |
| 3 | Opus | 2 Low | `new evidence`: an undeletable `.Soroband-old.app` from another account's update blocked every later one (rename onto a non-empty folder). `first look`: no test of an older latest release. |
| CodeRabbit | CodeRabbit CLI | 1 Trivial, 2 Minor | `first look`: a wording nit in install.md, fixed with absolute paths; the checksum and the mount, both failing safely, declined. |
| CodeRabbit | CodeRabbit | 1 Trivial | On 8174fd5, nitpick: `--check` could fetch assets unnoticed; accepted. |
| 4 | Opus | 2 Low | `fix regression`: round 3's per-run names left an undeletable old bundle hidden and unreported. `missed earlier`: this entry lacked the draft rounds' rows. |
| CodeRabbit | CodeRabbit CLI | 1 Major | `first look`: notarization, declined: it contradicts the decision of 2026-10-26 (no paid Apple account). |
| direct | Sonnet | 1 unrated | Checked 673d25a: fixed; a wording nit, declined. [Comment](https://github.com/AboulEinein/soroband/pull/54#issuecomment-6683282197). |
| CodeRabbit | CodeRabbit | 1 Minor | On 673d25a. `fix regression`: an open failure dropped the leftover's note. |
| CodeRabbit | CodeRabbit CLI | 1 Minor | `first look`: README's "only internet traffic" without the interface-totals exception. |
| CodeRabbit | CodeRabbit | none | On 61df5ca. |
| CodeRabbit | CodeRabbit | 1 Major, 3 Minor | On the records commit 4528eb9. `first look`: the second-account step's link needed `~/.local/bin`; the fresh-agent step could not run before the release (the Major). `fix regression`: the retro's count of reviews and two rows without an origin. |

**Retro.** Planned 3 rounds; it took 4 and 3 direct reviews. The findings shrank each round (6, 2, 2, 2) and changed kind, from the release path to the edges of replacing an app on disk. Most came from one place the plan did not spell out: `soroband update` replaces a bundle in a folder other accounts share, which the second-account exit criterion makes real. Round 1 saw the other user's process; CodeRabbit the account that cannot write; round 3 the other account's leftover (seen by running `rename` on APFS, not by reading); round 4 the leftover's silence after that fix. Each was a different path into the same state, a shared `/Applications`, and the rule in `verification.md` (list every path into the state a fix touches) would have caught rounds 3 and 4 in one if the fix had listed the second account as a path. Two process slips: round 1's fixes were pushed before their CLI review, which ran right after and found nothing (the "none" row), and the draft rounds' rows were noted but not committed until the end, which round 4 flagged. The CLI found a new nit on almost every run of the same tree; past the third, its findings were judged for real use and most declined. Changes: none to the rules beyond what the retros of #9 and #50 already say; the second-account case goes into the hand checklist.

## [#55](https://github.com/AboulEinein/soroband/pull/55) docs: map the docs and tighten them for a public repository (2026-11-06)

Planned rounds: 1.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| CodeRabbit | CodeRabbit CLI | 1 Minor | `first look`: SECURITY's `soroband update` needs the command linked; it now gives the full path too. |
| 1 | Opus | 2 Low | `first look`: the docs map said contributors need none of the records, against CONTRIBUTING; it left out SECURITY.md. |
| direct | Sonnet | none | Checked 363eb02; resolved both threads. [Comment](https://github.com/AboulEinein/soroband/pull/55#issuecomment-6682065030). |
| CodeRabbit | CodeRabbit | none | The ready PR, after #54 merged. |

**Retro.** Planned 1 round; it took 1 and a direct review. A docs-only change the reviewer could check link by link; its two findings were where the new map contradicted CONTRIBUTING and what it left out, both answered in wording. The audit's keep/tighten/move decisions were the user's before any edit, so nothing was redone.

## [#56](https://github.com/AboulEinein/soroband/pull/56) test: fix the flaky UI process and engine stop tests (2026-11-06)

Planned rounds: 1.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| CodeRabbit | CodeRabbit CLI | none | |
| 1 | Opus | none | Posted as a COMMENT review with a no-findings body. |
| CodeRabbit | CodeRabbit | 1 Trivial | Nitpick: a shutdown barrier would make the stop test exact; accepted, with the reason on the PR. |

**Retro.** Planned 1 round; it took 1. Each fix came with a reproduction of the flake (a widened gap, the mutant applied) and a check that the test still fails on the behavior it guards, so the reviewer could confirm both by reading.

## [#59](https://github.com/AboulEinein/soroband/pull/59) fix(island): keep the menu bar clear while a moment grows or shrinks (2026-11-07)

Planned rounds: 1.

| Review | Model | Findings | Origins |
| --- | --- | --- | --- |
| CodeRabbit | CodeRabbit CLI | 1 Minor | The neck's fillets curved outward from 8 pt above the menu bar's lower edge: fixed, the test now checks 0.5 pt above it. |
