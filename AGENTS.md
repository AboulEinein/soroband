# Soroband

macOS menu bar app that meters internet usage per app and per network, with a Rust core (`core/`) and a SwiftUI app (`app/`).

Start every session by reading [`docs/handover.md`](docs/handover.md): current state, next action, decisions and gotchas. The milestone ledger and the stopping rules are in [`docs/plan.md`](docs/plan.md); how to test and prove work is in [`docs/verification.md`](docs/verification.md); how work is reviewed is in [`docs/review.md`](docs/review.md); the product and architecture are in [`docs/design.md`](docs/design.md).

Rules that hold for every change:
- **Budget:** idle CPU ≤ 0.1%, memory ≤ 25 MB with no window open. A change that touches the engine or a long-lived view states its measured cost in the PR.
- **Privacy:** counters and metadata only. No packet contents, nothing leaves the Mac.
- **Glossary:** [`GLOSSARY.md`](GLOSSARY.md) holds the domain language. A change that adds, renames or retires a domain term updates it in the same PR.
- **Evidence:** a milestone is done when tests go red on broken behavior and the real app has been run, with the evidence in the PR.
- **Review:** a fresh blind reviewer per round. No PR is handed over with fixes no reviewer has seen. Whether another round adds value is a judgment, not a fixed cap; when to reassess the approach with an independent advisor agent is in `docs/review.md`. CodeRabbit reviews once the loop has ended, and its findings are logged to find what the loop misses.
- **One milestone, one branch, one PR.** Conventional Commits. Update the ledger and the handover before ending a session.
- **PR bodies** follow `.github/PULL_REQUEST_TEMPLATE.md`, written with the `pr` skill in `.claude/skills/pr`. Where they differ, the template wins: its Performance section always stays. The skill is vendored unchanged from [`mattpocock/skills`](https://github.com/mattpocock/skills/tree/e484a8095543718ced436b9b49a8160ed4554000/skills/engineering/pr) at `e484a80` (MIT, `LICENSE` beside it); to update, copy the folder again and change the commit here.
