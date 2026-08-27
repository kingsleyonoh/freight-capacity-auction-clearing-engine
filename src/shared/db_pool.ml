let ( let* ) = Lwt.bind

type pool =
  (Caqti_lwt.connection, Caqti_error.t) Caqti_lwt_unix.Pool.t

type t = { pool : pool }

type error = {
  code : Errors.Code.t;
  message : string;
}

type startup = { promise : (t, error) result Lwt.t }

type state =
  | Cold
  | Starting of startup
  | Running of t
  | Stopping of unit Lwt.t
  | Stopped

let code constant =
  match Errors.Code.of_string constant with
  | Ok value -> value
  | Error _ -> invalid_arg "Db_pool has an invalid internal error code"

let error code_value message = { code = code code_value; message }

let not_started = error "DATABASE_POOL_NOT_STARTED" "Database pool has not started"
let starting = error "DATABASE_POOL_STARTING" "Database pool is starting"
let stopping = error "DATABASE_POOL_STOPPING" "Database pool is stopping"
let stopped = error "DATABASE_POOL_STOPPED" "Database pool is stopped"
let invalid_size = error "DATABASE_POOL_INVALID_SIZE" "Database pool size must be positive"
let startup_failed = error "DATABASE_STARTUP_FAILED" "Database startup failed"
let operation_failed = error "DATABASE_OPERATION_FAILED" "Database operation failed"
let operation_not_found = error "DATABASE_OPERATION_NOT_FOUND" "Database row was not found"

let error_code value = value.code
let error_message value = value.message

let mutex = Lwt_mutex.create ()
let idle = Lwt_condition.create ()
let lifecycle = ref Cold
let active_uses = ref 0

let health_request =
  let open Caqti_request.Infix in
  (Caqti_type.int -->! Caqti_type.int) @:- "SELECT ?"

let drain pool =
  Lwt.catch
    (fun () -> Caqti_lwt_unix.Pool.drain pool)
    (fun _ -> Lwt.return_unit)

let health_check pool =
  Caqti_lwt_unix.Pool.use
    (fun (module Connection : Caqti_lwt.CONNECTION) ->
      Connection.find health_request 1)
    pool

let open_healthy_pool uri max_size =
  Lwt.catch
    (fun () ->
      let pool_config =
        Caqti_pool_config.create ~max_size ~max_idle_size:max_size
          ~max_idle_age:None ~max_use_count:None ()
      in
      match Caqti_lwt_unix.connect_pool ~pool_config uri with
      | Error _ -> Lwt.return (Error startup_failed)
      | Ok connected_pool ->
          let pool : pool = (connected_pool :> pool) in
          Lwt.catch
            (fun () ->
              let* health = health_check pool in
              match health with
              | Ok 1 -> Lwt.return (Ok { pool })
              | Ok _ | Error _ ->
                  let* () = drain pool in
                  Lwt.return (Error startup_failed))
            (fun _ ->
              let* () = drain pool in
              Lwt.return (Error startup_failed)))
    (fun _ -> Lwt.return (Error startup_failed))

let same_startup left right = left.promise == right.promise

let publish_start startup result =
  Lwt_mutex.with_lock mutex (fun () ->
      match !lifecycle, result with
      | Starting current, Ok handle when same_startup current startup ->
          lifecycle := Running handle;
          Lwt.return (`Return (Ok handle))
      | Starting current, Error failure when same_startup current startup ->
          lifecycle := Cold;
          Lwt.return (`Return (Error failure))
      | Stopping _, Ok handle -> Lwt.return (`Drain_interrupted handle)
      | Stopping _, Error failure -> Lwt.return (`Return (Error failure))
      | _, Ok handle -> Lwt.return (`Drain_interrupted handle)
      | _, Error failure -> Lwt.return (`Return (Error failure)))

let run_start startup resolver uri max_size =
  let* opened = open_healthy_pool uri max_size in
  let* publication = publish_start startup opened in
  let* final_result =
    match publication with
    | `Return result -> Lwt.return result
    | `Drain_interrupted handle ->
        let* () = drain handle.pool in
        Lwt.return (Error stopping)
  in
  if Lwt.is_sleeping startup.promise then Lwt.wakeup_later resolver final_result;
  Lwt.return_unit

