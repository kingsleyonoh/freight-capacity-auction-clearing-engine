open OUnit2
module Suite = Queue_conformance.Make (In_memory_queue)

let run_case case _context =
  let backend = In_memory_queue.create () in
  Lwt_main.run (case.Queue_conformance.run backend)

let suite =
  "in-memory queue conformance"
  >::: List.map
         (fun case -> case.Queue_conformance.name >:: run_case case)
         Suite.cases

let () = run_test_tt_main suite
