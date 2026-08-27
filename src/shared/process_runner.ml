open Lwt.Infix

type t = { allowed_env : string list }
type exit_outcome = [ `Exited of int | `Signaled of int | `Stopped of int ]
type stream = [ `Stdout | `Stderr ]
type capture = { root : string; namespace : string }

type request = {
  executable : string;
  argv : string list;
  env : (string * string) list;
  stdin : string;
  stdin_limit : int;
  stdout_limit : int;
  stderr_limit : int;
  timeout : float;
  term_grace : float;
  capture : capture option;
}

type output = {
  stdout : string;
  stderr : string;
  capture_directory : string option;
}

type error =
  | Invalid_request
  | Invalid_environment
  | Spawn_failed
  | Stdin_limit_exceeded
  | Output_limit_exceeded of stream
  | Timed_out
  | Cancelled
  | Nonzero_exit of exit_outcome
  | Termination_unavailable
  | Artifact_invalid
  | Artifact_write_failed

exception Stream_limit of stream

let create ~allowed_env = { allowed_env }
let capture ~root ~namespace = { root; namespace }

let request ~executable ~argv ~env ~stdin ~stdin_limit ~stdout_limit
    ~stderr_limit ~timeout ~term_grace ?capture () =
  {
    executable;
    argv;
    env;
    stdin;
    stdin_limit;
    stdout_limit;
    stderr_limit;
    timeout;
    term_grace;
    capture;
  }

let error_code = function
  | Invalid_request -> "PROCESS_INVALID_REQUEST"
  | Invalid_environment -> "PROCESS_INVALID_ENV"
  | Spawn_failed -> "PROCESS_SPAWN_FAILED"
  | Stdin_limit_exceeded -> "PROCESS_STDIN_LIMIT"
  | Output_limit_exceeded `Stdout -> "PROCESS_STDOUT_LIMIT"
  | Output_limit_exceeded `Stderr -> "PROCESS_STDERR_LIMIT"
  | Timed_out -> "PROCESS_TIMEOUT"
  | Cancelled -> "PROCESS_CANCELLED"
  | Nonzero_exit (`Exited _) -> "PROCESS_NONZERO_EXIT"
  | Nonzero_exit (`Signaled _) -> "PROCESS_SIGNALED"
  | Nonzero_exit (`Stopped _) -> "PROCESS_STOPPED"
  | Termination_unavailable -> "PROCESS_TERMINATION_UNAVAILABLE"
  | Artifact_invalid -> "PROCESS_ARTIFACT_INVALID"
  | Artifact_write_failed -> "PROCESS_ARTIFACT_WRITE_FAILED"

let error_to_string = error_code
let has_nul value = String.contains value '\000'

let valid_env_name value =
  let valid_character = function
    | 'A' .. 'Z' | '0' .. '9' | '_' -> true
    | _ -> false
  in
  value <> "" && String.for_all valid_character value

let validate_request runner request =
  if
    request.executable = ""
    || Filename.is_relative request.executable
    || has_nul request.executable || request.argv = []
    || List.exists has_nul request.argv
    || request.stdin_limit < 0 || request.stdout_limit < 0
    || request.stderr_limit < 0 || request.timeout <= 0.
    || request.term_grace < 0.
  then Error Invalid_request
  else if String.length request.stdin > request.stdin_limit then
    Error Stdin_limit_exceeded
  else
    let valid (name, value) =
      valid_env_name name
      && List.mem name runner.allowed_env
      && not (has_nul value)
    in
    if List.for_all valid request.env then Ok () else Error Invalid_environment

let setsid_path () =
  let candidates = [ "/usr/bin/setsid"; "/bin/setsid" ] in
  List.find_opt
    (fun path -> Sys.file_exists path && Unix.access path [ Unix.X_OK ] = ())
    candidates

let taskkill_path () =
  match Sys.getenv_opt "SystemRoot" with
  | None -> None
  | Some root ->
      let path = Filename.concat root "System32\\taskkill.exe" in
      if Sys.file_exists path then Some path else None

let termination_program () =
  if Sys.win32 then Option.map (fun path -> `Taskkill path) (taskkill_path ())
  else Option.map (fun path -> `Setsid path) (setsid_path ())

let command termination request =
  let arguments = Array.of_list request.argv in
  match termination with
  | `Setsid setsid ->
      ( setsid,
        Array.concat [ [| setsid; "--"; request.executable |]; arguments ] )
  | `Taskkill _ ->
      (request.executable, Array.append [| request.executable |] arguments)

