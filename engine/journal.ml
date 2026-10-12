open! Core

let magic = "EXJRNL01"

type t =
  { out : Out_channel.t
  ; mutable length : int
  }

let create path =
  let out = Out_channel.create ~binary:true path in
  Out_channel.output_string out magic;
  { out; length = 0 }
;;

let write t input =
  Out_channel.output_string t.out (Binable.to_string (module Input) input);
  t.length <- t.length + 1
;;

let attach t exchange = Exchange.record_inputs exchange ~f:(write t)
let length t = t.length
let flush t = Out_channel.flush t.out
let close t = Out_channel.close t.out

let to_string inputs =
  let buf = Buffer.create 4096 in
  Buffer.add_string buf magic;
  List.iter inputs ~f:(fun input ->
    Buffer.add_string buf (Binable.to_string (module Input) input));
  Buffer.contents buf
;;

let of_string s =
  let magic_len = String.length magic in
  if String.length s < magic_len || not (String.equal (String.prefix s magic_len) magic)
  then Or_error.error_string "Journal: missing magic string"
  else (
    let buf = Bigstring.of_string s in
    let len = Bigstring.length buf in
    let pos_ref = ref magic_len in
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
    loop [])
;;

let load path =
  Or_error.bind (Or_error.try_with (fun () -> In_channel.read_all path)) ~f:of_string
;;

let replay ?config inputs =
  let exchange = Exchange.create ?config () in
  List.iter inputs ~f:(Exchange.apply exchange);
  exchange
;;
