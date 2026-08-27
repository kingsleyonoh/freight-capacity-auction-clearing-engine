let ( let* ) = Lwt.bind

type error = { code : Errors.Code.t; message : string }

let make_error code message =
  match Errors.Code.of_string code with
  | Ok code -> { code; message }
  | Error _ -> failwith "internal Redis error code is invalid"

let error_code error = error.code
let error_message error = error.message

let invalid_config =
  make_error "REDIS_INVALID_CONFIG" "Redis configuration is invalid"

let not_started = make_error "REDIS_NOT_STARTED" "Redis has not started"
let stopping = make_error "REDIS_STOPPING" "Redis is stopping"
let stopped = make_error "REDIS_STOPPED" "Redis has stopped"
let unavailable = make_error "REDIS_UNAVAILABLE" "Redis is unavailable"
let startup_failed = make_error "REDIS_STARTUP_FAILED" "Redis startup failed"
let queue_full = make_error "REDIS_QUEUE_FULL" "Redis queue is full"

let payload_too_large =
  make_error "REDIS_PAYLOAD_TOO_LARGE" "Redis payload exceeds its queue limit"

let poison_payload =
  make_error "REDIS_POISON_PAYLOAD" "Redis queue payload is malformed"

let protocol_error =
  make_error "REDIS_PROTOCOL_ERROR" "Redis returned an invalid response"

let valid_component ?(max_length = 96) value =
  let length = String.length value in
  length > 0 && length <= max_length
  && String.for_all
       (function
         | 'a' .. 'z' | '0' .. '9' | '-' | '_' | ':' -> true | _ -> false)
       value

module Queue = struct
  type t = { key : string; max_depth : int; max_payload_bytes : int }

  let make ~name ~max_depth ~max_payload_bytes =
    if
      (not (valid_component ~max_length:64 name))
      || max_depth < 1 || max_depth > 100_000 || max_payload_bytes < 1
      || max_payload_bytes > 1_048_576
    then Error invalid_config
    else Ok { key = "fca:v1:queue:" ^ name; max_depth; max_payload_bytes }
end

module Payload = struct
  type t = Bytes of bytes | Json of Yojson.Safe.t

  let bytes value = Bytes (Bytes.copy value)
  let json value = Json value

  let bytes_value = function
    | Bytes value -> Some (Bytes.copy value)
    | Json _ -> None

  let json_value = function Json value -> Some value | Bytes _ -> None
end

module Owner_token = struct
  type t = string

  let of_string value =
    if valid_component ~max_length:128 value && String.length value >= 8 then
      Ok value
    else Error invalid_config
end

module Lock = struct
  type t = { key : string }

  let make ~tenant_id ~resource =
    if valid_component resource then
      Ok
        {
          key =
            "fca:v1:lock:"
            ^ Tenant_context.Tenant_id.to_string tenant_id
            ^ ":" ^ resource;
        }
    else Error invalid_config
end

module Progress_stream = struct
  type t = { key : string; max_length : int }

  let make ~tenant_id ~job_id ~max_length =
    if valid_component job_id && max_length >= 1 && max_length <= 100_000 then
      Ok
        {
          key =
            "fca:v1:progress:"
            ^ Tenant_context.Tenant_id.to_string tenant_id
            ^ ":" ^ job_id;
          max_length;
        }
    else Error invalid_config
end

module Progress = struct
  type t = { state : string; completed : int option; total : int option }

  let option_for_all predicate = function
    | None -> true
    | Some value -> predicate value

  let make ~state ?completed ?total () =
    let counts_valid =
      option_for_all (fun value -> value >= 0) completed
      && option_for_all (fun value -> value >= 0) total
      &&
      match (completed, total) with
      | Some done_, Some all -> done_ <= all
      | _ -> true
    in
    if valid_component ~max_length:48 state && counts_valid then
      Ok { state; completed; total }
    else Error invalid_config

  let state value = value.state
  let completed value = value.completed
  let total value = value.total
end

type t = {
  connection : Redis_lwt.Client.connection;
  io_mutex : Lwt_mutex.t;
  mutable admitting : bool;
  mutable failed : bool;
  mutable in_flight : int;
  mutable zero_waiters : unit Lwt.u list;
  mutable disconnected : bool;
}

type lifecycle =
  | Cold
  | Starting of (t, error) result Lwt.t
  | Running of t
  | Stopping of unit Lwt.t
  | Stopped

let lifecycle_mutex = Lwt_mutex.create ()
let lifecycle = ref Cold

