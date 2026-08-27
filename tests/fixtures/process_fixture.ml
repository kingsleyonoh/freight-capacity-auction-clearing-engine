let arg index = if Array.length Sys.argv > index then Sys.argv.(index) else ""

let write_repeated channel character count =
  let chunk = Bytes.make 4096 character in
  let rec loop remaining =
    if remaining > 0 then (
      let length = min remaining (Bytes.length chunk) in
      output channel chunk 0 length;
      flush channel;
      loop (remaining - length))
  in
  loop count

let read_stdin () =
  let buffer = Buffer.create 256 in
  (try
     while true do
       Buffer.add_channel buffer stdin 4096
     done
   with End_of_file -> ());
  Buffer.contents buffer

let contains haystack needle =
  let length = String.length needle in
  let rec loop index =
    index + length <= String.length haystack
    && (String.sub haystack index length = needle || loop (index + 1))
  in
  length = 0 || loop 0

let emit_argv () =
  let values =
    Array.to_list (Array.sub Sys.argv 2 (Array.length Sys.argv - 2))
  in
  print_endline
    (Yojson.Safe.to_string
       (`List (List.map (fun value -> `String value) values)))

let descendant marker delay =
  match Unix.fork () with
  | 0 ->
      Unix.sleepf delay;
      let channel = open_out_bin marker in
      output_string channel "survived";
      close_out channel;
      exit 0
  | _ -> Unix.sleepf (delay *. 4.)

let term_resistant_descendant marker delay =
  let ready_read, ready_write = Unix.pipe () in
  match Unix.fork () with
  | 0 ->
      Unix.close ready_read;
      Sys.set_signal Sys.sigterm Sys.Signal_ignore;
      ignore (Unix.write_substring ready_write "1" 0 1);
      Unix.close ready_write;
      Unix.close Unix.stdin;
      Unix.close Unix.stdout;
      Unix.close Unix.stderr;
      Unix.sleepf delay;
      let channel = open_out_bin marker in
      output_string channel "survived";
      close_out channel;
      exit 0
  | _ ->
      Unix.close ready_write;
      let ready = Bytes.create 1 in
      ignore (Unix.read ready_read ready 0 1);
      Unix.close ready_read;
      Unix.sleepf (delay *. 4.)

let capture_duckdb_invocation database stdin_text =
  let output = open_out_bin (database ^ ".invocation") in
  output_string output
    (Yojson.Safe.to_string
       (`Assoc
          [
            ( "argv",
              `List
                (Array.to_list Sys.argv |> List.tl
                |> List.map (fun value -> `String value)) );
            ("stdin", `String stdin_text);
          ]));
  close_out output

let duckdb database =
  let stdin_text = read_stdin () in
  if database <> ":memory:" then capture_duckdb_invocation database stdin_text;
  if String.starts_with ~prefix:"malformed" (Filename.basename database) then
    print_endline "not-json"
  else if
    List.for_all (contains stdin_text)
      [
        "duckdb_version";
        "benchmark_row_count";
        "tenant_count";
        "month_count";
        "auction_count";
        "load_count";
        "bid_count";
        "baseline_eligible_count";
        "landed_cost_sum";
      ]
  then
    print_endline
      "[{\"duckdb_version\":\"v1.3.2\",\"benchmark_row_count\":432,\"tenant_count\":2,\"month_count\":12,\"auction_count\":48,\"load_count\":144,\"bid_count\":432,\"baseline_eligible_count\":288,\"landed_cost_sum\":\"889488.00\"}]"
  else if contains stdin_text "parquet_supported" then
    print_endline "[{\"parquet_supported\":true}]"
  else if contains stdin_text "csv_supported" then
    print_endline "[{\"csv_supported\":true}]"
  else print_endline "[{\"duckdb_version\":\"v1.3.2\"}]"

let fixture_mode () = Filename.basename Sys.executable_name

