open! Core
open! Exchange_core

module Level = struct
  type t =
    { move_bps : int
    ; duration_ns : int option
    }
  [@@deriving sexp, compare, equal]
end

module Scope = struct
  type t =
    | Market_wide
    | Per_symbol
  [@@deriving sexp, compare, equal]
end

module Reopen = struct
  type t =
    | Automatic
    | On_request
  [@@deriving sexp, compare, equal]
end

module Config = struct
  type t =
    { levels : Level.t list
    ; scope : Scope.t
    ; watch : Symbol.t list
    ; observe : Price_collar.Reference.t
    ; reopen : Reopen.t
    }
  [@@deriving sexp, compare, equal]

  let fifteen_minutes = Some (Time_ns.Span.to_int_ns (Time_ns.Span.of_min 15.))

  let default =
    { levels =
        [ { move_bps = 700; duration_ns = fifteen_minutes }
        ; { move_bps = 1300; duration_ns = fifteen_minutes }
        ; { move_bps = 2000; duration_ns = None }
        ]
    ; scope = Market_wide
    ; watch = []
    ; observe = Mark
    ; reopen = Automatic
    }
  ;;

  let validate t =
    let rec ascending = function
      | (a : Level.t) :: (b :: _ as rest) -> a.move_bps < b.move_bps && ascending rest
      | [ _ ] | [] -> true
    in
    let positive (l : Level.t) =
      l.move_bps > 0 && Option.value_map l.duration_ns ~default:true ~f:(fun d -> d > 0)
    in
    if (not (List.is_empty t.levels))
       && ascending t.levels
       && List.for_all t.levels ~f:positive
    then Ok ()
    else Or_error.error_s [%message "Halt_rule: invalid levels" (t : t)]
  ;;
end

let move_bps ~reference ~px =
  let r = Price.to_units reference in
  if r <= 0
  then 0
  else (
    let d = Int.abs (Price.to_units px - r) in
    (* Exact in integers for any realistic move; a float only past [int] range. *)
    if d <= Int.max_value / 10_000
    then d * 10_000 / r
    else Float.iround_down_exn (Float.of_int d *. 10_000. /. Float.of_int r))
;;

let level_to_trigger (c : Config.t) ~triggered ~reference ~px =
  let move = move_bps ~reference ~px in
  (* Fast path, taken on almost every order: the move is below the next level. *)
  let rec threshold (levels : Level.t list) i =
    match levels with
    | [] -> Int.max_value
    | l :: rest -> if i = 0 then l.move_bps else threshold rest (i - 1)
  in
  if move < threshold c.levels triggered
  then None
  else
    List.foldi c.levels ~init:None ~f:(fun i acc (l : Level.t) ->
      if i >= triggered && move >= l.move_bps then Some i else acc)
;;

let watches (c : Config.t) symbol =
  List.is_empty c.watch || List.mem c.watch symbol ~equal:Symbol.equal
;;