let get () =
  match !lifecycle with
  | Running handle when handle.admitting && not handle.failed -> Ok handle
  | Running _ -> Error unavailable
  | Cold | Starting _ -> Error not_started
  | Stopping _ -> Error stopping
  | Stopped -> Error stopped

let parse_database path =
  let normalized =
    if path = "" || path = "/" then "0"
    else String.sub path 1 (String.length path - 1)
  in
  match int_of_string_opt normalized with
  | Some value when value >= 0 && value <= 15 -> Some value
  | _ -> None

type credentials = No_auth | Password of string | Acl of string * string

let parse_credentials = function
  | None -> Ok No_auth
  | Some userinfo -> (
      let decoded = Uri.pct_decode userinfo in
      match String.index_opt decoded ':' with
      | None -> Error invalid_config
      | Some index ->
          let user = String.sub decoded 0 index in
          let password =
            String.sub decoded (index + 1) (String.length decoded - index - 1)
          in
          if password = "" then Error invalid_config
          else if user = "" then Ok (Password password)
          else Ok (Acl (user, password)))

let parse_uri uri =
  match
    (Uri.scheme uri, Uri.host uri, Uri.query uri, parse_database (Uri.path uri))
  with
  | Some "redis", Some host, [], Some database ->
      let port = Option.value ~default:6379 (Uri.port uri) in
      if port < 1 || port > 65_535 then Error invalid_config
      else
        Result.map
          (fun credentials -> (host, port, database, credentials))
          (parse_credentials (Uri.userinfo uri))
  | _ -> Error invalid_config

let authenticate connection = function
  | No_auth -> Lwt.return_unit
  | Password password -> Redis_lwt.Client.auth connection password
  | Acl (user, password) ->
      Redis_lwt.Client.auth_acl connection user password

let connect ~timeout_s uri =
  match parse_uri uri with
  | Error error -> Lwt.return (Error error)
  | Ok (host, port, database, credentials) ->
      let opened = ref None in
      let work () =
        let spec = Redis_lwt.Client.connection_spec ~port host in
        let* connection = Redis_lwt.Client.connect spec in
        opened := Some connection;
        let* () = authenticate connection credentials in
        let* () = Redis_lwt.Client.select connection database in
        let* pong = Redis_lwt.Client.ping connection in
        if pong then Lwt.return connection else Lwt.fail Exit
      in
      Lwt.catch
        (fun () ->
          let* connection = Lwt_unix.with_timeout timeout_s work in
          Lwt.return (Ok connection))
        (fun _ ->
          match !opened with
          | None -> Lwt.return (Error startup_failed)
          | Some connection ->
              let* () =
                Lwt.catch
                  (fun () -> Redis_lwt.Client.disconnect connection)
                  (fun _ -> Lwt.return_unit)
              in
              Lwt.return (Error startup_failed))

let publish_start promise_wakener result =
  let* () =
    Lwt_mutex.with_lock lifecycle_mutex (fun () ->
        (match result with
        | Ok handle -> lifecycle := Running handle
        | Error _ -> lifecycle := Cold);
        Lwt.wakeup_later promise_wakener result;
        Lwt.return_unit)
  in
  Lwt.return result

let start_new ~timeout_s uri promise_wakener =
  let* connection_result = connect ~timeout_s uri in
  let result =
    match connection_result with
    | Error error -> Error error
    | Ok connection ->
        Ok
          {
            connection;
            io_mutex = Lwt_mutex.create ();
            admitting = true;
            failed = false;
            in_flight = 0;
            zero_waiters = [];
            disconnected = false;
          }
  in
  publish_start promise_wakener result

