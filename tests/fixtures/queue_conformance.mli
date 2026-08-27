module type QUEUE_BACKEND = sig
  type t
  type queue
  type payload
  type error_kind = [ `Full | `Payload_too_large | `Closed | `Other ]

  val make_queue :
    t -> name:string -> max_depth:int -> max_payload_bytes:int -> queue

  val bytes : bytes -> payload
  val json : Yojson.Safe.t -> payload
  val enqueue : t -> queue -> payload -> (unit, error_kind) result Lwt.t
  val dequeue : t -> queue -> (payload option, error_kind) result Lwt.t
  val payload_equal : payload -> payload -> bool
  val close : t -> unit Lwt.t
end

type 'backend case = { name : string; run : 'backend -> unit Lwt.t }

module Make (Backend : QUEUE_BACKEND) : sig
  val cases : Backend.t case list
end
