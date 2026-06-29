(lang dune 3.13)
(name freight_capacity_auction_clearing_engine)

(implicit_transitive_deps false)

(package
 (name freight_capacity_auction_clearing_engine)
 (synopsis "Tenant-scoped freight capacity auction clearing engine")
 (description "Dream/HTMX freight capacity auction clearing foundation with local Postgres, Redis, DuckDB replay, and solver process boundaries.")
 (depends
  (ocaml (>= 5.2.0))
  (dune (>= 3.13))
  dream
  lwt
  logs
  yojson
  ppx_deriving_yojson
  caqti
  caqti-lwt
  caqti-driver-postgresql
  (alcotest :with-test)
  (ounit2 :with-test)))
