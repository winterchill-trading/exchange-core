open! Core
open! Exchange_core

module Kind = struct
  type t =
    | Collar_rejected of
        { side : Side.t
        ; limit_px : Price.t
        ; reference : Price.t
        ; bound : Price.t
        }
    | Collar_repriced of
        { side : Side.t
        ; limit_px : Price.t
        ; repriced_px : Price.t
        ; reference : Price.t
        }
    | Halt_rejected of { side : Side.t }
    | Halted of
        { trigger_symbol : Symbol.t
        ; level : int
        ; reference : Price.t
        ; px : Price.t
        ; move_bps : int
        ; until : int option
        }
    | Reopen_pending
    | Reopened
  [@@deriving sexp_of, compare, equal]
end

type t =
  { symbol : Symbol.t
  ; account : Account.t option
  ; order_id : Order_id.t option
  ; kind : Kind.t
  ; time : int
  ; before_seq : int
  }
[@@deriving sexp_of, compare, equal]

module Stats = struct
  type t =
    { collar_rejected : int
    ; collar_repriced : int
    ; collar_unreferenced : int
    ; halt_rejected : int
    ; halts : int
    ; reopens : int
    }
  [@@deriving sexp_of, compare, equal]

  let zero =
    { collar_rejected = 0
    ; collar_repriced = 0
    ; collar_unreferenced = 0
    ; halt_rejected = 0
    ; halts = 0
    ; reopens = 0
    }
  ;;
end
