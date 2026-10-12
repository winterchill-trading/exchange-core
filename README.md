# exchange-core

Venue-neutral building blocks for exchange simulators: trading primitives, order and
account views, and a deterministic perpetuals exchange engine (matching, clearinghouse,
cross margin, funding, liquidation, synthetic order flow).

Built with [OxCaml](https://oxcaml.org) and the Jane Street library stack (Base, Core).
Fixed-point arithmetic comes from
[fixed-decimal](https://github.com/winterchill-trading/fixed-decimal) and matching from
[order-book](https://github.com/winterchill-trading/order-book).

Nothing here knows about a particular venue's wire format. A venue simulator (e.g.
[hl-sim](https://github.com/winterchill-trading/hl-sim) for Hyperliquid) is an adapter:
it maps its requests onto the engine, its universe onto `Instrument` records, and the
engine's results and events onto its own responses and error wording.

## Packages

The repository holds two opam packages, because `order-book` sits between them:

```
fixed-decimal -> exchange-core -> order-book -> exchange-core-engine
```

| Package | Library module | Contents |
| --- | --- | --- |
| `exchange-core` | `Exchange_core` | primitives and value types; no matching |
| `exchange-core-engine` | `Exchange_core_engine` | the engine, built on `order-book` |

## Build

```sh
opam switch create 5.2.0+ox --repos ox=git+https://github.com/oxcaml/opam-repository.git,default
opam pin add fixed-decimal https://github.com/winterchill-trading/fixed-decimal.git --no-action
opam pin add exchange-core . --no-action
opam pin add order-book https://github.com/winterchill-trading/order-book.git --no-action
opam install ./exchange-core-engine.opam --deps-only --with-test
dune build && dune test
```

Inside a dune workspace that also contains `fixed-decimal` and `order-book`, dune uses the
sibling sources and the pins are not needed.

CI installs the pinned siblings and the opam dependencies through the shared
[ox-setup](https://github.com/winterchill-trading/infra/blob/main/docs/ci.md) action, which
caches the built opam switch between runs.

## `Exchange_core`: primitives and views

| Module | Description |
| --- | --- |
| `Price`, `Size`, `Usd` | Distinct fixed-point types (`Fixed_decimal.Make ()`), 8 decimals |
| `Side` | `Buy` / `Sell` |
| `Tif` | `Gtc` / `Ioc` / `Alo` (add liquidity only, i.e. post only) |
| `Symbol` | Instrument name, opaque string |
| `Account` | Account id (address, API key, user name), opaque string |
| `Order_id`, `Trade_id` | Exchange-assigned ids (`int64`, `int`) |
| `Client_order_id` | Client-assigned id, opaque string; venues validate their own format |
| `Order_type` | `Limit of Tif.t` or `Market { slippage_bps }` |
| `Order_request` | Symbol, side, size, optional limit price, type, reduce-only, client id |
| `Order_status` | `Resting` / `Filled { total; avg_px }` / `Rejected of Reject_reason.t` |
| `Reject_reason` | Why an order was rejected (invalid size or price, margin, self-trade, ...) |
| `Cancel_status` | `Cancelled` / `Not_found` |
| `Open_order` | A resting order as reported to its owner |
| `L2` | Aggregated book snapshot, best first |
| `Position_view`, `Account_view` | Positions and cross-margin summary at mark: balance, equity, margin used, maintenance, available |
| `Fee_schedule` | Maker/taker fees in basis points |
| `Instrument` | Symbol, size decimals, price tick, optional significant-figure limit, max leverage, fees; validation and rounding |

None of these carry JSON codecs: encodings are venue-specific and live in the venue's
protocol library (`hl-protocol` re-exports these types with Hyperliquid's codecs).

## `Exchange_core_engine`: the engine

| Module | Description |
| --- | --- |
| `Position` | Signed size, weighted entry price, realised PnL and funding for one instrument; `Direction` of each trade |
| `Account_state` | Balance, positions and per-instrument leverage of one account |
| `Clearinghouse` | All accounts: fill settlement, per-instrument fees, initial and maintenance margin, liquidation, funding, `Account_view` |
| `Execution` | One account's side of a fill (fill plus settlement), as kept in its history |
| `Event` | Log entries: order accepted/rejected/filled/cancelled, fill, liquidation, funding; `Event.Numbered` adds the sequence number |
| `Target` | The order a modify replaces: by order id or client order id (also `Exchange.Target`) |
| `Exchange` | Top level: books per instrument, clearinghouse, marks, id counters, clock, event log; place (`place_with_order_id` also returns the assigned id), cancel, modify, views, `set_mark`, `funding_rate` / `set_funding_rate`, `step`, `drain_events` / `drain_numbered_events`, `record_inputs`, `apply` |
| `Input` | Every mutating request as a value, with a `bin_prot` encoding |
| `Journal` | Writes inputs to a binary file, loads them and replays them into a fresh exchange |
| `Book_replay` | Rebuilds order books from numbered events alone (as a feed consumer would), with gap detection |
| `Market_sim` | Seeded random-walk reference prices, marks, and noise traders posting, cancelling, quoting inside the spread and taking; `Config.randomize ~seed`; external reference prices (`set_reference`) and per-symbol noise trader counts (`set_noise_traders`) |
| `Stepped` | Deterministic stepped harness: exchange plus simulation advanced one step at a time, a strategy reacting to each step's events, every input recorded and checkable by replay |

```ocaml
let ex = Exchange.create () in
Exchange.deposit ex alice (Usd.of_int 10_000);
Exchange.place ex alice (Order_request.limit btc Buy ~px ~size)
(* Resting { order_id; client_order_id } *)
Exchange.step ex ~now:(Time_ns.Span.to_int_ns Time_ns.Span.hour);
Exchange.drain_events ex
```

## Journals, replay and the stepped harness

Every mutating `Exchange` call is reported, once performed, to the recorders added with
`Exchange.record_inputs` as an `Input.t`; `Exchange.apply` performs one. Because the
engine is deterministic, applying the recorded inputs in order to a fresh exchange with
the same `Config.t` reproduces the run exactly, event log included.

```ocaml
let journal = Journal.create "run.journal" in
Journal.attach journal ex;                    (* before Market_sim.create, so deposits count *)
(* ... run ... *)
Journal.close journal;
let replayed = Journal.replay (ok_exn (Journal.load "run.journal")) in
```

A journal file is the magic string `EXJRNL01` followed by one `bin_prot` value per input.
The wire shape uses only integers (units of `10^-8`), strings and floats, so it does not
change when the in-memory types do. A truncated last record is reported by `load`.

Events carry consecutive sequence numbers from 1 (`drain_numbered_events`).
`Book_replay` applies them to its own order books and must see every number in order;
the tests check its L2 against `Exchange.l2` after every tick of a seeded simulation.

`Stepped` is the harness for testing a strategy offline (intended for `mm-core`):

```ocaml
let h = Stepped.create ~journal Stepped.Config.default in
Exchange.deposit (Stepped.exchange h) me (Usd.of_int 100_000);
Stepped.run h ~steps:600 ~f:(fun h events ->
  (* react to this step's events by calling Exchange functions on (Stepped.exchange h) *)
  ());
ok_exn (Stepped.check_replay h)
```

Each step ticks the simulation, advances the clock by `step_ns` (100ms by default) and
returns that step's numbered events; the strategy's requests take effect immediately and
their events arrive with the next step. `check_replay` replays all recorded inputs into a
fresh exchange and reports the first event that differs.

## Anchoring the simulation to a reference market

The price anchor (see the specs repository, `design/price-anchor.md`) ties a simulated
symbol to another market through two `Market_sim` calls:

```ocaml
Market_sim.set_reference sim btc px;                       (* pin: reference and mark = px *)
Market_sim.set_reference sim btc px
  ~half_life:(Time_ns.Span.of_sec 1.);                     (* pull the walk towards px *)
Market_sim.clear_reference sim btc;                        (* back to the free walk *)
Market_sim.set_noise_traders sim btc 0                     (* no noise flow in btc *)
```

Without a half-life the walk stops and the noise traders quote around `px`. With one,
each tick the reference moves by its random step plus `k * (px - reference)`, with
`k = 1 - 0.5 ** (tick_interval / half_life)`; without noise the gap halves every
half-life (the test measures 5000, 2500, 1250 after 10, 20, 30 ticks of a 1 s half-life at
100 ms ticks). The random step is drawn for every symbol on every tick, so anchoring one
symbol leaves the others' random numbers unchanged.

`set_noise_traders` makes traders `0 .. n-1` trade the symbol from the next tick,
creating and funding new traders as needed and cancelling the resting orders of those
that stop. Both calls reach the exchange only through ordinary calls (`set_mark`,
`deposit`, `cancel`, `place`), so they are recorded as existing `Input.t` values: journals
keep their format and an anchored run replays bit for bit.

## Design notes

- **Determinism.** Time is an `int` count of nanoseconds advanced by the caller with
  `Exchange.step`; the engine never reads the wall clock. Order ids and trade ids are
  sequential. Every `Exchange.place` takes an order id before validating, so rejected
  orders and IOC or market orders that fill nothing consume one too; the id is in the
  `Order_rejected` event and `Exchange.place_with_order_id` returns it. Rejections
  recorded with `Exchange.reject` carry an id only if the front end passes one. Front ends convert timestamps to their venue's unit.
- **Matching** is price-time priority with maker-price fills and self-trade prevention;
  see the [order-book](https://github.com/winterchill-trading/order-book) design notes.
  Market orders are IOC orders priced `slippage_bps` (default 5%) through the best
  opposite price.
- **Order statuses.** An order that rests (even after partial fills) is `Resting`; an
  IOC or market order with any fill is `Filled` with the filled size and average price;
  an IOC order with no fill, an ALO order that would cross and failed checks are
  `Rejected` with a `Reject_reason.t`. Front ends may record their own rejections with
  `Exchange.reject` so they appear in the event log.
- **Validation**, in order: known symbol; limit price positive, on tick and within the
  instrument's significant-figure limit (integers always pass it); size a positive
  multiple of `10^-size_decimals`; no duplicate client order id among the account's
  resting orders; reduce-only orders clipped to the position (rejected if there is
  nothing to reduce); notional at least `min_order_value` unless reduce-only; margin.
- **Margin.** Cross margin only, one-way positions. Equity is balance plus unrealised
  PnL at mark. A new order needs `notional / leverage` for the part that increases the
  position, out of equity minus position margin minus margin held by resting orders
  (resting orders reserve their full notional / leverage). Maintenance margin is
  `notional / (2 * max_leverage)`. Default leverage is `min 20 max_leverage`.
- **Fees** come from each instrument's `Fee_schedule` (default taker 3.5 bps, maker
  1 bp) and are always charged.
- **Mark price** is the last `set_mark`, else the last trade price, else the book mid.
- **Liquidation.** `set_mark` and `step` close every position of an account whose equity
  is below maintenance margin at mark and cancel its resting orders. There is no
  liquidator or backstop: the closed size leaves open interest, and losses beyond the
  balance leave a negative balance.
- **Funding** is charged at each multiple of the funding interval (1 hour) crossed by
  `step`: every position pays `size * mark * rate`, so longs pay shorts when the rate is
  positive. The rate is per instrument (`set_funding_rate`, read back with
  `funding_rate`), default 0.00125%; it is not derived from a premium index.
- **Modify** cancels the target and places the replacement with a new order id (losing
  priority). If the replacement is rejected the original stays cancelled.
- **Fixed point.** `Price`, `Size` and `Usd` count units of `10^-8` in an `int`.
  Notional values use `Fixed_decimal.Product (Price) (Size) (Usd)` and fee and funding
  rates a private `Rate` type; products and quotients never overflow an intermediate
  and truncate toward zero.
- **Market simulation.** Each instrument's reference price is a geometric random walk
  with `vol_bps` volatility per second, stepped once per `tick`; the mark follows it.
  Starting prices come from `initial_prices`, keyed by symbol; unlisted symbols use
  `Config.default_price`, which recognises BTC, ETH and SOL by prefix (`BTC`, `BTCUSDT`
  and `BTC-PERP` all start at 100000) and starts anything else at 100. Order notionals
  ($20 to $2000 by default) are scaled up per instrument when one lot is worth more than
  the minimum, and sizes never round below one lot, so coarse size steps still trade.
  Noise traders (accounts `0xffff...ff0000000N`, $10M each) post GTC orders up to 25 bps
  from the reference, cancel old ones and occasionally send market orders. With
  `inside_touch_probability` above zero (default zero, which leaves seeded runs
  unchanged) they also post orders strictly inside a spread wider than one tick.
  `Config.randomize ~seed` draws volatility, trader count, probabilities and offsets from
  the seed. Prices are
  rounded with `Instrument.round_price`. Runs are reproducible for a seed, given the
  same sequence of external requests. Calling `tick` on a timer is the front end's job.

## Tests

`dune test` runs expect tests (instrument rules, fees, PnL, liquidation, funding,
exchange flows, a seeded market simulation, pinned and mean-reverting reference prices,
per-symbol noise trader counts, a text trace of book, margin and accounts per step,
journal round trips and replays, books rebuilt from events, the stepped harness) and
`Base_quickcheck` properties: balances plus unrealised PnL plus fees are conserved, books
never cross, and every resting order is listed once in its owner's open orders; with
steps and mark moves mixed in, positions net to zero once liquidated sizes
are counted, and order and trade ids are unique.
