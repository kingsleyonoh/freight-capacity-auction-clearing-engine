open Lwt.Infix

let actor_field = Dream.new_field ~name:"fca_actor" ()
let rate_state : (string, int * int) Hashtbl.t = Hashtbl.create 256

let error_json ?(status = `Bad_Request) code message =
  Metrics.error ();
  Dream.json ~status
    (Yojson.Safe.to_string
       (`Assoc [ ("error", `Assoc [ ("code", `String code); ("message", `String message); ("details", `List []) ]) ]))

let request_id request =
  match Dream.header request "X-Request-ID" with
  | Some value when String.length value > 0 && String.length value <= 128 -> value
  | _ -> Printf.sprintf "fca-%Ld" (Int64.of_float (Unix.gettimeofday () *. 1_000_000.))

let request_id_middleware next request =
  next request >|= fun response -> Dream.set_header response "X-Request-ID" (request_id request); response

let route_rate_limit target method_ =
  if target = "/api/tenants/register" then 5
  else if target = "/api/auth/refresh" then 30
  else if method_ = `GET then 120
  else if String.ends_with ~suffix:"/bids" target then 100
  else if String.ends_with ~suffix:"/close-bidding" target then 30
  else if String.ends_with ~suffix:"/approve" target || String.ends_with ~suffix:"/reject" target then 30
  else if String.ends_with ~suffix:"/export" target || String.ends_with ~suffix:"/clear" target then 20
  else 60

let rate_limit_middleware next request =
  let target = Dream.target request in
  if not (String.starts_with ~prefix:"/api/" target) then next request
  else
    let now = int_of_float (Unix.gettimeofday () /. 60.) in
    let key = Dream.client request ^ ":" ^ target in
    let limit = route_rate_limit target (Dream.method_ request) in
    let window, count = Option.value ~default:(now, 0) (Hashtbl.find_opt rate_state key) in
    let count = if window = now then count else 0 in
    if count >= limit then
      Dream.respond ~status:`Too_Many_Requests ~headers:[ ("Retry-After", "60") ] "{\"error\":{\"code\":\"RATE_LIMITED\",\"message\":\"Rate limit exceeded.\",\"details\":[]}}"
    else (Hashtbl.replace rate_state key (now, count + 1); next request)

let actor request = Dream.field request actor_field

let api_key request =
  match Dream.header request "X-API-Key" with
  | Some value -> Some value
  | None ->
      Option.bind (Dream.header request "Authorization") (fun value ->
          if String.starts_with ~prefix:"Bearer " value then Some (String.sub value 7 (String.length value - 7)) else None)

let bearer_token request =
  match Dream.header request "Authorization" with
  | Some value when String.starts_with ~prefix:"Bearer " value -> Some (String.sub value 7 (String.length value - 7))
  | _ -> None

let authenticate next request =
  Metrics.request ();
  if not (String.starts_with ~prefix:"/api/" (Dream.target request)) || Dream.target request = "/api/auth/register" || Dream.target request = "/api/tenants/register" || Dream.target request = "/api/integrations/webhook-engine/bid-updates" then next request
  else
    match api_key request with
    | None -> error_json ~status:`Unauthorized "AUTH_REQUIRED" "An API key is required."
    | Some key ->
        Store.authenticate ~api_key:key >>= function
        | Error Store.Not_found ->
            (match (bearer_token request, Sys.getenv_opt "SECRET_KEY_BASE") with
             | Some token, Some secret ->
                 (match Jwt_session.verify ~secret ~token with
                  | Ok claims when claims.tenant_id <> "" && claims.user_id <> "" ->
                      Dream.set_field request actor_field { Store.user_id = claims.user_id; tenant_id = claims.tenant_id; role = claims.role; carrier_id = None };
                      next request
                  | _ -> error_json ~status:`Unauthorized "AUTH_INVALID" "The bearer token is invalid.")
             | _ -> error_json ~status:`Unauthorized "AUTH_INVALID" "The API key is invalid.")
        | Error (Store.Invalid code) -> error_json ~status:`Unauthorized code "The API key is invalid."
        | Error Store.Unavailable -> error_json ~status:`Service_Unavailable "AUTH_UNAVAILABLE" "Authentication is temporarily unavailable."
        | Error Store.Conflict -> error_json ~status:`Unauthorized "AUTH_INVALID" "The API key is invalid."
        | Ok value ->
            Dream.set_field request actor_field value;
            next request

let permission request action scope =
  match actor request with
  | Some value when Permission_matrix.can ~role:value.Store.role ~action scope -> Ok value
  | Some _ -> Error (error_json ~status:`Forbidden "AUTH_FORBIDDEN" "The actor is not allowed to perform this action.")
  | None -> Error (error_json ~status:`Unauthorized "AUTH_REQUIRED" "Authentication is required.")

let json_body request =
  Dream.body request >|= fun body ->
  try Yojson.Safe.from_string body with Yojson.Json_error _ -> `Null

let string_member name = function
  | `Assoc fields -> (match List.assoc_opt name fields with Some (`String value) -> Some value | _ -> None)
  | _ -> None

let int_member name = function
  | `Assoc fields -> (match List.assoc_opt name fields with Some (`Int value) -> Some value | Some (`Intlit value) -> int_of_string_opt value | _ -> None)
  | _ -> None

let json_member name json = Yojson.Safe.Util.member name json

let bool_member name = function
  | `Assoc fields -> (match List.assoc_opt name fields with Some (`Bool value) -> Some value | _ -> None)
  | _ -> None

let json_list_member name = function
  | `Assoc fields -> (match List.assoc_opt name fields with Some (`List values) -> values | _ -> [])
  | _ -> []

let required_string name json = match string_member name json with Some value when value <> "" -> Ok value | _ -> Error (error_json "REQUEST_INVALID" ("Field " ^ name ^ " is required."))

