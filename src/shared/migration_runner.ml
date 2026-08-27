let ( let* ) = Lwt.bind

type error = { code : string; message : string }

let error code message = { code; message }

let catalog_invalid =
  error "MIGRATION_CATALOG_INVALID" "Migration catalog is invalid"

let schema_invalid =
  error "MIGRATION_SCHEMA_INVALID" "Migration schema is invalid"

let lock_timeout = error "MIGRATION_LOCK_TIMEOUT" "Migration lock timed out"

let drift =
  error "MIGRATION_DRIFT" "Migration history does not match the catalog"

let apply_failed =
  error "MIGRATION_APPLY_FAILED" "Migration could not be applied"

let operation_failed =
  error "MIGRATION_OPERATION_FAILED" "Migration operation failed"

let error_code value = value.code
let error_message value = value.message

module Schema = struct
  type t = string

  let valid value =
    let length = String.length value in
    length >= 1 && length <= 63
    && (match value.[0] with 'a' .. 'z' -> true | _ -> false)
    && String.for_all
         (function 'a' .. 'z' | '0' .. '9' | '_' -> true | _ -> false)
         value

  let of_string value = if valid value then Ok value else Error schema_invalid
  let to_string value = value
end

type status = {
  applied_count : int;
  pending_count : int;
  current_version : int64 option;
}

type applied = { version : int64; filename : string; checksum : string }

let current_schema_request =
  let open Caqti_request.Infix in
  (Caqti_type.unit ->! Caqti_type.string) "SELECT current_schema()"

let set_search_path_request =
  let open Caqti_request.Infix in
  (Caqti_type.string ->! Caqti_type.string)
    "SELECT set_config('search_path', ?, true)"

let ledger_exists_request =
  let open Caqti_request.Infix in
  (Caqti_type.unit ->! Caqti_type.bool)
    "SELECT to_regclass('schema_migrations') IS NOT NULL"

let ledger_rows_request =
  let open Caqti_request.Infix in
  (Caqti_type.unit ->* Caqti_type.(t3 int64 string string))
    "SELECT version, filename, checksum_sha256 FROM schema_migrations ORDER BY \
     version"

let checksum_request =
  let open Caqti_request.Infix in
  (Caqti_type.string ->! Caqti_type.string)
    "SELECT encode(sha256(convert_to(?, 'UTF8')), 'hex')"

let insert_ledger_request =
  let open Caqti_request.Infix in
  (Caqti_type.(t3 int64 string string) ->. Caqti_type.unit)
    "INSERT INTO schema_migrations (version, filename, checksum_sha256) VALUES \
     (?, ?, ?)"

let try_lock_request =
  let open Caqti_request.Infix in
  (Caqti_type.unit ->! Caqti_type.bool)
    "SELECT pg_try_advisory_lock(hashtextextended('fca:migrations:' || \
     current_database(), 0))"

let unlock_request =
  let open Caqti_request.Infix in
  (Caqti_type.unit ->! Caqti_type.bool)
    "SELECT pg_advisory_unlock(hashtextextended('fca:migrations:' || \
     current_database(), 0))"

let search_path schema =
  Printf.sprintf "\"%s\",pg_catalog" (Schema.to_string schema)

let configure_search_path (module Connection : Caqti_lwt.CONNECTION) schema =
  let* configured =
    Connection.find set_search_path_request (search_path schema)
  in
  Lwt.return (Result.map (fun _ -> ()) configured)

let resolve_schema (module Connection : Caqti_lwt.CONNECTION) = function
  | Some schema -> Lwt.return (Ok schema)
  | None -> (
      let* found = Connection.find current_schema_request () in
      match found with
      | Error _ -> Lwt.return (Error operation_failed)
      | Ok value -> Lwt.return (Schema.of_string value))

let read_applied ((module Connection : Caqti_lwt.CONNECTION) as connection)
    schema =
  let* result =
    Connection.with_transaction (fun () ->
        let* configured = configure_search_path connection schema in
        match configured with
        | Error _ as error -> Lwt.return error
        | Ok () -> (
            let* exists = Connection.find ledger_exists_request () in
            match exists with
            | Error _ as error -> Lwt.return error
            | Ok false -> Lwt.return (Ok [])
            | Ok true -> Connection.collect_list ledger_rows_request ()))
  in
  Lwt.return
    (match result with
    | Error _ -> Error operation_failed
    | Ok rows ->
        Ok
          (List.map
             (fun (version, filename, checksum) ->
               { version; filename; checksum })
             rows))

let rec compute_checksums (module Connection : Caqti_lwt.CONNECTION) acc =
  function
  | [] -> Lwt.return (Ok (List.rev acc))
  | entry :: rest -> (
      let* computed =
        Connection.find checksum_request (Migration_catalog.entry_sql entry)
      in
      match computed with
      | Error _ -> Lwt.return (Error operation_failed)
      | Ok checksum ->
          compute_checksums (module Connection) (checksum :: acc) rest)

let validate_prefix catalog_entries checksums rows =
  let rec loop applied entries sums =
    match (applied, entries, sums) with
    | [], _, _ -> Ok ()
    | _, [], _ | _, _, [] -> Error drift
    | row :: applied_rest, entry :: entry_rest, checksum :: checksum_rest ->
        if
          Int64.equal row.version (Migration_catalog.entry_version entry)
          && String.equal row.filename (Migration_catalog.entry_filename entry)
          && String.equal row.checksum checksum
        then loop applied_rest entry_rest checksum_rest
        else Error drift
  in
  loop rows catalog_entries checksums

