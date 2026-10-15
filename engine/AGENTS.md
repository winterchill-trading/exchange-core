# AGENTS.md: exchange-core/engine

Package `exchange-core-engine`, module `Exchange_core_engine`: the deterministic matching
exchange. Main modules: `Exchange` (order flow and events), `Clearinghouse` (margin,
positions, funding), `Book_liquidation` and `Account_state`, `Event`, `Book_replay`, and the
guards: `Price_collar`, `Halt_rule`, `Guard_event`.

Build: `opam exec --switch 5.2.0+ox -- dune build --root .. --only-packages exchange-core-engine @install`.

Rules:
- Same inputs, same outputs. Journals and replays must reproduce every event.
- Liquidation order and fee rules change the seeded market numbers; explain such changes in
  the commit message.
- Build the engine alone (`dune build ./engine`) while a sibling is mid-edit.
- New engine behaviour that front ends must see goes in a separate log (`Trigger_event`,
  `Book_liquidation.Event`, `Guard_event`) with `before_seq`, not as a new `Event.t` or
  `Reject_reason.t` constructor: the simulators and `mm-core` match those exhaustively and
  pin this repository at `main`.
- Settings that change matching are recorded `Input.t` values (appended constructors), not
  `Config.t` fields, so journals carry them and old journals still load.
- The order path with no collar and no halt rule must stay at the pinned allocation counts
  (`test/test_allocation.ml`); guard checks start with an emptiness test.