let store_error = function
  | Store.Not_found -> error_json ~status:`Not_Found "RESOURCE_NOT_FOUND" "The requested resource was not found."
  | Store.Conflict -> error_json ~status:`Conflict "RESOURCE_CONFLICT" "The requested change conflicts with current state."
  | Store.Unavailable -> error_json ~status:`Service_Unavailable "DATABASE_UNAVAILABLE" "The database is temporarily unavailable."
  | Store.Invalid code -> error_json code "The request could not be accepted."

let store_json loader tenant_id =
  loader tenant_id >>= function
  | Ok json -> Dream.json (Yojson.Safe.to_string json)
  | Error error -> store_error error

let report_of_snapshot snapshot =
  try
    let open Yojson.Safe.Util in
    let awards =
      snapshot |> member "awards" |> to_list |> List.map (fun award ->
          (award |> member "load_id" |> to_string, award |> member "carrier_id" |> to_string, award |> member "amount_cents" |> to_int))
    in
    Some { Report_renderer.auction_id = snapshot |> member "auction_id" |> to_string; tenant_id = snapshot |> member "tenant_id" |> to_string; awards; generated_at = snapshot |> member "generated_at" |> to_string }
  with Yojson.Safe.Util.Type_error _ -> None

let render_report ~format ~report_id snapshot =
  match report_of_snapshot snapshot with
  | None -> error_json ~status:`Internal_Server_Error "REPORT_SNAPSHOT_INVALID" "The frozen report snapshot is invalid."
  | Some report ->
      (match String.lowercase_ascii format with
       | "json" -> Dream.json (Yojson.Safe.to_string snapshot)
       | "csv" ->
           (match Report_renderer.render_csv ~viewer:Report_renderer.Operator report with
            | Error _ -> error_json ~status:`Internal_Server_Error "REPORT_RENDER_FAILED" "The report could not be rendered."
            | Ok body -> Dream.respond ~headers:[ ("Content-Type", "text/csv; charset=utf-8"); ("Content-Disposition", "attachment; filename=\"report-" ^ report_id ^ ".csv\"") ] body)
       | "html" ->
           (match Report_renderer.render_html ~viewer:Report_renderer.Operator report with
            | Error _ -> error_json ~status:`Internal_Server_Error "REPORT_RENDER_FAILED" "The report could not be rendered."
            | Ok body -> Dream.respond ~headers:[ ("Content-Type", "text/html; charset=utf-8"); ("Content-Disposition", "attachment; filename=\"report-" ^ report_id ^ ".html\"") ] body)
       | "pdf" -> error_json ~status:`Not_Implemented "REPORT_FORMAT_UNAVAILABLE" "PDF export is declared but no PDF renderer is installed."
       | _ -> error_json "REPORT_FORMAT_INVALID" "format must be csv, json, html, or pdf.")

let health _request = Dream.json "{\"status\":\"ok\",\"service\":\"freight-capacity-auction-clearing-engine\"}"

let health_db _request = Store.health () >>= fun healthy -> if healthy then Dream.json "{\"status\":\"ok\"}" else error_json ~status:`Service_Unavailable "DATABASE_UNAVAILABLE" "Database health check failed."

let ready _request = Store.health () >>= fun healthy -> if healthy then Dream.json "{\"status\":\"ready\"}" else error_json ~status:`Service_Unavailable "NOT_READY" "The service dependencies are not ready."

let me request =
  match actor request with
  | None -> error_json ~status:`Unauthorized "AUTH_REQUIRED" "Authentication is required."
  | Some value -> Dream.json (Yojson.Safe.to_string (`Assoc [ ("user_id", `String value.user_id); ("tenant_id", `String value.tenant_id); ("role", `String value.role); ("carrier_id", match value.carrier_id with None -> `Null | Some carrier -> `String carrier) ]))

let register request =
  (match Sys.getenv_opt "SELF_REGISTRATION_ENABLED" with Some "false" -> error_json ~status:`Forbidden "REGISTRATION_DISABLED" "Self-registration is disabled." | _ ->
     json_body request >>= fun json ->
     let tenant_name = match required_string "tenant_name" json with Ok value -> Ok value | Error _ -> required_string "name" json in
     let email = Ok (Option.value ~default:"admin@example.com" (string_member "email" json)) in
     let name = Ok (Option.value ~default:"Tenant administrator" (string_member "name" json)) in
     match (tenant_name, email, name) with
     | Ok tenant_name, Ok email, Ok name ->
         Store.register ~tenant_name ~email ~name >>= (function
           | Error error -> store_error error
           | Ok (actor, api_key) ->
               let token = match Sys.getenv_opt "SECRET_KEY_BASE" with Some secret -> `String (Jwt_session.issue ~secret ~tenant_id:actor.tenant_id ~user_id:actor.user_id ~role:actor.role ~ttl_seconds:3_600) | None -> `Null in
               Dream.json (Yojson.Safe.to_string (`Assoc [ ("api_key", `String api_key); ("access_token", token); ("tenant_id", `String actor.tenant_id); ("user_id", `String actor.user_id) ])))
     | Error response, _, _ | _, Error response, _ | _, _, Error response -> response)

let refresh request =
  match permission request Permission_matrix.Read_tenant Permission_matrix.Tenant with
  | Error response -> response
  | Ok value ->
      (match Sys.getenv_opt "SECRET_KEY_BASE" with
       | None -> error_json ~status:`Service_Unavailable "AUTH_CONFIG_INVALID" "Token signing is not configured."
       | Some secret -> Dream.json (Yojson.Safe.to_string (`Assoc [ ("access_token", `String (Jwt_session.issue ~secret ~tenant_id:value.tenant_id ~user_id:value.user_id ~role:value.role ~ttl_seconds:3_600)) ])))

