# AGENTS.md: exchange-core/engine

Package `exchange-core-engine`, module `Exchange_core_engine`: the deterministic matching
exchange. Main modules: `Exchange` (order flow and events), `Clearinghouse` (margin,
positions, funding), `Book_liquidation` and `Account_state`, `Event`, `Book_replay`.

Build: `opam exec --switch 5.2.0+ox -- dune build --root .. --only-packages exchange-core-engine @install`.

Rules:
- Same inputs, same outputs. Journals and replays must reproduce every event.
- Liquidation order and fee rules change the seeded market numbers; explain such changes in
  the commit message.
- Build the engine alone (`dune build ./engine`) while a sibling is mid-edit.
