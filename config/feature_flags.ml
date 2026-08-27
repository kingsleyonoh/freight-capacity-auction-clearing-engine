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

let of_runtime_config config =
  let integrations = Runtime_config.integrations config in
  let solver = Runtime_config.solver config in
  {
    notification_hub = integrations.notification.enabled;
    notification_retry =
      integrations.notification.enabled
      && integrations.notification.retry_enabled;
    workflow_engine = integrations.workflow.enabled;
    workflow_status_polling =
      integrations.workflow.enabled
      && integrations.workflow.status_polling_enabled;
    webhook_engine = integrations.webhook.enabled;
    heuristic_fallback_for_replay = solver.heuristic_fallback_for_replay;
  }

let heuristic_fallback_allowed flags = function
  | `Production_clearing -> false
  | `Scenario_replay | `Local_diagnostic -> flags.heuristic_fallback_for_replay

let replay_external_events_allowed _flags = function
  | `Production_clearing | `Scenario_replay | `Local_diagnostic -> false
