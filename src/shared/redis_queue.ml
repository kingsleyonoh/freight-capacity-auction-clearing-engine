type priority = Critical | Default | Bulk

type job = {
  tenant_id : string;
  queue : string;
  idempotency_key : string;
  payload_json : string;
  priority : priority;
}

type enqueue_command = {
  stream : string;
  fields : (string * string) list;
}

let require_non_blank field value =
  if String.trim value = "" then invalid_arg (field ^ " is required") else value

let priority_to_string = function
  | Critical -> "critical"
  | Default -> "default"
  | Bulk -> "bulk"

let stream_name ~tenant_id queue =
  Printf.sprintf "tenant:%s:queue:%s" (require_non_blank "tenant_id" tenant_id)
    (require_non_blank "queue" queue)

let create_job ?(priority = Default) ~tenant_id ~queue ~idempotency_key ~payload_json () =
  {
    tenant_id = require_non_blank "tenant_id" tenant_id;
    queue = require_non_blank "queue" queue;
    idempotency_key = require_non_blank "idempotency_key" idempotency_key;
    payload_json = require_non_blank "payload_json" payload_json;
    priority;
  }

let dedupe_key job = Printf.sprintf "tenant:%s:job:%s" job.tenant_id job.idempotency_key

let enqueue_command job =
  {
    stream = stream_name ~tenant_id:job.tenant_id job.queue;
    fields =
      [
        ("tenant_id", job.tenant_id);
        ("queue", job.queue);
        ("idempotency_key", job.idempotency_key);
        ("priority", priority_to_string job.priority);
        ("payload_json", job.payload_json);
      ];
  }
