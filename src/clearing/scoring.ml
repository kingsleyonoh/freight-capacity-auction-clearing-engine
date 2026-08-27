let total_score ~amount_cents ~service_score_milli =
  (amount_cents * 1_000) - (service_score_milli * 10)

let compare_bid (left : Model_builder.bid) (right : Model_builder.bid) =
  let score_left = total_score ~amount_cents:left.amount_cents ~service_score_milli:left.service_score_milli in
  let score_right = total_score ~amount_cents:right.amount_cents ~service_score_milli:right.service_score_milli in
  match compare score_left score_right with 0 -> String.compare left.id right.id | value -> value
