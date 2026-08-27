let ( let* ) = Lwt.bind

module Schema_name = struct
  type t = string

  let is_valid_string value =
    let length = String.length value in
    length >= 1 && length <= 63
    && (match value.[0] with 'a' .. 'z' -> true | _ -> false)
    && String.for_all
         (function 'a' .. 'z' | '0' .. '9' | '_' -> true | _ -> false)
         value

  let validated value =
    if is_valid_string value then value
    else invalid_arg "invalid internally generated PostgreSQL schema name"

  let compare = String.compare
  let is_valid = is_valid_string
  let length = String.length
  let to_string value = value
end

type t = { schema : Schema_name.t; mutable closed : bool }
type error = [ `Database_operation_failed ]

let random =
  Random.State.make
    [|
      Unix.getpid ();
      Hashtbl.hash (Unix.gettimeofday ());
      Hashtbl.hash (Sys.getcwd ());
    |]

let counter = ref 0

let generate_schema_name () =
  incr counter;
  let random_a = Random.State.bits random in
  let random_b = Random.State.bits random in
  Schema_name.validated
    (Printf.sprintf "fca_it_%x_%08x_%08x_%06x" (Unix.getpid ()) random_a
       random_b !counter)

let sample_generated_names_for_test count =
  if count < 0 || count > 10_000 then
    invalid_arg "invalid generated-name sample size";
  List.init count (fun _ -> generate_schema_name ())

let schema_name harness = harness.schema
let quote_identifier schema = "\"" ^ schema ^ "\""

let dynamic_exec_request sql =
  let open Caqti_request.Infix in
  (Caqti_type.unit ->. Caqti_type.unit) ~oneshot:true sql

let create_request schema =
  dynamic_exec_request ("CREATE SCHEMA " ^ quote_identifier schema)

let drop_request schema =
  dynamic_exec_request
    ("DROP SCHEMA IF EXISTS " ^ quote_identifier schema ^ " CASCADE")

let set_search_path_request =
  let open Caqti_request.Infix in
  (Caqti_type.string ->! Caqti_type.string)
    "SELECT set_config('search_path', ?, true)"

let schema_exists_request =
  let open Caqti_request.Infix in
  (Caqti_type.string ->! Caqti_type.bool)
    "SELECT EXISTS (SELECT 1 FROM pg_catalog.pg_namespace WHERE nspname = ?)"

let map_pool_result = function
  | Ok value -> Ok value
  | Error _ -> Error `Database_operation_failed

let create () =
  let schema = generate_schema_name () in
  let* result =
    Db_pool.with_connection (fun (module Connection : Caqti_lwt.CONNECTION) ->
        Connection.exec (create_request schema) ())
  in
  Lwt.return
    (match map_pool_result result with
    | Ok () -> Ok { schema; closed = false }
    | Error _ as error -> error)

let configure_search_path (module Connection : Caqti_lwt.CONNECTION) schema =
  let value = quote_identifier schema ^ ",pg_catalog" in
  let* result = Connection.find set_search_path_request value in
  Lwt.return (Result.map (fun _ -> ()) result)

let with_transaction harness callback =
  if harness.closed then Lwt.return (Error `Database_operation_failed)
  else
    let* result =
      Db_pool.with_connection
        (fun ((module Connection : Caqti_lwt.CONNECTION) as connection) ->
          Connection.with_transaction (fun () ->
              let* configured =
                configure_search_path connection harness.schema
              in
              match configured with
              | Error _ as error -> Lwt.return error
              | Ok () -> callback connection))
    in
    Lwt.return (map_pool_result result)

let with_rollback harness callback =
  if harness.closed then Lwt.return (Error `Database_operation_failed)
  else
    let* result =
      Db_pool.with_connection
        (fun ((module Connection : Caqti_lwt.CONNECTION) as connection) ->
          let* started = Connection.start () in
          match started with
          | Error _ as error -> Lwt.return error
          | Ok () ->
              Lwt.catch
                (fun () ->
                  let* configured =
                    configure_search_path connection harness.schema
                  in
                  let* callback_result =
                    match configured with
                    | Error _ as error -> Lwt.return error
                    | Ok () -> callback connection
                  in
                  let* rolled_back = Connection.rollback () in
                  Lwt.return
                    (match rolled_back with
                    | Error _ as error -> error
                    | Ok () -> callback_result))
                (fun exception_ ->
                  let* _ = Connection.rollback () in
                  Lwt.fail exception_))
    in
    Lwt.return (map_pool_result result)

let schema_exists schema =
  let* result =
    Db_pool.with_connection (fun (module Connection : Caqti_lwt.CONNECTION) ->
        Connection.find schema_exists_request schema)
  in
  Lwt.return (map_pool_result result)

let close harness =
  if harness.closed then Lwt.return (Ok ())
  else
    let* result =
      Db_pool.with_connection (fun (module Connection : Caqti_lwt.CONNECTION) ->
          Connection.exec (drop_request harness.schema) ())
    in
    let mapped = map_pool_result result in
    (match mapped with Ok () -> harness.closed <- true | Error _ -> ());
    Lwt.return mapped

let with_harness callback =
  let* created = create () in
  match created with
  | Error `Database_operation_failed ->
      Lwt.fail_with "PostgreSQL schema harness creation failed"
  | Ok harness ->
      Lwt.finalize
        (fun () -> callback harness)
        (fun () ->
          let* closed = close harness in
          match closed with
          | Ok () -> Lwt.return_unit
          | Error `Database_operation_failed ->
              Lwt.fail_with "PostgreSQL schema harness cleanup failed")
