# Changes

All notable changes to the two packages of this repository (`exchange-core` and
`exchange-core-engine`) are listed here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and versions follow
[Semantic Versioning](https://semver.org/) (before 1.0.0, a minor version may break the API).

## Unreleased

### Added

- `exchange-core-engine`: `Price_collar`, a per-symbol band around a reference price
  (last trade, mid or mark, the mark being what `Market_sim.set_reference` feeds) in
  basis points or ticks. Aggressive orders beyond it are rejected or re-priced to the
  band; market orders have their protection price clamped. Checked on the aggressor's
  side only; post-only and liquidation orders are exempt.
- `exchange-core-engine`: `Halt_rule`, a venue-neutral circuit breaker. Levels of move
  from a session reference with a halt duration (default 7% and 13% for 15 minutes, 20%
  until reopened), market-wide or per symbol, automatic reopening or reopening on request
  (the hook for a front end's reopening auction).
- `exchange-core-engine`: `Guard_event`, a typed audit log of collar rejections and
  re-pricings, halt rejections, halts and reopenings, ordered against the main log by
  `before_seq`, with counters (`Guard_event.Stats`).
- `Exchange.set_collar`, `collar`, `collar_reference`, `set_halt_rule`, `halt_rule`,
  `set_session_reference`, `session_reference`, `reopen`, `halt_status`,
  `drain_guard_events`, `guard_stats`.
- `Input.Set_collar`, `Set_halt_rule`, `Set_session_reference`, `Reopen`, appended to the
  journal encoding: journals record the settings and replays reproduce the guard events.
- Quickcheck property: no fill beyond the collar on the aggressor's side.
- Bench cases for the order path with a collar and the default halt rule.

### Compatibility

- No new `Event.t` or `Reject_reason.t` constructors: collar rejections are
  `Invalid_price` and halt rejections `Unsupported "trading halted"`, with the details in
  the guard log, so venue front ends that match every constructor build unchanged.
- Without a collar or halt rule the engine behaves, journals and replays exactly as
  before; the pinned allocation counts are unchanged.

## 0.1.0 (not yet tagged)

First release: primitives and views (`exchange-core`) and the deterministic perpetuals
engine (`exchange-core-engine`): matching with self-trade prevention, clearinghouse, cross
margin with margin tiers, funding (fixed or premium-based), liquidation at mark or through
the book, trigger orders, journals and replay, book rebuild from events, seeded market
simulation with external references, and the stepped harness.
