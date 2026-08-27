#!/usr/bin/env bash
set -euo pipefail

IMAGE="redis:7-alpine"
RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$-$(printf '%06x' "$((RANDOM * RANDOM))")"
CONTAINER="fca-redis-it-${RUN_ID}"
NETWORK="fca-redis-it-${RUN_ID}"
LABEL="fca.redis.integration=${RUN_ID}"
FULL_RUN_ID="${FCA_FULL_TEST_RUN_ID:-}"
FULL_LABEL_ARGS=()
if [[ -n "$FULL_RUN_ID" ]]; then
  if [[ ! "$FULL_RUN_ID" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]; then
    printf 'FCA_FULL_TEST_RUN_ID is invalid\n' >&2
    exit 64
  fi
  FULL_LABEL_ARGS=(--label "fca.full-test.run=${FULL_RUN_ID}")
fi
ARTIFACT_ROOT="${FCA_REDIS_ARTIFACT_ROOT:-.pi/redis-integration}"
ARTIFACT_DIR="${ARTIFACT_ROOT}/${RUN_ID}"
CONTROL_ROOT="${FCA_REDIS_CONTROL_ROOT:-${ARTIFACT_DIR}}"
CONTROL_DIR="${CONTROL_ROOT}/fca-redis-control-${RUN_ID}"
mkdir -p "$ARTIFACT_DIR" "$CONTROL_DIR"
printf 'run_id=%s\ncontainer=%s\nnetwork=%s\nlabel=%s\n' \
  "$RUN_ID" "$CONTAINER" "$NETWORK" "$LABEL" >"$ARTIFACT_DIR/identity.txt"

if [[ "${1:-}" == "--" ]]; then
  shift
fi

# Generated per disposable run; never persisted in source or artifacts.
DEFAULT_PASSWORD="pw:${RUN_ID}"
WRONG_PASSWORD="wrong:${RUN_ID}"
ACL_USER="app-user"
ACL_PASSWORD="acl:${RUN_ID}"
ACL_WRONG_PASSWORD="acl-wrong:${RUN_ID}"
DENIED_USER="eager-denied"
DENIED_PASSWORD="denied:${RUN_ID}"

container_created=false
network_created=false
container_paused=false

cleanup() {
  command_status=$?
  trap - EXIT INT TERM
  set +e
  cleanup_failed=false
  if [[ "$container_paused" == true ]]; then
    docker unpause "$CONTAINER" >"$ARTIFACT_DIR/container-emergency-unpause.txt" 2>&1 || cleanup_failed=true
    container_paused=false
  fi
  if [[ "$container_created" == true ]]; then
    docker inspect "$CONTAINER" \
      --format 'state={{json .State}} ports={{json .NetworkSettings.Ports}} image={{json .Config.Image}} mounts={{json .Mounts}}' \
      >"$ARTIFACT_DIR/container-final-inspect-redacted.txt" 2>&1 || cleanup_failed=true
    docker logs "$CONTAINER" >"$ARTIFACT_DIR/redis.log" 2>&1 || cleanup_failed=true
    docker rm -f "$CONTAINER" >"$ARTIFACT_DIR/container-remove.txt" 2>&1 || cleanup_failed=true
  fi
  if [[ "$network_created" == true ]]; then
    docker network rm "$NETWORK" >"$ARTIFACT_DIR/network-remove.txt" 2>&1 || cleanup_failed=true
  fi
  docker ps -a --filter "label=${LABEL}" --format '{{.Names}}' >"$ARTIFACT_DIR/post-cleanup-containers.txt" 2>&1 || cleanup_failed=true
  if docker network inspect "$NETWORK" >/dev/null 2>&1; then
    printf 'network_present=true\n' >"$ARTIFACT_DIR/post-cleanup-network.txt"
    cleanup_failed=true
  else
    printf 'network_present=false\n' >"$ARTIFACT_DIR/post-cleanup-network.txt"
  fi
  if [[ -s "$ARTIFACT_DIR/post-cleanup-containers.txt" ]]; then
    cleanup_failed=true
  fi
  rm -rf "$CONTROL_DIR" || cleanup_failed=true
  printf 'control_removed=%s\n' "$([[ ! -e "$CONTROL_DIR" ]] && echo true || echo false)" \
    >"$ARTIFACT_DIR/control-cleanup.txt"
  printf 'command_exit=%s\ncleanup_failed=%s\n' "$command_status" "$cleanup_failed" \
    >"$ARTIFACT_DIR/status.txt"
  if [[ "$cleanup_failed" == true ]]; then
    printf 'Redis integration cleanup failed; inspect %s\n' "$ARTIFACT_DIR" >&2
    exit 70
  fi
  exit "$command_status"
}
trap cleanup EXIT INT TERM

if ! docker image inspect "$IMAGE" --format 'id={{.Id}} repo_digests={{json .RepoDigests}}' \
  >"$ARTIFACT_DIR/image.txt" 2>&1; then
  printf 'Required cached Redis image is unavailable; refusing to pull\n' >&2
  exit 69
fi
docker network create --label "$LABEL" "${FULL_LABEL_ARGS[@]}" "$NETWORK" >"$ARTIFACT_DIR/network-create.txt"
network_created=true
MSYS_NO_PATHCONV=1 docker run -d --pull=never --name "$CONTAINER" --label "$LABEL" "${FULL_LABEL_ARGS[@]}" --network "$NETWORK" \
  --mount type=tmpfs,destination=/data,tmpfs-size=16777216 \
  --publish 127.0.0.1::6379 "$IMAGE" \
  redis-server --save '' --appendonly no --protected-mode no \
  --requirepass "$DEFAULT_PASSWORD" >"$ARTIFACT_DIR/container-create.txt"
container_created=true

docker inspect "$CONTAINER" \
  --format 'name={{.Name}} image={{.Config.Image}} labels={{json .Config.Labels}} ports={{json .NetworkSettings.Ports}} mounts={{json .Mounts}}' \
  >"$ARTIFACT_DIR/container-inspect-redacted.txt"

redis_cli() {
  docker exec "$CONTAINER" redis-cli --no-auth-warning -a "$DEFAULT_PASSWORD" "$@"
}

wait_ready() {
  local ready=false
  for _ in $(seq 1 60); do
    if redis_cli PING 2>/dev/null | grep -qx PONG; then
      ready=true
      break
    fi
    sleep 0.1
  done
  [[ "$ready" == true ]]
}

if ! wait_ready; then
  printf 'redis_ready=false\n' >"$ARTIFACT_DIR/readiness.txt"
  exit 1
fi
printf 'redis_ready=true authenticated=true\n' >"$ARTIFACT_DIR/readiness.txt"
docker exec "$CONTAINER" redis-server --version >"$ARTIFACT_DIR/redis-version.txt"
redis_cli ACL SETUSER "$ACL_USER" on ">${ACL_PASSWORD}" '~*' '+@all' >/dev/null
redis_cli ACL SETUSER "$DENIED_USER" on ">${DENIED_PASSWORD}" '~*' '+select' '-ping' >/dev/null

HOST_PORT="$(docker port "$CONTAINER" 6379/tcp | awk -F: '{print $NF}')"
printf 'loopback_port_assigned=true\n' >"$ARTIFACT_DIR/port.txt"
redis_cli -n 15 RPUSH fca:v1:queue:poison 'j:{broken' >/dev/null

encode_password() { printf '%s' "${1//:/%3A}"; }
ENCODED_DEFAULT="$(encode_password "$DEFAULT_PASSWORD")"
ENCODED_WRONG="$(encode_password "$WRONG_PASSWORD")"
ENCODED_ACL="$(encode_password "$ACL_PASSWORD")"
ENCODED_ACL_WRONG="$(encode_password "$ACL_WRONG_PASSWORD")"
ENCODED_DENIED="$(encode_password "$DENIED_PASSWORD")"
export REDIS_URL="redis://:${ENCODED_DEFAULT}@127.0.0.1:${HOST_PORT}/15"
export REDIS_URL_WRONG="redis://:${ENCODED_WRONG}@127.0.0.1:${HOST_PORT}/15"
export REDIS_URL_ACL="redis://${ACL_USER}:${ENCODED_ACL}@127.0.0.1:${HOST_PORT}/15"
export REDIS_URL_ACL_WRONG="redis://${ACL_USER}:${ENCODED_ACL_WRONG}@127.0.0.1:${HOST_PORT}/15"
export REDIS_URL_DENIED="redis://${DENIED_USER}:${ENCODED_DENIED}@127.0.0.1:${HOST_PORT}/15"
export REDIS_BASE_URL="redis://127.0.0.1:${HOST_PORT}/15"
export REDIS_INTERNAL_URL="redis://:${ENCODED_DEFAULT}@${CONTAINER}:6379/15"
export REDIS_INTERNAL_URL_WRONG="redis://:${ENCODED_WRONG}@${CONTAINER}:6379/15"
export REDIS_INTERNAL_URL_ACL="redis://${ACL_USER}:${ENCODED_ACL}@${CONTAINER}:6379/15"
export REDIS_INTERNAL_URL_ACL_WRONG="redis://${ACL_USER}:${ENCODED_ACL_WRONG}@${CONTAINER}:6379/15"
export REDIS_INTERNAL_URL_DENIED="redis://${DENIED_USER}:${ENCODED_DENIED}@${CONTAINER}:6379/15"
export REDIS_INTERNAL_BASE_URL="redis://${CONTAINER}:6379/15"
export FCA_REDIS_TEST_CONTAINER_NAME="$CONTAINER"
export FCA_REDIS_TEST_NETWORK="$NETWORK"
export FCA_REDIS_CONTROL_DIR="$CONTROL_DIR"
export FCA_REDIS_RUN_ID="$RUN_ID"
printf 'command_supplied=%s canonical_default=%s\n' "$([[ $# -gt 0 ]] && echo true || echo false)" "$([[ $# -eq 0 ]] && echo false || echo caller-controlled)" >"$ARTIFACT_DIR/command.txt"

wait_for_marker() {
  local marker=$1
  local pid=$2
  local attempts=${3:-600}
  for _ in $(seq 1 "$attempts"); do
    [[ -f "$CONTROL_DIR/$marker" ]] && return 0
    kill -0 "$pid" 2>/dev/null || return 1
    sleep 0.05
  done
  return 2
}

monitor_fault_scenarios() {
  local pid=$1
  if ! wait_for_marker failure-ready "$pid"; then
    return 0
  fi
  docker restart "$CONTAINER" >"$ARTIFACT_DIR/container-restart.txt"
  if ! wait_ready; then
    printf 'restart_ready=false\n' >"$ARTIFACT_DIR/restart-readiness.txt"
    return 1
  fi
  printf 'restart_ready=true\n' >"$ARTIFACT_DIR/restart-readiness.txt"
  printf 'ok\n' >"$CONTROL_DIR/failure-broken"

  if ! wait_for_marker drain-ready "$pid"; then
    return 1
  fi
  docker pause "$CONTAINER" >"$ARTIFACT_DIR/container-pause.txt"
  container_paused=true
  printf 'ok\n' >"$CONTROL_DIR/drain-paused"
  if ! wait_for_marker drain-release "$pid"; then
    return 1
  fi
  docker unpause "$CONTAINER" >"$ARTIFACT_DIR/container-unpause.txt"
  container_paused=false
  printf 'ok\n' >"$CONTROL_DIR/drain-unpaused"
}

if [[ $# -eq 0 ]]; then
  set -- env FCA_INTEGRATION_SUITE=redis dune exec tests/integration/main.exe
fi
set +e
"$@" > >(tee "$ARTIFACT_DIR/test-output.txt") 2>&1 &
test_pid=$!
monitor_fault_scenarios "$test_pid" &
monitor_pid=$!
wait "$test_pid"
test_status=$?
wait "$monitor_pid"
monitor_status=$?
set -e
if [[ "$monitor_status" -ne 0 ]]; then
  printf 'fault_monitor_exit=%s\n' "$monitor_status" >"$ARTIFACT_DIR/fault-monitor.txt"
  exit "$monitor_status"
fi

application_connections="$(redis_cli CLIENT LIST TYPE normal | awk 'END { print NR - 1 }')"
printf 'application_connections_after_test=%s\n' "$application_connections" >"$ARTIFACT_DIR/client-cleanup.txt"
if (( application_connections != 0 )); then
  exit 1
fi

if [[ "$test_status" -eq 0 && -f "$ARTIFACT_DIR/restart-readiness.txt" ]]; then
  printf 'running_failure_observed=true drain_observed=true\n' >"$ARTIFACT_DIR/lifecycle-proof.txt"
fi
exit "$test_status"