let make_status entries rows =
  let applied_count = List.length rows in
  let pending_count = List.length entries - applied_count in
  let current_version =
    match List.rev rows with [] -> None | row :: _ -> Some row.version
  in
  { applied_count; pending_count; current_version }

let inspect connection schema catalog =
  let entries = Migration_catalog.entries catalog in
  if entries = [] then Lwt.return (Error catalog_invalid)
  else
    let* checksums = compute_checksums connection [] entries in
    match checksums with
    | Error _ as error -> Lwt.return error
    | Ok checksums -> (
        let* rows = read_applied connection schema in
        match rows with
        | Error _ as error -> Lwt.return error
        | Ok rows -> (
            if List.length rows > List.length entries then
              Lwt.return (Error drift)
            else
              match validate_prefix entries checksums rows with
              | Error _ as error -> Lwt.return error
              | Ok () -> Lwt.return (Ok (entries, checksums, rows))))

let migration_request query =
  Caqti_request.create ~oneshot:true Caqti_type.unit Caqti_type.unit
    Caqti_mult.zero (fun _ -> query)

let rec execute_statements (module Connection : Caqti_lwt.CONNECTION) = function
  | [] -> Lwt.return (Ok ())
  | statement :: rest -> (
      let* executed = Connection.exec (migration_request statement) () in
      match executed with
      | Error _ as error -> Lwt.return error
      | Ok () -> execute_statements (module Connection) rest)

let apply_entry ((module Connection : Caqti_lwt.CONNECTION) as connection)
    schema entry checksum =
  let* result =
    Connection.with_transaction (fun () ->
        let* configured = configure_search_path connection schema in
        match configured with
        | Error _ as error -> Lwt.return error
        | Ok () -> (
            let* executed =
              execute_statements connection
                (Migration_catalog.entry_statements entry)
            in
            match executed with
            | Error _ as error -> Lwt.return error
            | Ok () ->
                Connection.exec insert_ledger_request
                  ( Migration_catalog.entry_version entry,
                    Migration_catalog.entry_filename entry,
                    checksum )))
  in
  match result with
  | Ok () -> Lwt.return (Ok ())
  | Error _ -> Lwt.return (Error apply_failed)

let rec drop count values =
  match (count, values) with
  | 0, rest -> rest
  | _, [] -> []
  | count, _ :: rest -> drop (count - 1) rest

let rec apply_pending connection schema entries checksums =
  match (entries, checksums) with
  | [], [] -> Lwt.return (Ok ())
  | entry :: entry_rest, checksum :: checksum_rest -> (
      let* applied = apply_entry connection schema entry checksum in
      match applied with
      | Error _ as error -> Lwt.return error
      | Ok () -> apply_pending connection schema entry_rest checksum_rest)
  | _ -> Lwt.return (Error catalog_invalid)

let rec acquire_lock (module Connection : Caqti_lwt.CONNECTION) deadline =
  let* acquired = Connection.find try_lock_request () in
  match acquired with
  | Error _ -> Lwt.return (Error operation_failed)
  | Ok true -> Lwt.return (Ok ())
  | Ok false ->
      if Unix.gettimeofday () >= deadline then Lwt.return (Error lock_timeout)
      else
        let* () = Lwt_unix.sleep 0.05 in
        acquire_lock (module Connection) deadline

let release_lock (module Connection : Caqti_lwt.CONNECTION) =
  let* _ = Connection.find unlock_request () in
  Lwt.return_unit

let with_pool_connection callback =
  let* result =
    Db_pool.with_connection (fun connection ->
        let* value = callback connection in
        Lwt.return (Ok value))
  in
  match result with
  | Error _ -> Lwt.return (Error operation_failed)
  | Ok value -> Lwt.return value

let status ?schema catalog =
  with_pool_connection (fun connection ->
      let* resolved = resolve_schema connection schema in
      match resolved with
      | Error _ as error -> Lwt.return error
      | Ok schema ->
          let* inspected = inspect connection schema catalog in
          Lwt.return
            (match inspected with
            | Error _ as error -> error
            | Ok (entries, _, rows) -> Ok (make_status entries rows)))

let current ?schema catalog =
  let* result = status ?schema catalog in
  Lwt.return (Result.map (fun value -> value.current_version) result)

let run ?schema ?(lock_timeout_s = 30.) catalog =
  if lock_timeout_s <= 0. || lock_timeout_s > 300. then
    Lwt.return (Error lock_timeout)
  else
    with_pool_connection (fun connection ->
        let* resolved = resolve_schema connection schema in
        match resolved with
        | Error _ as error -> Lwt.return error
        | Ok schema -> (
            let deadline = Unix.gettimeofday () +. lock_timeout_s in
            let* locked = acquire_lock connection deadline in
            match locked with
            | Error _ as error -> Lwt.return error
            | Ok () ->
                Lwt.finalize
                  (fun () ->
                    let* inspected = inspect connection schema catalog in
                    match inspected with
                    | Error _ as error -> Lwt.return error
                    | Ok (entries, checksums, rows) -> (
                        let applied_count = List.length rows in
                        let pending_entries = drop applied_count entries in
                        let pending_checksums = drop applied_count checksums in
                        let* applied =
                          apply_pending connection schema pending_entries
                            pending_checksums
                        in
                        match applied with
                        | Error _ as error -> Lwt.return error
                        | Ok () ->
                            let* final_state =
                              inspect connection schema catalog
                            in
                            Lwt.return
                              (match final_state with
                              | Error _ as error -> error
                              | Ok (entries, _, rows) ->
                                  Ok (make_status entries rows))))
                  (fun () -> release_lock connection)))
