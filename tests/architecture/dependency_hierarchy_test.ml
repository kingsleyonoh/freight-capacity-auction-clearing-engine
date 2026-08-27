module String_set = Set.Make (String)

type sexp = Atom of string | List of sexp list
type token = Left | Right | Word of string

let allowed =
  [
    ("fca_config", []);
    ("fca_shared", []);
    ("fca_process_runner", []);
    ("fca_auth", [ "fca_shared" ]);
    ("fca_tenants", [ "fca_shared"; "fca_auth" ]);
    ("fca_carriers", [ "fca_shared"; "fca_auth" ]);
    ("fca_policies", [ "fca_shared"; "fca_auth" ]);
    ( "fca_imports",
      [
        "fca_shared"; "fca_auth"; "fca_tenants"; "fca_carriers"; "fca_policies";
      ] );
    ( "fca_auctions",
      [
        "fca_shared";
        "fca_auth";
        "fca_tenants";
        "fca_carriers";
        "fca_policies";
        "fca_imports";
      ] );
    ("fca_solver", [ "fca_shared"; "fca_process_runner" ]);
    ( "fca_clearing",
      [
        "fca_shared";
        "fca_auctions";
        "fca_carriers";
        "fca_policies";
        "fca_solver";
      ] );
    ("fca_approvals", [ "fca_shared"; "fca_auth"; "fca_clearing" ]);
    ( "fca_replays",
      [
        "fca_shared";
        "fca_process_runner";
        "fca_auctions";
        "fca_policies";
        "fca_clearing";
        "fca_solver";
      ] );
    ( "fca_reports",
      [
        "fca_shared";
        "fca_tenants";
        "fca_auctions";
        "fca_clearing";
        "fca_approvals";
      ] );
    ( "fca_notifications",
      [
        "fca_shared";
        "fca_auth";
        "fca_tenants";
        "fca_auctions";
        "fca_approvals";
        "fca_reports";
      ] );
    ( "fca_integrations",
      [
        "fca_shared";
        "fca_auth";
        "fca_auctions";
        "fca_approvals";
        "fca_notifications";
      ] );
    ( "fca_application",
      [
        "fca_shared";
        "fca_auth";
        "fca_tenants";
        "fca_carriers";
        "fca_policies";
        "fca_imports";
        "fca_auctions";
        "fca_solver";
        "fca_clearing";
        "fca_approvals";
        "fca_replays";
        "fca_reports";
        "fca_notifications";
        "fca_integrations";
      ] );
    ( "fca_jobs",
      [
        "fca_shared";
        "fca_auth";
        "fca_tenants";
        "fca_carriers";
        "fca_policies";
        "fca_imports";
        "fca_auctions";
        "fca_solver";
        "fca_clearing";
        "fca_approvals";
        "fca_replays";
        "fca_reports";
        "fca_notifications";
        "fca_integrations";
      ] );
    ( "fca_ui",
      [
        "fca_shared";
        "fca_auth";
        "fca_tenants";
        "fca_carriers";
        "fca_policies";
        "fca_imports";
        "fca_auctions";
        "fca_clearing";
        "fca_approvals";
        "fca_replays";
        "fca_reports";
        "fca_notifications";
        "fca_integrations";
      ] );
  ]

let tokenize text =
  let length = String.length text in
  let rec word_end index =
    if
      index >= length
      || List.mem text.[index] [ ' '; '\n'; '\r'; '\t'; '('; ')'; ';' ]
    then index
    else word_end (index + 1)
  in
  let rec comment_end index =
    if index >= length || text.[index] = '\n' then index
    else comment_end (index + 1)
  in
  let rec loop index tokens =
    if index >= length then List.rev tokens
    else
      match text.[index] with
      | ' ' | '\n' | '\r' | '\t' -> loop (index + 1) tokens
      | ';' -> loop (comment_end (index + 1)) tokens
      | '(' -> loop (index + 1) (Left :: tokens)
      | ')' -> loop (index + 1) (Right :: tokens)
      | _ ->
          let ending = word_end index in
          loop ending (Word (String.sub text index (ending - index)) :: tokens)
  in
  loop 0 []

