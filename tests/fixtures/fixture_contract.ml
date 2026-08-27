exception Invalid of string

let fail code = raise (Invalid code)

let load_json path =
  if not (Sys.file_exists path) then fail ("FIXTURE_MISSING:" ^ path);
  try Yojson.Safe.from_file path
  with _ -> fail ("FIXTURE_JSON_INVALID:" ^ path)

let read_text path =
  if not (Sys.file_exists path) then fail ("FIXTURE_MISSING:" ^ path);
  let channel = open_in_bin path in
  Fun.protect
    ~finally:(fun () -> close_in_noerr channel)
    (fun () -> really_input_string channel (in_channel_length channel))

let assoc = function
  | `Assoc fields -> fields
  | _ -> fail "FIXTURE_OBJECT_REQUIRED"

let list = function
  | `List values -> values
  | _ -> fail "FIXTURE_ARRAY_REQUIRED"

let member name fields =
  match List.assoc_opt name fields with
  | Some value -> value
  | None -> fail ("FIXTURE_FIELD_MISSING:" ^ name)

let string name fields =
  match member name fields with
  | `String value -> value
  | _ -> fail ("FIXTURE_STRING_REQUIRED:" ^ name)

let int name fields =
  match member name fields with
  | `Int value -> value
  | _ -> fail ("FIXTURE_INTEGER_REQUIRED:" ^ name)

let bool name fields =
  match member name fields with
  | `Bool value -> value
  | _ -> fail ("FIXTURE_BOOLEAN_REQUIRED:" ^ name)

let string_list name fields =
  member name fields |> list
  |> List.map (function
    | `String value -> value
    | _ -> fail ("FIXTURE_STRING_ARRAY_REQUIRED:" ^ name))

let exact_fields expected fields =
  let sort = List.sort String.compare in
  if sort expected <> sort (List.map fst fields) then
    fail "FIXTURE_FIELDS_NOT_EXACT"

let expect_string expected name fields =
  if string name fields <> expected then fail ("FIXTURE_VALUE_INVALID:" ^ name)

let expect_int expected name fields =
  if int name fields <> expected then fail ("FIXTURE_VALUE_INVALID:" ^ name)

let expect_bool expected name fields =
  if bool name fields <> expected then fail ("FIXTURE_VALUE_INVALID:" ^ name)

let lines text =
  String.split_on_char '\n' text
  |> List.map (fun line ->
      let length = String.length line in
      if length > 0 && line.[length - 1] = '\r' then
        String.sub line 0 (length - 1)
      else line)
  |> List.filter (fun line -> String.trim line <> "")

let contains ~substring value =
  let wanted = String.length substring in
  let rec loop index =
    index + wanted <= String.length value
    && (String.sub value index wanted = substring || loop (index + 1))
  in
  wanted = 0 || loop 0

let root () =
  match Sys.getenv_opt "FCA_FIXTURE_ROOT" with
  | Some value -> value
  | None -> "tests/fixtures"

let path relative = Filename.concat (root ()) relative

let tenant_ids () =
  let fields = load_json (path "tenants.json") |> assoc in
  exact_fields [ "schema_version"; "tenants" ] fields;
  expect_int 1 "schema_version" fields;
  let tenants = member "tenants" fields |> list in
  if List.length tenants <> 2 then fail "FIXTURE_EXACTLY_TWO_TENANTS_REQUIRED";
  List.map (fun value -> string "id" (assoc value)) tenants

let rec files_under path =
  if not (Sys.file_exists path) then fail ("FIXTURE_MISSING:" ^ path)
  else if Sys.is_directory path then
    Sys.readdir path |> Array.to_list |> List.sort String.compare
    |> List.concat_map (fun name -> files_under (Filename.concat path name))
  else [ path ]

let csv_rows text =
  let parse line =
    if contains ~substring:"\"" line then fail "FIXTURE_CSV_QUOTES_UNSUPPORTED";
    String.split_on_char ',' line
  in
  match List.map parse (lines text) with
  | [] -> fail "FIXTURE_CSV_EMPTY"
  | header :: rows ->
      let width = List.length header in
      if width = 0 || List.exists (fun value -> value = "") header then
        fail "FIXTURE_CSV_HEADER_INVALID";
      List.iter
        (fun row ->
          if List.length row <> width then fail "FIXTURE_CSV_ROW_WIDTH_INVALID")
        rows;
      (header, rows)

let ndjson text =
  lines text
  |> List.mapi (fun index line ->
      try Yojson.Safe.from_string line
      with _ -> fail (Printf.sprintf "FIXTURE_NDJSON_INVALID:%d" (index + 1)))

