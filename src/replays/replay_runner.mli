type baseline = Lowest_cost | First_acceptable | Incumbent_preference | Historical_awards
type metric = { baseline : baseline; assigned : int; total_cost_cents : int; service_score_milli : int; error : string option }

val baseline_to_string : baseline -> string
val run : baseline list -> (int * int * int) list -> metric list
