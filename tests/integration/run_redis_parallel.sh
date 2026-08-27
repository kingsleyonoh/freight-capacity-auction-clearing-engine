#!/usr/bin/env bash
set -euo pipefail

PARALLEL_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$-$(printf '%06x' "$((RANDOM * RANDOM))")"
ROOT="${FCA_REDIS_PARALLEL_ARTIFACT_ROOT:-.pi/redis-parallel}/${PARALLEL_ID}"
A_ROOT="$ROOT/a"
B_ROOT="$ROOT/b"
mkdir -p "$A_ROOT" "$B_ROOT"

if [[ "${1:-}" == "--" ]]; then
  shift
fi
if [[ $# -eq 0 ]]; then
  set -- env FCA_INTEGRATION_SUITE=redis FCA_REDIS_SCENARIO=core \
    dune exec tests/integration/main.exe
fi
printf 'parallel_id=%s\ninvocations=2\nscenario=core\n' "$PARALLEL_ID" \
  >"$ROOT/plan.txt"

set +e
(FCA_REDIS_ARTIFACT_ROOT="$A_ROOT" tests/integration/run_redis.sh -- "$@") \
  >"$ROOT/a-output.txt" 2>&1 &
a_pid=$!
(FCA_REDIS_ARTIFACT_ROOT="$B_ROOT" tests/integration/run_redis.sh -- "$@") \
  >"$ROOT/b-output.txt" 2>&1 &
b_pid=$!
wait "$a_pid"
a_status=$?
wait "$b_pid"
b_status=$?
set -e
printf 'a_exit=%s\nb_exit=%s\n' "$a_status" "$b_status" >"$ROOT/exit-status.txt"
if [[ "$a_status" -ne 0 || "$b_status" -ne 0 ]]; then
  printf 'parallel Redis conformance failed; inspect %s\n' "$ROOT" >&2
  exit 1
fi

mapfile -t a_identities < <(find "$A_ROOT" -mindepth 2 -maxdepth 2 -name identity.txt -type f)
mapfile -t b_identities < <(find "$B_ROOT" -mindepth 2 -maxdepth 2 -name identity.txt -type f)
if [[ "${#a_identities[@]}" -ne 1 || "${#b_identities[@]}" -ne 1 ]]; then
  printf 'expected exactly one identity per parallel harness\n' >&2
  exit 1
fi
read_value() { awk -F= -v key="$2" '$1 == key { print substr($0, length(key) + 2) }' "$1"; }
a_id="$(read_value "${a_identities[0]}" run_id)"
b_id="$(read_value "${b_identities[0]}" run_id)"
a_container="$(read_value "${a_identities[0]}" container)"
b_container="$(read_value "${b_identities[0]}" container)"
a_network="$(read_value "${a_identities[0]}" network)"
b_network="$(read_value "${b_identities[0]}" network)"
if [[ -z "$a_id" || -z "$b_id" || "$a_id" == "$b_id" || \
      "$a_container" == "$b_container" || "$a_network" == "$b_network" ]]; then
  printf 'parallel Redis identities were not distinct\n' >&2
  exit 1
fi

remaining_containers=0
remaining_networks=0
for id in "$a_id" "$b_id"; do
  count="$(docker ps -a --filter "label=fca.redis.integration=${id}" --format '{{.Names}}' | wc -l | tr -d ' ')"
  remaining_containers=$((remaining_containers + count))
done
for network in "$a_network" "$b_network"; do
  if docker network inspect "$network" >/dev/null 2>&1; then
    remaining_networks=$((remaining_networks + 1))
  fi
done
printf 'distinct_run_ids=true\ndistinct_containers=true\ndistinct_networks=true\nremaining_containers=%s\nremaining_networks=%s\n' \
  "$remaining_containers" "$remaining_networks" >"$ROOT/isolation-proof.txt"
if [[ "$remaining_containers" -ne 0 || "$remaining_networks" -ne 0 ]]; then
  printf 'parallel Redis cleanup proof failed\n' >&2
  exit 70
fi
printf '%s\n' "$ROOT"
