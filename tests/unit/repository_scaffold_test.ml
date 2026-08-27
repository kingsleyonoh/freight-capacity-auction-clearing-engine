let declared_directories =
  [ "bin"; "config"; "src/shared"; "src/auth"; "src/tenants";
    "src/auctions"; "src/carriers"; "src/policies"; "src/imports/templates";
    "src/clearing"; "src/solver"; "src/approvals"; "src/replays";
    "src/reports/templates"; "src/notifications/templates";
    "src/integrations"; "src/jobs"; "src/ui"; "migrations"; "tests/unit";
    "tests/integration"; "tests/authorization"; "tests/architecture";
    "tests/fixtures/imports"; "tests/fixtures/solver"; "tests/fixtures/replay";
    "tests/fixtures/notification_hub"; "tests/fixtures/workflow_engine";
    "tests/fixtures/webhook_engine"; "tests/e2e"; "docs" ]

let is_directory path =
  try (Unix.stat path).st_kind = Unix.S_DIR with Unix.Unix_error _ -> false

let project_root () =
  let rec ascend path candidate =
    let candidate = if Sys.file_exists (Filename.concat path "dune-project") then Some path else candidate in
    let parent = Filename.dirname path in
    if parent = path then Option.value ~default:(Sys.getcwd ()) candidate
    else ascend parent candidate
  in
  ascend (Sys.getcwd ()) None

let test_declared_scaffold () =
  let root = project_root () in
  let missing =
    List.filter (fun path -> not (is_directory (Filename.concat root path))) declared_directories
  in
  Alcotest.(check (list string)) "all PRD section 9 directories exist" [] missing

let () =
  Alcotest.run "repository scaffold"
    [ ("declared paths", [ Alcotest.test_case "all exist" `Quick test_declared_scaffold ]) ]
