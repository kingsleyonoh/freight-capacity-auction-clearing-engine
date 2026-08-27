open Lwt.Infix

let env_or name fallback = Option.value (Sys.getenv_opt name) ~default:fallback

let fixture_path () =
  env_or "FCA_TENANT_FIXTURE" "tests/fixtures/tenants.json" |> Unix.realpath

let fixture () =
  match Tenant_fixture.load_file (fixture_path ()) with
  | Ok fixture -> fixture
  | Error errors ->
      Alcotest.failf "fixture rejected: %s"
        (String.concat "," (List.map Tenant_fixture.error_code errors))

let free_loopback_port () =
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  Fun.protect
    ~finally:(fun () -> Unix.close socket)
    (fun () ->
      Unix.bind socket (Unix.ADDR_INET (Unix.inet_addr_loopback, 0));
      match Unix.getsockname socket with
      | Unix.ADDR_INET (_, port) -> port
      | _ -> Alcotest.fail "expected an internet socket")

let rec remove_tree path =
  if Sys.file_exists path then
    if Sys.is_directory path then (
      Sys.readdir path
      |> Array.iter (fun child -> remove_tree (Filename.concat path child));
      Unix.rmdir path)
    else Sys.remove path

let json_line channel =
  Lwt_io.read_line channel >|= fun line -> Yojson.Safe.from_string line

let event_name = function
  | `Assoc fields -> (
      match List.assoc_opt "event" fields with
      | Some (`String event) -> event
      | _ -> "")
  | _ -> ""

let worker_fields body =
  match Yojson.Safe.from_string body with
  | `Assoc fields -> (
      match List.assoc_opt "worker" fields with
      | Some (`Assoc worker_fields) -> worker_fields
      | _ -> Alcotest.fail "worker result object is missing")
  | _ -> Alcotest.fail "worker response must be an object"

let assert_worker_result tenant body =
  let fields = worker_fields body in
  Alcotest.(check (option string))
    "worker validates requested tenant" (Some tenant.Tenant_fixture.id)
    (match List.assoc_opt "validated_tenant_id" fields with
    | Some (`String value) -> Some value
    | _ -> None);
  Alcotest.(check (option int))
    "worker reloaded exactly two tenants" (Some 2)
    (match List.assoc_opt "tenant_count" fields with
    | Some (`Int value) -> Some value
    | _ -> None);
  Alcotest.(check (option bool))
    "worker revalidated overlap" (Some true)
    (match List.assoc_opt "overlap_validated" fields with
    | Some (`Bool value) -> Some value
    | _ -> None)

let exercise_http port tenant =
  let ready_uri =
    Uri.of_string (Printf.sprintf "http://127.0.0.1:%d/__test/ready" port)
  in
  Cohttp_lwt_unix.Client.get ready_uri >>= fun (ready, ready_body) ->
  Cohttp_lwt.Body.drain_body ready_body >>= fun () ->
  Alcotest.(check int)
    "real HTTP ready" 200
    (Cohttp.Response.status ready |> Cohttp.Code.code_of_status);
  let path = "/__test/tenants/" ^ tenant.Tenant_fixture.id ^ "/validate" in
  let uri = Uri.of_string (Printf.sprintf "http://127.0.0.1:%d%s" port path) in
  let headers =
    Cohttp.Header.of_list
      [ ("content-type", "application/json"); ("x-fca-test-tenant", tenant.id) ]
  in
  Cohttp_lwt_unix.Client.call ~headers
    ~body:(Cohttp_lwt.Body.of_string "{}")
    `POST uri
  >>= fun (response, body) ->
  Cohttp_lwt.Body.to_string body >|= fun body ->
  Alcotest.(check int)
    "meaningful worker validation" 200
    (Cohttp.Response.status response |> Cohttp.Code.code_of_status);
  assert_worker_result tenant body

let executable env fallback = env_or env fallback |> Unix.realpath

let start_supervisor port root =
  let supervisor =
    executable "FCA_RUNTIME_SUPERVISOR"
      "_build/default/tests/e2e/fixtures/runtime_supervisor.exe"
  in
  let server =
    executable "FCA_HTTP_FIXTURE_SERVER"
      "_build/default/tests/e2e/fixtures/http_fixture_server.exe"
  in
  let worker =
    executable "FCA_WORKER_FIXTURE"
      "_build/default/tests/e2e/fixtures/worker_fixture.exe"
  in
  let args =
    [|
      supervisor;
      "--server";
      server;
      "--worker";
      worker;
      "--fixture";
      fixture_path ();
      "--control";
      root;
      "--port";
      string_of_int port;
    |]
  in
  Lwt_process.open_process_full ~env:[||] (supervisor, args)

let run_journey process port tenant =
  json_line process#stdout >>= fun ready ->
  Alcotest.(check string) "supervisor ready" "ready" (event_name ready);
  exercise_http port tenant >>= fun () ->
  Lwt_io.write_line process#stdin {|{"protocolVersion":1,"command":"stop"}|}
  >>= fun () ->
  json_line process#stdout >>= fun stopped ->
  Alcotest.(check string) "supervisor stopped" "stopped" (event_name stopped);
  process#status >|= fun status ->
  Alcotest.(check int)
    "supervisor exit" 0
    (match status with Unix.WEXITED code -> code | _ -> 255)

let assert_cleanup port root =
  Alcotest.(check bool) "control directory cleaned" false (Sys.file_exists root);
  let socket = Unix.socket Unix.PF_INET Unix.SOCK_STREAM 0 in
  let closed =
    Fun.protect
      ~finally:(fun () -> Unix.close socket)
      (fun () ->
        try
          Unix.connect socket (Unix.ADDR_INET (Unix.inet_addr_loopback, port));
          false
        with Unix.Unix_error _ -> true)
  in
  Alcotest.(check bool) "loopback port closed" true closed

let test_lifecycle_protocol () =
  let port = free_loopback_port () in
  let tenant = List.hd (fixture ()).tenants in
  let root =
    Filename.concat
      (Filename.get_temp_dir_name ())
      (Printf.sprintf "fca-e2e-lifecycle-%d-%d" (Unix.getpid ()) port)
  in
  remove_tree root;
  let process = start_supervisor port root in
  Lwt_main.run (run_journey process port tenant);
  assert_cleanup port root

let run () =
  Alcotest.run "real-http-lifecycle"
    [
      ( "compiled-fixtures",
        [
          Alcotest.test_case "ready worker stop cleanup" `Quick
            test_lifecycle_protocol;
        ] );
    ]
