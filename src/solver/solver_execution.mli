type result = { terminal_status : string; stdout : string; stderr : string; input_hash : string; output_hash : string }

val run : Process_runner.t -> executable:string -> model_path:string -> data_path:string -> timeout:float -> (result, string) Stdlib.result Lwt.t
