type t = Pending | Approved | Rejected | Expired | Workflow_failed | Cancelled
type error = Invalid_transition | Missing_decider

let of_string = function
  | "pending" -> Some Pending | "approved" -> Some Approved | "rejected" -> Some Rejected | "expired" -> Some Expired | "workflow_failed" -> Some Workflow_failed | "cancelled" -> Some Cancelled | _ -> None

let to_string = function
  | Pending -> "pending" | Approved -> "approved" | Rejected -> "rejected" | Expired -> "expired" | Workflow_failed -> "workflow_failed" | Cancelled -> "cancelled"

let transition ~current ~next ~decider =
  if current <> Pending then Error Invalid_transition
  else if (next = Approved || next = Rejected) && Option.is_none decider then Error Missing_decider
  else if List.mem next [ Approved; Rejected; Expired; Workflow_failed; Cancelled ] then Ok next
  else Error Invalid_transition
