# AGENTS.md: exchange-core

## Purpose

Venue-neutral building blocks for a perpetuals exchange: trading primitives and views
(`exchange-core`), and a deterministic engine (`exchange-core-engine`). Nothing here knows a
venue's wire format; venue simulators are adapters over the engine.

## Layout

| Path | Holds |
| --- | --- |
| `lib/` | Package `exchange-core` (module `Exchange_core`): primitives, accounts, fees, instruments, views (see `lib/AGENTS.md`) |
| `engine/` | Package `exchange-core-engine` (module `Exchange_core_engine`): the matching exchange, clearinghouse, liquidation, journals, replay (see `engine/AGENTS.md`) |
| `bench/` | `main` (core_bench) and `scenario/`, the 1000-account benchmark (see `bench/AGENTS.md`) |
| `test/` | Expect tests, Quickcheck properties, allocation tests (see `test/AGENTS.md`) |
| `.github/` | CI workflow and the shared obj-magic check (see `.github/AGENTS.md`) |
| `README.md` | Packages, modules, journals and replay, anchoring, design notes, performance |
| `exchange-core.opam`, `exchange-core-engine.opam`, `dune-project` | Two packages; edit `dune-project`, the `.opam` files are generated |

## Build, test, docs

Run from this repository. The workspace root is one level up, so every command takes
`--root ..`.

```sh
opam exec --switch 5.2.0+ox -- dune build --root .. @exchange-core/all
opam exec --switch 5.2.0+ox -- dune build --root .. @exchange-core/runtest
```

Parallel work with another agent: prefix each with `DUNE_BUILD_DIR=_build-exchange-core`.

CI builds the engine package on its own, which is the same target the simulators depend on:

```sh
opam exec --switch 5.2.0+ox -- dune build --root .. --only-packages exchange-core-engine @install
opam exec --switch 5.2.0+ox -- dune build --root .. --only-packages exchange-core-engine @runtest
```

Standalone (outside the workspace): pin `fixed-decimal` and `order-book` from GitHub
(CI order), pin this checkout as `exchange-core`, then
`opam install ./exchange-core-engine.opam --deps-only --with-test`. The packages are not
yet on the org opam repository (see `../specs/repos/opam-repository.md`).

## Conventions

- Format only this repository: `dune build --root .. @exchange-core/fmt --auto-promote`.
  Never run `dune fmt` at the workspace root.
- Every module has an `.mli`. Consume siblings by public opam name.
- The engine is deterministic: no clock reads and no randomness outside an injected source.
  A seeded market simulation is part of the tests, so any change that alters its numbers
  must be explained in the commit.
- Venue codecs never live here. Yojson or wire encodings belong in the venue protocol
  library.
- Allocation pins in `test/test_allocation.ml`: word counts differ between macOS arm64 and
  Linux amd64; keep the comment next to each pin current.
- Comments for humans at non-obvious choices (margin, funding, liquidation order).

## Dependencies and dependents

Sibling checkouts: `fixed-decimal`, `order-book`. CI pins `fixed-decimal`, `exchange-core` (the
engine's own package, same URL) and `order-book`, in that order. Consumers pin this
repository by URL, once per package name: `../cboe-sim`, `../cme-sim`, `../coinbase-feed`,
`../deribit-feed`, `../equities-core`, `../hl-client`.

## CI

`.github/workflows/ci.yml`: the engine's `opam` file is copied into `_ox-engine/` and the
shared `ox-setup` action installs its dependencies there; then this checkout is pinned and
only the `exchange-core-engine` package is built and tested. The obj-magic check follows.
Pushes cancel the running job.

To check a run: one `gh run list --limit 1`, then at most one `gh run watch <id>
--exit-status`. Never poll in a loop.

## Pitfalls

- Two packages from one repository are required because `order-book` sits between them;
  one opam package would form a cycle.
- Re-export a type from another library with type equality: `include Exchange_core.Price`
  in the `.ml` and `include module type of struct include Exchange_core.Price end` in the
  `.mli`. A hand-written `Comparable.S` gets a fresh witness and breaks map sharing.
- `git rm` stages deletions, and a later `git add ... && git commit` sweeps them into that
  commit. Commit by path when splitting a refactor.
- `dune build ./engine` builds just the engine directory, handy while a sibling is mid-edit.

## Where to read more

- `README.md`: packages, primitives, the engine, journals and replay, anchoring, design
  notes, performance, tests.
- `../specs/repos/exchange-core.md`: key modules and status.
- `../order-book/`, `../fixed-decimal/`: the layers below.
- `../oxcaml-claude-skills/skills/oxcaml-performance/`: engine hot paths.
- `../oxcaml-claude-skills/skills/oxcaml-modes/`: local and `global_` annotations.
- `../oxcaml-claude-skills/AGENTS.md`: workspace-wide guide.
- `../oxcaml-claude-skills/GOTCHAS.md`: the exchange-core extraction section.

## Never do

- Install opam packages that change the compiler or `core`, `base`, `async`, `ppx_jane`
  on the shared `5.2.0+ox` switch. Dry-run first: `opam install --switch 5.2.0+ox --dry-run <pkg>`.
- Publish, tag or release.
- Poll CI in loops.
