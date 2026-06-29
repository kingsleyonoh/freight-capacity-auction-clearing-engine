type integration = Notification_hub | Workflow_engine | Webhook_engine

type status = Pending | In_flight | Succeeded | Failed_retryable | Failed_terminal

type event = {
  tenant_id : string;
  integration : integration;
  event_type : string;
  aggregate_id : string;
  payload_json : string;
  idempotency_key : string;
  status : status;
  attempts : int;
}

let require_non_blank field value =
  if String.trim value = "" then invalid_arg (field ^ " is required") else value

let integration_to_string = function
  | Notification_hub -> "notification_hub"
  | Workflow_engine -> "workflow_engine"
  | Webhook_engine -> "webhook_engine"

let status_to_string = function
  | Pending -> "pending"
  | In_flight -> "in_flight"
  | Succeeded -> "succeeded"
  | Failed_retryable -> "failed_retryable"
  | Failed_terminal -> "failed_terminal"

let default_idempotency_key ~tenant_id ~integration ~event_type ~aggregate_id =
  Printf.sprintf "%s:%s:%s:%s" tenant_id (integration_to_string integration) event_type
    aggregate_id

let create ?idempotency_key ~tenant_id ~integration ~event_type ~aggregate_id ~payload_json () =
  let tenant_id = require_non_blank "tenant_id" tenant_id in
  let event_type = require_non_blank "event_type" event_type in
  let aggregate_id = require_non_blank "aggregate_id" aggregate_id in
  let payload_json = require_non_blank "payload_json" payload_json in
  let idempotency_key =
    match idempotency_key with
    | Some value -> require_non_blank "idempotency_key" value
    | None -> default_idempotency_key ~tenant_id ~integration ~event_type ~aggregate_id
  in
  {
    tenant_id;
    integration;
    event_type;
    aggregate_id;
    payload_json;
    idempotency_key;
    status = Pending;
    attempts = 0;
  }

let mark_in_flight event = { event with status = In_flight; attempts = event.attempts + 1 }

let mark_succeeded event = { event with status = Succeeded }

let mark_failed_retryable event = { event with status = Failed_retryable }

let mark_failed_terminal event = { event with status = Failed_terminal }

let ready_for_retry event =
  match event.status with Pending | Failed_retryable -> true | In_flight | Succeeded | Failed_terminal -> false
