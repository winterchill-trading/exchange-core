(** A binary log of an exchange's inputs, for replaying a run.

    The file starts with an 8-byte magic string, followed by one [bin_prot]-encoded
    {!Input.t} per request, in the order they were performed. Values are self-delimiting,
    so there is no per-record header. A crash can leave a truncated last record; {!load}
    reports it as an error. *)

open! Core

(** {2 Writing} *)

type t

(** Creates (or truncates) the file and writes the magic string. *)
val create : string -> t

val write : t -> Input.t -> unit

(** Writes every request the exchange performs from now on. *)
val attach : t -> Exchange.t -> unit

(** Number of inputs written so far. *)
val length : t -> int

val flush : t -> unit
val close : t -> unit

(** {2 Reading and replaying} *)

val magic : string

(** Encodes inputs as a journal file's contents (magic string included). *)
val to_string : Input.t list -> string

val of_string : string -> Input.t list Or_error.t

(** Reads a journal file. *)
val load : string -> Input.t list Or_error.t

(** Applies the inputs, in order, to a new exchange created with [config] (default
    {!Exchange.Config.default}). The configuration must be the one the journalled exchange
    was created with. *)
val replay : ?config:Exchange.Config.t -> Input.t list -> Exchange.t
