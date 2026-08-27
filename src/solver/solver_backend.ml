open Lwt.Infix

type selected = [ `Minizinc | `Ortools ]

type availability =
  | Available of { version : string; capabilities : string list }
  | Missing of string
  | Unhealthy of string

type config = {
  selected : selected;
  minizinc_executable : string;
  minizinc_configured : bool;
  ortools_executable : string option;
  timeout : float;
}

type config_error =
  | Backend_invalid
  | Timeout_invalid
  | Minizinc_path_invalid
  | Ortools_path_invalid
  | Ortools_path_required

type terminal_status =
  | Satisfied
  | All_solutions
  | Optimal_solution
  | Unsatisfiable
  | Unbounded
  | Unsat_or_unbounded
  | Unknown
  | Solver_error

type report = {
  selected : selected;
  minizinc : availability;
  ortools : availability;
}

type selected_report = { selected : selected; availability : availability }
type error = Malformed_output

let config_error_code = function
  | Backend_invalid -> "SOLVER_BACKEND_INVALID"
  | Timeout_invalid -> "SOLVER_TIMEOUT_INVALID"
  | Minizinc_path_invalid -> "SOLVER_MINIZINC_PATH_INVALID"
  | Ortools_path_invalid -> "SOLVER_ORTOOLS_PATH_INVALID"
  | Ortools_path_required -> "SOLVER_ORTOOLS_PATH_REQUIRED"

let supplied get name = Option.map String.trim (get name)

let parse_backend get errors =
  match supplied get "SOLVER_BACKEND" with
  | None -> `Minizinc
  | Some "minizinc" -> `Minizinc
  | Some "ortools" -> `Ortools
  | Some _ ->
      errors := Backend_invalid :: !errors;
      `Minizinc

let parse_timeout get errors =
  match supplied get "SOLVER_TIMEOUT_SECONDS" with
  | None -> 30.
  | Some value -> (
      match int_of_string_opt value with
      | Some timeout when timeout >= 1 && timeout <= 3_600 ->
          float_of_int timeout
      | _ ->
          errors := Timeout_invalid :: !errors;
          30.)

let parse_minizinc get errors =
  match supplied get "MINIZINC_BINARY_PATH" with
  | None -> ("minizinc", false)
  | Some value when value <> "" && not (String.contains value '\000') ->
      (value, true)
  | Some _ ->
      errors := Minizinc_path_invalid :: !errors;
      ("minizinc", true)

let parse_ortools get errors =
  match supplied get "ORTOOLS_WORKER_PATH" with
  | None | Some "" -> None
  | Some value when not (String.contains value '\000') -> Some value
  | Some _ ->
      errors := Ortools_path_invalid :: !errors;
      None