let minizinc_version () =
  match fixture_mode () with
  | "mz-version-multiline" ->
      "MiniZinc to FlatZinc converter, version 2.8.7\n/tmp/solver-private"
  | "mz-version-path" ->
      "MiniZinc to FlatZinc converter, version /tmp/solver-private"
  | "mz-version-control" ->
      "MiniZinc to FlatZinc converter, version 2.8.\027SECRET"
  | "mz-version-oversize" ->
      "MiniZinc to FlatZinc converter, version " ^ String.make 200 '9'
  | "mz-version-wrong-prefix" -> "solver-private version 2.8.7"
  | "mz-version-malformed-semver" ->
      "MiniZinc to FlatZinc converter, version 2.8"
  | _ -> "MiniZinc to FlatZinc converter, version 2.8.7"

let minizinc_capability () =
  match fixture_mode () with
  | "mz-capability-path" -> "../../solver-private"
  | "mz-capability-control" -> "gecode\nSECRET"
  | "mz-capability-oversize" -> String.make 200 'a'
  | _ -> "org.gecode.gecode"

let minizinc () =
  let flag = if arg 1 = "minizinc" then arg 2 else arg 1 in
  match flag with
  | "--version" -> print_endline (minizinc_version ())
  | "--solvers-json" ->
      print_endline
        (Yojson.Safe.to_string
           (`List [ `Assoc [ ("id", `String (minizinc_capability ())) ] ]))
  | _ ->
      print_endline
        "{\"type\":\"solution\",\"output\":{\"json\":{\"award\":1}}}";
      print_endline "{\"type\":\"status\",\"status\":\"OPTIMAL_SOLUTION\"}"

let ortools_version () =
  match fixture_mode () with
  | "ort-version-multiline" -> "9.12.0\n/tmp/solver-private"
  | "ort-version-path" -> "/tmp/solver-private"
  | "ort-version-control" -> "9.12.\027SECRET"
  | "ort-version-oversize" -> String.make 200 '9'
  | "ort-version-malformed-semver" -> "9.12"
  | _ -> "9.12.0"

let ortools_metadata () =
  match fixture_mode () with
  | "ort-capability-path" ->
      [ ("capabilities", `List [ `String "../../solver-private" ]) ]
  | "ort-capability-control" ->
      [ ("capabilities", `List [ `String "health\nSECRET" ]) ]
  | "ort-capability-oversize" ->
      [ ("capabilities", `List [ `String (String.make 200 'a') ]) ]
  | _ -> []

let ortools () =
  let flag = if arg 1 = "ortools" then arg 2 else arg 1 in
  if flag = "--health-json" then
    let backend =
      if fixture_mode () = "ort-backend-wrong" then "solver-private"
      else "ortools"
    in
    print_endline
      (Yojson.Safe.to_string
         (`Assoc
            ([
               ("protocol_version", `Int 1);
               ("status", `String "ok");
               ("backend", `String backend);
               ("version", `String (ortools_version ()));
             ]
            @ ortools_metadata ())))
  else exit 64

let () =
  match arg 1 with
  | "--version" | "--solvers-json" -> minizinc ()
  | "--health-json" -> ortools ()
  | "-batch" -> duckdb (arg (Array.length Sys.argv - 1))
  | "argv" -> emit_argv ()
  | "stdin" ->
      print_string (read_stdin ());
      flush stdout
  | "nonzero" ->
      prerr_endline "sensitive child detail";
      exit (int_of_string (arg 2))
  | "signal" ->
      Unix.kill (Unix.getpid ()) Sys.sigterm;
      Unix.sleepf 1.
  | "malformed" -> print_endline "not-json"
  | "flood" ->
      write_repeated stdout 'o' (int_of_string (arg 2));
      write_repeated stderr 'e' (int_of_string (arg 3))
  | "sleep" ->
      Unix.sleepf (float_of_string (arg 2));
      print_endline "awake"
  | "descendant" -> descendant (arg 2) (float_of_string (arg 3))
  | "term-resistant-descendant" ->
      term_resistant_descendant (arg 2) (float_of_string (arg 3))
  | "minizinc" -> minizinc ()
  | "ortools" -> ortools ()
  | "duckdb" -> duckdb (arg (Array.length Sys.argv - 1))
  | _ ->
      prerr_endline "unknown fixture mode";
      exit 64
