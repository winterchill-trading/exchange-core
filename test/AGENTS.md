# AGENTS.md: exchange-core/test

Expect tests for instrument rules, fees, PnL, liquidation, funding, flows, the seeded market
simulation, journals, replays and the stepped harness; Quickcheck properties for conservation
(balances plus unrealised PnL plus fees), non-crossing books and unique ids.
`helpers.ml` is the shared setup. `test_allocation.ml` pins word counts.

Run: `opam exec --switch 5.2.0+ox -- dune build --root .. @exchange-core/runtest`.

Rules:
- Promote only after reading the diff and after a successful `@runtest` build.
- A seeded simulation number that moves needs a reason in the commit message.
- Do not print file paths in expect output.
