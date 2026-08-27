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
type error

val error_code : error -> string
val of_yojson : Yojson.Safe.t -> (t, error list) result
val load_file : string -> (t, error list) result
val to_yojson : t -> Yojson.Safe.t
val find_tenant : t -> string -> tenant option
val public_tenant_yojson : tenant -> Yojson.Safe.t
val public_identity_literals : tenant -> string list

val validate_schema_file :
  schema_path:string -> fixture_path:string -> (unit, string) result