let config_from_lookup ~get =
  let errors = ref [] in
  let selected = parse_backend get errors in
  let minizinc_executable, minizinc_configured = parse_minizinc get errors in
  let ortools_executable = parse_ortools get errors in
  let timeout = parse_timeout get errors in
  if
    selected = `Ortools
    && Option.is_none ortools_executable
    && not (List.mem Ortools_path_invalid !errors)
  then errors := Ortools_path_required :: !errors;
  match List.rev !errors with
  | [] ->
      Ok
        {
          selected;
          minizinc_executable;
          minizinc_configured;
          ortools_executable;
          timeout;
        }
  | errors -> Error errors

let selected_name = function `Minizinc -> "minizinc" | `Ortools -> "ortools"

let error_to_string Malformed_output = "SOLVER_MALFORMED_OUTPUT"

let executable_exists path =
  try
    Unix.access path [ Unix.X_OK ];
    true
  with _ -> false

let split_path value =
  String.split_on_char (if Sys.win32 then ';' else ':') value
  |> List.filter (fun item -> item <> "")

let resolve_executable executable =
  if executable = "" || String.contains executable '\000' then None
  else if
    (not (Filename.is_relative executable))
    || String.contains executable Filename.dir_sep.[0]
  then
    if executable_exists executable then Some (Unix.realpath executable)
    else None
  else
    let path = Option.value ~default:"" (Sys.getenv_opt "PATH") in
    split_path path
    |> List.find_map (fun directory ->
        let candidate = Filename.concat directory executable in
        if executable_exists candidate then Some (Unix.realpath candidate)
        else None)

let selected_executable (config : config) =
  match config.selected with
  | `Minizinc -> resolve_executable config.minizinc_executable
  | `Ortools -> Option.bind config.ortools_executable resolve_executable

let timeout (config : config) = config.timeout

let available_version = function
  | Available { version; _ } -> Some version
  | Missing _ | Unhealthy _ -> None

let process_request executable argv timeout =
  Process_runner.request ~executable ~argv ~env:[] ~stdin:"" ~stdin_limit:0
    ~stdout_limit:131072 ~stderr_limit:16384 ~timeout ~term_grace:0.2 ()

let run runner executable argv timeout =
  Process_runner.run runner (process_request executable argv timeout)

let safe_numeric_identifier value =
  let length = String.length value in
  length >= 1 && length <= 10
  && (length = 1 || value.[0] <> '0')
  && String.for_all (function '0' .. '9' -> true | _ -> false) value

let strict_semver value =
  String.length value <= 64
  &&
  match String.split_on_char '.' value with
  | [ major; minor; patch ] ->
      List.for_all safe_numeric_identifier [ major; minor; patch ]
  | _ -> false

let parse_minizinc_version value =
  let prefix = "MiniZinc to FlatZinc converter, version " in
  let lines = String.split_on_char '\n' (String.trim value) in
  let value = match lines with first :: rest when List.for_all (String.starts_with ~prefix:"Copyright (C)") rest -> first | _ -> "" in
  if
    String.length value <= String.length prefix + 64
    && String.starts_with ~prefix value
  then
    let version =
      String.sub value (String.length prefix)
        (String.length value - String.length prefix)
    in
    if strict_semver version then Some version else None
  else None

let safe_capability_id value =
  let length = String.length value in
  let safe_character = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '.' | '_' | '-' -> true
    | _ -> false
  in
  let safe_first = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' -> true
    | _ -> false
  in
  length >= 1 && length <= 64
  && safe_first value.[0]
  && String.for_all safe_character value

let parse_solvers value =
  try
    match Yojson.Safe.from_string value with
    | `List solvers when solvers <> [] && List.length solvers <= 64 ->
        let ids =
          List.map
            (function
              | `Assoc fields -> (
                  match List.assoc_opt "id" fields with
                  | Some (`String id) when safe_capability_id id -> id
                  | _ -> raise Exit)
              | _ -> raise Exit)
            solvers
        in
        if List.length (List.sort_uniq String.compare ids) = List.length ids
        then Some ids
        else None
    | _ -> None
  with _ -> None

let probe_minizinc runner executable configured timeout =
  match resolve_executable executable with
  | None ->
      let reason =
        if configured then "MINIZINC_CONFIGURED_NOT_FOUND"
        else "MINIZINC_DEFAULT_NOT_FOUND"
      in
      Lwt.return (Missing reason)
  | Some executable -> (
      Lwt.both
        (run runner executable [ "--version" ] timeout)
        (run runner executable [ "--solvers-json" ] timeout)
      >|= fun (version, solvers) ->
      match (version, solvers) with
      | Ok version, Ok solvers -> (
          match parse_minizinc_version version.stdout with
          | None -> Unhealthy "MINIZINC_VERSION_MALFORMED"
          | Some version -> (
              match parse_solvers solvers.stdout with
              | Some capabilities -> Available { version; capabilities }
              | None -> Unhealthy "MINIZINC_CAPABILITIES_MALFORMED"))
      | _ -> Unhealthy "MINIZINC_PROBE_FAILED")

