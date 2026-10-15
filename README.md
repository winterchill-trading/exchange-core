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
| `Trigger` | Trigger price and kind (take-profit or stop-loss) of a trigger order; which way the mark has to move for each side |
| `Open_order` | A resting order as reported to its owner |
| `L2` | Aggregated book snapshot, best first |
| `Position_view`, `Account_view` | Positions and cross-margin summary at mark: balance, equity, margin used, maintenance, available |
| `Fee_schedule` | Maker/taker fees in basis points |
| `Instrument` | Symbol, size decimals, price tick, optional significant-figure limit, max leverage, fees, optional margin tiers; validation and rounding |
| `Margin_tier` | Notional tiers of maximum leverage and the continuous tiered maintenance margin |

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
| `Price_index` | Oracle price and Hyperliquid's mark: median of oracle plus a 150 s average of the book's premium, the book's own prices and their 30 s average |
| `Premium_funding` | Impact prices, the premium over the oracle, and the clamped, capped funding rate from its average |
| `Book_liquidation` | Liquidation through the book with a backstop liquidator: settings and liquidation steps |
| `Trigger_order`, `Trigger_event` | A trigger order waiting for the mark, and what happens to it (placed, triggered, cancelled), in a log of its own |
| `Target` | The order a modify replaces: by order id or client order id (also `Exchange.Target`) |
| `Exchange` | Top level: books per instrument, clearinghouse, marks, id counters, clock, event log; place (`place_with_order_id` also returns the assigned id), cancel, modify, views, `set_mark`, `funding_rate` / `set_funding_rate`, `step`, `drain_events` / `drain_numbered_events`, `record_inputs`, `apply` |
| `Input` | Every mutating request as a value, with a `bin_prot` encoding |
| `Journal` | Writes inputs to a binary file, loads them and replays them into a fresh exchange |
| `Book_replay` | Rebuilds order books from numbered events alone (as a feed consumer would), with gap detection |
| `Market_sim` | Seeded random-walk reference prices, marks, and noise traders posting, cancelling, quoting inside the spread and taking; `Config.randomize ~seed`; external reference prices (`set_reference`) and per-symbol noise trader counts (`set_noise_traders`) |
| `Price_collar` | A per-symbol band around a reference price (last trade, mid or mark) in bps or ticks, and what happens to an aggressive order beyond it (reject or re-price) |
| `Halt_rule` | Circuit-breaker levels (move from a session reference, halt duration), market-wide or per symbol, automatic or requested reopening |
| `Guard_event` | Audit log of the collar and the halt rule (`drain_guard_events`), and their counters (`guard_stats`) |
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

Settings outside `Config.t` go in a `Journal.Header.t`; today that is the self-trade
policy. An exchange with a non-default policy is journalled with the magic string
`EXJRNL02` and a `bin_prot` header before the inputs; with the default policy the file
is written exactly as before, so existing journals keep their bytes and replay
unchanged. `Journal.attach` raises if the header does not match the exchange.

```ocaml
let ex = Exchange.create ~self_trade:Expire_maker () in
let journal = Journal.create ~header:{ self_trade = Expire_maker } "run.journal" in
Journal.attach journal ex;
(* ... *)
let header, inputs = ok_exn (Journal.load_with_header "run.journal") in
let replayed = Journal.replay ~header inputs in
```

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

## Price collar and halts

A collar stops an aggressive order from trading more than a band away from a reference
price, the guard real venues run as price banding or aberrant-trade protection. A halt
rule is a venue-neutral circuit breaker. Both are off until set, and both are set through
recorded calls, so journals carry them and a replay reproduces every guard event.

```ocaml
Exchange.set_collar ex btc
  (Some { reference = Mark; band = Bps 50; action = Reprice });   (* or Ticks n, Reject *)
Exchange.set_halt_rule ex (Some Halt_rule.Config.default);         (* 7%, 13%, 20% *)
Exchange.set_session_reference ex btc px;                          (* new session *)
Exchange.reopen ex;                                                (* lift every halt *)
Exchange.drain_guard_events ex;  Exchange.guard_stats ex
```

- **Reference.** `Last_trade`, `Mid` (both sides present) or `Mark`. The mark is the last
  `set_mark`, which is what `Market_sim.set_reference` feeds, so an anchored simulator
  collars against the external market. Without a reference price the order passes and
  `collar_unreferenced` counts it.
- **Band.** `Bps n` of the reference or `Ticks n`; bounds are rounded inward to valid
  prices (tick and significant figures), but never past the reference.
- **Which orders.** Only orders that would trade on entry, and only on the aggressor's
  side: a buy may not trade above `reference + band`, a sell not below
  `reference - band`. A resting order that a moving reference left outside the band can
  still fill, at a price better than the band for the aggressor, as on the venues that run
  collars. Post-only orders and liquidation orders are not checked.