let environment values =
  values |> List.map (fun (name, value) -> name ^ "=" ^ value) |> Array.of_list

let drain stream limit channel =
  let buffer = Buffer.create (min limit 4096) in
  let chunk = Bytes.create 4096 in
  let rec loop total =
    Lwt_io.read_into channel chunk 0 (Bytes.length chunk) >>= fun count ->
    if count = 0 then Lwt.return (Buffer.contents buffer)
    else if total + count > limit then Lwt.fail (Stream_limit stream)
    else (
      Buffer.add_subbytes buffer chunk 0 count;
      loop (total + count))
  in
  loop 0

let write_stdin process value =
  Lwt.finalize
    (fun () -> Lwt_io.write process#stdin value)
    (fun () ->
      Lwt.catch
        (fun () -> Lwt_io.close process#stdin)
        (fun _ -> Lwt.return_unit))

let outcome = function
  | Unix.WEXITED code -> `Exited code
  | Unix.WSIGNALED signal -> `Signaled signal
  | Unix.WSTOPPED signal -> `Stopped signal

let kill_posix_group pid signal =
  try
    Unix.kill (-pid) signal;
    Ok ()
  with
  | Unix.Unix_error (Unix.ESRCH, _, _) -> Ok ()
  | _ -> Error ()

let posix_group_presence pid =
  try
    Unix.kill (-pid) 0;
    Ok `Present
  with
  | Unix.Unix_error (Unix.ESRCH, _, _) -> Ok `Absent
  | Unix.Unix_error (Unix.EPERM, _, _) -> Ok `Present
  | _ -> Error ()

let proc_children pid =
  if Sys.win32 then []
  else
    try
      let path = Printf.sprintf "/proc/%d/task/%d/children" pid pid in
      let channel = open_in path in
      let contents =
        Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
            really_input_string channel (in_channel_length channel))
      in
      contents
      |> String.split_on_char ' '
      |> List.filter_map int_of_string_opt
    with _ -> []

let process_tree root =
  let rec visit seen pid =
    if List.mem pid seen then seen
    else List.fold_left visit (pid :: seen) (proc_children pid)
  in
  visit [] root

let kill_pid pid signal =
  try Unix.kill pid signal with Unix.Unix_error (Unix.ESRCH, _, _) -> () | _ -> ()

let proc_pid_is_zombie pid =
  if Sys.win32 then false
  else
    try
      let path = Printf.sprintf "/proc/%d/stat" pid in
      let channel = open_in path in
      let contents =
        Fun.protect ~finally:(fun () -> close_in_noerr channel) (fun () ->
            really_input_string channel (in_channel_length channel))
      in
      match String.rindex_opt contents ')' with
      | Some closing_name ->
          String.length contents > closing_name + 2
          && contents.[closing_name + 2] = 'Z'
      | None -> false
    with _ -> false

let tree_presence pids =
  List.for_all
    (fun pid ->
      match Unix.kill pid 0 with
      | () -> proc_pid_is_zombie pid
      | exception Unix.Unix_error (Unix.ESRCH, _, _) -> true
      | exception _ -> false)
    pids

let bounded_status status timeout =
  Lwt.choose
    [
      (status >|= fun _ -> Ok ());
      (Lwt_unix.sleep timeout >|= fun () -> Error ());
    ]

let verify_posix_group_absent pid timeout =
  let deadline = Unix.gettimeofday () +. timeout in
  let rec verify () =
    match posix_group_presence pid with
    | Ok `Absent -> Lwt.return (Ok ())
    | Error () -> Lwt.return (Error ())
    | Ok `Present when Unix.gettimeofday () >= deadline -> Lwt.return (Error ())
    | Ok `Present -> Lwt_unix.sleep 0.01 >>= verify
  in
  verify ()

let terminate_posix_group process grace =
  let verification_timeout = max 0.5 grace in
  let tree = process_tree process#pid in
  match kill_posix_group process#pid Sys.sigterm with
  | Error () -> Lwt.return (Error ())
  | Ok () -> (
      List.iter (fun pid -> if pid <> process#pid then kill_pid pid Sys.sigterm) tree;
      Lwt_unix.sleep grace >>= fun () ->
      (match posix_group_presence process#pid with
        | Error () -> Lwt.return (Error ())
        | Ok `Absent -> Lwt.return (Ok ())
        | Ok `Present -> Lwt.return (kill_posix_group process#pid Sys.sigkill))
      >>= function
      | Error () -> Lwt.return (Error ())
      | Ok () -> (
          List.iter (fun pid -> if pid <> process#pid then kill_pid pid Sys.sigkill) tree;
          bounded_status process#status verification_timeout >>= function
          | Error () -> Lwt.return (Error ())
          | Ok () ->
              let deadline = Unix.gettimeofday () +. verification_timeout in
              let rec verify () =
                if (not (tree_presence tree)) && Unix.gettimeofday () < deadline then
                  Lwt_unix.sleep 0.01 >>= verify
                else if not (tree_presence tree) then Lwt.return (Error ())
                else if tree_presence tree then Lwt.return (Ok ())
                else verify_posix_group_absent process#pid verification_timeout
              in
              verify ())
      )

let kill_windows_tree taskkill pid =
  let pid = string_of_int pid in
  let command = (taskkill, [| taskkill; "/PID"; pid; "/T"; "/F" |]) in
  Lwt.catch
    (fun () ->
      Lwt_process.exec ~env:[||] command >|= function
      | Unix.WEXITED 0 -> Ok ()
      | _ -> Error ())
    (fun _ -> Lwt.return (Error ()))

let terminate_tree termination process grace =
  match termination with
  | `Taskkill taskkill ->
      if Lwt.is_sleeping process#status then
        kill_windows_tree taskkill process#pid
      else Lwt.return (Error ())
  | `Setsid _ -> terminate_posix_group process grace

let valid_namespace value =
  let valid_character = function
    | 'a' .. 'z' | 'A' .. 'Z' | '0' .. '9' | '-' | '_' -> true
    | _ -> false
  in
  value <> "" && value <> "." && value <> ".."
  && String.length value <= 64
  && String.for_all valid_character value

let has_symlink_component path =
  if Sys.win32 then (Unix.lstat path).st_kind = Unix.S_LNK
  else
    let components =
      String.split_on_char '/' path |> List.filter (fun value -> value <> "")
    in
    let start = if Filename.is_relative path then Sys.getcwd () else "/" in
    let _, found =
      List.fold_left
        (fun (current, found) component ->
          let current = Filename.concat current component in
          (current, found || (Unix.lstat current).st_kind = Unix.S_LNK))
        (start, false) components
    in
    found

let validate_root root =
  try
    let stat = Unix.lstat root in
    if stat.st_kind <> Unix.S_DIR || has_symlink_component root then
      Error Artifact_invalid
    else Ok (Unix.realpath root)
  with _ -> Error Artifact_invalid

let unique_directory root namespace =
  let rec attempt count =
    if count > 20 then Error Artifact_write_failed
    else
      let suffix = Printf.sprintf "%d-%06x" (Unix.getpid ()) (Random.bits ()) in
      let path = Filename.concat root (namespace ^ "-" ^ suffix) in
      try
        Unix.mkdir path 0o700;
        Ok path
      with
      | Unix.Unix_error (Unix.EEXIST, _, _) -> attempt (count + 1)
      | _ -> Error Artifact_write_failed
  in
  attempt 0

let write_all descriptor value =
  let bytes = Bytes.unsafe_of_string value in
  let rec loop offset =
    if offset < Bytes.length bytes then
      let count =
        Unix.write descriptor bytes offset (Bytes.length bytes - offset)
      in
      if count = 0 then raise End_of_file else loop (offset + count)
  in
  loop 0

let fsync_directory directory =
  if not Sys.win32 then
    let descriptor = Unix.openfile directory [ Unix.O_RDONLY ] 0 in
    Fun.protect
      ~finally:(fun () -> Unix.close descriptor)
      (fun () -> Unix.fsync descriptor)

let atomic_write directory name value =
  let temporary = Filename.concat directory ("." ^ name ^ ".tmp") in
  let final = Filename.concat directory name in
  let descriptor =
    Unix.openfile temporary [ Unix.O_WRONLY; Unix.O_CREAT; Unix.O_EXCL ] 0o600
  in
  Fun.protect
    ~finally:(fun () -> try Unix.close descriptor with _ -> ())
    (fun () ->
      write_all descriptor value;
      Unix.fsync descriptor);
  try
    Unix.link temporary final;
    Unix.unlink temporary;
    fsync_directory directory
  with error ->
    (try Unix.unlink temporary with _ -> ());
    raise error

let capture_output capture outcome stdout stderr =
  if not (valid_namespace capture.namespace) then Error Artifact_invalid
  else
    match validate_root capture.root with
    | Error error -> Error error
    | Ok root -> (
        match unique_directory root capture.namespace with
        | Error error -> Error error
        | Ok directory -> (
            try
              let status =
                match outcome with
                | `Exited code -> `Assoc [ ("exit", `Int code) ]
                | `Signaled signal -> `Assoc [ ("signal", `Int signal) ]
                | `Stopped signal -> `Assoc [ ("stop", `Int signal) ]
              in
              let metadata =
                Yojson.Safe.to_string
                  (`Assoc
                     [
                       ("status", status);
                       ("stdout_bytes", `Int (String.length stdout));
                       ("stderr_bytes", `Int (String.length stderr));
                     ])
              in
              atomic_write directory "stdout.bin" stdout;
              atomic_write directory "stderr.bin" stderr;
              atomic_write directory "metadata.json" metadata;
              Ok directory
            with _ ->
              List.iter
                (fun name ->
                  try Sys.remove (Filename.concat directory name) with _ -> ())
                [ "stdout.bin"; "stderr.bin"; "metadata.json" ];
              (try Unix.rmdir directory with _ -> ());
              Error Artifact_write_failed))

let finish_capture request status stdout stderr =
  match request.capture with
  | None -> Ok None
  | Some capture ->
      Result.map Option.some (capture_output capture status stdout stderr)

let successful_result request status stdout stderr =
  let status = outcome status in
  match finish_capture request status stdout stderr with
  | Error error -> Error error
  | Ok capture_directory -> (
      match status with
      | `Exited 0 -> Ok { stdout; stderr; capture_directory }
      | other -> Error (Nonzero_exit other))

