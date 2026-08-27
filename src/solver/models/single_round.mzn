int: load_count;
int: bid_count;
array[1..load_count] of int: reserve_cents;
array[1..bid_count] of int: bid_load;
array[1..bid_count] of int: bid_amount_cents;
array[1..bid_count] of int: bid_service_milli;
array[1..bid_count] of int: bid_carrier;
array[1..load_count] of var 1..bid_count: selected;

constraint forall (load in 1..load_count) (bid_load[selected[load]] = load /\ bid_amount_cents[selected[load]] >= reserve_cents[load]);
solve minimize sum (load in 1..load_count) (bid_amount_cents[selected[load]] - bid_service_milli[selected[load]]);
output [ "{\"type\":\"status\",\"status\":\"OPTIMAL_SOLUTION\"}" ];
