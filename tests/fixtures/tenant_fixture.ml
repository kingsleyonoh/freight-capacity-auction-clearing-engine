type address = {
  line1 : string;
  city : string;
  region : string;
  postal_code : string;
  country : string;
}

type registration = {
  jurisdiction : string;
  broker_registration : string;
  tax_id : string;
}

type contact = {
  email : string;
  phone : string;
  support_url : string;
  operations_contact : string;
}

type carrier_overlap = { id : string; public_name : string }
type load_overlap = { id : string; public_ref : string; public_label : string }
type auction_overlap = { id : string; public_name : string }

type overlap = {
  carrier : carrier_overlap;
  load : load_overlap;
  auction : auction_overlap;
}

type tenant = {
  id : string;
  name : string;
  legal_name : string;
  full_legal_name : string;
  display_name : string;
  address : address;
  registration : registration;
  contact : contact;
  wordmark : string;
  brand_color : string;
  timezone : string;
  default_currency : string;
  operator_license : string;
  overlap : overlap;
}

type t = { schema_version : int; tenants : tenant list }
type error = Error_code of string

exception Invalid of string

let error_code (Error_code code) = code
let invalid code = raise (Invalid code)

let assoc = function
  | `Assoc fields -> fields
  | _ -> invalid "FIXTURE_SCHEMA_INVALID"

let exact_fields expected fields =
  let expected = List.sort String.compare expected in
  let actual = List.map fst fields |> List.sort String.compare in
  if actual <> expected then invalid "FIXTURE_SCHEMA_INVALID"

let member name fields =
  match List.assoc_opt name fields with
  | Some value -> value
  | None -> invalid "FIXTURE_SCHEMA_INVALID"

let string name fields =
  match member name fields with
  | `String value when String.trim value <> "" -> value
  | _ -> invalid "FIXTURE_SCHEMA_INVALID"

