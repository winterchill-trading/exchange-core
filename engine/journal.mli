(** A binary log of an exchange's inputs, for replaying a run.

    The file starts with an 8-byte magic string, followed by one [bin_prot]-encoded
    {!Input.t} per request, in the order they were performed. Values are self-delimiting,
    so there is no per-record header. A crash can leave a truncated last record; {!load}
    reports it as an error.

    Settings that are not part of {!Exchange.Config.t} (the self-trade policy) go in a
    {!Header}. A journal with the default header is written as [magic] and inputs, exactly
    as before headers existed; any other header is written as [magic_with_header], the
    [bin_prot]-encoded header, then the inputs. A journal without a header reads as
    [Header.default]. *)

open! Core

module Header : sig
  type t = { self_trade : Order_book.Stp.t (** of the journalled exchange *) }
  [@@deriving sexp_of, equal]

  (** [Order_book.Stp.default]. *)
  val default : t
end

(** {2 Writing} *)

type t

(** Creates (or truncates) the file and writes the magic string and [header] (default
    {!Header.default}), which should describe the exchange the journal is attached to. *)
val create : ?header:Header.t -> string -> t

val write : t -> Input.t -> unit

(** Writes every request the exchange performs from now on. Raises if the exchange's
    self-trade policy is not the header's. *)
val attach : t -> Exchange.t -> unit

(** Number of inputs written so far. *)
val length : t -> int

val flush : t -> unit
val close : t -> unit

(** {2 Reading and replaying} *)

(** Magic string of a journal with the default header ("EXJRNL01"). *)
val magic : string

(** Magic string of a journal followed by a header ("EXJRNL02"). *)
val magic_with_header : string

(** Encodes inputs as a journal file's contents (magic string and header included). *)
val to_string : ?header:Header.t -> Input.t list -> string

(** The inputs of a journal, either format; the header is dropped. *)
val of_string : string -> Input.t list Or_error.t

val of_string_with_header : string -> (Header.t * Input.t list) Or_error.t

(** Reads a journal file. *)
val load : string -> Input.t list Or_error.t

val load_with_header : string -> (Header.t * Input.t list) Or_error.t

(** Applies the inputs, in order, to a new exchange created with [config] (default
    {!Exchange.Config.default}) and [header]'s self-trade policy (default
    {!Header.default}). Both must be those of the journalled exchange. *)
val replay : ?config:Exchange.Config.t -> ?header:Header.t -> Input.t list -> Exchange.t
