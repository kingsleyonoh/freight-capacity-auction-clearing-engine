let fixture = Sys.getenv "FCA_PROCESS_FIXTURE" |> Unix.realpath
let run_lwt value = Lwt_main.run value
let runner () = Process_runner.create ~allowed_env:[]

let contains haystack needle =
  let length = String.length needle in
  let rec loop index =
    index + length <= String.length haystack
    && (String.sub haystack index length = needle || loop (index + 1))
  in
  length = 0 || loop 0

let lookup values name = List.assoc_opt name values

let config values =
  match Solver_backend.config_from_lookup ~get:(lookup values) with
  | Ok config -> config
  | Error errors ->
      let codes =
        List.map Solver_backend.config_error_code errors |> String.concat ","
      in
      Alcotest.fail ("unexpected solver config errors: " ^ codes)

let configured ?(selected = "minizinc") minizinc ortools =
  [
    ("SOLVER_BACKEND", selected);
    ("MINIZINC_BINARY_PATH", minizinc);
    ("SOLVER_TIMEOUT_SECONDS", "1");
  ]
  @ Option.fold ~none:[]
      ~some:(fun value -> [ ("ORTOOLS_WORKER_PATH", value) ])
      ortools
  |> config

let availability_name = function
  | Solver_backend.Available _ -> "available"
  | Solver_backend.Missing _ -> "missing"
  | Solver_backend.Unhealthy _ -> "unhealthy"

let expect_unhealthy expected = function
  | Solver_backend.Unhealthy reason ->
      Alcotest.(check string) "stable unhealthy reason" expected reason
  | value ->
      Alcotest.fail ("expected unhealthy, received " ^ availability_name value)

let test_probes_both_and_selected () =
  let report =
    run_lwt
      (Solver_backend.probe (runner ()) (configured fixture (Some fixture)))
  in
  Alcotest.(check string)
    "minizinc available" "available"
    (availability_name report.minizinc);
  Alcotest.(check string)
    "ortools available" "available"
    (availability_name report.ortools);
  Alcotest.(check string)
    "selected remains minizinc" "minizinc"
    (Solver_backend.selected_name report.selected);
  match (report.minizinc, report.ortools) with
  | Solver_backend.Available minizinc, Solver_backend.Available ortools ->
      Alcotest.(check string)
        "normalized MiniZinc version" "2.8.7" minizinc.version;
      Alcotest.(check (list string))
        "normalized capability IDs" [ "org.gecode.gecode" ]
        minizinc.capabilities;
      Alcotest.(check string)
        "normalized OR-Tools version" "9.12.0" ortools.version
  | _ -> Alcotest.fail "expected normalized available metadata"

let test_missing_and_no_fallback () =
  let missing =
    Filename.concat (Filename.get_temp_dir_name ()) "fca-missing-minizinc"
  in
  let report =
    run_lwt
      (Solver_backend.probe (runner ()) (configured missing (Some fixture)))
  in
  Alcotest.(check string)
    "selected backend missing" "missing"
    (availability_name (Solver_backend.selected_availability report));
  Alcotest.(check string)
    "unselected alternative available" "available"
    (availability_name report.ortools);
  Alcotest.(check string)
    "no implicit fallback" "minizinc"
    (Solver_backend.selected_name report.selected)

let test_selected_probe_has_no_fallback_surface () =
  let selected =
    run_lwt
      (Solver_backend.probe_selected (runner ())
         (configured fixture (Some fixture)))
  in
  Alcotest.(check string)
    "explicit selected backend" "minizinc"
    (Solver_backend.selected_name selected.selected);
  Alcotest.(check string)
    "selected MiniZinc available" "available"
    (availability_name selected.availability);
  let rendered =
    Solver_backend.selected_report_to_yojson selected |> Yojson.Safe.to_string
  in
  Alcotest.(check bool)
    "selected probe does not expose OR-Tools fallback" false
    (contains rendered "ortools")

let test_optional_ortools_blank_normalizes_to_unconfigured () =
  match
    Solver_backend.config_from_lookup
      ~get:
        (lookup
           [
             ("SOLVER_BACKEND", "minizinc");
             ("MINIZINC_BINARY_PATH", fixture);
             ("ORTOOLS_WORKER_PATH", "   ");
           ])
  with
  | Ok _ -> ()
  | Error errors ->
      Alcotest.fail
        ("optional blank OR-Tools path rejected: "
        ^ (List.map Solver_backend.config_error_code errors |> String.concat ",")
        )