let tenant_me request =
  match permission request Permission_matrix.Read_tenant Permission_matrix.Tenant with
  | Error response -> response
  | Ok value -> Store.get_tenant ~tenant_id:value.tenant_id >>= function
    | Ok (`Assoc fields) -> Dream.json (Yojson.Safe.to_string (`Assoc (("role", `String value.role) :: fields)))
    | Ok json -> Dream.json (Yojson.Safe.to_string json)
    | Error error -> store_error error

let tenant_settings request =
  match permission request Permission_matrix.Read_tenant Permission_matrix.Tenant with
  | Error response -> response
  | Ok value -> Store.get_tenant ~tenant_id:value.tenant_id >>= function
    | Ok json -> Dream.json (Yojson.Safe.to_string json)
    | Error error -> store_error error

let patch_tenant_settings request =
  match permission request Permission_matrix.Manage_users Permission_matrix.Tenant with
  | Error response -> response
  | Ok value ->
      json_body request >>= fun json ->
      (match (required_string "name" json, required_string "display_name" json) with
       | Ok name, Ok display_name -> Store.update_tenant ~tenant_id:value.tenant_id ~name ~display_name >>= (function Ok updated -> Dream.json (Yojson.Safe.to_string updated) | Error error -> store_error error)
       | Error response, _ | _, Error response -> response)

let create_import request =
  match permission request Permission_matrix.Manage_auctions Permission_matrix.Tenant with
  | Error response -> response
  | Ok value ->
      json_body request >>= fun json ->
      let resource_type = Option.value ~default:"" (string_member "resource_type" json) in
      let source_filename = Option.value ~default:"upload.csv" (string_member "source_filename" json) in
      let source_format = Option.value ~default:"csv" (string_member "source_format" json) in
      let csv = Option.value ~default:"" (string_member "csv" json) in
      let mapping = Option.value ~default:"{}" (string_member "mapping" json) in
      let auction_id = string_member "auction_id" json in
      let rows = json_list_member "rows" json in
      let valid_resource = List.mem resource_type [ "carriers"; "lanes"; "loads"; "bids"; "replay_dataset" ] in
      let valid_format = List.mem source_format [ "csv"; "parquet"; "json_api" ] in
      if not valid_resource || not valid_format then error_json "IMPORT_INPUT_INVALID" "resource_type or source_format is not supported."
      else
        let row_count = if rows <> [] then List.length rows else if csv = "" then 0 else max 0 (List.length (String.split_on_char '\n' csv) - 1) in
        let valid_count, invalid_count = if rows <> [] then row_count, 0 else if csv = "" then 0, 0 else row_count, 0 in
        Store.create_import ~tenant_id:value.tenant_id ~user_id:value.user_id ~resource_type ~source_filename ~source_format ~auction_id ~mapping ~staging_rows:(Yojson.Safe.to_string (`List rows)) ~row_count ~valid_row_count:valid_count ~invalid_row_count:invalid_count >>= function
        | Ok import_id -> Store.get_import ~tenant_id:value.tenant_id ~import_id >>= (function Ok json -> Dream.json (Yojson.Safe.to_string json) | Error error -> store_error error)
        | Error error -> store_error error

let get_import request =
  match permission request Permission_matrix.Read_tenant Permission_matrix.Tenant with
  | Error response -> response
  | Ok value -> Store.get_import ~tenant_id:value.tenant_id ~import_id:(Dream.param request "id") >>= function
    | Ok json -> Dream.json (Yojson.Safe.to_string json)
    | Error error -> store_error error

let commit_import request =
  match permission request Permission_matrix.Manage_auctions Permission_matrix.Tenant with
  | Error response -> response
  | Ok value ->
      json_body request >>= fun json ->
      let confirm = Option.value ~default:false (bool_member "confirm" json) in
      Store.commit_import ~tenant_id:value.tenant_id ~import_id:(Dream.param request "id") ~confirm >>= function
      | Ok result -> Dream.json (Yojson.Safe.to_string result)
      | Error error -> store_error error

let pagination_limit request =
  match Dream.query request "limit" with
  | None -> Ok 25
  | Some value ->
      (match int_of_string_opt value with
       | Some limit when limit >= 1 && limit <= 100 -> Ok limit
       | _ -> Error (error_json "PAGINATION_INVALID" "limit must be an integer between 1 and 100."))

let contains_case_insensitive ~needle value =
  let needle = String.lowercase_ascii needle in
  let value = String.lowercase_ascii value in
  let needle_length = String.length needle in
  let value_length = String.length value in
  let rec loop index =
    if needle_length = 0 then true
    else if index + needle_length > value_length then false
    else if String.sub value index needle_length = needle then true
    else loop (index + 1)
  in
  loop 0

let paginate_json_array request items =
  match pagination_limit request with
  | Error response -> Error response
  | Ok limit ->
      let cursor = Dream.query request "cursor" in
      let start_index =
        match cursor with
        | None -> Ok 0
        | Some value ->
            (match List.find_index (fun item -> string_member "id" item = Some value) items with
             | Some index -> Ok (index + 1)
             | None -> Error (error_json "PAGINATION_INVALID" "cursor is not valid for this tenant."))
      in
      (match start_index with
       | Error response -> Error response
       | Ok start_index ->
           let rec drop count values =
             if count <= 0 then values else match values with [] -> [] | _ :: tail -> drop (count - 1) tail
           in
           let page = items |> drop start_index |> fun values -> List.filteri (fun index _ -> index < limit) values in
           let consumed = start_index + List.length page in
           let next_cursor = if consumed < List.length items then Option.bind (List.nth_opt items (consumed - 1)) (string_member "id") else None in
           Ok (`Assoc [ ("data", `List page); ("next_cursor", Option.fold ~none:`Null ~some:(fun value -> `String value) next_cursor) ]))

let list_auctions request =
  match permission request Permission_matrix.Read_tenant Permission_matrix.Tenant with
  | Error response -> response
  | Ok value -> Store.list_auctions ~tenant_id:value.tenant_id >>= function
    | Ok (`List items) ->
        let status = Dream.query request "status" in
        let mode = Dream.query request "mode" in
        let search = Dream.query request "search" in
        let filtered =
          List.filter
            (fun item ->
              let matches name expected = match expected with None -> true | Some actual -> string_member name item = Some actual in
              let matches_search = match search with None -> true | Some value -> Option.value ~default:false (Option.map (contains_case_insensitive ~needle:value) (string_member "name" item)) in
              matches "status" status && matches "mode" mode && matches_search)
            items
        in
        (match paginate_json_array request filtered with
         | Ok json -> Dream.json (Yojson.Safe.to_string json)
         | Error response -> response)
    | Ok json -> Dream.json (Yojson.Safe.to_string json)
    | Error error -> store_error error

let list_carriers request =
  match permission request Permission_matrix.Read_tenant Permission_matrix.Tenant with
  | Error response -> response
  | Ok value -> store_json (fun tenant_id -> Store.list_carriers ~tenant_id) value.tenant_id

let get_carrier request =
  match permission request Permission_matrix.Read_tenant Permission_matrix.Tenant with
  | Error response -> response
  | Ok value -> Store.get_carrier ~tenant_id:value.tenant_id ~carrier_id:(Dream.param request "id") >>= function Ok json -> Dream.json (Yojson.Safe.to_string json) | Error error -> store_error error

let create_carrier request =
  match permission request Permission_matrix.Manage_auctions Permission_matrix.Tenant with
  | Error response -> response
  | Ok value ->
      json_body request >>= fun json ->
      (match (required_string "legal_name" json, required_string "display_name" json, required_string "equipment_type" json) with
       | Ok legal_name, Ok display_name, Ok equipment_type ->
           let mc_number = Option.value ~default:"" (string_member "mc_number" json) in
           let dot_number = Option.value ~default:"" (string_member "dot_number" json) in
           let status = Option.value ~default:"active" (string_member "status" json) in
           Store.create_carrier ~tenant_id:value.tenant_id ~legal_name ~display_name ~mc_number ~dot_number ~equipment_type ~status >>= (function Ok id -> Dream.json (Yojson.Safe.to_string (`Assoc [ ("id", `String id); ("status", `String status) ])) | Error error -> store_error error)
       | Error response, _, _ | _, Error response, _ | _, _, Error response -> response)

let patch_carrier request =
  match permission request Permission_matrix.Manage_auctions Permission_matrix.Tenant with
  | Error response -> response
  | Ok value ->
      json_body request >>= fun json ->
      (match (required_string "legal_name" json, required_string "display_name" json, required_string "equipment_type" json) with
       | Ok legal_name, Ok display_name, Ok equipment_type ->
           let status = Option.value ~default:"active" (string_member "status" json) in
           Store.update_carrier ~tenant_id:value.tenant_id ~carrier_id:(Dream.param request "id") ~legal_name ~display_name ~equipment_type ~status >>= (function Ok result -> Dream.json (Yojson.Safe.to_string result) | Error error -> store_error error)
       | Error response, _, _ | _, Error response, _ | _, _, Error response -> response)

let list_users request =
  match permission request Permission_matrix.Manage_users Permission_matrix.Tenant with
  | Error response -> response
  | Ok value -> store_json (fun tenant_id -> Store.list_users ~tenant_id) value.tenant_id

let get_user request =
  match permission request Permission_matrix.Manage_users Permission_matrix.Tenant with
  | Error response -> response
  | Ok value -> Store.get_user ~tenant_id:value.tenant_id ~user_id:(Dream.param request "id") >>= function Ok json -> Dream.json (Yojson.Safe.to_string json) | Error error -> store_error error

