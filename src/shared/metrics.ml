let requests = Atomic.make 0
let errors = Atomic.make 0

let tenant_registered = Atomic.make 0
let auction_created = Atomic.make 0
let import_completed = Atomic.make 0
let clearing_started = Atomic.make 0
let clearing_succeeded = Atomic.make 0
let clearing_infeasible = Atomic.make 0
let award_approved = Atomic.make 0
let export_downloaded = Atomic.make 0
let replay_completed = Atomic.make 0
let policy_activated = Atomic.make 0

let request () = Atomic.incr requests
let error () = Atomic.incr errors

let track = function
  | "tenant_registered" -> Atomic.incr tenant_registered
  | "auction_created" -> Atomic.incr auction_created
  | "import_completed" -> Atomic.incr import_completed
  | "clearing_started" -> Atomic.incr clearing_started
  | "clearing_succeeded" -> Atomic.incr clearing_succeeded
  | "clearing_infeasible" -> Atomic.incr clearing_infeasible
  | "award_approved" -> Atomic.incr award_approved
  | "export_downloaded" -> Atomic.incr export_downloaded
  | "replay_completed" -> Atomic.incr replay_completed
  | "policy_activated" -> Atomic.incr policy_activated
  | _ -> ()

let prometheus () =
  let event name counter =
    Printf.sprintf "fca_analytics_events_total{event=\"%s\"} %d\n" name
      (Atomic.get counter)
  in
  String.concat ""
    [ Printf.sprintf "fca_requests_total %d\n" (Atomic.get requests);
      Printf.sprintf "fca_errors_total %d\n" (Atomic.get errors);
      event "tenant_registered" tenant_registered;
      event "auction_created" auction_created;
      event "import_completed" import_completed;
      event "clearing_started" clearing_started;
      event "clearing_succeeded" clearing_succeeded;
      event "clearing_infeasible" clearing_infeasible;
      event "award_approved" award_approved;
      event "export_downloaded" export_downloaded;
      event "replay_completed" replay_completed;
      event "policy_activated" policy_activated ]
