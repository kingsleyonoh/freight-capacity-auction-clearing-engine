#!/usr/bin/env bash
set -euo pipefail

ARTIFACT_ROOT="${FCA_INTEGRATION_ARTIFACT_ROOT:-.pi/combined-integration}"
FULL_RUN_ID="${FCA_FULL_TEST_RUN_ID:-standalone}"
if [[ ! "$FULL_RUN_ID" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]; then
  printf 'FCA_FULL_TEST_RUN_ID is invalid\n' >&2
  exit 64
fi
RUN_ID="${FULL_RUN_ID}-$(date -u +%Y%m%dT%H%M%SZ)-$$-$(printf '%06x' "$((RANDOM * RANDOM))")"
ARTIFACT_DIR="${ARTIFACT_ROOT}/${RUN_ID}"
mkdir -p "$ARTIFACT_DIR"

if [[ $# -eq 0 ]]; then
  set -- env -u FCA_INTEGRATION_SUITE dune exec tests/integration/main.exe
fi

printf 'services=postgresql-16,redis-7,http-loopback\nselector=default-all\ncommand=caller-supplied-or-canonical\nfull_run_id=%s\n' \
  "$FULL_RUN_ID" >"$ARTIFACT_DIR/command.txt"
export FCA_PG_ARTIFACT_ROOT="$ARTIFACT_DIR/postgres"
export FCA_REDIS_ARTIFACT_ROOT="$ARTIFACT_DIR/redis"

tests/integration/run_postgres16.sh -- \
  tests/integration/run_redis.sh "$@" 2>&1 | tee "$ARTIFACT_DIR/combined-output.txt"
printf 'combined_exit=0\n' >"$ARTIFACT_DIR/status.txt"
printf '%s\n' "$ARTIFACT_DIR"