let test_ortools_unconfigured_rejected () =
  match
    Solver_backend.config_from_lookup
      ~get:
        (lookup
           [ ("SOLVER_BACKEND", "ortools"); ("MINIZINC_BINARY_PATH", fixture) ])
  with
  | Error errors ->
      Alcotest.(check (list string))
        "selected OR-Tools requires a path"
        [ "SOLVER_ORTOOLS_PATH_REQUIRED" ]
        (List.map Solver_backend.config_error_code errors)
  | Ok _ -> Alcotest.fail "expected selected OR-Tools configuration failure"

let temporary_directory prefix =
  let path = Filename.temp_file prefix "" in
  Sys.remove path;
  Unix.mkdir path 0o700;
  path

let copy_file source target =
  let input_channel = open_in_bin source in
  let output_channel = open_out_bin target in
  Fun.protect
    ~finally:(fun () ->
      close_in_noerr input_channel;
      close_out_noerr output_channel)
    (fun () ->
      let buffer = Bytes.create 8192 in
      let rec loop () =
        match input input_channel buffer 0 (Bytes.length buffer) with
        | 0 -> ()
        | count ->
            output output_channel buffer 0 count;
            loop ()
      in
      loop ());
  Unix.chmod target 0o700

let with_fixture_mode mode consume =
  let root = temporary_directory "fca-solver-metadata" in
  let executable = Filename.concat root mode in
  copy_file fixture executable;
  Fun.protect
    ~finally:(fun () ->
      Sys.remove executable;
      Unix.rmdir root)
    (fun () -> consume executable)

let assert_no_raw_metadata report =
  let rendered =
    Solver_backend.report_to_yojson report |> Yojson.Safe.to_string
  in
  List.iter
    (fun forbidden ->
      Alcotest.(check bool)
        ("report excludes " ^ forbidden)
        false
        (contains rendered forbidden))
    [ "solver-private"; "SECRET"; "../"; "\\" ]

let test_hostile_minizinc_versions () =
  let modes =
    [
      "mz-version-multiline";
      "mz-version-path";
      "mz-version-control";
      "mz-version-oversize";
      "mz-version-wrong-prefix";
      "mz-version-malformed-semver";
    ]
  in
  List.iter
    (fun mode ->
      with_fixture_mode mode (fun executable ->
          let report =
            run_lwt
              (Solver_backend.probe (runner ()) (configured executable None))
          in
          expect_unhealthy "MINIZINC_VERSION_MALFORMED" report.minizinc;
          assert_no_raw_metadata report))
    modes

let test_hostile_minizinc_capabilities () =
  let modes =
    [ "mz-capability-path"; "mz-capability-control"; "mz-capability-oversize" ]
  in
  List.iter
    (fun mode ->
      with_fixture_mode mode (fun executable ->
          let report =
            run_lwt
              (Solver_backend.probe (runner ()) (configured executable None))
          in
          expect_unhealthy "MINIZINC_CAPABILITIES_MALFORMED" report.minizinc;
          assert_no_raw_metadata report))
    modes

let test_hostile_ortools_metadata () =
  let modes =
    [
      "ort-version-multiline";
      "ort-version-path";
      "ort-version-control";
      "ort-version-oversize";
      "ort-version-malformed-semver";
      "ort-backend-wrong";
      "ort-capability-path";
      "ort-capability-control";
      "ort-capability-oversize";
    ]
  in
  List.iter
    (fun mode ->
      with_fixture_mode mode (fun executable ->
          let report =
            run_lwt
              (Solver_backend.probe (runner ())
                 (configured fixture (Some executable)))
          in
          expect_unhealthy "ORTOOLS_HEALTH_MALFORMED" report.ortools;
          assert_no_raw_metadata report))
    modes

let test_config_is_solver_specific () =
  let requested = ref [] in
  let get name =
    requested := name :: !requested;
    None
  in
  (match Solver_backend.config_from_lookup ~get with
  | Ok _ -> ()
  | Error _ -> Alcotest.fail "solver-only defaults should parse");
  let actual = List.sort_uniq String.compare !requested in
  Alcotest.(check (list string))
    "only solver-specific variables requested"
    [
      "MINIZINC_BINARY_PATH";
      "ORTOOLS_WORKER_PATH";
      "SOLVER_BACKEND";
      "SOLVER_TIMEOUT_SECONDS";
    ]
    actual

