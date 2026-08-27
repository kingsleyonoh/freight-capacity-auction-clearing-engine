# Redis 0.8 Emits MAXCOUNT for Stream Trimming

- **Symptom:** Redis rejects typed `XADD ~maxlen` or `XTRIM` requests from package version 0.8 even though the requested Stream length is valid.
- **Cause:** Redis 0.8's cached `client.ml` encoder emits the non-existent token `MAXCOUNT` where Redis requires `MAXLEN` for those Stream commands.
- **Solution:** Keep normal operations on the typed client, but isolate one private append-only custom encoder for exactly `XADD key MAXLEN ~ limit * fields`, parse only the expected bulk stream ID, and expose no general raw-command API.
- **Discovered in:** Freight Capacity Auction Clearing Engine, Phase 0 shared Redis boundary, 2026-07-15.
- **Affects:** opam `redis` / `redis-lwt` 0.8 Stream append/trim calls using the affected encoder.