let start ~timeout_s uri =
  if (not (Float.is_finite timeout_s)) || timeout_s <= 0.0 then
    Lwt.return (Error invalid_config)
  else
    let* action =
      Lwt_mutex.with_lock lifecycle_mutex (fun () ->
          match !lifecycle with
          | Running handle when handle.admitting && not handle.failed ->
              Lwt.return (`Return (Ok handle))
          | Running _ -> Lwt.return (`Return (Error unavailable))
          | Starting promise -> Lwt.return (`Wait promise)
          | Stopping _ -> Lwt.return (`Return (Error stopping))
          | Stopped -> Lwt.return (`Return (Error stopped))
          | Cold ->
              let promise, wakener = Lwt.wait () in
              lifecycle := Starting promise;
              Lwt.return (`Start wakener))
    in
    match action with
    | `Return result -> Lwt.return result
    | `Wait promise -> promise
    | `Start wakener -> start_new ~timeout_s uri wakener

let admit handle =
  Lwt_mutex.with_lock lifecycle_mutex (fun () ->
      match !lifecycle with
      | Running current
        when current == handle && handle.admitting && not handle.failed ->
          handle.in_flight <- handle.in_flight + 1;
          Lwt.return (Ok ())
      | Running _ -> Lwt.return (Error unavailable)
      | Cold | Starting _ -> Lwt.return (Error not_started)
      | Stopping _ -> Lwt.return (Error stopping)
      | Stopped -> Lwt.return (Error stopped))

let finish handle =
  Lwt_mutex.with_lock lifecycle_mutex (fun () ->
      handle.in_flight <- max 0 (handle.in_flight - 1);
      if handle.in_flight = 0 then begin
        List.iter
          (fun wakener -> Lwt.wakeup_later wakener ())
          handle.zero_waiters;
        handle.zero_waiters <- []
      end;
      Lwt.return_unit)

let fail_closed handle =
  Lwt_mutex.with_lock lifecycle_mutex (fun () ->
      handle.failed <- true;
      handle.admitting <- false;
      Lwt.return_unit)

let protocol_failure handle =
  let* () = fail_closed handle in
  Lwt.return (Error protocol_error)

let use handle operation =
  let* admitted = admit handle in
  match admitted with
  | Error error -> Lwt.return (Error error)
  | Ok () ->
      Lwt.finalize
        (fun () ->
          Lwt.catch
            (fun () ->
              Lwt_mutex.with_lock handle.io_mutex (fun () ->
                  let* value = operation handle.connection in
                  Lwt.return (Ok value)))
            (fun _ ->
              let* () = fail_closed handle in
              Lwt.return (Error unavailable)))
        (fun () -> finish handle)

let encode_payload = function
  | Payload.Bytes value -> "b:" ^ Bytes.to_string value
  | Payload.Json value -> "j:" ^ Yojson.Safe.to_string value

let decode_payload value =
  if String.starts_with ~prefix:"b:" value then
    Ok
      (Payload.Bytes
         (Bytes.of_string (String.sub value 2 (String.length value - 2))))
  else if String.starts_with ~prefix:"j:" value then
    let encoded = String.sub value 2 (String.length value - 2) in
    try Ok (Payload.Json (Yojson.Safe.from_string encoded))
    with Yojson.Json_error _ -> Error poison_payload
  else Error poison_payload

let enqueue_script =
  "if redis.call('LLEN',KEYS[1]) >= tonumber(ARGV[1]) then return 0 "
  ^ "else redis.call('RPUSH',KEYS[1],ARGV[2]); return 1 end"

let enqueue handle queue payload =
  let encoded = encode_payload payload in
  if String.length encoded - 2 > queue.Queue.max_payload_bytes then
    Lwt.return (Error payload_too_large)
  else
    let* result =
      use handle (fun connection ->
          Redis_lwt.Client.eval connection enqueue_script [ queue.key ]
            [ string_of_int queue.max_depth; encoded ])
    in
    match result with
    | Ok (`Int 1 | `Int64 1L) -> Lwt.return (Ok ())
    | Ok (`Int 0 | `Int64 0L) -> Lwt.return (Error queue_full)
    | Ok _ -> protocol_failure handle
    | Error error -> Lwt.return (Error error)

let dequeue handle queue =
  let* result =
    use handle (fun connection ->
        Redis_lwt.Client.lpop connection queue.Queue.key)
  in
  match result with
  | Error error -> Lwt.return (Error error)
  | Ok None -> Lwt.return (Ok None)
  | Ok (Some value) ->
      Lwt.return (Result.map Option.some (decode_payload value))

let valid_ttl ttl_ms = ttl_ms >= 10 && ttl_ms <= 86_400_000

let acquire handle lock ~owner ~ttl_ms =
  if not (valid_ttl ttl_ms) then Lwt.return (Error invalid_config)
  else
    use handle (fun connection ->
        Redis_lwt.Client.set connection ~px:ttl_ms ~nx:true lock.Lock.key owner)

let renew_script =
  "if redis.call('GET',KEYS[1]) == ARGV[1] then "
  ^ "return redis.call('PEXPIRE',KEYS[1],ARGV[2]) else return 0 end"

let release_script =
  "if redis.call('GET',KEYS[1]) == ARGV[1] then "
  ^ "return redis.call('DEL',KEYS[1]) else return 0 end"

let eval_owner handle script lock owner args =
  let* result =
    use handle (fun connection ->
        Redis_lwt.Client.eval connection script [ lock.Lock.key ] (owner :: args))
  in
  match result with
  | Ok (`Int 1 | `Int64 1L) -> Lwt.return (Ok true)
  | Ok (`Int 0 | `Int64 0L) -> Lwt.return (Ok false)
  | Ok _ -> protocol_failure handle
  | Error error -> Lwt.return (Error error)

let renew handle lock ~owner ~ttl_ms =
  if not (valid_ttl ttl_ms) then Lwt.return (Error invalid_config)
  else
    let* result =
      eval_owner handle renew_script lock owner [ string_of_int ttl_ms ]
    in
    Lwt.return
      (Result.map (fun value -> if value then `Renewed else `Not_owner) result)

let release handle lock ~owner =
  let* result = eval_owner handle release_script lock owner [] in
  Lwt.return
    (Result.map (fun value -> if value then `Released else `Not_owner) result)

let encode_optional = function None -> "-" | Some value -> string_of_int value

let append_progress handle stream progress =
  let command =
    [
      "XADD";
      stream.Progress_stream.key;
      "MAXLEN";
      "~";
      string_of_int stream.max_length;
      "*";
      "state";
      progress.Progress.state;
      "completed";
      encode_optional progress.completed;
      "total";
      encode_optional progress.total;
    ]
  in
  let* result =
    use handle (fun connection ->
        Redis_lwt.Client.send_custom_request connection command)
  in
  match result with
  | Ok (`Bulk (Some id)) -> Lwt.return (Ok id)
  | Ok _ -> protocol_failure handle
  | Error error -> Lwt.return (Error error)

