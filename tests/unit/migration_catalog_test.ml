let source filename sql : Migration_catalog.source = { filename; sql }

let expect_ok = function
  | Ok value -> value
  | Error error ->
      Alcotest.failf "unexpected catalog error %s"
        (Migration_catalog.error_code error)

let expect_error expected = function
  | Error error ->
      Alcotest.(check string)
        "safe catalog code" expected
        (Migration_catalog.error_code error)
  | Ok _ -> Alcotest.fail ("expected catalog error " ^ expected)

let check_entry expected_version expected_filename entry =
  Alcotest.(check int64)
    "version" expected_version
    (Migration_catalog.entry_version entry);
  Alcotest.(check string)
    "filename" expected_filename
    (Migration_catalog.entry_filename entry)

let read_file path =
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let production_catalog_is_explicit () =
  let entries = Migration_catalog.entries Migration_catalog.production in
  Alcotest.(check int) "four production entries" 4 (List.length entries);
  match entries with
  | entry :: second :: third :: [ fourth ] ->
      check_entry 1L "000001_create_schema_migrations.sql" entry;
      check_entry 2L "000002_create_auction_core.sql" second;
      check_entry 3L "000003_create_replay_approval_notifications.sql" third;
      check_entry 4L "000004_create_integrations.sql" fourth;
      let migration_path =
        match Sys.getenv_opt "FCA_BASELINE_MIGRATION" with
        | Some path -> path
        | None -> Alcotest.fail "FCA_BASELINE_MIGRATION is required"
      in
      Alcotest.(check string)
        "committed SQL bytes are embedded exactly" (read_file migration_path)
        (Migration_catalog.entry_sql entry);
      Alcotest.(check int)
        "one statement" 1
        (List.length (Migration_catalog.entry_statements entry))
  | _ -> Alcotest.fail "production catalog cardinality changed"

let parser_accepts_supported_statements () =
  let sql =
    "-- migration comment\n\
     CREATE TABLE parser_probe (value text);\n\
     INSERT INTO parser_probe VALUES ('quoted;semicolon');\n\
     DO $body$ BEGIN PERFORM 'dollar;semicolon'; END $body$;\n"
  in
  let catalog =
    expect_ok
      (Migration_catalog.of_sources [ source "900001_parser_probe.sql" sql ])
  in
  let entries = Migration_catalog.entries catalog in
  match entries with
  | [ entry ] ->
      Alcotest.(check int)
        "three Caqti-parsed statements" 3
        (List.length (Migration_catalog.entry_statements entry))
  | _ -> Alcotest.fail "supported catalog did not retain one entry"

let filename_and_order_validation () =
  let valid_sql = "SELECT 1;\n" in
  List.iter
    (fun filename ->
      expect_error "MIGRATION_CATALOG_INVALID"
        (Migration_catalog.of_sources [ source filename valid_sql ]))
    [
      "1_bad.sql";
      "000000_zero.sql";
      "000001_Bad.sql";
      "000001_bad-name.sql";
      "000001_bad.txt";
    ];
  expect_error "MIGRATION_CATALOG_INVALID"
    (Migration_catalog.of_sources
       [
         source "000002_second.sql" valid_sql;
         source "000001_first.sql" valid_sql;
       ]);
  expect_error "MIGRATION_CATALOG_INVALID"
    (Migration_catalog.of_sources
       [
         source "000001_first.sql" valid_sql;
         source "000001_duplicate.sql" valid_sql;
       ])

let restricted_dialect_validation () =
  List.iter
    (fun sql ->
      expect_error "MIGRATION_CATALOG_INVALID"
        (Migration_catalog.of_sources [ source "900001_invalid.sql" sql ]))
    [
      "/* block comments are forbidden */ SELECT 1;";
      "BEGIN; SELECT 1; COMMIT;";
      "START TRANSACTION; SELECT 1;";
      "SELECT ?;";
      "SELECT $1;";
      "SELECT $(unsafe);";
      "SELECT 1";
      "\\set unsafe value;";
    ]

let exact_bytes_are_preserved () =
  let sql = "-- exact bytes\r\nSELECT 'value';\r\n" in
  let catalog =
    expect_ok
      (Migration_catalog.of_sources [ source "900001_exact_bytes.sql" sql ])
  in
  match Migration_catalog.entries catalog with
  | [ entry ] ->
      Alcotest.(check string)
        "exact SQL bytes" sql
        (Migration_catalog.entry_sql entry)
  | _ -> Alcotest.fail "exact-byte source missing"

let () =
  Alcotest.run "Production migration catalog"
    [
      ( "catalog",
        [
          Alcotest.test_case "explicit embedded production entry" `Quick
            production_catalog_is_explicit;
          Alcotest.test_case "Caqti parser handles supported semicolons" `Quick
            parser_accepts_supported_statements;
          Alcotest.test_case "validates filenames versions and order" `Quick
            filename_and_order_validation;
          Alcotest.test_case "rejects restricted dialect" `Quick
            restricted_dialect_validation;
          Alcotest.test_case "preserves exact SQL bytes" `Quick
            exact_bytes_are_preserved;
        ] );
    ]