let test_invalid_timeouts_fail_fast () =
  [ "not-a-number"; "0"; "-1"; "1.5"; "3601"; "nan"; "inf"; "1e999" ]
  |> List.iter (fun timeout ->
      match
        Solver_backend.config_from_lookup
          ~get:(lookup [ ("SOLVER_TIMEOUT_SECONDS", timeout) ])
      with
      | Error errors ->
          Alcotest.(check (list string))
            "invalid timeout code"
            [ "SOLVER_TIMEOUT_INVALID" ]
            (List.map Solver_backend.config_error_code errors)
      | Ok _ -> Alcotest.fail ("accepted invalid timeout " ^ timeout));
  [ "1"; "3600" ]
  |> List.iter (fun timeout ->
      match
        Solver_backend.config_from_lookup
          ~get:(lookup [ ("SOLVER_TIMEOUT_SECONDS", timeout) ])
      with
      | Ok _ -> ()
      | Error _ -> Alcotest.fail ("rejected bounded timeout " ^ timeout))

let test_path_presence_reasons_are_stable () =
  let missing_minizinc =
    Filename.concat
      (Filename.get_temp_dir_name ())
      "configured-missing-minizinc"
  in
  let missing_ortools =
    Filename.concat (Filename.get_temp_dir_name ()) "configured-missing-ortools"
  in
  let report =
    run_lwt
      (Solver_backend.probe (runner ())
         (configured missing_minizinc (Some missing_ortools)))
  in
  (match report.minizinc with
  | Solver_backend.Missing reason ->
      Alcotest.(check string)
        "configured MiniZinc reason" "MINIZINC_CONFIGURED_NOT_FOUND" reason
  | _ -> Alcotest.fail "expected configured MiniZinc missing");
  match report.ortools with
  | Solver_backend.Missing reason ->
      Alcotest.(check string)
        "configured OR-Tools reason" "ORTOOLS_CONFIGURED_NOT_FOUND" reason
  | _ -> Alcotest.fail "expected configured OR-Tools missing"

let parse value =
  match Solver_backend.parse_minizinc_stream value with
  | Ok status -> status
  | Error error -> Alcotest.fail (Solver_backend.error_to_string error)

let test_official_terminal_json () =
  let stream =
    "{\"type\":\"solution\",\"output\":{\"json\":{\"award\":1}}}\n\
     {\"type\":\"status\",\"status\":\"OPTIMAL_SOLUTION\"}\n"
  in
  Alcotest.(check string)
    "official terminal status" "OPTIMAL_SOLUTION"
    (Solver_backend.terminal_status_name (parse stream));
  Alcotest.(check string)
    "official infeasible status" "UNSATISFIABLE"
    (Solver_backend.terminal_status_name
       (parse "{\"type\":\"status\",\"status\":\"UNSATISFIABLE\"}\n"))

let test_malformed_terminal_json () =
  let cases =
    [
      "{\"type\":\"solution\"}\n";
      "not-json\n";
      "{\"type\":\"status\",\"status\":\"MADE_UP\"}\n";
      "{\"type\":\"status\",\"status\":\"SATISFIED\"}\n\
       {\"type\":\"solution\"}\n";
    ]
  in
  List.iter
    (fun value ->
      match Solver_backend.parse_minizinc_stream value with
      | Error Solver_backend.Malformed_output -> ()
      | _ -> Alcotest.fail "expected malformed terminal JSON")
    cases

let () =
  Alcotest.run "solver backend boundary"
    [
      ( "probe",
        [
          Alcotest.test_case "MiniZinc and OR-Tools health" `Quick
            test_probes_both_and_selected;
          Alcotest.test_case "selected backend never falls back" `Quick
            test_missing_and_no_fallback;
          Alcotest.test_case "selected-only probe surface" `Quick
            test_selected_probe_has_no_fallback_surface;
          Alcotest.test_case "optional blank OR-Tools normalizes" `Quick
            test_optional_ortools_blank_normalizes_to_unconfigured;
          Alcotest.test_case "OR-Tools selection requires config" `Quick
            test_ortools_unconfigured_rejected;
          Alcotest.test_case "hostile MiniZinc versions are redacted" `Quick
            test_hostile_minizinc_versions;
          Alcotest.test_case "hostile MiniZinc capabilities are redacted" `Quick
            test_hostile_minizinc_capabilities;
          Alcotest.test_case "hostile OR-Tools metadata is redacted" `Quick
            test_hostile_ortools_metadata;
          Alcotest.test_case "configured missing reasons are stable" `Quick
            test_path_presence_reasons_are_stable;
        ] );
      ( "configuration",
        [
          Alcotest.test_case "solver-only parser" `Quick
            test_config_is_solver_specific;
          Alcotest.test_case "invalid timeout fails fast" `Quick
            test_invalid_timeouts_fail_fast;
        ] );
      ( "MiniZinc stream",
        [
          Alcotest.test_case "official terminal JSON" `Quick
            test_official_terminal_json;
          Alcotest.test_case "malformed/missing terminal" `Quick
            test_malformed_terminal_json;
        ] );
    ]
