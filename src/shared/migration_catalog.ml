[@@@alert "-caqti_private"]

type source = { filename : string; sql : string }

type entry = {
  version : int64;
  filename : string;
  sql : string;
  statements : Caqti_query.t list;
}

type t = entry list
type error = { code : string; message : string }

let invalid =
  {
    code = "MIGRATION_CATALOG_INVALID";
    message = "Migration catalog is invalid";
  }

let error_code error = error.code
let error_message error = error.message
let entries catalog = catalog
let entry_version entry = entry.version
let entry_filename entry = entry.filename
let entry_sql entry = entry.sql
let entry_statements entry = entry.statements

let contains ~needle value =
  let needle_length = String.length needle in
  let value_length = String.length value in
  let rec loop index =
    if needle_length = 0 then true
    else if index + needle_length > value_length then false
    else if String.sub value index needle_length = needle then true
    else loop (index + 1)
  in
  loop 0

let valid_slug slug =
  let length = String.length slug in
  length > 0
  && (match slug.[0] with 'a' .. 'z' -> true | _ -> false)
  && (match slug.[length - 1] with
    | 'a' .. 'z' | '0' .. '9' -> true
    | _ -> false)
  && String.for_all
       (function 'a' .. 'z' | '0' .. '9' | '_' -> true | _ -> false)
       slug
  && not (contains ~needle:"__" slug)

let filename_version filename =
  let length = String.length filename in
  if length < 12 || not (String.ends_with ~suffix:".sql" filename) then None
  else
    let digits = String.sub filename 0 6 in
    if
      filename.[6] <> '_'
      || not
           (String.for_all (function '0' .. '9' -> true | _ -> false) digits)
    then None
    else
      let slug = String.sub filename 7 (length - 11) in
      if not (valid_slug slug) then None
      else
        let version = Int64.of_string digits in
        if Int64.compare version 0L <= 0 then None else Some version

let terminal_semicolon sql =
  let trimmed = String.trim sql in
  String.length trimmed > 0 && trimmed.[String.length trimmed - 1] = ';'

let psql_meta_command sql =
  String.split_on_char '\n' sql
  |> List.exists (fun line ->
      let line = String.trim line in
      String.length line > 0 && line.[0] = '\\')

let rec has_dynamic_node = function
  | Caqti_query.P _ | Caqti_query.E _ | Caqti_query.V _ -> true
  | Caqti_query.S fragments -> List.exists has_dynamic_node fragments
  | Caqti_query.Annot (_, query) -> has_dynamic_node query
  | Caqti_query.L _ | Caqti_query.Q _ -> false

let rec literal_prefix = function
  | Caqti_query.L text -> text
  | Caqti_query.S fragments ->
      String.concat "" (List.map literal_prefix fragments)
  | Caqti_query.Annot (_, query) -> literal_prefix query
  | Caqti_query.Q _ | Caqti_query.P _ | Caqti_query.E _ | Caqti_query.V _ -> ""

let starts_control_statement query =
  let text = literal_prefix query |> String.trim |> String.uppercase_ascii in
  let starts keyword =
    text = keyword
    || String.starts_with ~prefix:(keyword ^ " ") text
    || String.starts_with ~prefix:(keyword ^ "\n") text
    || String.starts_with ~prefix:(keyword ^ "\r") text
    || String.starts_with ~prefix:(keyword ^ "\t") text
  in
  List.exists starts
    [
      "BEGIN";
      "COMMIT";
      "ROLLBACK";
      "START TRANSACTION";
      "SAVEPOINT";
      "RELEASE SAVEPOINT";
      "SET TRANSACTION";
      "END";
    ]

let parse_statements sql =
  if
    contains ~needle:"/*" sql || contains ~needle:"*/" sql
    || psql_meta_command sql
    || not (terminal_semicolon sql)
  then Error invalid
  else
    let parser = Angstrom.(Caqti_query.angstrom_list_parser <* end_of_input) in
    match Angstrom.parse_string ~consume:All parser sql with
    | Error _ -> Error invalid
    | Ok [] -> Error invalid
    | Ok statements
      when List.exists has_dynamic_node statements
           || List.exists starts_control_statement statements ->
        Error invalid
    | Ok statements -> Ok statements

let parse_source (source : source) =
  match (filename_version source.filename, parse_statements source.sql) with
  | Some version, Ok statements ->
      Ok { version; filename = source.filename; sql = source.sql; statements }
  | None, _ | _, Error _ -> Error invalid

let rec validate_order previous acc (sources : source list) =
  match sources with
  | [] -> Ok (List.rev acc)
  | source :: rest -> (
      match parse_source source with
      | Error _ as error -> error
      | Ok entry ->
          if Int64.compare entry.version previous <= 0 then Error invalid
          else validate_order entry.version (entry :: acc) rest)

let of_sources sources = validate_order 0L [] sources

let production =
  let sources =
    List.map
      (fun (filename, sql) -> { filename; sql })
      Migration_catalog_data.production_sources
  in
  match of_sources sources with
  | Ok catalog -> catalog
  | Error _ -> invalid_arg "embedded production migration catalog is invalid"