let create_user request =
  match permission request Permission_matrix.Manage_users Permission_matrix.Tenant with
  | Error response -> response
  | Ok value ->
      json_body request >>= fun json ->
      (match (required_string "email" json, required_string "name" json, required_string "role" json) with
       | Ok email, Ok name, Ok role ->
           Store.create_user ~tenant_id:value.tenant_id ~email ~name ~role ~carrier_id:(string_member "carrier_id" json) >>= (function Ok id -> Dream.json (Yojson.Safe.to_string (`Assoc [ ("id", `String id); ("role", `String role) ])) | Error error -> store_error error)
       | Error response, _, _ | _, Error response, _ | _, _, Error response -> response)

let patch_user request =
  match permission request Permission_matrix.Manage_users Permission_matrix.Tenant with
  | Error response -> response
  | Ok value ->
      json_body request >>= fun json ->
      (match (required_string "name" json, required_string "role" json) with
       | Ok name, Ok role -> Store.update_user ~tenant_id:value.tenant_id ~user_id:(Dream.param request "id") ~name ~role ~carrier_id:(string_member "carrier_id" json) >>= (function Ok result -> Dream.json (Yojson.Safe.to_string result) | Error error -> store_error error)
       | Error response, _ | _, Error response -> response)

let list_policies request =
  match permission request Permission_matrix.Read_tenant Permission_matrix.Tenant with
  | Error response -> response
  | Ok value -> store_json (fun tenant_id -> Store.list_policies ~tenant_id) value.tenant_id

let create_policy request =
  match permission request Permission_matrix.Manage_policy Permission_matrix.Tenant with
  | Error response -> response
  | Ok value ->
      json_body request >>= fun json ->
      (match required_string "name" json with
       | Error response -> response
       | Ok name ->
           let max_risk = Option.value ~default:"0.15" (string_member "max_service_risk" json) in
           let max_share = Option.value ~default:"0.30" (string_member "max_single_carrier_share" json) in
           let reserve = Option.value ~default:"hard_reject" (string_member "reserve_price_behavior" json) in
           Store.create_policy ~tenant_id:value.tenant_id ~name ~max_service_risk:max_risk ~max_single_carrier_share:max_share ~reserve_price_behavior:reserve >>= (function Ok result -> Dream.json (Yojson.Safe.to_string result) | Error error -> store_error error))

let activate_policy request =
  match permission request Permission_matrix.Manage_policy Permission_matrix.Tenant with
  | Error response -> response
  | Ok value -> Store.activate_policy ~tenant_id:value.tenant_id ~policy_id:(Dream.param request "id") >>= function Ok json -> Dream.json (Yojson.Safe.to_string json) | Error error -> store_error error

let list_clearing_jobs request =
  match permission request Permission_matrix.Read_tenant Permission_matrix.Tenant with
  | Error response -> response
  | Ok value -> store_json (fun tenant_id -> Store.list_clearing_jobs ~tenant_id) value.tenant_id

let get_clearing_job request =
  match permission request Permission_matrix.Read_tenant Permission_matrix.Tenant with
  | Error response -> response
  | Ok value -> Store.get_clearing_job ~tenant_id:value.tenant_id ~job_id:(Dream.param request "id") >>= function Ok json -> Dream.json (Yojson.Safe.to_string json) | Error error -> store_error error

let list_awards request =
  let carrier_actor = match actor request with Some value when value.role = "carrier_viewer" -> true | _ -> false in
  let action, scope = if carrier_actor then Permission_matrix.Read_own_bid, Permission_matrix.Own_carrier else Permission_matrix.Read_competitor_bid, Permission_matrix.Tenant in
  match permission request action scope with
  | Error response -> response
  | Ok value -> Store.list_awards ~tenant_id:value.tenant_id ~auction_id:(Some (Dream.param request "id")) ~carrier_id:(if value.role = "carrier_viewer" then value.carrier_id else None) >>= function Ok json -> Dream.json (Yojson.Safe.to_string json) | Error error -> store_error error

let list_explanations request =
  match actor request with
  | None -> error_json ~status:`Unauthorized "AUTH_REQUIRED" "Authentication is required."
  | Some value ->
      let scope, action = if value.role = "carrier_viewer" then "carrier", Permission_matrix.Read_own_bid else "operator", Permission_matrix.Read_competitor_bid in
      (match permission request action Permission_matrix.Tenant with
       | Error response -> response
       | Ok _ -> Store.list_decisions ~tenant_id:value.tenant_id ~auction_id:(Dream.param request "id") ~redaction_scope:scope ~carrier_id:value.carrier_id >>= function Ok json -> Dream.json (Yojson.Safe.to_string json) | Error error -> store_error error)

let list_audit_events request =
  match permission request Permission_matrix.Export_report Permission_matrix.Tenant with
  | Error response -> response
  | Ok value -> store_json (fun tenant_id -> Store.list_audit_events ~tenant_id) value.tenant_id

let list_approvals request =
  match permission request Permission_matrix.Approve_award Permission_matrix.Tenant with
  | Error response -> response
  | Ok value -> store_json (fun tenant_id -> Store.list_approvals ~tenant_id) value.tenant_id

let list_notifications request =
  match permission request Permission_matrix.Read_tenant Permission_matrix.Tenant with
  | Error response -> response
  | Ok value ->
      let user_id = if value.role = "carrier_viewer" then Some value.user_id else None in
      Store.list_notifications ~tenant_id:value.tenant_id ~user_id >>= function
      | Ok json -> Dream.json (Yojson.Safe.to_string json)
      | Error error -> store_error error

let mark_notification_read request =
  match permission request Permission_matrix.Read_tenant Permission_matrix.Tenant with
  | Error response -> response
  | Ok value ->
      Store.mark_notification_read ~tenant_id:value.tenant_id ~user_id:value.user_id
        ~notification_id:(Dream.param request "id")
      >>= function
      | Ok () -> Dream.json "{\"status\":\"read\"}"
      | Error error -> store_error error

let list_replays request =
  match permission request Permission_matrix.Read_replay Permission_matrix.Tenant with
  | Error response -> response
  | Ok value -> store_json (fun tenant_id -> Store.list_replays ~tenant_id) value.tenant_id

let get_replay request =
  match permission request Permission_matrix.Read_replay Permission_matrix.Tenant with
  | Error response -> response
  | Ok value -> Store.get_replay ~tenant_id:value.tenant_id ~replay_id:(Dream.param request "id") >>= function Ok json -> Dream.json (Yojson.Safe.to_string json) | Error error -> store_error error

let create_replay request =
  match permission request Permission_matrix.Read_replay Permission_matrix.Tenant with
  | Error response -> response
  | Ok value ->
      json_body request >>= fun json ->
      (match (required_string "name" json, required_string "dataset_uri" json, required_string "baseline_strategy" json, required_string "policy_id" json) with
       | Ok name, Ok dataset_uri, Ok baseline_strategy, Ok policy_id -> Store.create_replay ~tenant_id:value.tenant_id ~user_id:value.user_id ~name ~dataset_uri ~baseline_strategy ~policy_id >>= (function Ok id -> Dream.json (Yojson.Safe.to_string (`Assoc [ ("id", `String id); ("status", `String "queued") ])) | Error error -> store_error error)
       | Error response, _, _, _ | _, Error response, _, _ | _, _, Error response, _ | _, _, _, Error response -> response)

let list_reports request =
  match permission request Permission_matrix.Export_report Permission_matrix.Tenant with
  | Error response -> response
  | Ok value -> store_json (fun tenant_id -> Store.list_reports ~tenant_id) value.tenant_id

let notification_preferences request =
  match permission request Permission_matrix.Read_tenant Permission_matrix.Tenant with
  | Error response -> response
  | Ok value -> Store.list_notification_preferences ~tenant_id:value.tenant_id ~user_id:value.user_id >>= function Ok json -> Dream.json (Yojson.Safe.to_string json) | Error error -> store_error error

let patch_notification_preference request =
  match permission request Permission_matrix.Read_tenant Permission_matrix.Tenant with
  | Error response -> response
  | Ok value ->
      json_body request >>= fun json ->
      (match (required_string "event_type" json, required_string "channel" json, bool_member "enabled" json) with
       | Ok event_type, Ok channel, Some enabled ->
           let quiet_hours = match json_member "quiet_hours" json with `Assoc _ as value -> Yojson.Safe.to_string value | `Null -> "{}" | _ -> "{}" in
           if enabled || event_type <> "award_approval_required" || channel <> "in_app" then Store.update_notification_preference ~tenant_id:value.tenant_id ~user_id:value.user_id ~event_type ~channel ~enabled ~quiet_hours >>= (function Ok result -> Dream.json (Yojson.Safe.to_string result) | Error error -> store_error error)
           else error_json ~status:`Conflict "CRITICAL_NOTIFICATION_REQUIRED" "Critical approval notifications must remain enabled in-app."
       | Error response, _, _ | _, Error response, _ -> response
       | _, _, None -> error_json "REQUEST_INVALID" "enabled must be a boolean.")

let list_integrations request =
  match permission request Permission_matrix.Manage_integration Permission_matrix.Tenant with
  | Error response -> response
  | Ok value -> store_json (fun tenant_id -> Store.list_integrations ~tenant_id) value.tenant_id

let patch_integration request =
  match permission request Permission_matrix.Manage_integration Permission_matrix.Tenant with
  | Error response -> response
  | Ok value ->
      json_body request >>= fun json ->
      (match (required_string "integration_name" json, bool_member "enabled" json) with
       | Ok integration_name, Some enabled ->
           let config = match json_member "config" json with `Assoc _ as value -> Yojson.Safe.to_string value | _ -> "{}" in
           let config_json = try Yojson.Safe.from_string config with Yojson.Json_error _ -> `Assoc [] in
           if Event_outbox.has_secret_field config_json then
             error_json "INTEGRATION_CONFIG_SECRET" "Integration metadata cannot contain credentials or secret-bearing fields."
           else
             Store.update_integration ~tenant_id:value.tenant_id ~integration_name ~enabled ~config >>= (function Ok result -> Dream.json (Yojson.Safe.to_string result) | Error error -> store_error error)
       | Error response, _ -> response
       | _, None -> error_json "REQUEST_INVALID" "enabled must be a boolean.")

let integration_health request =
  match permission request Permission_matrix.Read_tenant Permission_matrix.Tenant with
  | Error response -> response
  | Ok value -> store_json (fun tenant_id -> Store.list_integrations ~tenant_id) value.tenant_id

let idempotency_key request fallback = Option.value ~default:fallback (Dream.header request "Idempotency-Key")

let test_notification_hub request =
  match permission request Permission_matrix.Manage_integration Permission_matrix.Tenant with
  | Error response -> response
  | Ok value ->
      if Sys.getenv_opt "NOTIFICATION_HUB_ENABLED" <> Some "true" then
        Dream.json "{\"adapter\":\"notification_hub\",\"status\":\"disabled\"}"
      else
        let event_type = Option.value ~default:"freight_auction.integration.test" (Dream.header request "X-Event-Type") in
        Store.enqueue_integration ~tenant_id:value.tenant_id ~integration_name:"notification_hub" ~event_type ~target_url_env_var:"NOTIFICATION_HUB_URL" ~payload:"{}" ~idempotency_key:(idempotency_key request ("notification-test-" ^ value.user_id)) >>= function
        | Ok json -> Dream.json (Yojson.Safe.to_string json)
        | Error error -> store_error error

let test_workflow_engine request =
  match permission request Permission_matrix.Manage_integration Permission_matrix.Tenant with
  | Error response -> response
  | Ok value ->
      if Sys.getenv_opt "WORKFLOW_ENGINE_ENABLED" <> Some "true" then
        Dream.json "{\"adapter\":\"workflow_engine\",\"status\":\"disabled\"}"
      else
        json_body request >>= fun json ->
        (match required_string "workflow_id" json with
         | Error response -> response
         | Ok workflow_id ->
             let payload = Yojson.Safe.to_string (`Assoc [ ("workflow_id", `String workflow_id) ]) in
             Store.enqueue_integration ~tenant_id:value.tenant_id ~integration_name:"workflow_engine" ~event_type:"freight_auction.approval.test" ~target_url_env_var:"WORKFLOW_ENGINE_URL" ~payload ~idempotency_key:(idempotency_key request ("workflow-test-" ^ workflow_id)) >>= function
             | Ok result -> Dream.json (Yojson.Safe.to_string result)
             | Error error -> store_error error)

let webhook_bid_update request =
  match Sys.getenv_opt "WEBHOOK_ENGINE_RECEIVER_SECRET", Dream.header request "X-Webhook-Signature" with
  | Some secret, Some signature ->
      Dream.body request >>= fun body ->
      if String.length body > 1_048_576 || not (Integration_protocol.verify_webhook ~secret ~body ~signature) then
        error_json ~status:`Unauthorized "WEBHOOK_SIGNATURE_INVALID" "The webhook signature is invalid."
      else
        (try
           let json = Yojson.Safe.from_string body in
           Dream.json (Yojson.Safe.to_string (`Assoc [ ("received", `Bool true); ("event_type", Option.value ~default:"unknown" (string_member "event_type" json) |> fun value -> `String value) ]))
         with Yojson.Json_error _ -> error_json "WEBHOOK_PAYLOAD_INVALID" "The webhook payload is invalid.")
  | _ -> error_json ~status:`Unauthorized "WEBHOOK_AUTH_REQUIRED" "A webhook signature is required."

let approve_award request =
  match permission request Permission_matrix.Approve_award Permission_matrix.Tenant with
  | Error response -> response
  | Ok value ->
      json_body request >>= fun json ->
      let note = Option.value ~default:"Approved by operator" (string_member "note" json) in
      Store.approve_award ~tenant_id:value.tenant_id ~user_id:value.user_id ~award_id:(Dream.param request "id") ~note >>= function
      | Ok approval_id -> Dream.json (Yojson.Safe.to_string (`Assoc [ ("award_id", `String (Dream.param request "id")); ("approval_id", `String approval_id); ("status", `String "approved") ]))
      | Error error -> store_error error

let reject_award request =
  match permission request Permission_matrix.Approve_award Permission_matrix.Tenant with
  | Error response -> response
  | Ok value ->
      json_body request >>= fun json ->
      (match required_string "reason" json with
       | Error response -> response
       | Ok reason -> Store.reject_award ~tenant_id:value.tenant_id ~user_id:value.user_id ~award_id:(Dream.param request "id") ~reason >>= function
         | Ok _ -> Dream.json "{\"status\":\"rejected\"}"
         | Error error -> store_error error)

let withdraw_award request =
  match actor request with
  | None -> error_json ~status:`Unauthorized "AUTH_REQUIRED" "Authentication is required."
  | Some value ->
      let scope = if value.role = "carrier_viewer" then Permission_matrix.Own_carrier else Permission_matrix.Tenant in
      (match permission request Permission_matrix.Withdraw_award scope with
       | Error response -> response
       | Ok _ ->
           let carrier_id = if value.role = "carrier_viewer" then value.carrier_id else None in
           Store.withdraw_award ~tenant_id:value.tenant_id ~award_id:(Dream.param request "id") ~carrier_id >>= function
           | Error error -> store_error error
           | Ok auction_id ->
               Store.record_audit ~tenant_id:value.tenant_id ~user_id:value.user_id ~entity_type:"award" ~entity_id:(Dream.param request "id") ~event_type:"award_withdrawn" ~payload:(Yojson.Safe.to_string (`Assoc [ ("auction_id", `String auction_id) ])) >>= fun audit ->
               (match audit with
                | Error error -> store_error error
                | Ok () ->
                    Store.enqueue_clear ~tenant_id:value.tenant_id ~auction_id ~user_id:value.user_id >>= function
                    | Ok job_id -> Dream.json (Yojson.Safe.to_string (`Assoc [ ("status", `String "reclear_queued"); ("auction_id", `String auction_id); ("job_id", `String job_id) ]))
                    | Error error -> store_error error))