let failed_result termination process request failed =
  terminate_tree termination process request.term_grace >>= fun terminated ->
  Lwt.catch (fun () -> process#close >|= fun _ -> ()) (fun _ -> Lwt.return_unit)
  >|= fun () ->
  match terminated with
  | Error () -> Error Termination_unavailable
  | Ok () -> (
      match failed with
      | `Timeout -> Error Timed_out
      | `Cancelled -> Error Cancelled
      | `Limit stream -> Error (Output_limit_exceeded stream)
      | `Io_failed -> Error Spawn_failed)

let run_process ?cancel termination request process =
  let stdout = drain `Stdout request.stdout_limit process#stdout in
  let stderr = drain `Stderr request.stderr_limit process#stderr in
  let io =
    Lwt.both (write_stdin process request.stdin) (Lwt.both stdout stderr)
  in
  let completed =
    Lwt.both process#status io >|= fun value -> `Completed value
  in
  let timeout = Lwt_unix.sleep request.timeout >|= fun () -> `Timeout in
  let cancelled =
    Option.map (fun value -> value >|= fun () -> `Cancelled) cancel
  in
  let events = timeout :: completed :: Option.to_list cancelled in
  Lwt.catch
    (fun () -> Lwt.choose events)
    (function
      | Stream_limit stream -> Lwt.return (`Limit stream)
      | _ -> Lwt.return `Io_failed)
  >>= function
  | `Completed (status, (_, (stdout, stderr))) ->
      Lwt.return (successful_result request status stdout stderr)
  | (`Timeout | `Cancelled | `Limit _ | `Io_failed) as failed ->
      failed_result termination process request failed

let executable_ready path =
  try
    let stat = Unix.lstat path in
    stat.st_kind = Unix.S_REG && Unix.access path [ Unix.X_OK ] = ()
  with _ -> false

let run ?cancel runner request =
  match validate_request runner request with
  | Error error -> Lwt.return (Error error)
  | Ok () -> (
      if not (executable_ready request.executable) then
        Lwt.return (Error Spawn_failed)
      else
        match termination_program () with
        | None -> Lwt.return (Error Termination_unavailable)
        | Some termination -> (
            let process =
              try
                Ok
                  (Lwt_process.open_process_full ~env:(environment request.env)
                     (command termination request))
              with _ -> Error Spawn_failed
            in
            match process with
            | Error error -> Lwt.return (Error error)
            | Ok process -> run_process ?cancel termination request process))