let start_decision () =
  Lwt_mutex.with_lock mutex (fun () ->
      match !lifecycle with
      | Cold ->
          let promise, resolver = Lwt.wait () in
          let startup = { promise } in
          lifecycle := Starting startup;
          Lwt.return (`Launch (startup, resolver))
      | Starting current -> Lwt.return (`Await current.promise)
      | Running handle -> Lwt.return (`Ready handle)
      | Stopping _ -> Lwt.return (`Reject stopping)
      | Stopped -> Lwt.return (`Reject stopped))

let start ?(max_size = 10) uri =
  if max_size < 1 then Lwt.return (Error invalid_size)
  else
    let* decision = start_decision () in
    match decision with
    | `Await promise -> Lwt.protected promise
    | `Ready handle -> Lwt.return (Ok handle)
    | `Reject failure -> Lwt.return (Error failure)
    | `Launch (startup, resolver) ->
        Lwt.async (fun () -> run_start startup resolver uri max_size);
        Lwt.protected startup.promise

let get () =
  match !lifecycle with
  | Cold -> Error not_started
  | Starting _ -> Error starting
  | Running handle -> Ok handle
  | Stopping _ -> Error stopping
  | Stopped -> Error stopped

let admit_use () =
  Lwt_mutex.with_lock mutex (fun () ->
      match !lifecycle with
      | Running handle ->
          incr active_uses;
          Lwt.return (Ok handle)
      | Cold -> Lwt.return (Error not_started)
      | Starting _ -> Lwt.return (Error starting)
      | Stopping _ -> Lwt.return (Error stopping)
      | Stopped -> Lwt.return (Error stopped))

let release_use () =
  Lwt_mutex.with_lock mutex (fun () ->
      decr active_uses;
      if !active_uses = 0 then Lwt_condition.broadcast idle ();
      Lwt.return_unit)

let use_pool handle callback =
  let contains haystack needle =
    let needle_length = String.length needle in
    let rec search offset =
      if offset + needle_length > String.length haystack then false
      else if String.sub haystack offset needle_length = needle then true
      else search (offset + 1)
    in
    needle_length = 0 || search 0
  in
  Lwt.catch
    (fun () ->
      let* result = Caqti_lwt_unix.Pool.use callback handle.pool in
      match result with
      | Ok value -> Lwt.return (Ok value)
      | Error error when contains (Caqti_error.show error) "Received 0 tuples" ->
          Lwt.return (Error operation_not_found)
      | Error _ -> Lwt.return (Error operation_failed))
    (fun _ -> Lwt.return (Error operation_failed))

let with_connection callback =
  let* admission = admit_use () in
  match admission with
  | Error failure -> Lwt.return (Error failure)
  | Ok handle ->
      Lwt.finalize
        (fun () -> use_pool handle callback)
        release_use

let rec wait_until_idle () =
  let* () =
    Lwt_mutex.with_lock mutex (fun () ->
        if !active_uses = 0 then Lwt.return_unit
        else Lwt_condition.wait ~mutex idle)
  in
  if !active_uses = 0 then Lwt.return_unit else wait_until_idle ()

let finish_shutdown promise resolver =
  let* () =
    Lwt_mutex.with_lock mutex (fun () ->
        lifecycle := Stopped;
        Lwt.return_unit)
  in
  if Lwt.is_sleeping promise then Lwt.wakeup_later resolver ();
  Lwt.return_unit

let stop_running promise resolver handle =
  let* () = wait_until_idle () in
  let* () = drain handle.pool in
  finish_shutdown promise resolver

let stop_starting promise resolver startup_promise =
  let* _ = Lwt.protected startup_promise in
  finish_shutdown promise resolver

let shutdown_decision () =
  Lwt_mutex.with_lock mutex (fun () ->
      match !lifecycle with
      | Cold ->
          lifecycle := Stopped;
          Lwt.return `Done
      | Stopped -> Lwt.return `Done
      | Stopping promise -> Lwt.return (`Await promise)
      | Starting startup ->
          let promise, resolver = Lwt.wait () in
          lifecycle := Stopping promise;
          Lwt.return (`Stop_starting (promise, resolver, startup.promise))
      | Running handle ->
          let promise, resolver = Lwt.wait () in
          lifecycle := Stopping promise;
          Lwt.return (`Stop_running (promise, resolver, handle)))

let shutdown () =
  let* decision = shutdown_decision () in
  match decision with
  | `Done -> Lwt.return_unit
  | `Await promise -> Lwt.protected promise
  | `Stop_starting (promise, resolver, startup_promise) ->
      Lwt.async (fun () -> stop_starting promise resolver startup_promise);
      Lwt.protected promise
  | `Stop_running (promise, resolver, handle) ->
      Lwt.async (fun () -> stop_running promise resolver handle);
      Lwt.protected promise
