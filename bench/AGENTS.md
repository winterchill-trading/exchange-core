# AGENTS.md: exchange-core/bench

`main.ml` runs core_bench against `scenario/`: 1000 accounts each holding a BTC position and
one maker with 100 resting orders. Every fill is kept in the per-account history, so run it
with a short quota.

Build: part of `@exchange-core/all`.

Rules:
- Report ns and words per step; a time gain that adds words is noted in the commit.
- Name the platform when a number goes into the README.
