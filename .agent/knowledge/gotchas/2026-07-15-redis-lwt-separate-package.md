# Redis Lwt Is a Separate opam Package

- **Symptom:** Dune reports that library `redis-lwt` is unavailable even though opam package `redis` version 0.8 is installed.
- **Cause:** In version 0.8, the Lwt implementation is distributed as the separate opam package `redis-lwt`; installing `redis` alone does not install that library.
- **Solution:** Pin both `redis = 0.8` and `redis-lwt = 0.8` in the project opam manifest and list both libraries explicitly in the shared Dune stanza.
- **Discovered in:** Freight Capacity Auction Clearing Engine, Phase 0 shared Redis boundary, 2026-07-15.
- **Affects:** opam `redis` / `redis-lwt` 0.8 projects using the Lwt client.
