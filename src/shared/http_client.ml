module Runtime_config = Freight_capacity_auction_clearing_engine_config.Runtime_config
module Tenant_context = Tenant_context

type retry_policy = {
  max_attempts : int;
  backoff_ms : int;
}

type t = {
  http_method : string;
  url : string;
  headers : (string * string) list;
  body : string option;
  timeout_seconds : int;
  retry_policy : retry_policy;
  tenant_id : string option;
  request_id : string option;
}

let default_retry_policy = { max_attempts = 3; backoff_ms = 250 }

let require_non_blank field value =
  if String.trim value = "" then invalid_arg (field ^ " is required") else value

let require_positive field value =
  if value <= 0 then invalid_arg (field ^ " must be positive") else value

let is_sensitive_header key =
  match String.lowercase_ascii key with
  | "authorization" | "proxy-authorization" | "x-api-key" | "cookie" | "set-cookie" -> true
  | _ -> false

let redacted_headers headers =
  List.map
    (fun (key, value) -> if is_sensitive_header key then (key, "<redacted>") else (key, value))
    headers

let create ?(headers = []) ?body ?(retry_policy = default_retry_policy) ?tenant_context
    ~http_method ~url ~timeout_seconds () =
  if retry_policy.max_attempts <= 0 then invalid_arg "retry max_attempts must be positive";
  if retry_policy.backoff_ms < 0 then invalid_arg "retry backoff_ms cannot be negative";
  {
    http_method = require_non_blank "http_method" http_method;
    url = require_non_blank "url" url;
    headers;
    body;
    timeout_seconds = require_positive "timeout_seconds" timeout_seconds;
    retry_policy;
    tenant_id = Option.map (fun (context : Tenant_context.t) -> context.tenant_id) tenant_context;
    request_id = Option.map (fun (context : Tenant_context.t) -> context.request_id) tenant_context;
  }

let from_config ?headers ?body ?retry_policy ?tenant_context config ~http_method ~url () =
  create ?headers ?body ?retry_policy ?tenant_context ~http_method ~url
    ~timeout_seconds:config.Runtime_config.integration_http_timeout_seconds ()
