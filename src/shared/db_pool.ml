module Runtime_config = Freight_capacity_auction_clearing_engine_config.Runtime_config
module Cache = Cache

type t = {
  database_url : string;
  safe_database_url : string;
  max_size : int;
}

let default_max_size = 10

let require_non_blank field value =
  if String.trim value = "" then invalid_arg (field ^ " is required") else value

let find_substring haystack needle start =
  let haystack_len = String.length haystack in
  let needle_len = String.length needle in
  let rec loop index =
    if index + needle_len > haystack_len then None
    else if String.sub haystack index needle_len = needle then Some index
    else loop (index + 1)
  in
  if needle_len = 0 then Some start else loop start

let redact_credentials url =
  match find_substring url "://" 0 with
  | None -> url
  | Some scheme_index -> (
      let credentials_start = scheme_index + 3 in
      match String.index_from_opt url credentials_start '@' with
      | None -> url
      | Some at_index ->
          String.sub url 0 credentials_start ^ "<redacted>"
          ^ String.sub url at_index (String.length url - at_index))

let create ?(max_size = default_max_size) config =
  if max_size <= 0 then invalid_arg "max_size must be positive";
  let database_url = require_non_blank "database_url" config.Runtime_config.database_url in
  { database_url; safe_database_url = redact_credentials database_url; max_size }

let get_or_create cache config = Cache.get_or_compute cache ~compute:(fun () -> create config)

let tenant_predicate ~table_alias =
  Printf.sprintf "%s.tenant_id = $tenant_id" (require_non_blank "table_alias" table_alias)
