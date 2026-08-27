let requests = Atomic.make 0
let errors = Atomic.make 0

let request () = Atomic.incr requests
let error () = Atomic.incr errors
let prometheus () = Printf.sprintf "fca_requests_total %d\nfca_errors_total %d\n" (Atomic.get requests) (Atomic.get errors)