let parse_ortools_health value =
  try
    let json = Yojson.Safe.from_string value in
    let fields = match json with `Assoc fields -> fields | _ -> raise Exit in
    let names = List.map fst fields |> List.sort String.compare in
    if names <> [ "backend"; "protocol_version"; "status"; "version" ] then None
    else
      let open Yojson.Safe.Util in
      let protocol = json |> member "protocol_version" |> to_int in
      let status = json |> member "status" |> to_string in
      let backend = json |> member "backend" |> to_string in
      let version = json |> member "version" |> to_string in
      if
        protocol = 1 && status = "ok" && backend = "ortools"
        && strict_semver version
      then Some version
      else None
  with _ -> None

let probe_ortools runner executable timeout =
  match executable with
  | None -> Lwt.return (Missing "ORTOOLS_NOT_CONFIGURED")
  | Some configured -> (
      match resolve_executable configured with
      | None -> Lwt.return (Missing "ORTOOLS_CONFIGURED_NOT_FOUND")
      | Some executable -> (
          run runner executable [ "--health-json" ] timeout >|= function
          | Ok output -> (
              match parse_ortools_health output.stdout with
              | Some version ->
                  Available { version; capabilities = [ "health-v1" ] }
              | None -> Unhealthy "ORTOOLS_HEALTH_MALFORMED")
          | Error _ -> Unhealthy "ORTOOLS_HEALTH_FAILED"))

let probe runner config =
  Lwt.both
    (probe_minizinc runner config.minizinc_executable config.minizinc_configured
       config.timeout)
    (probe_ortools runner config.ortools_executable config.timeout)
  >|= fun (minizinc, ortools) ->
  { selected = config.selected; minizinc; ortools }

let probe_selected runner (config : config) =
  let availability =
    match config.selected with
    | `Minizinc ->
        probe_minizinc runner config.minizinc_executable
          config.minizinc_configured config.timeout
    | `Ortools -> probe_ortools runner config.ortools_executable config.timeout
  in
  availability >|= fun availability ->
  { selected = config.selected; availability }

let selected_availability (report : report) =
  match report.selected with
  | `Minizinc -> report.minizinc
  | `Ortools -> report.ortools

let terminal_status_of_string = function
  | "SATISFIED" -> Some Satisfied
  | "ALL_SOLUTIONS" -> Some All_solutions
  | "OPTIMAL_SOLUTION" -> Some Optimal_solution
  | "UNSATISFIABLE" -> Some Unsatisfiable
  | "UNBOUNDED" -> Some Unbounded
  | "UNSAT_OR_UNBOUNDED" -> Some Unsat_or_unbounded
  | "UNKNOWN" -> Some Unknown
  | "ERROR" -> Some Solver_error
  | _ -> None

let terminal_status_name = function
  | Satisfied -> "SATISFIED"
  | All_solutions -> "ALL_SOLUTIONS"
  | Optimal_solution -> "OPTIMAL_SOLUTION"
  | Unsatisfiable -> "UNSATISFIABLE"
  | Unbounded -> "UNBOUNDED"
  | Unsat_or_unbounded -> "UNSAT_OR_UNBOUNDED"
  | Unknown -> "UNKNOWN"
  | Solver_error -> "ERROR"

let parse_line line =
  try
    let normalized =
      let buffer = Buffer.create (String.length line) in
      let rec copy index =
        if index >= String.length line then ()
        else if line.[index] = '\\' && index + 1 < String.length line && line.[index + 1] = '"' then (Buffer.add_char buffer '"'; copy (index + 2))
        else (Buffer.add_char buffer line.[index]; copy (index + 1))
      in
      copy 0;
      Buffer.contents buffer
    in
    match Yojson.Safe.from_string normalized with
    | `Assoc fields -> (
        match List.assoc_opt "type" fields with
        | Some (`String "status") -> (
            match List.assoc_opt "status" fields with
            | Some (`String value) ->
                Option.map
                  (fun value -> `Terminal value)
                  (terminal_status_of_string value)
            | _ -> None)
        | Some (`String _) -> Some `Other
        | _ -> None)
    | _ -> None
  with _ -> None

let parse_minizinc_stream value =
  let lines =
    String.split_on_char '\n' value
    |> List.filter (fun line -> String.trim line <> "")
  in
  let is_separator line =
    let line = String.trim line in
    line <> "" && String.for_all (function '-' | '=' -> true | _ -> false) line
  in
  let rec loop seen_status = function
    | [] -> (match seen_status with Some status -> Ok status | None -> Error Malformed_output)
    | line :: rest ->
        (match parse_line line with
         | Some (`Terminal status) -> (match seen_status with None -> loop (Some status) rest | Some _ -> Error Malformed_output)
         | Some `Other -> (match seen_status with None -> loop seen_status rest | Some _ -> Error Malformed_output)
         | None when is_separator line -> loop seen_status rest
         | None -> loop seen_status rest)
  in
  loop None lines

let availability_to_yojson = function
  | Available { version; capabilities } ->
      `Assoc
        [
          ("status", `String "available");
          ("version", `String version);
          ( "capabilities",
            `List (List.map (fun value -> `String value) capabilities) );
        ]
  | Missing reason ->
      `Assoc [ ("status", `String "missing"); ("reason", `String reason) ]
  | Unhealthy reason ->
      `Assoc [ ("status", `String "unhealthy"); ("reason", `String reason) ]

let report_to_yojson (report : report) =
  `Assoc
    [
      ("selected", `String (selected_name report.selected));
      ("selected_status", availability_to_yojson (selected_availability report));
      ("minizinc", availability_to_yojson report.minizinc);
      ("ortools", availability_to_yojson report.ortools);
    ]

let selected_report_to_yojson (report : selected_report) =
  `Assoc
    [
      ("selected", `String (selected_name report.selected));
      ("availability", availability_to_yojson report.availability);
    ]
