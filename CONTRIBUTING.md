# Contributing

Thanks for your interest in Soroband. The project is in early development: the roadmap and the state of each milestone are in [`docs/plan.md`](docs/plan.md), and [`docs/handover.md`](docs/handover.md) says what is being worked on next.

Coding agents start from [`AGENTS.md`](AGENTS.md), which lists the rules every change follows and the documents to read first. People can read it the same way.

## Requirements

- macOS 14 or later
- Xcode with the current macOS SDK
- Rust stable: `rustup` for universal builds (it adds the `x86_64-apple-darwin` standard library); Homebrew's `rust` is enough for `--host` builds and `scripts/install.sh`

## Building

The app and core are being set up in milestone M0. Until then, the prototypes run on their own:

```sh
# Engine prototype: per-app internet bytes for 40 s, polling every 5 s
cd prototypes/meter-probe && cargo run --release -- 40 5

# UI prototype with fake data, launched in the menu bar
prototypes/ui-spike/run.sh
```

## Pull requests

- One topic per pull request. Open an issue first for anything larger than a fix. Roadmap work is one milestone per branch and pull request, as [`docs/plan.md`](docs/plan.md#how-the-work-runs) describes.
- Commit messages follow [Conventional Commits](https://www.conventionalcommits.org/) (`feat(core): ...`, `fix(app): ...`).
- The description follows [`.github/PULL_REQUEST_TEMPLATE.md`](.github/PULL_REQUEST_TEMPLATE.md): the summary, the evidence (the test that failed and now passes, screenshots for visible changes), the performance section and the merge danger. Agents write it with the `pr` skill in `.claude/skills/pr`.
- Tests go red when the behavior breaks, and a change to the app is shown running. [`docs/verification.md`](docs/verification.md) has the tools and what each milestone must show.
- CI runs `cargo fmt --check`, `cargo clippy -D warnings`, `cargo test`, the Swift tests other than the snapshot tests, and an unsigned universal build. Snapshot tests depend on the Mac's fonts and macOS version, so run `scripts/verify/snapshots.sh` locally when a view changes.
- A domain term that is added, renamed or retired is updated in [`GLOSSARY.md`](GLOSSARY.md) in the same pull request.
- Soroband runs all day, so every change respects the budget in [`docs/design.md`](docs/design.md#performance-budget): idle CPU ≤ 0.1%, memory ≤ 25 MB with no window open. If your change touches the engine or a long-lived view, include before and after measurements.
- Soroband reads counters and metadata only. Changes that inspect packet contents or send data off the Mac will not be accepted.
- Kernel recordings used as test fixtures are anonymized before they are committed (see `core/README.md`).
- Maintainer work is reviewed by a fresh blind reviewer each round, as [`docs/review.md`](docs/review.md) describes.
