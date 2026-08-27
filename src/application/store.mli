type actor = { user_id : string; tenant_id : string; role : string; carrier_id : string option }
type error = Unavailable | Not_found | Conflict | Invalid of string

val health : unit -> bool Lwt.t
val authenticate : api_key:string -> (actor, error) result Lwt.t
val seed_demo : unit -> (string * string, error) result Lwt.t
val register : tenant_name:string -> email:string -> name:string -> (actor * string, error) result Lwt.t
val list_auctions : tenant_id:string -> (Yojson.Safe.t, error) result Lwt.t
val get_auction : tenant_id:string -> auction_id:string -> carrier_id:string option -> (Yojson.Safe.t, error) result Lwt.t
val list_bids : tenant_id:string -> auction_id:string -> carrier_id:string option -> (Yojson.Safe.t, error) result Lwt.t
val create_auction : auto_clear_on_close:bool -> tenant_id:string -> user_id:string -> name:string -> mode:string -> bid_open_at:string -> bid_close_at:string -> (string, error) result Lwt.t
val update_auction : tenant_id:string -> auction_id:string -> name:string -> bid_open_at:string -> bid_close_at:string -> (Yojson.Safe.t, error) result Lwt.t
val close_auction : tenant_id:string -> auction_id:string -> (unit, error) result Lwt.t
val enqueue_clear : tenant_id:string -> auction_id:string -> user_id:string -> (string, error) result Lwt.t
val add_load : tenant_id:string -> auction_id:string -> lane_id:string -> external_ref:string -> pickup_start:string -> pickup_end:string -> delivery_start:string -> delivery_end:string -> weight_lbs:int -> equipment_type:string -> (string, error) result Lwt.t
val submit_bid : tenant_id:string -> auction_id:string -> load_id:string -> carrier_id:string -> idempotency_key:string -> bid_amount_cents:int -> service_score_milli:int -> submitted_at:string -> (string, error) result Lwt.t
val submit_webhook_bid : tenant_id:string -> auction_id:string -> load_id:string -> carrier_id:string -> idempotency_key:string -> bid_amount_cents:int -> service_score_milli:int -> submitted_at:string -> (string, error) result Lwt.t
val list_carriers : tenant_id:string -> (Yojson.Safe.t, error) result Lwt.t
val get_carrier : tenant_id:string -> carrier_id:string -> (Yojson.Safe.t, error) result Lwt.t
val create_carrier : tenant_id:string -> legal_name:string -> display_name:string -> mc_number:string -> dot_number:string -> equipment_type:string -> status:string -> (string, error) result Lwt.t
val update_carrier : tenant_id:string -> carrier_id:string -> legal_name:string -> display_name:string -> equipment_type:string -> status:string -> (Yojson.Safe.t, error) result Lwt.t
val list_carrier_bids : tenant_id:string -> carrier_id:string -> (Yojson.Safe.t, error) result Lwt.t
val list_users : tenant_id:string -> (Yojson.Safe.t, error) result Lwt.t
val get_user : tenant_id:string -> user_id:string -> (Yojson.Safe.t, error) result Lwt.t
val create_user : tenant_id:string -> email:string -> name:string -> role:string -> carrier_id:string option -> (string, error) result Lwt.t
val update_user : tenant_id:string -> user_id:string -> name:string -> role:string -> carrier_id:string option -> (Yojson.Safe.t, error) result Lwt.t
val get_tenant : tenant_id:string -> (Yojson.Safe.t, error) result Lwt.t
val list_policies : tenant_id:string -> (Yojson.Safe.t, error) result Lwt.t
val create_policy : tenant_id:string -> name:string -> max_service_risk:string -> max_single_carrier_share:string -> reserve_price_behavior:string -> (Yojson.Safe.t, error) result Lwt.t
val activate_policy : tenant_id:string -> policy_id:string -> (Yojson.Safe.t, error) result Lwt.t
val list_clearing_jobs : tenant_id:string -> (Yojson.Safe.t, error) result Lwt.t
val get_clearing_job : tenant_id:string -> job_id:string -> (Yojson.Safe.t, error) result Lwt.t
val list_awards : tenant_id:string -> auction_id:string option -> carrier_id:string option -> (Yojson.Safe.t, error) result Lwt.t
val list_approvals : tenant_id:string -> (Yojson.Safe.t, error) result Lwt.t
val list_notifications : tenant_id:string -> user_id:string option -> (Yojson.Safe.t, error) result Lwt.t
val mark_notification_read : tenant_id:string -> user_id:string -> notification_id:string -> (unit, error) result Lwt.t
val list_integrations : tenant_id:string -> (Yojson.Safe.t, error) result Lwt.t
val update_integration : tenant_id:string -> integration_name:string -> enabled:bool -> config:string -> (Yojson.Safe.t, error) result Lwt.t
val enqueue_integration : tenant_id:string -> integration_name:string -> event_type:string -> target_url_env_var:string -> payload:string -> idempotency_key:string -> (Yojson.Safe.t, error) result Lwt.t
val enqueue_notification_event : tenant_id:string -> event_type:string -> payload:string -> idempotency_key:string -> (unit, error) result Lwt.t
val list_reports : tenant_id:string -> (Yojson.Safe.t, error) result Lwt.t
val list_replays : tenant_id:string -> (Yojson.Safe.t, error) result Lwt.t
val list_audit_events : tenant_id:string -> (Yojson.Safe.t, error) result Lwt.t
val list_decisions : tenant_id:string -> auction_id:string -> redaction_scope:string -> carrier_id:string option -> (Yojson.Safe.t, error) result Lwt.t
val record_audit : tenant_id:string -> user_id:string -> entity_type:string -> entity_id:string -> event_type:string -> payload:string -> (unit, error) result Lwt.t
val record_system_audit : tenant_id:string -> entity_id:string -> event_type:string -> payload:string -> (unit, error) result Lwt.t
val approve_award : tenant_id:string -> user_id:string -> award_id:string -> note:string -> (string, error) result Lwt.t
val reject_award : tenant_id:string -> user_id:string -> award_id:string -> reason:string -> (string, error) result Lwt.t
val withdraw_award : tenant_id:string -> award_id:string -> carrier_id:string option -> (string, error) result Lwt.t
val export_snapshot : tenant_id:string -> auction_id:string -> format:string -> user_id:string -> (string * Yojson.Safe.t, error) result Lwt.t
val get_report : tenant_id:string -> report_id:string -> (string * string * Yojson.Safe.t, error) result Lwt.t
val update_tenant : tenant_id:string -> name:string -> display_name:string -> (Yojson.Safe.t, error) result Lwt.t
val create_import : tenant_id:string -> user_id:string -> resource_type:string -> source_filename:string -> source_format:string -> auction_id:string option -> mapping:string -> staging_rows:string -> validation_summary:string -> row_errors:string -> row_count:int -> valid_row_count:int -> invalid_row_count:int -> (string, error) result Lwt.t
val import_context : tenant_id:string -> (Yojson.Safe.t, error) result Lwt.t
val get_import : tenant_id:string -> import_id:string -> (Yojson.Safe.t, error) result Lwt.t
val commit_import : tenant_id:string -> import_id:string -> confirm:bool -> (Yojson.Safe.t, error) result Lwt.t
val list_notification_preferences : tenant_id:string -> user_id:string -> (Yojson.Safe.t, error) result Lwt.t
val update_notification_preference : tenant_id:string -> user_id:string -> event_type:string -> channel:string -> enabled:bool -> quiet_hours:string -> (Yojson.Safe.t, error) result Lwt.t
val create_replay : tenant_id:string -> user_id:string -> name:string -> dataset_uri:string -> baseline_strategy:string -> policy_id:string -> (string, error) result Lwt.t
val get_replay : tenant_id:string -> replay_id:string -> (Yojson.Safe.t, error) result Lwt.t
val cancel_replay : tenant_id:string -> replay_id:string -> (unit, error) result Lwt.t
