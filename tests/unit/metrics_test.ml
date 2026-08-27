let contains needle value =
  let rec loop index =
    if index + String.length needle > String.length value then false
    else if String.sub value index (String.length needle) = needle then true
    else loop (index + 1)
  in
  loop 0

let test_analytics_counter_is_privacy_safe () =
  Metrics.track "auction_created";
  let output = Metrics.prometheus () in
  Alcotest.(check bool) "event counter exported" true (contains "fca_analytics_events_total{event=\"auction_created\"}" output);
  Alcotest.(check bool) "no payload dimensions" false (contains "tenant_id" output)

let () = Alcotest.run "Metrics" [ ("analytics", [ Alcotest.test_case "privacy-safe event counter" `Quick test_analytics_counter_is_privacy_safe ]) ]
