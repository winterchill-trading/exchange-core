open! Core
open! Exchange_core

type t =
  { books : Order_book.t Symbol.Table.t
  ; mutable next_seq : int
  }

let create ?(next_seq = 1) symbols =
  let books = Symbol.Table.create () in
  List.iter symbols ~f:(fun symbol ->
    Hashtbl.set books ~key:symbol ~data:(Order_book.create symbol));
  { books; next_seq }
;;

let next_seq t = t.next_seq
let book t symbol = Hashtbl.find t.books symbol

let find_book t symbol =
  match book t symbol with
  | Some b -> Ok b
  | None -> Or_error.error_s [%message "Book_replay: unknown symbol" (symbol : Symbol.t)]
;;

(* Books are rebuilt without matching, so trade ids are never needed. *)
let no_tid () = Trade_id.of_int 0

let rest book ~oid ~owner ~side ~px ~sz ~cloid ~time =
  let result =
    Order_book.add_limit
      book
      ~oid
      ~owner
      ~side
      ~px
      ~sz
      ~tif:Gtc
      ?cloid
      ~time
      ~next_tid:no_tid
      ()
  in
  match result.status with
  | Resting when List.is_empty result.fills -> Ok ()
  | _ ->
    Or_error.error_s
      [%message
        "Book_replay: accepted order does not rest" (oid : Order_id.t) (px : Price.t)]
;;

let apply_event t (event : Event.t) =
  match event with
  | Order_accepted { account; order; time = _ } ->
    let%bind.Or_error book = find_book t order.symbol in
    rest
      book
      ~oid:order.order_id
      ~owner:account
      ~side:order.side
      ~px:order.px
      ~sz:order.size
      ~cloid:order.client_order_id
      ~time:order.timestamp
  | Fill { fill; _ } ->
    let%bind.Or_error book = find_book t fill.symbol in
    (match Order_book.cancel book fill.maker_oid with
     | None ->
       Or_error.error_s
         [%message "Book_replay: fill of an unknown maker" (fill : Order_book.Fill.t)]
     | Some maker ->
       let remaining = Size.( - ) maker.remaining fill.sz in
       if Size.is_negative remaining
       then
         Or_error.error_s
           [%message "Book_replay: fill larger than the maker" (fill : Order_book.Fill.t)]
       else if Size.is_zero remaining
       then Ok ()
       else
         (* Re-adding moves the order to the back of its level; aggregated levels and
            order counts are unaffected. *)
         rest
           book
           ~oid:maker.oid
           ~owner:maker.owner
           ~side:maker.side
           ~px:maker.px
           ~sz:remaining
           ~cloid:maker.cloid
           ~time:maker.timestamp)
  | Order_cancelled { order; _ } ->
    let%map.Or_error book = find_book t order.symbol in
    (* IOC and market remainders were never on the book. *)
    ignore (Order_book.cancel book order.order_id : Order_book.Resting_order.t option)
  | Order_rejected _ | Order_filled _ | Liquidation _ | Funding _ -> Ok ()
;;

let apply t ({ seq; event } : Event.Numbered.t) =
  if seq <> t.next_seq
  then
    Or_error.error_s
      [%message "Book_replay: sequence gap" ~expected:(t.next_seq : int) ~got:(seq : int)]
  else (
    t.next_seq <- seq + 1;
    apply_event t event)
;;

let rec apply_all t = function
  | [] -> Ok ()
  | event :: rest ->
    let%bind.Or_error () = apply t event in
    apply_all t rest
;;

let l2 t symbol ~n_levels ~time =
  book t symbol
  |> Option.map ~f:(fun b ->
    let bids, asks = Order_book.l2 b ~n_levels in
    { L2.symbol; time; bids; asks })
;;
