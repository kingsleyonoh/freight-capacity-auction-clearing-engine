type viewer = Operator | Carrier of string
type report = { auction_id : string; tenant_id : string; awards : (string * string * int) list; generated_at : string }
type error = Missing_token of string | Invalid_token of string

val render_json : viewer:viewer -> report -> (Yojson.Safe.t, error) result
val render_csv : viewer:viewer -> report -> (string, error) result
val render_html : viewer:viewer -> report -> (string, error) result
