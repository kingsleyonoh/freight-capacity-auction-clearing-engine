# Shared Redis Queue Lifecycle

## What it establishes

Each server or worker process owns one fail-closed Redis connection for bounded FIFO queues, owned expiring locks, and bounded typed job-progress Streams, with terminal graceful shutdown.

## Files

- `src/shared/redis_queue.ml` / `src/shared/redis_queue.mli` — validated names and payloads, singleton lifecycle, atomic queue admission, lock ownership, bounded progress Streams, and shutdown
- `tests/integration/redis_queue_test.ml` — real Redis queue, lock, Stream, startup, and terminal-lifecycle behavior
- `tests/integration/run_redis.sh` — unique cached-image Redis 7 harness with host-loopback and explicit joined-network URLs, persistence disabled, tmpfs data, and cleanup proof
- `tests/fixtures/queue_conformance.{ml,mli}` / `in_memory_queue.{ml,mli}` — tests-only shared bounded-FIFO semantics and private per-instance memory fixture
- `tests/integration/run_redis_parallel.sh` — two simultaneous isolated core-conformance invocations with distinct identities and zero-resource cleanup proof

## When to read this

Before writing code that:
- Starts, obtains, or shuts down Redis access
- Enqueues or consumes jobs, acquires worker locks, or emits progress
- Changes Redis key namespaces, queue limits, or process connection budgets

## Contract

- Composition unwraps the validated `REDIS_URL` and calls `Redis_queue.start`; domain modules never read Redis configuration or create another connection.
- Startup accepts `redis://` only, performs optional AUTH, SELECT, and PING before publishing one cached handle, and fails closed after running I/O/protocol/cancellation failures. `rediss://` is rejected rather than downgraded.
- Queue constructors enforce names, depth, and payload limits. Enqueue atomically checks depth and `RPUSH`es in one Lua call; dequeue uses nonblocking `LPOP` on the sole connection.
- Locks use `SET NX PX`; renew and release are compare-owner Lua operations. Never release or renew a lock using a different owner token.
- Progress contains only state and numeric completion. Append uses one private bounded `XADD ... MAXLEN ~` custom encoder; read uses typed nonblocking `XREAD`. No public raw Redis, flush, reset, or server-shutdown API exists.
- Shutdown stops admission, waits for admitted operations, disconnects once, and remains terminal and idempotent.
- Shared conformance covers byte/JSON FIFO, nonblocking empty dequeue, exact serialized payload caps, atomic max-depth/no-drop behavior, 64-way concurrent admission, and terminal idempotent close. OUnit2 runs the memory fixture; Alcotest runs the same semantics through a thin public-API Redis adapter.
- The memory fixture is not production code and has no reset/raw-storage hook. It copies payloads and holds only its private per-instance `Lwt_mutex`. Redis locks, Streams, AUTH, failure, and drain behavior remain real-Redis-only tests.
- Harness invocations own a labelled Redis container/network, generated credentials, tmpfs data, and no persistence. Host commands use loopback; only an explicitly network-joined child receives internal URLs. No shared server is flushed.

## Cross-references

- `.agent/knowledge/modules/src-shared.md`
- `.agent/rules/jobs_rules.md`
- `.agent/knowledge/gotchas/2026-07-15-redis-lwt-separate-package.md`
- `.agent/knowledge/gotchas/2026-07-15-redis-0-8-stream-maxlen-token.md`
- `docs/freight-capacity-auction-clearing-engine_prd.md` §7
