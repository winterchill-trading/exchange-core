open! Core

let magic = "EXJRNL01"
let magic_with_header = "EXJRNL02"

module Header = struct
  type t = { self_trade : Order_book.Stp.t } [@@deriving sexp_of, equal]

  let default = { self_trade = Order_book.Stp.default }

  (* The file encoding, kept apart from [Order_book.Stp.t]: bin_prot writes a variant as
     its constructor index, so constructors are only ever appended here. *)
  module Wire = struct
    type stp =
      | Cancel_taker
      | Expire_maker
      | Cancel_both
    [@@deriving bin_io]

    type t = { self_trade : stp } [@@deriving bin_io]
  end

  let to_wire { self_trade } : Wire.t =
    { self_trade =
        (match self_trade with
         | Cancel_taker -> Cancel_taker
         | Expire_maker -> Expire_maker
         | Cancel_both -> Cancel_both)
    }
  ;;

  let of_wire ({ self_trade } : Wire.t) =
    { self_trade =
        (match self_trade with
         | Cancel_taker -> Cancel_taker
         | Expire_maker -> Expire_maker
         | Cancel_both -> Cancel_both)
    }
  ;;

  (* A default header is not written, so such journals stay byte-identical to the
     headerless format. *)
  let prefix t =
    if equal t default
    then magic
    else magic_with_header ^ Binable.to_string (module Wire) (to_wire t)
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
  let exchange = Exchange.create ?config ~self_trade:header.self_trade () in
  List.iter inputs ~f:(Exchange.apply exchange);
  exchange
;;