let parse_optional value =
  if value = "-" then Some None
  else Option.map Option.some (int_of_string_opt value)

let parse_progress fields =
  match
    ( List.assoc_opt "state" fields,
      List.assoc_opt "completed" fields,
      List.assoc_opt "total" fields )
  with
  | Some state, Some completed, Some total -> (
      match (parse_optional completed, parse_optional total) with
      | Some completed, Some total -> Progress.make ~state ?completed ?total ()
      | _ -> Error poison_payload)
  | _ -> Error poison_payload

let read_progress handle stream ~after ~limit =
  if limit < 1 || limit > 1_000 then Lwt.return (Error invalid_config)
  else
    let cursor =
      match after with None -> `After "0-0" | Some id -> `After id
    in
    let* result =
      use handle (fun connection ->
          Redis_lwt.Client.xread connection ~count:limit
            [ (stream.Progress_stream.key, cursor) ])
    in
    match result with
    | Error error -> Lwt.return (Error error)
    | Ok streams ->
        let events =
          Option.value ~default:[] (List.assoc_opt stream.key streams)
        in
        let rec decode acc = function
          | [] -> Ok (List.rev acc)
          | (id, fields) :: rest -> (
              match parse_progress fields with
              | Ok progress -> decode ((id, progress) :: acc) rest
              | Error error -> Error error)
        in
        Lwt.return (decode [] events)

let wait_for_zero handle =
  Lwt_mutex.with_lock lifecycle_mutex (fun () ->
      if handle.in_flight = 0 then Lwt.return `Ready
      else
        let promise, wakener = Lwt.wait () in
        handle.zero_waiters <- wakener :: handle.zero_waiters;
        Lwt.return (`Wait promise))

let disconnect_once handle =
  let* wait = wait_for_zero handle in
  let* () =
    match wait with `Ready -> Lwt.return_unit | `Wait promise -> promise
  in
  let* () =
    Lwt_mutex.with_lock handle.io_mutex (fun () ->
        if handle.disconnected then Lwt.return_unit
        else begin
          handle.disconnected <- true;
          Lwt.catch
            (fun () -> Redis_lwt.Client.disconnect handle.connection)
            (fun _ -> Lwt.return_unit)
        end)
  in
  Lwt_mutex.with_lock lifecycle_mutex (fun () ->
      lifecycle := Stopped;
      Lwt.return_unit)

let rec shutdown () =
  let* action =
    Lwt_mutex.with_lock lifecycle_mutex (fun () ->
        match !lifecycle with
        | Stopped | Cold ->
            lifecycle := Stopped;
            Lwt.return `Done
        | Stopping promise -> Lwt.return (`Wait promise)
        | Starting promise -> Lwt.return (`Starting promise)
        | Running handle ->
            handle.admitting <- false;
            let promise = disconnect_once handle in
            lifecycle := Stopping promise;
            Lwt.return (`Wait promise))
  in
  match action with
  | `Done -> Lwt.return_unit
  | `Wait promise -> promise
  | `Starting promise ->
      let* _ = promise in
      shutdown ()
