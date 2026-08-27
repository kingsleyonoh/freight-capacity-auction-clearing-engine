type viewer = Operator | Carrier of string
type report = { auction_id : string; tenant_id : string; awards : (string * string * int) list; generated_at : string }
type error = Missing_token of string | Invalid_token of string

let visible viewer (load_id, carrier_id, amount) =
  match viewer with Operator -> Some (load_id, carrier_id, amount) | Carrier own when own = carrier_id -> Some (load_id, carrier_id, amount) | Carrier _ -> None

let escape_html value =
  let buffer = Buffer.create (String.length value) in
  String.iter
    (function
      | '&' -> Buffer.add_string buffer "&amp;"
      | '<' -> Buffer.add_string buffer "&lt;"
      | '>' -> Buffer.add_string buffer "&gt;"
      | '"' -> Buffer.add_string buffer "&quot;"
      | '\'' -> Buffer.add_string buffer "&#39;"
      | character -> Buffer.add_char buffer character)
    value;
  Buffer.contents buffer

let csv_cell value =
  let escaped = String.concat "\"\"" (String.split_on_char '"' value) in
  "\"" ^ escaped ^ "\""

let render_json ~viewer report =
  if report.auction_id = "" then Error (Missing_token "auction_id")
  else if report.tenant_id = "" then Error (Missing_token "tenant_id")
  else
    let awards = report.awards |> List.filter_map (visible viewer) |> List.map (fun (load_id, carrier_id, amount) -> `Assoc [ ("load_id", `String load_id); ("carrier_id", `String carrier_id); ("amount_cents", `Int amount) ]) in
    Ok (`Assoc [ ("auction_id", `String report.auction_id); ("tenant_id", `String report.tenant_id); ("generated_at", `String report.generated_at); ("awards", `List awards) ])

let render_csv ~viewer report =
  match render_json ~viewer report with
  | Error error -> Error error
  | Ok _ ->
      let rows = report.awards |> List.filter_map (visible viewer) |> List.map (fun (load_id, carrier_id, amount) -> Printf.sprintf "%s,%s,%d" (csv_cell load_id) (csv_cell carrier_id) amount) in
      Ok ("load_id,carrier_id,amount_cents\n" ^ String.concat "\n" rows ^ "\n")

let render_html ~viewer report =
  match render_json ~viewer report with
  | Error error -> Error error
  | Ok _ ->
      let rows = report.awards |> List.filter_map (visible viewer) |> List.map (fun (load_id, carrier_id, amount) -> Printf.sprintf "<tr><td>%s</td><td>%s</td><td>%d</td></tr>" (escape_html load_id) (escape_html carrier_id) amount) in
      Ok ("<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\"><title>Auction report</title></head><body><h1>Auction " ^ escape_html report.auction_id ^ "</h1><table><thead><tr><th>Load</th><th>Carrier</th><th>Amount</th></tr></thead><tbody>" ^ String.concat "" rows ^ "</tbody></table></body></html>")
