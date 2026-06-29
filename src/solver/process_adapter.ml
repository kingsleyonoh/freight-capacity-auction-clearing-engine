module Runtime_config = Freight_capacity_auction_clearing_engine_config.Runtime_config

type backend = Minizinc | Ortools | Heuristic_baseline

type run_request = {
  tenant_id : string;
  auction_id : string;
  job_id : string;
  backend : backend;
  model_path : string;
  output_path : string;
  timeout_seconds : int;
}

type process_command = {
  program : string;
  args : string list;
  timeout_seconds : int;
}

let require_non_blank field value =
  if String.trim value = "" then invalid_arg (field ^ " is required") else value

let backend_to_string = function
  | Minizinc -> "minizinc"
  | Ortools -> "ortools"
  | Heuristic_baseline -> "heuristic_baseline"

let backend_of_string = function
  | "minizinc" -> Ok Minizinc
  | "ortools" -> Ok Ortools
  | "heuristic_baseline" -> Ok Heuristic_baseline
  | value -> Error ("unknown solver backend: " ^ value)

let backend_of_config config =
  match backend_of_string config.Runtime_config.solver_backend with
  | Ok backend -> backend
  | Error message -> invalid_arg message

let create_request config ~tenant_id ~auction_id ~job_id ~model_path ~output_path () =
  {
    tenant_id = require_non_blank "tenant_id" tenant_id;
    auction_id = require_non_blank "auction_id" auction_id;
    job_id = require_non_blank "job_id" job_id;
    backend = backend_of_config config;
    model_path = require_non_blank "model_path" model_path;
    output_path = require_non_blank "output_path" output_path;
    timeout_seconds = config.Runtime_config.solver_timeout_seconds;
  }

let artifact_prefix request =
  Printf.sprintf "%s/%s/%s" request.tenant_id request.auction_id request.job_id

let production_success_allowed request =
  match request.backend with Heuristic_baseline -> false | Minizinc | Ortools -> true

let command config request =
  match request.backend with
  | Minizinc ->
      Ok
        {
          program = require_non_blank "MINIZINC_BINARY_PATH" config.Runtime_config.minizinc_binary_path;
          args = [ request.model_path; "--output-to"; request.output_path ];
          timeout_seconds = request.timeout_seconds;
        }
  | Ortools ->
      if String.trim config.Runtime_config.ortools_worker_path = "" then
        Error "ORTOOLS_WORKER_PATH is required for ortools backend"
      else
        Ok
          {
            program = config.Runtime_config.ortools_worker_path;
            args = [ "--model"; request.model_path; "--output"; request.output_path ];
            timeout_seconds = request.timeout_seconds;
          }
  | Heuristic_baseline -> Error "heuristic_baseline is not a production solver process"
