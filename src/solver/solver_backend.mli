type selected = [ `Minizinc | `Ortools ]

type availability = private
  | Available of { version : string; capabilities : string list }
  | Missing of string
  | Unhealthy of string

type config

type config_error =
  | Backend_invalid
  | Timeout_invalid
  | Minizinc_path_invalid
  | Ortools_path_invalid
  | Ortools_path_required

type terminal_status

type report = {
  selected : selected;
  minizinc : availability;
  ortools : availability;
}

type selected_report = {
  selected : selected;
  availability : availability;
}

type error = Malformed_output

val config_from_lookup :
  get:(string -> string option) -> (config, config_error list) result

val config_error_code : config_error -> string
val probe : Process_runner.t -> config -> report Lwt.t
val probe_selected : Process_runner.t -> config -> selected_report Lwt.t
val selected_name : selected -> string
val selected_executable : config -> string option
val timeout : config -> float
val available_version : availability -> string option
val selected_availability : report -> availability
val parse_minizinc_stream : string -> (terminal_status, error) result
val terminal_status_name : terminal_status -> string
val error_to_string : error -> string
val availability_to_yojson : availability -> Yojson.Safe.t
val report_to_yojson : report -> Yojson.Safe.t
val selected_report_to_yojson : selected_report -> Yojson.Safe.t
