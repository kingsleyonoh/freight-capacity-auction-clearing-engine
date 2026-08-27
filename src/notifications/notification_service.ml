type urgency = Low | Medium | High | Critical
type preference = { event_type : string; channel : string; enabled : bool }
type decision = Deliver of string list | Suppress of string

let decide ~urgency ~preferences ~event_type ~channels =
  let enabled channel = match List.find_opt (fun preference -> preference.event_type = event_type && preference.channel = channel) preferences with None -> true | Some preference -> preference.enabled in
  let selected = List.filter enabled channels in
  if selected <> [] || urgency = Critical then Deliver (if selected = [] then [ "in_app" ] else selected) else Suppress "PREFERENCE_DISABLED"
