let canonical_tenants =
  match Tenant_fixture.load_file (Sys.getenv "FCA_TENANT_FIXTURE") with
  | Ok { tenants = [ first; second ]; _ } -> (first, second)
  | Ok _ | Error _ -> failwith "canonical tenant fixture must be valid"

let tenant_id =
  let first, _ = canonical_tenants in
  match Tenant_context.Tenant_id.of_string first.Tenant_fixture.id with
  | Ok value -> value
  | Error _ -> failwith "canonical fixture UUID must be valid"

let is_error = function Error _ -> true | Ok _ -> false

let default_event_id =
  let _, second = canonical_tenants in
  second.Tenant_fixture.overlap.auction.id

let make ?(event_id = default_event_id)
    ?(event_type = "freight_auction.award.proposed")
    ?(idempotency_key = "award:22222222:proposed:v1")
    ?(target = Event_outbox.Notification_hub)
    ?(target_url_env_var = "NOTIFICATION_HUB_URL") payload =
  Event_outbox.event ~tenant_id ~event_id ~event_type ~idempotency_key ~target
    ~target_url_env_var ~payload

let test_valid_event () =
  match
    make (`Assoc [ ("award_id", `String "award-1"); ("count", `Int 1) ])
  with
  | Error _ -> Alcotest.fail "valid event rejected"
  | Ok event ->
      Alcotest.(check string)
        "event grammar retained" "freight_auction.award.proposed"
        (Event_outbox.event_type event);
      Alcotest.(check string)
        "env metadata retained" "NOTIFICATION_HUB_URL"
        (Event_outbox.target_url_env_var event)

let test_validation () =
  Alcotest.(check bool)
    "event grammar" true
    (is_error (make ~event_type:"award proposed" (`Assoc [])));
  Alcotest.(check bool)
    "idempotency required" true
    (is_error (make ~idempotency_key:" " (`Assoc [])));
  Alcotest.(check bool)
    "target metadata uppercase" true
    (is_error (make ~target_url_env_var:"notification_url" (`Assoc [])));
  let oversized = String.make (65 * 1024) 'x' in
  Alcotest.(check bool)
    "payload cap" true
    (is_error (make (`Assoc [ ("value", `String oversized) ])))

let test_recursive_secret_denial () =
  let nested =
    `Assoc
      [
        ( "safe",
          `List
            [
              `Assoc
                [ ("authorization_token", `String "synthetic-redacted-value") ];
            ] );
      ]
  in
  Alcotest.(check bool)
    "recursive secret-bearing key denied" true
    (is_error (make nested));
  Alcotest.(check bool)
    "cookie key denied" true
    (is_error (make (`Assoc [ ("cookie", `String "synthetic") ])));
  Alcotest.(check bool)
    "camel-case API key denied" true
    (is_error (make (`Assoc [ ("apiKey", `String "synthetic") ])));
  Alcotest.(check bool)
    "credential field denied" true
    (is_error (make (`Assoc [ ("credentials", `String "synthetic") ])))

module Writer_contract : Event_outbox.WRITER with type transaction = int =
struct
  type transaction = int
  type error = [ `Unavailable ]

  let enqueue transaction _event =
    if transaction > 0 then Lwt.return (Ok (`Inserted "row-1"))
    else Lwt.return (Ok (`Existing "row-1"))
end

let test_writer_contract () =
  let event =
    match make (`Assoc [ ("award_id", `String "award-1") ]) with
    | Ok value -> value
    | Error _ -> Alcotest.fail "valid writer event rejected"
  in
  let result = Lwt_main.run (Writer_contract.enqueue 1 event) in
  Alcotest.(check bool)
    "caller transaction yields row decision only" true
    (match result with Ok (`Inserted "row-1") -> true | _ -> false)

let () =
  Alcotest.run "Event outbox interface"
    [
      ( "event",
        [ Alcotest.test_case "valid typed event" `Quick test_valid_event ] );
      ( "validation",
        [ Alcotest.test_case "grammar and caps" `Quick test_validation ] );
      ( "security",
        [
          Alcotest.test_case "recursive key denial" `Quick
            test_recursive_secret_denial;
        ] );
      ( "writer",
        [
          Alcotest.test_case "caller transaction port" `Quick
            test_writer_contract;
        ] );
    ]
