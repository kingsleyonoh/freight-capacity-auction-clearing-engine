# Queue and Background Job Rules

- Worker entry point is `bin/worker.ml`; domain job registrations live under `src/jobs/`. New jobs are wired and discoverable in the same change.
- Redis schedules/wakes work; PostgreSQL rows are the canonical state and contain all data required after restart.
- Every job payload includes `tenant_id`, canonical record ID, request/correlation ID, and idempotency identity—never secret values or an unbounded domain snapshot when a frozen DB snapshot exists.
- Acquire an owned expiring lock, atomically claim allowed status, and reject duplicate/terminal execution. Release only locks owned by the worker.
- Persist queued/running/succeeded/failed/infeasible/cancelled/retry states and timestamps according to each PRD table. Retry only classified transient failures with bounded backoff.
- Clearing and replay child processes have timeout, cancellation, exit/error capture, artifact cleanup, and graceful shutdown. Blocking process/file work does not run on Dream's event loop.
- Optional integration/notification delivery flows through `integration_outbox`; adapter failure never rolls back auction/award/approval truth.
- Replay work cannot emit live external events unless explicitly allowed, and never mutates live awards.
- Workers log safe structured `{tenant_id,job_id,request_id,status,duration_ms,error_code}` and never secrets/raw bid payloads.
- Tests use local Redis plus PostgreSQL and cover duplicate delivery, retry, lock expiry/ownership, restart after claim, poison payload, cancellation, and exactly-once canonical outcome.
- Scheduled frequencies and enable flags follow PRD §7; disabled optional pollers/health checks remain inert and visible as disabled.
