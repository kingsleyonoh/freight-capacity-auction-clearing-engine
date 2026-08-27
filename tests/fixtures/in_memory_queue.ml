type payload = Bytes of bytes | Json of Yojson.Safe.t
type error_kind = [ `Full | `Payload_too_large | `Closed | `Other ]
type t = { mutex : Lwt_mutex.t; mutable closed : bool }

type queue = {
  owner : t;
  max_depth : int;
  max_payload_bytes : int;
  items : payload Queue.t;
}

let create () = { mutex = Lwt_mutex.create (); closed = false }

let make_queue owner ~name:_ ~max_depth ~max_payload_bytes =
  if max_depth < 1 || max_payload_bytes < 1 then
    invalid_arg "invalid queue limits";
  { owner; max_depth; max_payload_bytes; items = Queue.create () }

let copy_json value = Yojson.Safe.from_string (Yojson.Safe.to_string value)

let copy_payload = function
  | Bytes value -> Bytes (Bytes.copy value)
  | Json value -> Json (copy_json value)

let bytes value = Bytes (Bytes.copy value)
let json value = Json (copy_json value)

let payload_size = function
  | Bytes value -> Bytes.length value
  | Json value -> String.length (Yojson.Safe.to_string value)

let payload_equal left right =
  match (left, right) with
  | Bytes left, Bytes right -> Bytes.equal left right
  | Json left, Json right -> left = right
  | Bytes _, Json _ | Json _, Bytes _ -> false

let valid_owner backend queue = backend == queue.owner

let enqueue backend queue payload =
  Lwt_mutex.with_lock backend.mutex (fun () ->
      if not (valid_owner backend queue) then Lwt.return (Error `Other)
      else if backend.closed then Lwt.return (Error `Closed)
      else if payload_size payload > queue.max_payload_bytes then
        Lwt.return (Error `Payload_too_large)
      else if Queue.length queue.items >= queue.max_depth then
        Lwt.return (Error `Full)
      else begin
        Queue.push (copy_payload payload) queue.items;
        Lwt.return (Ok ())
      end)

let dequeue backend queue =
  Lwt_mutex.with_lock backend.mutex (fun () ->
      if not (valid_owner backend queue) then Lwt.return (Error `Other)
      else if backend.closed then Lwt.return (Error `Closed)
      else
        match Queue.take_opt queue.items with
        | None -> Lwt.return (Ok None)
        | Some payload -> Lwt.return (Ok (Some (copy_payload payload))))

let close backend =
  Lwt_mutex.with_lock backend.mutex (fun () ->
      backend.closed <- true;
      Lwt.return_unit)