let export_auction request =
  match permission request Permission_matrix.Export_report Permission_matrix.Tenant with
  | Error response -> response
  | Ok value ->
      json_body request >>= fun json ->
      let format = Option.value ~default:"json" (string_member "format" json) in
      Store.export_snapshot ~tenant_id:value.tenant_id ~user_id:value.user_id ~auction_id:(Dream.param request "id") ~format >>= function
      | Error error -> store_error error
      | Ok (report_id, snapshot) -> render_report ~format ~report_id snapshot

let get_report request =
  match permission request Permission_matrix.Export_report Permission_matrix.Tenant with
  | Error response -> response
  | Ok value -> Store.get_report ~tenant_id:value.tenant_id ~report_id:(Dream.param request "id") >>= function
    | Error error -> store_error error
    | Ok (report_id, format, snapshot) -> render_report ~format ~report_id snapshot

let get_auction request =
  match permission request Permission_matrix.Read_tenant Permission_matrix.Tenant with
  | Error response -> response
  | Ok value ->
      let carrier_id = if value.role = "carrier_viewer" then value.carrier_id else None in
      Store.get_auction ~tenant_id:value.tenant_id ~auction_id:(Dream.param request "id") ~carrier_id >>= function Ok json -> Dream.json (Yojson.Safe.to_string json) | Error error -> store_error error