let lower = String.lowercase_ascii
let schema_error path code = fail ("FIXTURE_SCHEMA:" ^ path ^ ":" ^ code)

let json_type_matches expected = function
  | `Null -> expected = "null"
  | `Bool _ -> expected = "boolean"
  | `Int _ | `Intlit _ -> expected = "integer" || expected = "number"
  | `Float _ -> expected = "number"
  | `String _ -> expected = "string"
  | `Assoc _ -> expected = "object"
  | `List _ | `Tuple _ -> expected = "array"
  | `Variant _ -> false

let all_chars predicate value =
  let rec loop index =
    index = String.length value || (predicate value.[index] && loop (index + 1))
  in
  loop 0

let digits value =
  value <> "" && all_chars (fun c -> c >= '0' && c <= '9') value

let decimal_with scale value =
  match String.split_on_char '.' value with
  | [ whole; fraction ] ->
      digits whole && String.length fraction = scale && digits fraction
  | _ -> false

let regexp_matches pattern value =
  match pattern with
  | "^[A-Z]{3}$" ->
      String.length value = 3 && all_chars (fun c -> c >= 'A' && c <= 'Z') value
  | "^\\d+\\.\\d{2}$" -> decimal_with 2 value
  | "^\\d+\\.\\d{4}$" -> decimal_with 4 value
  | "^[0-9a-f]{64}$" ->
      String.length value = 64
      && all_chars
           (fun c -> (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))
           value
  | "^/" -> String.length value > 0 && value.[0] = '/'
  | _ -> ( try Str.string_match (Str.regexp pattern) value 0 with _ -> false)

let valid_uuid value =
  String.length value = 36
  && regexp_matches
       "^[0-9a-fA-F][0-9a-fA-F]*-[0-9a-fA-F][0-9a-fA-F]*-[0-9a-fA-F][0-9a-fA-F]*-[0-9a-fA-F][0-9a-fA-F]*-[0-9a-fA-F][0-9a-fA-F]*$"
       value

let valid_date value =
  String.length value = 10
  && regexp_matches "^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$" value

let valid_datetime value =
  String.length value >= 20
  && value.[String.length value - 1] = 'Z'
  && contains ~substring:"T" value

let rec validate_schema_at path schema instance =
  let fields = assoc schema in
  validate_one_of path fields instance;
  validate_declared_type path fields instance;
  (match List.assoc_opt "const" fields with
  | Some expected when expected <> instance -> schema_error path "CONST"
  | _ -> ());
  (match List.assoc_opt "enum" fields with
  | Some values when not (List.mem instance (list values)) ->
      schema_error path "ENUM"
  | _ -> ());
  match instance with
  | `Assoc values -> validate_object path fields values
  | `List values -> validate_array path fields values
  | `String value -> validate_schema_string path fields value
  | `Int value -> validate_schema_int path fields value
  | _ -> ()

and validate_one_of path fields instance =
  match List.assoc_opt "oneOf" fields with
  | None -> ()
  | Some alternatives ->
      let validate count alternative =
        try
          validate_schema_at path alternative instance;
          count + 1
        with Invalid _ -> count
      in
      let successes = List.fold_left validate 0 (list alternatives) in
      if successes <> 1 then schema_error path "ONE_OF"

and validate_declared_type path fields instance =
  match List.assoc_opt "type" fields with
  | Some (`String expected) ->
      if not (json_type_matches expected instance) then schema_error path "TYPE"
  | Some (`List expected) ->
      let matches =
        List.exists
          (function
            | `String value -> json_type_matches value instance
            | _ -> schema_error path "TYPE_DECLARATION")
          expected
      in
      if not matches then schema_error path "TYPE"
  | Some _ -> schema_error path "TYPE_DECLARATION"
  | None -> ()

and validate_object path fields values =
  let properties =
    match List.assoc_opt "properties" fields with
    | Some value -> assoc value
    | None -> []
  in
  (match List.assoc_opt "required" fields with
  | Some required ->
      required |> list
      |> List.iter (function
        | `String name ->
            if not (List.mem_assoc name values) then
              schema_error (path ^ "." ^ name) "REQUIRED"
        | _ -> schema_error path "REQUIRED_DECLARATION")
  | None -> ());
  (match List.assoc_opt "additionalProperties" fields with
  | Some (`Bool false) ->
      List.iter
        (fun (name, _) ->
          if not (List.mem_assoc name properties) then
            schema_error (path ^ "." ^ name) "ADDITIONAL_PROPERTY")
        values
  | _ -> ());
  List.iter
    (fun (name, value) ->
      match List.assoc_opt name properties with
      | Some property -> validate_schema_at (path ^ "." ^ name) property value
      | None -> ())
    values

and validate_array path fields values =
  (match List.assoc_opt "minItems" fields with
  | Some (`Int minimum) when List.length values < minimum ->
      schema_error path "MIN_ITEMS"
  | _ -> ());
  (match List.assoc_opt "maxItems" fields with
  | Some (`Int maximum) when List.length values > maximum ->
      schema_error path "MAX_ITEMS"
  | _ -> ());
  (match List.assoc_opt "uniqueItems" fields with
  | Some (`Bool true) ->
      let unique = List.sort_uniq Stdlib.compare values in
      if List.length unique <> List.length values then
        schema_error path "UNIQUE_ITEMS"
  | _ -> ());
  match List.assoc_opt "items" fields with
  | Some item_schema ->
      List.iteri
        (fun index value ->
          validate_schema_at
            (Printf.sprintf "%s[%d]" path index)
            item_schema value)
        values
  | None -> ()