let int name fields =
  match member name fields with
  | `Int value -> value
  | _ -> invalid "FIXTURE_SCHEMA_INVALID"

let lower = String.lowercase_ascii

let contains ~substring value =
  let length = String.length substring in
  let rec loop index =
    index + length <= String.length value
    && (String.sub value index length = substring || loop (index + 1))
  in
  length = 0 || loop 0

let forbidden_fragments =
  [
    "api_key";
    "jwt";
    "cookie";
    "signature";
    "hash";
    "password";
    "credential";
    "secret";
    "authorization";
    "connection_uri";
    "bid_amount";
  ]

let rec reject_secret_keys = function
  | `Assoc fields ->
      List.iter
        (fun (key, value) ->
          let key = lower key in
          if
            List.exists
              (fun part -> contains key ~substring:part)
              forbidden_fragments
          then invalid "FIXTURE_SECRET_KEY_FORBIDDEN";
          reject_secret_keys value)
        fields
  | `List values -> List.iter reject_secret_keys values
  | _ -> ()

let is_hex = function
  | '0' .. '9' | 'a' .. 'f' | 'A' .. 'F' -> true
  | _ -> false

let valid_uuid value =
  String.length value = 36
  && List.for_all (fun index -> value.[index] = '-') [ 8; 13; 18; 23 ]
  && value.[14] = '4'
  && List.mem (Char.lowercase_ascii value.[19]) [ '8'; '9'; 'a'; 'b' ]
  && String.for_all (fun character -> character = '-' || is_hex character) value

let uuid name fields =
  let value = string name fields in
  if valid_uuid value then value else invalid "FIXTURE_UUID_INVALID"

let parse_address value =
  let fields = assoc value in
  exact_fields [ "line1"; "city"; "region"; "postal_code"; "country" ] fields;
  {
    line1 = string "line1" fields;
    city = string "city" fields;
    region = string "region" fields;
    postal_code = string "postal_code" fields;
    country = string "country" fields;
  }

let parse_registration value =
  let fields = assoc value in
  exact_fields [ "jurisdiction"; "broker_registration"; "tax_id" ] fields;
  {
    jurisdiction = string "jurisdiction" fields;
    broker_registration = string "broker_registration" fields;
    tax_id = string "tax_id" fields;
  }

let parse_contact value =
  let fields = assoc value in
  exact_fields [ "email"; "phone"; "support_url"; "operations_contact" ] fields;
  let contact =
    {
      email = string "email" fields;
      phone = string "phone" fields;
      support_url = string "support_url" fields;
      operations_contact = string "operations_contact" fields;
    }
  in
  if
    (not (contains contact.email ~substring:"@example.test"))
    || not
         (String.starts_with ~prefix:"https://" contact.support_url
         && contains contact.support_url ~substring:".example.test/")
  then invalid "FIXTURE_PUBLIC_CONTACT_INVALID";
  contact

let parse_overlap value =
  let fields = assoc value in
  exact_fields [ "carrier"; "load"; "auction" ] fields;
  let carrier_fields = member "carrier" fields |> assoc in
  exact_fields [ "id"; "public_name" ] carrier_fields;
  let load_fields = member "load" fields |> assoc in
  exact_fields [ "id"; "public_ref"; "public_label" ] load_fields;
  let auction_fields = member "auction" fields |> assoc in
  exact_fields [ "id"; "public_name" ] auction_fields;
  {
    carrier =
      {
        id = uuid "id" carrier_fields;
        public_name = string "public_name" carrier_fields;
      };
    load =
      {
        id = uuid "id" load_fields;
        public_ref = string "public_ref" load_fields;
        public_label = string "public_label" load_fields;
      };
    auction =
      {
        id = uuid "id" auction_fields;
        public_name = string "public_name" auction_fields;
      };
  }

let tenant_fields =
  [
    "id";
    "name";
    "legal_name";
    "full_legal_name";
    "display_name";
    "address";
    "registration";
    "contact";
    "wordmark";
    "brand_color";
    "timezone";
    "default_currency";
    "operator_license";
    "overlap";
  ]

let parse_tenant value =
  let fields = assoc value in
  exact_fields tenant_fields fields;
  {
    id = uuid "id" fields;
    name = string "name" fields;
    legal_name = string "legal_name" fields;
    full_legal_name = string "full_legal_name" fields;
    display_name = string "display_name" fields;
    address = parse_address (member "address" fields);
    registration = parse_registration (member "registration" fields);
    contact = parse_contact (member "contact" fields);
    wordmark = string "wordmark" fields;
    brand_color = string "brand_color" fields;
    timezone = string "timezone" fields;
    default_currency = string "default_currency" fields;
    operator_license = string "operator_license" fields;
    overlap = parse_overlap (member "overlap" fields);
  }

let unique values =
  List.sort_uniq String.compare values |> List.length = List.length values

let semantic_validate tenants =
  match tenants with
  | [ first; second ] ->
      let ids select = List.map select tenants in
      if not (unique (ids (fun tenant -> tenant.id))) then
        invalid "FIXTURE_TENANT_ID_DUPLICATE";
      let identity_groups =
        [
          ids (fun tenant -> tenant.name);
          ids (fun tenant -> tenant.legal_name);
          ids (fun tenant -> tenant.full_legal_name);
          ids (fun tenant -> tenant.display_name);
          ids (fun tenant -> tenant.registration.broker_registration);
          ids (fun tenant -> tenant.registration.tax_id);
          ids (fun tenant -> tenant.contact.email);
          ids (fun tenant -> tenant.contact.operations_contact);
          ids (fun tenant -> tenant.operator_license);
        ]
      in
      if not (List.for_all unique identity_groups) then
        invalid "FIXTURE_IDENTITY_NOT_DISTINCT";
      if
        first.overlap.carrier.public_name <> second.overlap.carrier.public_name
        || first.overlap.load.public_ref <> second.overlap.load.public_ref
        || first.overlap.load.public_label <> second.overlap.load.public_label
        || first.overlap.auction.public_name
           <> second.overlap.auction.public_name
      then invalid "FIXTURE_OVERLAP_REQUIRED";
      let entity_ids tenant =
        [
          tenant.overlap.carrier.id;
          tenant.overlap.load.id;
          tenant.overlap.auction.id;
        ]
      in
      if not (unique (List.concat_map entity_ids tenants)) then
        invalid "FIXTURE_ENTITY_ID_DUPLICATE"
  | _ -> invalid "FIXTURE_EXACTLY_TWO_REQUIRED"

let of_yojson json =
  try
    reject_secret_keys json;
    let fields = assoc json in
    exact_fields [ "schema_version"; "tenants" ] fields;
    let schema_version = int "schema_version" fields in
    if schema_version <> 1 then invalid "FIXTURE_SCHEMA_VERSION_UNSUPPORTED";
    let tenants =
      match member "tenants" fields with
      | `List values -> List.map parse_tenant values
      | _ -> invalid "FIXTURE_SCHEMA_INVALID"
    in
    semantic_validate tenants;
    Ok { schema_version; tenants }
  with Invalid code -> Error [ Error_code code ]