- **Action.** `Reject` rejects a marketable limit order priced beyond the band
  (`Rejected Invalid_price`, plus a `Collar_rejected` guard event with the reference and
  the bound). `Reprice` moves its limit to the bound. Market orders are never rejected:
  their protection price is clamped to the bound and they match as an IOC order there. A
  `Collar_repriced` event is written only when the collar changed the outcome (part of
  the order left unfilled while liquidity remained within its original limit).
- **Halts.** Each watched symbol's price (mark, mid or last trade) is compared with its
  session reference (`set_session_reference`, else the first price seen under the rule).
  A move past an untriggered level halts the symbol, or every symbol (`Market_wide`), for
  the level's duration; each level triggers once per session; the last level of the
  default rule halts until `reopen`. While halted, orders that would trade are rejected
  (`Rejected (Unsupported "trading halted")` plus `Halt_rejected`); passive orders rest and
  cancels work, so the book can rebuild. Elapsed halts lift at the next `step`, or with
  `Reopen.On_request` wait (`Reopen_pending`) for the front end to run its reopening
  auction and call `reopen`. The TradFi simulators keep their own LULD bands.
- **Compatibility.** Rejections reuse existing `Reject_reason` constructors and the guard
  log is separate from `Event.t`, so front ends that match every constructor build
  unchanged; the four new `Input` constructors are appended to the journal encoding.

`test/test_collar_property.ml` checks with `Base_quickcheck`, over random order flow,
references, bands and actions, that no fill happens beyond the collar on the aggressor's
side.

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
- **Self-trade prevention** is chosen per exchange with `Exchange.create ?self_trade`
  (an `Order_book.Stp.t`, applied to every book):

  | Policy | Taker that meets its own resting order | Own resting order |
  | --- | --- | --- |
  | `Cancel_taker` (default; Binance and Bybit simulators) | remainder cancelled; `Rejected Self_trade` if nothing filled | stays |
  | `Expire_maker` (Hyperliquid simulator) | keeps matching behind it; never rejected for self-trade | `Order_cancelled` with reason `Self_trade`, reserved margin released |
  | `Cancel_both` | as `Cancel_taker` | as `Expire_maker` |

  Expired orders are reported after the taker's fills and before its own events, so a
  book rebuilt from events never sees the taker rest across them.
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
  `notional / (2 * max_leverage)`, or with margin tiers
  `notional * rate(tier) - deduction(tier)`, each tier's rate half the initial margin at
  its leverage and the deductions keeping it continuous; `set_leverage` then refuses a
  leverage above the tier of the current position. Default leverage is `min 20 max_leverage`.
- **Fees** come from each instrument's `Fee_schedule` (default taker 3.5 bps, maker
  1 bp) and are always charged.
- **Mark price** is the last `set_mark`, else the last trade price, else the book mid.
- **Oracle price** (`set_oracle`, optional): an external index price, as Hyperliquid's
  validators publish every 3 seconds. Each update sets the mark to the median of the
  oracle plus the 150 s moving average of `mid - oracle`, the median of best bid, best
  ask and last trade, and (since the third, external input is missing) the 30 s average
  of that median, rounded to a valid price (`Price_index`). From the first oracle on,
  `step` samples the premium of the impact prices (average fill of 20,000 USDC for BTC
  and ETH, 6,000 otherwise) over the oracle every 5 s, and funding charges
  `size * oracle * rate` with the rate `P + clamp (0.01% - P, ±0.05%)` per 8 hours, one
  eighth per hour, capped at 4% an hour (`Premium_funding`, set with
  `Exchange.create ~premium_funding`). `Market_sim.Config.oracle_interval` publishes the
  reference walk as the oracle instead of the mark.
- **Liquidation.** `set_mark`, `set_oracle` and `step` close every position of an account
  whose equity is below maintenance margin at mark and cancel its resting orders. There
  is no liquidator or backstop: the closed size leaves open interest, and losses beyond
  the balance leave a negative balance.
- **Liquidation through the book** (`Exchange.create ~book_liquidation`, Hyperliquid's
  scheme): the account's orders are cancelled, then each position gets a reduce-only
  market order from the account to the book (20% of a position above 100,000 USDC, the
  whole position within 30 s of a partial one); below two thirds of maintenance the
  backstop moves the positions and the remaining balance to a liquidator account at the
  mark. Steps come from `drain_liquidation_events`; journals record the setting in an
  `EXJRNL03` header.
- **Funding** is charged at each multiple of the funding interval (1 hour) crossed by
  `step`: every position pays `size * mark * rate`, so longs pay shorts when the rate is
  positive. The rate is per instrument (`set_funding_rate`, read back with
  `funding_rate`), default 0.00125%, unless the symbol has an oracle price (above).
