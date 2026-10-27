# core

Rust workspace:

- `soroband-core`: the meter engine (kernel network statistics client, app attribution, interface reconciliation) and storage (SQLite). Built as a static library for the app.
- `soroband-cli`: the `soroband` command, for live usage and queries over the stored history.

Created in milestone M0 ([`docs/plan.md`](../docs/plan.md#m0-repository-foundation)). The engine design and its measurements are in [`docs/design.md`](../docs/design.md#meter-engine); the prototype it is ported from is [`prototypes/meter-probe`](../prototypes/meter-probe).
