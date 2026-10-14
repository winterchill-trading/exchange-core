# AGENTS.md: exchange-core/.github

- `workflows/ci.yml` builds the engine in stages: its `opam` file is copied to
  `_ox-engine/`, the shared `ox-setup` action installs the pinned siblings there, then this
  checkout is pinned and only `exchange-core-engine` is built and tested. Then the reusable
  obj-magic workflow from `winterchill-trading/infra`.
- The pins list (`fixed-decimal`, `exchange-core`, `order-book`) must match the dependency
  order in `dune-project`.
- Concurrency is `cancel-in-progress: true`; push once per finished change.
- To check a run: one `gh run list --limit 1`, then at most one `gh run watch <id>
  --exit-status`. Never poll.
