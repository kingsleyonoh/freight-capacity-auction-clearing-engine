type urgency = Low | Medium | High | Critical
type preference = { event_type : string; channel : string; enabled : bool }
type decision = Deliver of string list | Suppress of string

val decide : urgency:urgency -> preferences:preference list -> event_type:string -> channels:string list -> decision
