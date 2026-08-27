type solver_scope =
  [ `Production_clearing | `Scenario_replay | `Local_diagnostic ]

type t = {
  notification_hub : bool;
  notification_retry : bool;
  workflow_engine : bool;
  workflow_status_polling : bool;
  webhook_engine : bool;
  heuristic_fallback_for_replay : bool;
}

val of_runtime_config : Runtime_config.t -> t
val heuristic_fallback_allowed : t -> solver_scope -> bool
val replay_external_events_allowed : t -> solver_scope -> bool
