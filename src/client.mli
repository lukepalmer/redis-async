(** A connection to a Redis and low-level methods for interaction *)

open Core
open Async

type 'a t

module Make (Key : Bulk_io_intf.S) (Value : Bulk_io_intf.S) : sig
  module Key_parser   : Parse_bulk_intf.S with type t := Key.t
  module Value_parser : Parse_bulk_intf.S with type t := Value.t

  val create
    :  ?on_disconnect:(unit -> unit)
    -> where_to_connect:[< Socket.Address.t ] Tcp.Where_to_connect.t
    -> unit
    -> Key.t t Deferred.Or_error.t

  val close : Key.t t -> unit Deferred.t

  (** Send a command built from strings to Redis and expect a Response of the specified
      kind.

      All Redis commands are arrays of strings (keeping in mind that strings are the same
      as byte arrays) so this is the most general form. *)
  val command_string
    :  Key.t t
    -> string list
    -> (module Response_intf.S with type t = 'r)
    -> 'r Deferred.Or_error.t

  (** Send a command built from strings followed by serialized [Key.t]s to Redis and
      expect a Response of the specified kind. *)
  val command_key
    :  Key.t t
    -> ?result_of_empty_input:'r Or_error.t
    -> string list
    -> Key.t list
    -> (module Response_intf.S with type t = 'r)
    -> 'r Deferred.Or_error.t

  (** Send a command built from strings followed by serialized [Key.t]s, followed by
      serialized [Value.t]s to Redis and expect a Response of the specified kind. *)
  val command_keys_values
    :  Key.t t
    -> ?result_of_empty_input:'r Or_error.t
    -> string list
    -> Key.t list
    -> Value.t list
    -> (module Response_intf.S with type t = 'r)
    -> 'r Deferred.Or_error.t

  (** Send a command built from strings followed by an associative list of interleaved
      [Key.t]s and [Value.t]s to Redis and expect a Response of the specified kind. *)
  val command_kv
    :  Key.t t
    -> ?result_of_empty_input:'r Or_error.t
    -> string list
    -> (Key.t, Value.t) List.Assoc.t
    -> (module Response_intf.S with type t = 'r)
    -> 'r Deferred.Or_error.t

  (** Turn on Redis client tracking and provide a pipe of invalidation messages received
      from the server. Closing the pipe turns tracking off.

      Read here for more on usage:
      https://redis.io/commands/client-tracking
      https://redis.io/topics/client-side-caching

      @param bcast Whether to use broadcast mode. Off by default.
  *)
  val client_tracking
    :  Key.t t
    -> ?bcast:bool
    -> unit
    -> [ `All | `Key of Key.t ] Pipe.Reader.t Deferred.Or_error.t
end
