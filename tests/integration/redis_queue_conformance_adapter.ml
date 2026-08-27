type t = Redis_queue.t
type queue = Redis_queue.Queue.t
type payload = Redis_queue.Payload.t
type error_kind = [ `Full | `Payload_too_large | `Closed | `Other ]

let make_queue _backend ~name ~max_depth ~max_payload_bytes =
  match Redis_queue.Queue.make ~name ~max_depth ~max_payload_bytes with
  | Ok queue -> queue
  | Error error ->
      failwith
        ("Redis conformance queue construction failed: "
        ^ Errors.Code.to_string (Redis_queue.error_code error))

let bytes = Redis_queue.Payload.bytes
let json = Redis_queue.Payload.json

let map_error error =
  match Errors.Code.to_string (Redis_queue.error_code error) with
  | "REDIS_QUEUE_FULL" -> `Full
  | "REDIS_PAYLOAD_TOO_LARGE" -> `Payload_too_large
  | "REDIS_STOPPING" | "REDIS_STOPPED" -> `Closed
  | _ -> `Other

let map_result result = Result.map_error map_error result

let enqueue backend queue payload =
  Lwt.map map_result (Redis_queue.enqueue backend queue payload)

let dequeue backend queue =
  Lwt.map map_result (Redis_queue.dequeue backend queue)

let payload_equal left right =
  match
    ( Redis_queue.Payload.bytes_value left,
      Redis_queue.Payload.bytes_value right,
      Redis_queue.Payload.json_value left,
      Redis_queue.Payload.json_value right )
  with
  | Some left, Some right, _, _ -> Bytes.equal left right
  | None, None, Some left, Some right -> left = right
  | _ -> false

let close _backend = Redis_queue.shutdown ()
