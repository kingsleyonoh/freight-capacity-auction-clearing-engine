type integration_outbox = {
  id : string;
  tenant_id : string;
  integration_name : string;
  event_type : string;
  target_url_env_var : string;
  payload : Yojson.Safe.t;
  idempotency_key : string;
}

type replay_job = {
  id : string;
  tenant_id : string;
  dataset_uri : string;
  baseline_strategy : string;
  created_by_user_id : string;
}

type workflow_execution = {
  approval_id : string;
  award_id : string;
  tenant_id : string;
  execution_id : string;
}

val close_expired_auctions : unit -> (int, string) result Lwt.t
val expire_approvals : cutoff_hours:int -> (int, string) result Lwt.t
val deliver_notifications : unit -> (int, string) result Lwt.t
val claim_integration_outbox : unit -> (integration_outbox option, string) result Lwt.t
val mark_integration_succeeded : id:string -> tenant_id:string -> (unit, string) result Lwt.t
val mark_integration_retry :
  id:string -> tenant_id:string -> error_code:string -> error_message:string -> (unit, string) result Lwt.t
val update_integration_health :
  tenant_id:string -> integration_name:string -> status:string -> (unit, string) result Lwt.t
val record_workflow_execution : tenant_id:string -> award_id:string -> execution_id:string -> (unit, string) result Lwt.t
val claim_workflow_execution : unit -> (workflow_execution option, string) result Lwt.t
val apply_workflow_decision : tenant_id:string -> approval_id:string -> decision:string -> (unit, string) result Lwt.t
val mark_workflow_failed : tenant_id:string -> approval_id:string -> (unit, string) result Lwt.t
val claim_replay : unit -> (replay_job option, string) result Lwt.t
val complete_replay :
  id:string -> tenant_id:string -> metrics:string -> (unit, string) result Lwt.t
val fail_replay :
  id:string -> tenant_id:string -> error_code:string -> error_message:string -> (unit, string) result Lwt.t
val refresh_carrier_scores : unit -> (int, string) result Lwt.t
val compact_report_artifacts : unit -> (int, string) result Lwt.t
