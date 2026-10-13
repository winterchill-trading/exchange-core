open! Core

let magic = "EXJRNL01"
let magic_with_header = "EXJRNL02"
let magic_with_header_v3 = "EXJRNL03"

module Header = struct
  type t =
    { self_trade : Order_book.Stp.t
    ; book_liquidation : Book_liquidation.Config.t option
    }
  [@@deriving sexp_of, equal]

  let default = { self_trade = Order_book.Stp.default; book_liquidation = None }

  let create ?(self_trade = default.self_trade) ?book_liquidation () =
    { self_trade; book_liquidation }
  ;;

  let of_exchange exchange =
    { self_trade = Exchange.self_trade exchange
    ; book_liquidation = Exchange.book_liquidation exchange
    }
  ;;

  (* The file encoding, kept apart from [Order_book.Stp.t]: bin_prot writes a variant as
     its constructor index, so constructors are only ever appended here. *)
  module Wire = struct
    type stp =
      | Cancel_taker
      | Expire_maker
      | Cancel_both
    [@@deriving bin_io]

    type t = { self_trade : stp } [@@deriving bin_io]

    (* The "EXJRNL03" header: the "EXJRNL02" one plus book liquidation. *)
    type book_liquidation =
      { liquidator : string
      ; partial_above : int
      ; partial_fraction : float
      ; cooldown_ns : int
      ; backstop_fraction : float
      }
    [@@deriving bin_io]

    type v3 =
      { self_trade : stp
      ; book_liquidation : book_liquidation option
      }
    [@@deriving bin_io]
  end

  let stp_to_wire : Order_book.Stp.t -> Wire.stp = function
    | Cancel_taker -> Cancel_taker
    | Expire_maker -> Expire_maker
    | Cancel_both -> Cancel_both
  ;;

  let stp_of_wire : Wire.stp -> Order_book.Stp.t = function
    | Cancel_taker -> Cancel_taker
    | Expire_maker -> Expire_maker
    | Cancel_both -> Cancel_both
  ;;

  let to_wire t : Wire.t = { self_trade = stp_to_wire t.self_trade }

  let of_wire ({ self_trade } : Wire.t) =
    { default with self_trade = stp_of_wire self_trade }
  ;;

  let to_wire_v3 t : Wire.v3 =
    { self_trade = stp_to_wire t.self_trade
    ; book_liquidation =
        Option.map t.book_liquidation ~f:(fun (c : Book_liquidation.Config.t) ->
          { Wire.liquidator = Exchange_core.Account.to_string c.liquidator
          ; partial_above = Exchange_core.Usd.to_units c.partial_above
          ; partial_fraction = c.partial_fraction
          ; cooldown_ns = Time_ns.Span.to_int_ns c.cooldown
          ; backstop_fraction = c.backstop_fraction
          })
    }
  ;;

  let of_wire_v3 ({ self_trade; book_liquidation } : Wire.v3) =
    { self_trade = stp_of_wire self_trade
    ; book_liquidation =
        Option.map book_liquidation ~f:(fun (w : Wire.book_liquidation) ->
          { Book_liquidation.Config.liquidator =
              Exchange_core.Account.of_string w.liquidator
          ; partial_above = Exchange_core.Usd.of_units w.partial_above
          ; partial_fraction = w.partial_fraction
          ; cooldown = Time_ns.Span.of_int_ns w.cooldown_ns
          ; backstop_fraction = w.backstop_fraction
          })
    }
  ;;

  (* A default header is not written, so such journals stay byte-identical to the
     headerless format, and one without book liquidation keeps the "EXJRNL02" form. *)
  let prefix t =
    if equal t default
    then magic
    else if Option.is_none t.book_liquidation
    then magic_with_header ^ Binable.to_string (module Wire) (to_wire t)
    else
      magic_with_header_v3
      ^ Binable.to_string
          (module struct
            type t = Wire.v3 [@@deriving bin_io]
          end)
          (to_wire_v3 t)
  ;;
end

type t =
  { out : Out_channel.t
  ; header : Header.t
  ; mutable length : int
  }

let create ?(header = Header.default) path =
  let out = Out_channel.create ~binary:true path in
  Out_channel.output_string out (Header.prefix header);
  { out; header; length = 0 }
;;

let write t input =
  Out_channel.output_string t.out (Binable.to_string (module Input) input);
  t.length <- t.length + 1
;;

let attach t exchange =
  let self_trade = Exchange.self_trade exchange in
  if not (Order_book.Stp.equal self_trade t.header.self_trade)
  then
    raise_s
      [%message
        "Journal.attach: the exchange's self-trade policy differs from the header"
          (self_trade : Order_book.Stp.t)
          (t.header : Header.t)];
  let book_liquidation = Exchange.book_liquidation exchange in
  if not
       ([%equal: Book_liquidation.Config.t option]
          book_liquidation
          t.header.book_liquidation)
  then
    raise_s
      [%message
        "Journal.attach: the exchange's book liquidation differs from the header"
          (book_liquidation : Book_liquidation.Config.t option)
          (t.header : Header.t)];
  Exchange.record_inputs exchange ~f:(write t)
;;

let length t = t.length
let flush t = Out_channel.flush t.out
let close t = Out_channel.close t.out

let to_string ?(header = Header.default) inputs =
  let buf = Buffer.create 4096 in
  Buffer.add_string buf (Header.prefix header);
  List.iter inputs ~f:(fun input ->
    Buffer.add_string buf (Binable.to_string (module Input) input));
  Buffer.contents buf
;;

let of_string_with_header s =
  let magic_len = String.length magic in
  let has prefix = String.is_prefix s ~prefix in
  let buf = Bigstring.of_string s in
  let pos_ref = ref magic_len in
  let header =
    if has magic
    then Ok Header.default
    else if has magic_with_header
    then (
      match Header.Wire.bin_read_t buf ~pos_ref with
      | wire -> Ok (Header.of_wire wire)
      | exception exn ->
        Or_error.error_s [%message "Journal: unreadable header" (exn : exn)])
    else if has magic_with_header_v3
    then (
      match Header.Wire.bin_read_v3 buf ~pos_ref with
      | wire -> Ok (Header.of_wire_v3 wire)
      | exception exn ->
        Or_error.error_s [%message "Journal: unreadable header" (exn : exn)])
    else Or_error.error_string "Journal: missing magic string"
  in
  Or_error.bind header ~f:(fun header ->
    let len = Bigstring.length buf in
    let rec loop acc =
      if !pos_ref >= len
      then Ok (List.rev acc)
      else (
        let start = !pos_ref in
        match Input.bin_read_t buf ~pos_ref with
        | input -> loop (input :: acc)
        | exception exn ->
          Or_error.error_s
            [%message
              "Journal: unreadable record"
                ~offset:(start : int)
                ~records_read:(List.length acc : int)
                (exn : exn)])
    in
    Or_error.map (loop []) ~f:(fun inputs -> header, inputs))
;;

let of_string s = Or_error.map (of_string_with_header s) ~f:snd

let load_with_header path =
  Or_error.bind
    (Or_error.try_with (fun () -> In_channel.read_all path))
    ~f:of_string_with_header
;;

let load path = Or_error.map (load_with_header path) ~f:snd

let replay ?config ?(header = Header.default) inputs =
  let exchange =
    Exchange.create
      ?config
      ~self_trade:header.self_trade
      ?book_liquidation:header.book_liquidation
      ()
  in
  List.iter inputs ~f:(Exchange.apply exchange);
  exchange
;;
