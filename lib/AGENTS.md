# AGENTS.md: exchange-core/lib

Package `exchange-core`, module `Exchange_core`: primitives and views with no matching.
Examples: `Price`, `Account`, `Account_view`, `Client_order_id`, `Cancel_status`,
`Fee_schedule`, `Instrument`.

Build: `opam exec --switch 5.2.0+ox -- dune build --root .. @exchange-core/all`.

Rules:
- Value types here are the shared vocabulary; a change to one is a change for every
  simulator. Add a test that exercises the new behaviour.
- No venue codecs. Keep yojson derivations out of this library.
- Downstream libraries re-export these types with type equality, never with a copy.
