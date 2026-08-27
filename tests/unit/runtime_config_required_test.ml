let test_aggregates_missing_required_values () =
  let values =
    Config_test_support.with_values []
    |> List.filter (fun (name, _) ->
           not (List.mem name [ "DATABASE_URL"; "REDIS_URL"; "SECRET_KEY_BASE" ]))
  in
  match Runtime_config.load ~get:(Config_test_support.get_from values) with
  | Ok _ -> Alcotest.fail "expected required-variable errors"
  | Error errors ->
      let variables =
        List.map (fun (error : Runtime_config.validation_error) -> error.variable) errors
        |> List.sort String.compare
      in
      Alcotest.(check (list string)) "required errors aggregated"
        [ "DATABASE_URL"; "REDIS_URL"; "SECRET_KEY_BASE" ] variables;
      List.iter (fun error ->
          Alcotest.(check bool) "stable missing code" true (error.Runtime_config.code = `Missing))
        errors

let () =
  Alcotest.run "runtime config required values"
    [ ("required", [ Alcotest.test_case "aggregate missing values" `Quick test_aggregates_missing_required_values ]) ]
