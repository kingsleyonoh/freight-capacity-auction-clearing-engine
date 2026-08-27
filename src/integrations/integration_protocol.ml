type adapter = Notification_hub | Workflow_engine | Webhook_engine
type environment = Sandbox | Production
type request = { adapter : adapter; environment : environment; idempotency_key : string; event_type : string; payload : Yojson.Safe.t }
type response = Accepted of string | Disabled | Retry of string | Rejected of string

let adapter_to_string = function Notification_hub -> "notification_hub" | Workflow_engine -> "workflow_engine" | Webhook_engine -> "webhook_engine"
let request_valid request = request.idempotency_key <> "" && request.event_type <> "" && String.length request.idempotency_key <= 200
let webhook_signature ~secret ~body = Digestif.SHA256.hmac_string ~key:secret body |> Digestif.SHA256.to_hex
let secure_equal left right =
  let length = String.length left in
  if length <> String.length right then false
  else
    let difference = ref 0 in
    for index = 0 to length - 1 do
      difference :=
        !difference
        lor (Char.code left.[index] lxor Char.code right.[index])
    done;
    !difference = 0

let verify_webhook ~secret ~body ~signature =
  secure_equal (webhook_signature ~secret ~body) signature