and validate_schema_string path fields value =
  (match List.assoc_opt "pattern" fields with
  | Some (`String pattern) when not (regexp_matches pattern value) ->
      schema_error path "PATTERN"
  | _ -> ());
  match List.assoc_opt "format" fields with
  | Some (`String "uuid") when not (valid_uuid value) ->
      schema_error path "UUID"
  | Some (`String "date") when not (valid_date value) ->
      schema_error path "DATE"
  | Some (`String "date-time") when not (valid_datetime value) ->
      schema_error path "DATE_TIME"
  | _ -> ()

and validate_schema_int path fields value =
  (match List.assoc_opt "minimum" fields with
  | Some (`Int minimum) when value < minimum -> schema_error path "MINIMUM"
  | _ -> ());
  match List.assoc_opt "maximum" fields with
  | Some (`Int maximum) when value > maximum -> schema_error path "MAXIMUM"
  | _ -> ()

let validate_schema schema instance = validate_schema_at "$" schema instance

let validate_schema_file ~schema_path ~instance_path =
  validate_schema (load_json schema_path) (load_json instance_path)

let forbidden_key key =
  let key = lower key in
  List.exists
    (fun part -> contains ~substring:part key)
    [
      "password";
      "credential";
      "cookie";
      "authorization";
      "auth";
      "api_key";
      "receiver_secret";
      "private_key";
      "access_token";
      "refresh_token";
      "secret";
      "hash";
      "host";
      "base_url";
      "full_uri";
      "jwt";
      "signature";
      "raw_error";
      "raw_exception";
    ]

let validate_signature_descriptor path value =
  let fields = assoc value in
  exact_fields [ "algorithm"; "encoding"; "length"; "value" ] fields;
  expect_string "sha256" "algorithm" fields;
  expect_string "hex" "encoding" fields;
  expect_int 64 "length" fields;
  expect_string "[REDACTED_FIXTURE]" "value" fields;
  if path <> "$.request.body.signature_descriptor" then
    fail "FIXTURE_SIGNATURE_PATH_FORBIDDEN"

let reject_sensitive_string path value =
  let lowered = lower value in
  if contains ~substring:"://" lowered then
    fail ("FIXTURE_FULL_URI_FORBIDDEN:" ^ path);
  if
    contains ~substring:"bearer " lowered
    || contains ~substring:"basic " lowered
    || contains ~substring:"cookie:" lowered
    || contains ~substring:"eyj" value
  then fail ("FIXTURE_SECRET_VALUE_FORBIDDEN:" ^ path)

let reject_private_data ?allowed_signature_path json =
  let rec walk path = function
    | `Assoc fields ->
        List.iter
          (fun (key, value) ->
            let child = path ^ "." ^ key in
            if lower key = "signature_descriptor" then
              match allowed_signature_path with
              | Some allowed when child = allowed ->
                  validate_signature_descriptor child value
              | _ -> fail ("FIXTURE_SIGNATURE_FORBIDDEN:" ^ child)
            else (
              if forbidden_key key then
                fail ("FIXTURE_PRIVATE_KEY_FORBIDDEN:" ^ child);
              walk child value))
          fields
    | `List values -> List.iter (walk (path ^ "[]")) values
    | `String value -> reject_sensitive_string path value
    | _ -> ()
  in
  walk "$" json

let reject_secret_keys ?(allow_redacted_signature = false) json =
  reject_private_data
    ?allowed_signature_path:
      (if allow_redacted_signature then
         Some "$.request.body.signature_descriptor"
       else None)
    json