let load_file path =
  try Yojson.Safe.from_file path |> of_yojson
  with _ -> Error [ Error_code "FIXTURE_FILE_INVALID" ]

let address_to_yojson address =
  `Assoc
    [
      ("line1", `String address.line1);
      ("city", `String address.city);
      ("region", `String address.region);
      ("postal_code", `String address.postal_code);
      ("country", `String address.country);
    ]

let registration_to_yojson registration =
  `Assoc
    [
      ("jurisdiction", `String registration.jurisdiction);
      ("broker_registration", `String registration.broker_registration);
      ("tax_id", `String registration.tax_id);
    ]

let contact_to_yojson contact =
  `Assoc
    [
      ("email", `String contact.email);
      ("phone", `String contact.phone);
      ("support_url", `String contact.support_url);
      ("operations_contact", `String contact.operations_contact);
    ]

let overlap_to_yojson overlap =
  `Assoc
    [
      ( "carrier",
        `Assoc
          [
            ("id", `String overlap.carrier.id);
            ("public_name", `String overlap.carrier.public_name);
          ] );
      ( "load",
        `Assoc
          [
            ("id", `String overlap.load.id);
            ("public_ref", `String overlap.load.public_ref);
            ("public_label", `String overlap.load.public_label);
          ] );
      ( "auction",
        `Assoc
          [
            ("id", `String overlap.auction.id);
            ("public_name", `String overlap.auction.public_name);
          ] );
    ]

let tenant_to_yojson tenant =
  `Assoc
    [
      ("id", `String tenant.id);
      ("name", `String tenant.name);
      ("legal_name", `String tenant.legal_name);
      ("full_legal_name", `String tenant.full_legal_name);
      ("display_name", `String tenant.display_name);
      ("address", address_to_yojson tenant.address);
      ("registration", registration_to_yojson tenant.registration);
      ("contact", contact_to_yojson tenant.contact);
      ("wordmark", `String tenant.wordmark);
      ("brand_color", `String tenant.brand_color);
      ("timezone", `String tenant.timezone);
      ("default_currency", `String tenant.default_currency);
      ("operator_license", `String tenant.operator_license);
      ("overlap", overlap_to_yojson tenant.overlap);
    ]

let to_yojson fixture =
  `Assoc
    [
      ("schema_version", `Int fixture.schema_version);
      ("tenants", `List (List.map tenant_to_yojson fixture.tenants));
    ]

let find_tenant fixture id =
  List.find_opt (fun tenant -> tenant.id = id) fixture.tenants

let public_tenant_yojson tenant =
  `Assoc
    [
      ("id", `String tenant.id);
      ("name", `String tenant.name);
      ("display_name", `String tenant.display_name);
      ("overlap", overlap_to_yojson tenant.overlap);
    ]

let public_identity_literals tenant =
  [
    tenant.name;
    tenant.legal_name;
    tenant.full_legal_name;
    tenant.display_name;
    tenant.address.line1;
    tenant.address.city;
    tenant.address.region;
    tenant.registration.jurisdiction;
    tenant.registration.broker_registration;
    tenant.registration.tax_id;
    tenant.contact.email;
    tenant.contact.phone;
    tenant.contact.support_url;
    tenant.contact.operations_contact;
    tenant.wordmark;
    tenant.operator_license;
  ]

let validate_schema_file ~schema_path ~fixture_path =
  try
    let schema = Yojson.Safe.from_file schema_path |> assoc in
    let draft = member "$schema" schema in
    if draft <> `String "https://json-schema.org/draft/2020-12/schema" then
      Error "FIXTURE_SCHEMA_DOCUMENT_INVALID"
    else
      match load_file fixture_path with
      | Ok _ -> Ok ()
      | Error errors -> Error (String.concat "," (List.map error_code errors))
  with _ -> Error "FIXTURE_SCHEMA_DOCUMENT_INVALID"
