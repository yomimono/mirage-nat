type direction =
  | Source
  | Destination

type protocol =
  | Udp
  | Tcp

type port = Cstruct.uint16
type endpoint = (Ipaddr.t * port)
type mapping = (endpoint * endpoint)

type translation = {
  internal_lookup: mapping;
  external_lookup: mapping;
  internal_mapping: mapping;
  external_mapping: mapping
}

type mode =
  | Redirect
  | Nat

type translate_result =
  | Translated
  | Untranslated

module type CLOCK = sig
  val now : unit -> int64
end

module type TIME = sig
  val sleep : float -> unit Lwt.t
end
module type S = sig
  type t

  type insert_result =
    | Ok
    | Overlap
    | Unparseable

  val empty : unit -> t Lwt.t

  (** given a lookup table, rewrite direction, and an ip-level frame,
    * perform any translation indicated by presence in the table
    * on the Cstruct.t .  If the packet should be forwarded, return Some packet,
    * else return None.
    * This function is zero-copy and mutates values in the given Cstruct.  *)
  val translate : t -> direction -> Cstruct.t -> translate_result Lwt.t

  (** given a table, a frame, and a translation IP and port,
    * put relevant entries for the (src_ip, src_port), (dst_ip, dst_port) from the
    * frame and given (xl_ip, xl_port).
      entries will look like:
      ((src_ip, src_port), (dst_ip, dst_port) to
         (xl_ip, xl_port), (dst_ip, dst_port)) and
      ((dst_ip, dst_port), (xl_ip, xl_port)) to
         (dst_ip, dst_port), (src_ip, src_port)).
    * if insertion succeeded, return the new table;
    * otherwise, return an error type indicating the problem. *)
  val add_nat : t -> Cstruct.t -> endpoint -> insert_result Lwt.t

  (** given a table, a frame from which (src_ip, src_port) and (xl_left_ip,
      xl_left_port) can be extracted (these are source and destination for the
      packet), a translation (xl_left_ip, xl_left_port) pair, and a final
      destination (dst_ip, dst_port) pair, add entries to table of the form:
      ((src_ip, src_port), (xl_left_ip, xl_left_port)) to
           ((xl_right_ip, xl_right_port), (dst_ip, dst_port)) and
      ((dst_ip, dst_port), (xl_right_ip, xl_right_port)) to
           ((xl_left_ip, xl_left_port), (src_ip, src_port)).
      ((xl_ip, xl_right_port), (dst_ip, dst_port)) to (src_ip, src_port).
    * if insertion succeeded, return the new table;
    * otherwise, return an error type indicating the problem. *)
  val add_redirect : t -> Cstruct.t -> endpoint -> endpoint -> insert_result Lwt.t
end

(* phantom types for Cstructs, so type system can help us keep them straight *)
type transport = Nat_decompose.transport
type ethernet = Nat_decompose.ethernet
type ip = Nat_decompose.ip
type 'a layer = 'a Nat_decompose.layer

(* given a function for recalculating transport-layer checksums and an (ip,
   transport) pair, recalculate and set checksum for valid-looking udp or tcp
   packets.

   Return a tuple of (ethernet and IP headers only, transport layer)
   for dispatch to I.write .
*)

val recalculate_transport_checksum : (Cstruct.t -> Cstruct.t list -> int) ->
  (ethernet layer * ip layer * transport layer)
  -> (Cstruct.t * Cstruct.t)

(* set the ethernet source address to the provided MAC address *)
val set_smac : ethernet layer -> Macaddr.t -> ethernet layer

(* support for direct rewriting of packets *)
val rewrite_ip : bool -> ip layer -> direction -> (Ipaddr.t * Ipaddr.t) -> unit

val rewrite_port : transport layer -> direction -> (int * int) -> unit

module type Lookup = sig
  type t 

  val lookup : t -> protocol -> source:endpoint -> destination:endpoint ->
    (int64 * mapping) option Lwt.t

  val insert : t -> int -> protocol -> translation -> t option Lwt.t

  val delete : t -> protocol ->
    internal_lookup:mapping ->
    external_lookup:mapping -> t Lwt.t

  val empty : unit -> t Lwt.t
end