let list_bids request =
  match actor request with
  | None -> error_json ~status:`Unauthorized "AUTH_REQUIRED" "Authentication is required."
  | Some value ->
      let scope, carrier_id, action = if value.role = "carrier_viewer" then Permission_matrix.Own_carrier, value.carrier_id, Permission_matrix.Read_own_bid else Permission_matrix.Any_carrier, None, Permission_matrix.Read_competitor_bid in
      (match permission request action scope with
       | Error response -> response
       | Ok _ -> Store.list_bids ~tenant_id:value.tenant_id ~auction_id:(Dream.param request "id") ~carrier_id >>= function Ok json -> Dream.json (Yojson.Safe.to_string json) | Error error -> store_error error)

let list_carrier_bids request =
  match permission request Permission_matrix.Read_own_bid Permission_matrix.Own_carrier with
  | Error response -> response
  | Ok value ->
      (match value.carrier_id with None -> error_json ~status:`Forbidden "CARRIER_SCOPE_REQUIRED" "A carrier identity is required." | Some carrier_id -> Store.list_carrier_bids ~tenant_id:value.tenant_id ~carrier_id >>= function Ok json -> Dream.json (Yojson.Safe.to_string json) | Error error -> store_error error)

let create_auction request =
  match permission request Permission_matrix.Manage_auctions Permission_matrix.Tenant with
  | Error response -> response
  | Ok value ->
      json_body request >>= fun json ->
      match (required_string "name" json, required_string "mode" json, required_string "bid_open_at" json, required_string "bid_close_at" json) with
      | Ok name, Ok mode, Ok open_at, Ok close_at ->
          if mode <> "single_round_spot" then
            error_json ~status:`Not_Implemented "AUCTION_MODE_UNSUPPORTED" "Only single_round_spot is enabled for production clearing."
          else
            let auto_clear_on_close = Option.value ~default:false (bool_member "auto_clear_on_close" json) in
            Store.create_auction ~auto_clear_on_close ~tenant_id:value.tenant_id ~user_id:value.user_id ~name ~mode ~bid_open_at:open_at ~bid_close_at:close_at >>= (function Ok id -> Dream.json (Yojson.Safe.to_string (`Assoc [ ("id", `String id); ("status", `String "open"); ("auto_clear_on_close", `Bool auto_clear_on_close) ])) | Error error -> store_error error)
      | Error response, _, _, _ | _, Error response, _, _ | _, _, Error response, _ | _, _, _, Error response -> response

let update_auction request =
  match permission request Permission_matrix.Manage_auctions Permission_matrix.Tenant with
  | Error response -> response
  | Ok value ->
      json_body request >>= fun json ->
      (match (required_string "name" json, required_string "bid_open_at" json, required_string "bid_close_at" json) with
       | Ok name, Ok bid_open_at, Ok bid_close_at ->
           Store.update_auction ~tenant_id:value.tenant_id ~auction_id:(Dream.param request "id") ~name ~bid_open_at ~bid_close_at >>= (function
             | Ok result -> Dream.json (Yojson.Safe.to_string result)
             | Error error -> store_error error)
       | Error response, _, _ | _, Error response, _ | _, _, Error response -> response)

let close_auction request =
  match permission request Permission_matrix.Close_auction Permission_matrix.Tenant with
  | Error response -> response
  | Ok value ->
      json_body request >>= fun json ->
      let auto_queue = Option.value ~default:false (bool_member "auto_queue_clearing" json) in
      Store.close_auction ~tenant_id:value.tenant_id ~auction_id:(Dream.param request "id") >>= function
      | Error error -> store_error error
      | Ok () when auto_queue ->
          Store.enqueue_clear ~tenant_id:value.tenant_id ~auction_id:(Dream.param request "id") ~user_id:value.user_id >>= (function
            | Ok job_id -> Dream.json (Yojson.Safe.to_string (`Assoc [ ("status", `String "clearing_queued"); ("job_id", `String job_id) ]))
            | Error error -> store_error error)
      | Ok () -> Dream.json "{\"status\":\"closed\"}"