let rec parse_one = function
  | Word value :: rest -> (Atom value, rest)
  | Left :: rest ->
      let rec items accumulator = function
        | Right :: tail -> (List (List.rev accumulator), tail)
        | [] -> failwith "unclosed Dune stanza"
        | tokens ->
            let item, remaining = parse_one tokens in
            items (item :: accumulator) remaining
      in
      items [] rest
  | Right :: _ -> failwith "unexpected closing parenthesis"
  | [] -> failwith "unexpected end of Dune file"

let parse text =
  let rec all accumulator = function
    | [] -> List.rev accumulator
    | tokens ->
        let item, remaining = parse_one tokens in
        all (item :: accumulator) remaining
  in
  all [] (tokenize text)

let field name fields =
  List.find_map
    (function
      | List (Atom key :: values) when key = name -> Some values | _ -> None)
    fields

let project_dependencies fields =
  Option.value ~default:[] (field "libraries" fields)
  |> List.filter_map (function
    | Atom name when String.starts_with ~prefix:"fca_" name -> Some name
    | _ -> None)

let libraries text =
  parse text
  |> List.filter_map (function
    | List (Atom "library" :: fields) -> (
        match field "name" fields with
        | Some [ Atom name ] -> Some (name, project_dependencies fields)
        | _ -> None)
    | _ -> None)

let rec files_under root relative =
  let path = if relative = "" then root else Filename.concat root relative in
  Sys.readdir path |> Array.to_list
  |> List.concat_map (fun name ->
      let child_relative =
        if relative = "" then name else Filename.concat relative name
      in
      let child = Filename.concat root child_relative in
      if Sys.is_directory child then
        if
          List.mem name
            [ ".git"; "_build"; "_opam"; "node_modules"; ".pi"; ".yolo" ]
        then []
        else files_under root child_relative
      else if name = "dune" then [ child ]
      else [])

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let project_root () =
  let rec ascend path candidate =
    let candidate =
      if Sys.file_exists (Filename.concat path "dune-project") then Some path
      else candidate
    in
    let parent = Filename.dirname path in
    if parent = path then Option.value ~default:(Sys.getcwd ()) candidate
    else ascend parent candidate
  in
  ascend (Sys.getcwd ()) None

let inspect root =
  files_under root ""
  |> List.concat_map (fun path -> libraries (read_file path))

let validate libraries =
  let known = List.map fst allowed |> String_set.of_list in
  let errors = ref [] in
  List.iter
    (fun (name, dependencies) ->
      if
        String.starts_with ~prefix:"fca_" name
        && not (String_set.mem name known)
      then errors := ("unknown library " ^ name) :: !errors;
      match List.assoc_opt name allowed with
      | None -> ()
      | Some permitted ->
          List.iter
            (fun dependency ->
              if not (List.mem dependency permitted) then
                errors := (name ^ " -> " ^ dependency) :: !errors)
            dependencies)
    libraries;
  List.rev !errors

let test_actual_project () =
  let libraries = inspect (project_root ()) in
  Alcotest.(check bool)
    "real fca_config library exists" true
    (List.exists (fun (name, _) -> name = "fca_config") libraries);
  Alcotest.(check (list string))
    "actual libraries obey the graph" [] (validate libraries)

let test_policy_fail_closed () =
  Alcotest.(check (list string))
    "unknown project library rejected"
    [ "unknown library fca_surprise" ]
    (validate [ ("fca_surprise", []) ]);
  Alcotest.(check (list string))
    "upward edge rejected"
    [ "fca_approvals -> fca_integrations" ]
    (validate [ ("fca_approvals", [ "fca_integrations" ]) ]);
  Alcotest.(check (list string))
    "absent future libraries allowed" []
    (validate [ ("fca_config", []) ])

let () =
  Alcotest.run "Dune dependency hierarchy"
    [
      ( "actual",
        [ Alcotest.test_case "project graph" `Quick test_actual_project ] );
      ( "policy",
        [ Alcotest.test_case "fail closed" `Quick test_policy_fail_closed ] );
    ]
