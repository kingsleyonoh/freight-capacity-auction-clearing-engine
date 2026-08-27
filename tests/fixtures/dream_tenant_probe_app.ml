(* TEST-ONLY Dream probe. This module is linked only by test libraries and
   test fixture executables; production bins must never depend on it. *)

open Lwt.Infix

type worker_check = string -> (Yojson.Safe.t, string) result Lwt.t

let tenant_header = "X-FCA-Test-Tenant"
let request_field = Dream.new_field ~name:"fca_test_tenant_context" ()

let error_json ~status code message =
  let body =
    `Assoc
      [
        ( "error",
          `Assoc
            [
              ("code", `String code);
              ("message", `String message);
              ("details", `List []);
            ] );
      ]
    |> Yojson.Safe.to_string
  in
  Dream.json ~status body

let request_id request =
  match Dream.header request "X-FCA-Test-Request" with
  | Some value when value <> "" && String.length value <= 128 -> value
  | _ -> "test-request-1"

let canonical_error error =
  match error.Dream.condition with
  | `Response response -> Lwt.return response
  | `String _ | `Exn _ ->
      error_json ~status:`Internal_Server_Error "TEST_INTERNAL_ERROR"
        "The test fixture request failed."

let tenant_middleware fixture next request =
  if Dream.target request = "/__test/ready" then next request
  else
    match Dream.header request tenant_header with
    | None ->
        error_json ~status:`Bad_Request "TEST_TENANT_REQUIRED"
          "A fixture tenant is required."
    | Some raw_id -> (
        match Tenant_fixture.find_tenant fixture raw_id with
        | None ->
            error_json ~status:`Bad_Request "TEST_TENANT_INVALID"
              "The fixture tenant is invalid."
        | Some tenant -> (
            match Tenant_context.Tenant_id.of_string tenant.id with
            | Error _ ->
                error_json ~status:`Internal_Server_Error
                  "TEST_FIXTURE_CONTEXT_INVALID"
                  "The fixture tenant context is invalid."
            | Ok tenant_id -> (
                match
                  Tenant_context.system ~tenant_id ~name:"test_probe"
                    ~request_id:(request_id request) ()
                with
                | Error _ ->
                    error_json ~status:`Internal_Server_Error
                      "TEST_FIXTURE_CONTEXT_INVALID"
                      "The fixture tenant context is invalid."
                | Ok context ->
                    Dream.set_field request request_field context;
                    next request)))

let context request =
  match Dream.field request request_field with
  | Some value -> value
  | None -> failwith "test tenant middleware was not registered"

let with_request_id request response =
  Dream.set_header response "X-Request-ID"
    (Tenant_context.request_id (context request));
  Lwt.return response

let json_response request json =
  Dream.json (Yojson.Safe.to_string json) >>= with_request_id request

let not_found request =
  error_json ~status:`Not_Found "TEST_RESOURCE_NOT_FOUND"
    "The requested test resource was not found."
  >>= with_request_id request

let requested_current_tenant fixture request =
  let context_id =
    context request |> Tenant_context.tenant_id
    |> Tenant_context.Tenant_id.to_string
  in
  let path_id = Dream.param request "tenant_id" in
  if path_id <> context_id then None
  else Tenant_fixture.find_tenant fixture context_id

let ready _request =
  Dream.json
    ~headers:[ ("X-Request-ID", "test-readiness") ]
    (Yojson.Safe.to_string
       (`Assoc
          [
            ("service", `String "fca-test-fixture"); ("protocol_version", `Int 1);
          ]))

let tenant_probe fixture request =
  match requested_current_tenant fixture request with
  | None -> not_found request
  | Some tenant ->
      json_response request
        (`Assoc
           [
             ("tenant", Tenant_fixture.public_tenant_yojson tenant);
             ("schema_version", `Int fixture.schema_version);
           ])

let valid_error_code value =
  value <> ""
  && String.length value <= 64
  && String.for_all
       (function 'A' .. 'Z' | '0' .. '9' | '_' -> true | _ -> false)
       value

let worker_probe fixture worker_check request =
  match requested_current_tenant fixture request with
  | None -> not_found request
  | Some tenant -> (
      worker_check tenant.id >>= function
      | Ok result ->
          json_response request
            (`Assoc
               [
                 ("tenant", Tenant_fixture.public_tenant_yojson tenant);
                 ("worker", result);
               ])
      | Error code ->
          let code =
            if valid_error_code code then code else "WORKER_FIXTURE_REJECTED"
          in
          error_json ~status:`Service_Unavailable code
            "The fixture worker could not validate the request."
          >>= with_request_id request)

let build ~fixture ~worker_check =
  Dream.catch canonical_error
  @@ tenant_middleware fixture
  @@ Dream.router
       [
         Dream.get "/__test/ready" ready;
         Dream.get "/__test/tenants/:tenant_id" (tenant_probe fixture);
         Dream.post "/__test/tenants/:tenant_id/validate"
           (worker_probe fixture worker_check);
       ]
