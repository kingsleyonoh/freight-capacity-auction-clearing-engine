let read_exact path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let () =
  match Array.to_list Sys.argv with
  | _ :: pairs when List.length pairs > 0 && List.length pairs mod 2 = 0 ->
      let rec sources acc = function
        | [] -> List.rev acc
        | filename :: path :: rest ->
            sources ((filename, read_exact path) :: acc) rest
        | _ -> assert false
      in
      Printf.printf "let production_sources : (string * string) list = [\n";
      sources [] pairs
      |> List.iter (fun (filename, sql) ->
             Printf.printf "  (%S, %S);\n" filename sql);
      Printf.printf "]\n"
  | _ ->
      prerr_endline
        "usage: generate_migration_catalog filename path [filename path ...]";
      exit 64
