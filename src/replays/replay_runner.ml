type baseline = Lowest_cost | First_acceptable | Incumbent_preference | Historical_awards
type metric = { baseline : baseline; assigned : int; total_cost_cents : int; service_score_milli : int; error : string option }

let baseline_to_string = function
  | Lowest_cost -> "lowest_cost" | First_acceptable -> "first_acceptable" | Incumbent_preference -> "incumbent_preference" | Historical_awards -> "historical_awards"

let run baselines rows =
  let choose baseline =
    match baseline with
    | Lowest_cost -> List.sort (fun (left_cost, _, left_order) (right_cost, _, right_order) ->
        let comparison = compare left_cost right_cost in
        if comparison <> 0 then comparison else compare left_order right_order) rows
    | First_acceptable -> rows
    | Incumbent_preference -> List.sort (fun (left_cost, left_score, left_order) (right_cost, right_score, right_order) ->
        let comparison = compare right_score left_score in
        if comparison <> 0 then comparison else if compare left_cost right_cost <> 0 then compare left_cost right_cost else compare left_order right_order) rows
    | Historical_awards -> List.sort (fun (left_cost, _, left_order) (right_cost, _, right_order) ->
        let comparison = compare left_order right_order in
        if comparison <> 0 then comparison else compare left_cost right_cost) rows
  in
  List.map (fun baseline ->
      let chosen = match choose baseline with [] -> [] | row :: _ -> [ row ] in
      let assigned = List.length chosen in
      let total = List.fold_left (fun sum (cost, _, _) -> sum + cost) 0 chosen in
      let service = List.fold_left (fun sum (_, score, _) -> sum + score) 0 chosen in
      { baseline; assigned; total_cost_cents = total; service_score_milli = service; error = None }) baselines
