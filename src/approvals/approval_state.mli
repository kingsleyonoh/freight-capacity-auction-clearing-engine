type t = Pending | Approved | Rejected | Expired | Workflow_failed | Cancelled
type error = Invalid_transition | Missing_decider

val of_string : string -> t option
val to_string : t -> string
val transition : current:t -> next:t -> decider:string option -> (t, error) result