- **Trigger orders** (`place_trigger`) wait off the book, holding no margin, until the
  mark reaches the trigger price: a sell stop-loss or a buy take-profit fires at or below
  it, a buy stop-loss or a sell take-profit at or above it. The request is then placed
  as an ordinary limit or market order under the trigger order's id, with every check
  done at that moment. Marks are compared after `set_mark` and `step` and when the
  order is placed, so a trigger the mark has already reached fires at once. Cancel,
  cancel by client order id and modify (`?trigger` for a trigger replacement) reach
  trigger orders; liquidation cancels them. Their events come from
  `drain_trigger_events`, ordered against the main log by `before_seq`, so front ends
  that match every `Event.t` constructor are unaffected.
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

## Performance

`bench/main.exe` (core_bench) runs against `bench/scenario`: 1000 accounts each holding a
BTC position and one maker with 100 resting orders. Run it with a short quota, since
every fill is kept in the per-account fill history:

```sh
dune exec bench/main.exe -- -quota 3
```

`test/test_allocation.ml` pins the minor words per call, and
`test/test_mark_to_market.ml` checks marking, funding and the order margin check against
the original sort-every-account implementation with `Base_quickcheck`.

- **Step** marks only accounts with an open position, kept in a map sorted by account id
  (`Clearinghouse` adds an account on its first open position and prunes flat ones on the
  next pass), instead of sorting every account. Each account's `equity - maintenance` is
  one pass over `Account_state.position_list`, and the mark is read once per symbol per
  pass.
- **Submit** checks margin in one pass over the positions, reads reserved margin from a
  per-account cache (each resting order's `px * remaining / leverage` share, updated when
  an order rests, fills or leaves the book, recomputed for a symbol when its leverage
  changes; `test/test_reserved_margin.ml` checks it against a walk), takes the book closure `local_`, reuses one
  trade id source and settles through `Clearinghouse.settle_fill_u`, which returns the
  two settlements as an unboxed pair.

Measured on arm64 (CI is amd64), time noisy within 10 to 20%; words are exact:

| Case | Build | Before | After |
| --- | --- | --- | --- |
| step, 1000 accounts | dev | 1770 us, 77831 w | 159 us, 20 w |
| | release | 388 us, 77831 w | 73 us, 20 w |
| | release `-O3` | 371 us, 77827 w | 51 us, 16 w |
| IOC buy + sell, 2 fills | dev | 5.2 us, 565 w | 2.9 us, 477 w |
| | release | 3.1 us, 551 w | 2.8 us, 463 w |
| | release `-O3` | 6.2 us, 431 w | 2.5 us, 367 w |
| submit + cancel | dev | 1.34 us, 359 w | 0.90 us, 345 w |
| | release | 0.73 us, 352 w | 0.88 us, 338 w |
| | release `-O3` | 0.67 us, 281 w | 0.78 us, 286 w |
| maker submit + cancel, 100 resting | dev | 22.2 us, 3160 w | 0.93 us, 348 w |
| | release | 13.4 us, 3153 w | 0.91 us, 341 w |
| | release `-O3` | 10.7 us, 3082 w | 0.81 us, 289 w |
| submit + cancel, 500 own resting | release | 44.4 us, 3359 w | 0.95 us, 378 w |
| | release `-O3` | | 0.86 us, 323 w |

With a collar and the default halt rule set (`collar+halt` in the bench), each order pays
for a reference lookup, the bound and one halt comparison; the cases without them are
unchanged (the pinned allocation counts did not move). Measured on arm64, 2 s quota:

| Case | Build | No guard | Collar + halt rule |
| --- | --- | --- | --- |
| IOC buy + sell, 2 fills | dev | 2.75 us, 479 w | 2.97 us, 495 w |
| | release | 2.73 us, 465 w | 2.87 us, 481 w |
| | release `-O3` | 2.43 us, 369 w | 2.54 us, 385 w |
| submit + cancel | release | 0.85 us, 338 w | 0.94 us, 346 w |
| | release `-O3` | 0.77 us, 286 w | 0.84 us, 294 w |
| step, 1000 accounts | release | 68 us, 20 w | (unchanged) |

The cache costs a few words per submit (about 15 on the IOC round trip) and makes the
check independent of how many orders the account has resting. The remaining submit words
are mostly its outputs: events, settlements, executions and
the fill history.

## Tests

`dune test` runs expect tests (instrument rules, fees, PnL, liquidation, funding,
exchange flows, a seeded market simulation, pinned and mean-reverting reference prices,
per-symbol noise trader counts, a text trace of book, margin and accounts per step,
journal round trips and replays, books rebuilt from events, the stepped harness, collar
bands, rejections and re-pricing, market-wide and per-symbol halts and their replays) and
`Base_quickcheck` properties: balances plus unrealised PnL plus fees are conserved, books
never cross, and every resting order is listed once in its owner's open orders; with
steps and mark moves mixed in, positions net to zero once liquidated sizes
are counted, and order and trade ids are unique; with a collar, no fill beyond it on the
aggressor's side.
