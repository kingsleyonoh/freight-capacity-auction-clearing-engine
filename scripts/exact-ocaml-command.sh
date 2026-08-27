#!/usr/bin/env bash
set -euo pipefail

IMAGE="fca-phase0-api-e2e-test:ocaml-5.2.0-dream-alpha7"
if [[ $# -eq 0 ]]; then
  printf 'usage: %s command [args...]\n' "$0" >&2
  exit 64
fi
FORMAT_MODE=false
for argument in "$@"; do
  if [[ "$argument" == "@fmt" ]]; then
    IMAGE="fca-mesh-ocaml-5.2.0-format:latest"
    FORMAT_MODE=true
    break
  fi
done
readonly IMAGE FORMAT_MODE
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
  printf 'required cached exact OCaml 5.2.0 image is unavailable; refusing to pull\n' >&2
  exit 69
fi

rewrite_loopback() {
  local value=$1
  value=${value//127.0.0.1/host.docker.internal}
  value=${value//localhost/host.docker.internal}
  printf '%s' "$value"
}

docker_args=(
  run --rm --pull=never
  --add-host host.docker.internal:host-gateway
  --volume "$PWD:/workspace"
  --workdir /workspace
  --entrypoint opam
)
if [[ "$FORMAT_MODE" == true ]]; then
  docker_args+=(--env "DUNE_BUILD_DIR=/tmp/fca-format-build")
fi
if [[ -n "${FCA_FULL_TEST_RUN_ID:-}" ]]; then
  if [[ ! "$FCA_FULL_TEST_RUN_ID" =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$ ]]; then
    printf 'FCA_FULL_TEST_RUN_ID is invalid\n' >&2
    exit 64
  fi
  docker_args+=(--label "fca.full-test.run=${FCA_FULL_TEST_RUN_ID}")
fi
for network_name in "${FCA_PG_TEST_NETWORK:-}" "${FCA_REDIS_TEST_NETWORK:-}"; do
  if [[ -n "$network_name" ]]; then
    docker_args+=(--network "$network_name")
  fi
done
readonly pass_names=(
  DATABASE_URL DATABASE_URL_WRONG REDIS_URL REDIS_URL_WRONG REDIS_URL_ACL
  REDIS_URL_ACL_WRONG REDIS_URL_DENIED REDIS_BASE_URL FCA_PG_TEST_CONTAINER_NAME
  FCA_PG_TEST_NETWORK FCA_PG_RUN_ID FCA_PG_SCHEMA_PREFIX FCA_REDIS_TEST_CONTAINER_NAME
  FCA_REDIS_TEST_NETWORK FCA_REDIS_CONTROL_DIR FCA_REDIS_RUN_ID FCA_INTEGRATION_SUITE
  FCA_POSTGRES_SCENARIO FCA_REDIS_SCENARIO FCA_PROCESS_FIXTURE FCA_DUCKDB_BINARY
  REPLAY_MAX_ROWS MINIZINC_BINARY_PATH ORTOOLS_WORKER_PATH SOLVER_BACKEND
  SOLVER_TIMEOUT_SECONDS FCA_FULL_TEST_RUN_ID
)
for name in "${pass_names[@]}"; do
  if [[ -v "$name" ]]; then
    value=${!name}
    case "$name" in
      DATABASE_URL) value=${DATABASE_INTERNAL_URL:-$value} ;;
      DATABASE_URL_WRONG) value=${DATABASE_INTERNAL_URL_WRONG:-$value} ;;
      REDIS_URL) value=${REDIS_INTERNAL_URL:-$value} ;;
      REDIS_URL_WRONG) value=${REDIS_INTERNAL_URL_WRONG:-$value} ;;
      REDIS_URL_ACL) value=${REDIS_INTERNAL_URL_ACL:-$value} ;;
      REDIS_URL_ACL_WRONG) value=${REDIS_INTERNAL_URL_ACL_WRONG:-$value} ;;
      REDIS_URL_DENIED) value=${REDIS_INTERNAL_URL_DENIED:-$value} ;;
      REDIS_BASE_URL) value=${REDIS_INTERNAL_BASE_URL:-$value} ;;
      *) value=$(rewrite_loopback "$value") ;;
    esac
    if [[ "$name" == "FCA_DUCKDB_BINARY" && "$value" != /* ]]; then
      value="/workspace/${value#./}"
    fi
    docker_args+=(--env "${name}=${value}")
  fi
done

docker_args+=("$IMAGE" exec -- "$@")
MSYS_NO_PATHCONV=1 exec docker "${docker_args[@]}"