let clear_auction request =
  match permission request Permission_matrix.Request_clear Permission_matrix.Tenant with
  | Error response -> response
  | Ok value ->
      Store.get_auction ~tenant_id:value.tenant_id ~auction_id:(Dream.param request "id") ~carrier_id:None >>= function
      | Error error -> store_error error
      | Ok auction ->
          (match string_member "mode" auction with
           | Some mode when Result.is_ok (Capability_registry.production_mode mode) ->
               Store.enqueue_clear ~tenant_id:value.tenant_id ~auction_id:(Dream.param request "id") ~user_id:value.user_id >>= (function
                 | Ok job_id -> Dream.json (Yojson.Safe.to_string (`Assoc [ ("job_id", `String job_id); ("status", `String "queued") ]))
                 | Error error -> store_error error)
           | _ -> error_json ~status:`Not_Implemented "AUCTION_MODE_UNSUPPORTED" "Only single_round_spot is enabled for production clearing.")

let cancel_job request =
  match permission request Permission_matrix.Request_clear Permission_matrix.Tenant with
  | Error response -> response
  | Ok value ->
      Job_store.cancel ~tenant_id:value.tenant_id ~job_id:(Dream.param request "id")
      >>= function
      | Ok () -> Dream.json "{\"status\":\"cancelled\"}"
      | Error _ -> error_json ~status:`Conflict "JOB_STATE_CONFLICT" "The clearing job could not be cancelled in its current state."

let retry_job request =
  match permission request Permission_matrix.Request_clear Permission_matrix.Tenant with
  | Error response -> response
  | Ok value ->
      Job_store.retry ~tenant_id:value.tenant_id ~job_id:(Dream.param request "id")
      >>= function
      | Ok () -> Dream.json "{\"status\":\"queued\"}"
      | Error _ -> error_json ~status:`Conflict "JOB_STATE_CONFLICT" "The clearing job is not retryable."

let add_load request =
  match permission request Permission_matrix.Manage_auctions Permission_matrix.Tenant with
  | Error response -> response
  | Ok value ->
      json_body request >>= fun json ->
      let fields = List.map (fun name -> (name, required_string name json)) [ "lane_id"; "external_ref"; "pickup_start"; "pickup_end"; "delivery_start"; "delivery_end"; "equipment_type" ] in
      let weight = int_member "weight_lbs" json in
      match (List.map snd fields, weight) with
      | [ Ok lane; Ok external_ref; Ok pickup_start; Ok pickup_end; Ok delivery_start; Ok delivery_end; Ok equipment ], Some weight_lbs ->
          Store.add_load ~tenant_id:value.tenant_id ~auction_id:(Dream.param request "id") ~lane_id:lane ~external_ref ~pickup_start ~pickup_end ~delivery_start ~delivery_end ~weight_lbs ~equipment_type:equipment >>= (function Ok id -> Dream.json (Yojson.Safe.to_string (`Assoc [ ("id", `String id); ("status", `String "eligible") ])) | Error error -> store_error error)
      | _ -> error_json "REQUEST_INVALID" "All load fields are required."

let submit_bid request =
  match permission request Permission_matrix.Submit_bid Permission_matrix.Own_carrier with
  | Error response -> response
  | Ok value ->
      json_body request >>= fun json ->
      let carrier_id = match value.carrier_id with Some carrier -> Some carrier | None -> string_member "carrier_id" json in
      (match (carrier_id, required_string "load_id" json, required_string "idempotency_key" json, int_member "bid_amount_cents" json, int_member "service_score_milli" json, required_string "submitted_at" json) with
       | Some carrier, Ok load_id, Ok idempotency_key, Some amount, Some score, Ok submitted_at ->
           Store.submit_bid ~tenant_id:value.tenant_id ~auction_id:(Dream.param request "id") ~load_id ~carrier_id:carrier ~idempotency_key ~bid_amount_cents:amount ~service_score_milli:score ~submitted_at >>= (function Ok id -> Dream.json (Yojson.Safe.to_string (`Assoc [ ("id", `String id); ("status", `String "submitted") ])) | Error error -> store_error error)
       | _ -> error_json "REQUEST_INVALID" "A valid load, idempotency key, amount, score, and timestamp are required.")

let _legacy_page _request = Dream.html "<!doctype html><html lang=\"en\"><body>legacy</body></html>"

let _legacy_assets _request = Dream.respond ~status:`OK ~headers:[ ("Content-Type", "text/css; charset=utf-8") ] "body{}"

let assets _request = Dream.respond ~status:`OK ~headers:[ ("Content-Type", "text/css; charset=utf-8") ] "body{margin:0;background:#f5f7f9;color:#16212b;font:16px system-ui,sans-serif}header{display:flex;justify-content:space-between;align-items:center;padding:20px 6vw;background:#102a43;color:#fff}header a{color:inherit;text-decoration:none;margin-right:20px}.hero{max-width:760px;padding:12vh 6vw}.eyebrow{letter-spacing:.12em;color:#127c8a;font-size:.75rem;font-weight:700}.hero h1{font-size:clamp(2.3rem,6vw,5rem);line-height:1.02;margin:.4em 0}.large-copy{font-size:1.25rem}.button{display:inline-block;background:#8f3018;color:#fff;padding:14px 20px;border-radius:8px;text-decoration:none;font-weight:700}.desk{margin:0 6vw 48px;padding:28px;background:#fff;border:1px solid #b8c6d1;border-radius:12px}.section-heading{display:flex;justify-content:space-between}.risk-status{font-weight:700;color:#7b2616}.status-icon{display:inline-grid;place-items:center;width:24px;height:24px;border-radius:50%;background:#7b2616;color:#fff}.table-wrap{overflow:auto}table{border-collapse:collapse;width:100%;min-width:560px}th,td{text-align:left;border-bottom:1px solid #b8c6d1;padding:12px}button,input{font:inherit;min-height:44px}.row-action{border:2px solid #102a43;background:#fff;color:#102a43;border-radius:7px;padding:8px 12px}.detail-panel,.import-ledger,.frontier{margin-top:24px;padding:20px;border:1px solid #b8c6d1;border-radius:8px}.detail-panel{background:#edf7f6}.import-ledger{background:#fffaf0}.import-ledger input{display:block;margin:8px 0;border:2px solid #102a43;padding:8px}.import-ledger p[role=alert]{color:#7b2616;font-weight:600}.frontier{background:#f1f5fb}.essential-graphic{padding:18px;background:#102a43;color:#fff;border-radius:8px;margin-bottom:12px}.dialog{position:fixed;inset:20% 10%;z-index:2;background:#fff;border:3px solid #102a43;padding:28px;box-shadow:0 12px 40px #16212b55}.cards{display:grid;grid-template-columns:repeat(3,1fr);gap:18px;padding:0 6vw 8vh}.cards article{background:#fff;padding:24px;border:1px solid #b8c6d1;border-radius:12px}.sr-only{position:absolute;width:1px;height:1px;padding:0;margin:-1px;overflow:hidden;clip:rect(0,0,0,0);white-space:nowrap;border:0}:focus-visible{outline:3px solid #c2410c;outline-offset:3px}@media(max-width:700px){header{display:block}.section-heading{display:block}.cards{grid-template-columns:1fr}.hero{padding-top:8vh}.desk{margin-inline:3vw;padding:18px}}@media(prefers-reduced-motion:reduce){*,*::before,*::after{animation-duration:.01ms!important;transition-duration:.01ms!important;scroll-behavior:auto!important}}"
let page request = Dream.html (Console_page.html_for_path (Dream.target request))

let app () =
  Dream.pipeline [ request_id_middleware; rate_limit_middleware; authenticate ]
    (Dream.router
       [ Dream.get "/" page; Dream.get "/login" page; Dream.get "/dashboard" page; Dream.get "/auctions" page; Dream.get "/auctions/:id" page; Dream.get "/auctions/:id/import" page; Dream.get "/auctions/:id/clearing" page; Dream.get "/auctions/:id/infeasible" page; Dream.get "/approvals" page; Dream.get "/replays" page; Dream.get "/reports" page; Dream.get "/policies" page; Dream.get "/policies/:id" page; Dream.get "/carrier/bids" page; Dream.get "/carriers/:id" page; Dream.get "/settings/integrations" page; Dream.get "/settings/notifications" page; Dream.get "/settings/tenant" page; Dream.get "/settings/users" page; Dream.get "/operator/jobs" page; Dream.get "/assets/style.css" assets;
         Dream.get "/health" health; Dream.get "/health/db" health_db; Dream.get "/health/ready" ready;
         Dream.post "/api/auth/register" register; Dream.post "/api/tenants/register" register; Dream.post "/api/auth/refresh" refresh; Dream.get "/api/me" me; Dream.get "/tenants/me" tenant_me; Dream.get "/api/auctions" list_auctions; Dream.post "/api/auctions" create_auction; Dream.get "/api/auctions/:id" get_auction; Dream.patch "/api/auctions/:id" update_auction; Dream.get "/api/auctions/:id/bids" list_bids; Dream.get "/api/carrier/bids" list_carrier_bids; Dream.post "/api/auctions/:id/close" close_auction; Dream.post "/api/auctions/:id/close-bidding" close_auction; Dream.post "/api/auctions/:id/clear" clear_auction; Dream.post "/api/auctions/:id/loads" add_load; Dream.post "/api/auctions/:id/bids" submit_bid;
         Dream.get "/api/policies" list_policies; Dream.post "/api/policies" create_policy; Dream.post "/api/policies/:id/activate" activate_policy; Dream.get "/api/carriers" list_carriers; Dream.post "/api/carriers" create_carrier; Dream.get "/api/carriers/:id" get_carrier; Dream.patch "/api/carriers/:id" patch_carrier; Dream.get "/api/replays" list_replays; Dream.post "/api/replays" create_replay; Dream.get "/api/replays/:id" get_replay; Dream.get "/api/approvals" list_approvals; Dream.get "/api/notifications" list_notifications; Dream.post "/api/notifications/:id/read" mark_notification_read; Dream.get "/api/reports" list_reports; Dream.get "/api/reports/:id" get_report; Dream.get "/api/audit-events" list_audit_events; Dream.get "/api/settings/integrations" list_integrations; Dream.get "/api/integration-settings" list_integrations; Dream.patch "/api/integration-settings" patch_integration; Dream.get "/api/integrations/health" integration_health; Dream.post "/api/integrations/notification-hub/test" test_notification_hub; Dream.post "/api/integrations/workflow-engine/test" test_workflow_engine; Dream.post "/api/integrations/webhook-engine/bid-updates" webhook_bid_update; Dream.get "/api/settings/notifications" notification_preferences; Dream.patch "/api/settings/notifications" patch_notification_preference; Dream.get "/api/settings/tenant" tenant_settings; Dream.patch "/api/settings/tenant" patch_tenant_settings; Dream.get "/api/settings/users" list_users; Dream.post "/api/settings/users" create_user; Dream.get "/api/settings/users/:id" get_user; Dream.patch "/api/settings/users/:id" patch_user; Dream.post "/api/imports" create_import; Dream.get "/api/imports/:id" get_import; Dream.post "/api/imports/:id/commit" commit_import;
         Dream.get "/api/clearing-jobs" list_clearing_jobs; Dream.get "/api/clearing-jobs/:id" get_clearing_job; Dream.post "/api/clearing-jobs/:id/cancel" cancel_job; Dream.post "/api/clearing-jobs/:id/retry" retry_job; Dream.get "/api/auctions/:id/awards" list_awards; Dream.get "/api/auctions/:id/explanations" list_explanations; Dream.post "/api/auctions/:id/export" export_auction; Dream.post "/api/awards/:id/approve" approve_award; Dream.post "/api/awards/:id/reject" reject_award; Dream.post "/api/awards/:id/withdraw" withdraw_award; Dream.get "/metrics" (fun _ -> Dream.respond (Metrics.prometheus ())) ])

let () =
  match Runtime_config.from_process_env () with
  | Error _ -> prerr_endline "{\"status\":\"error\",\"code\":\"CONFIG_INVALID\"}"; exit 2
  | Ok config ->
      let data = Runtime_config.data config in
      Runtime_config.Secret.with_value data.database_url (fun database_url ->
          match Lwt_main.run (Db_pool.start (Uri.of_string database_url)) with
          | Error _ -> prerr_endline "{\"status\":\"error\",\"code\":\"DATABASE_STARTUP_FAILED\"}"; exit 1
          | Ok _ ->
              (if data.migrations_auto_run then
                 match Lwt_main.run (Migration_runner.run Migration_catalog.production) with
                 | Error _ -> prerr_endline "{\"status\":\"error\",\"code\":\"MIGRATION_STARTUP_FAILED\"}"; exit 1
                 | Ok _ -> ());
              Runtime_config.Secret.with_value data.redis_url (fun redis_url ->
                  match Lwt_main.run (Redis_queue.start ~timeout_s:5.0 (Uri.of_string redis_url)) with
                  | Error _ -> prerr_endline "{\"status\":\"error\",\"code\":\"REDIS_STARTUP_FAILED\"}"; exit 1
                  | Ok _ -> Dream.run ~interface:"0.0.0.0" ~port:(Runtime_config.app config).port ~greeting:false (app ())))
