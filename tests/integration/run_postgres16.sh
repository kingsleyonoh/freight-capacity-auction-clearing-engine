#!/usr/bin/env bash
set -eu

# Public disposable integration-test literals. Never reuse outside this harness.
readonly TEST_DATABASE="fca_test"
readonly TEST_USER="fca_test"
readonly TEST_PASSWORD="fca_test_only_not_a_secret"
readonly WRONG_PASSWORD="fca_test_wrong_sample"
readonly IMAGE="postgres:16-alpine"

if [ "${1:-}" = "--" ]; then
  shift
fi
if [ "$#" -eq 0 ]; then
  echo "usage: $0 -- command [args...]" >&2
  exit 64
fi

RUN_ID="$(date -u +%Y%m%dT%H%M%SZ)-$$-$(od -An -N3 -tx1 /dev/urandom | tr -d ' \n')"
CONTAINER="fca-pg16-it-$RUN_ID"
NETWORK="fca-pg16-net-$RUN_ID"
LABEL="fca.integration.run=$RUN_ID"
FULL_RUN_ID="${FCA_FULL_TEST_RUN_ID:-}"
if [ -z "$FULL_RUN_ID" ]; then
  FULL_LABEL=""
elif printf '%s' "$FULL_RUN_ID" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$'; then
  FULL_LABEL="fca.full-test.run=$FULL_RUN_ID"
else
  echo "FCA_FULL_TEST_RUN_ID is invalid" >&2
  exit 64
fi
ARTIFACT_DIR="${FCA_PG_ARTIFACT_ROOT:-tests/_artifacts/postgres}/$RUN_ID"
mkdir -p "$ARTIFACT_DIR"

container_created=0
network_created=0
cleanup_failed=0

cleanup() {
  command_status=$?
  trap - EXIT INT TERM
  {
    echo "run_id=$RUN_ID"
    echo "command_exit=$command_status"
    echo "container=$CONTAINER"
    echo "network=$NETWORK"
  } >"$ARTIFACT_DIR/status.txt"

  if [ "$container_created" -eq 1 ]; then
    docker inspect --format 'state={{json .State}} ports={{json .NetworkSettings.Ports}} image={{json .Config.Image}} image_id={{json .Image}}' \
      "$CONTAINER" >"$ARTIFACT_DIR/container-inspect-redacted.txt" 2>&1 || cleanup_failed=1
    docker logs "$CONTAINER" >"$ARTIFACT_DIR/postgres.log" 2>&1 || cleanup_failed=1
    docker rm -f "$CONTAINER" >"$ARTIFACT_DIR/container-remove.txt" 2>&1 || cleanup_failed=1
  fi
  if [ "$network_created" -eq 1 ]; then
    docker network rm "$NETWORK" >"$ARTIFACT_DIR/network-remove.txt" 2>&1 || cleanup_failed=1
  fi

  docker ps -a --filter "label=$LABEL" --format '{{.Names}} {{.Status}}' \
    >"$ARTIFACT_DIR/post-cleanup-containers.txt" 2>&1 || cleanup_failed=1
  if docker network inspect "$NETWORK" >/dev/null 2>&1; then
    echo "network_still_present" >"$ARTIFACT_DIR/post-cleanup-network.txt"
    cleanup_failed=1
  else
    echo "network_absent" >"$ARTIFACT_DIR/post-cleanup-network.txt"
  fi

  if [ -s "$ARTIFACT_DIR/post-cleanup-containers.txt" ]; then
    cleanup_failed=1
  fi
  if [ "$cleanup_failed" -ne 0 ]; then
    echo "PostgreSQL integration cleanup failed; inspect $ARTIFACT_DIR" >&2
    exit 70
  fi
  exit "$command_status"
}
trap cleanup EXIT INT TERM

if ! docker image inspect "$IMAGE" --format 'image_id={{.Id}} repo_digests={{json .RepoDigests}}' \
  >"$ARTIFACT_DIR/image.txt" 2>&1; then
  echo "Required cached image is unavailable; refusing to pull" >&2
  exit 69
fi

if [ -n "$FULL_LABEL" ]; then
  docker network create --label "$LABEL" --label "$FULL_LABEL" "$NETWORK" \
    >"$ARTIFACT_DIR/network-create.txt" 2>&1
else
  docker network create --label "$LABEL" "$NETWORK" \
    >"$ARTIFACT_DIR/network-create.txt" 2>&1
fi
network_created=1

if [ -n "$FULL_LABEL" ]; then
  docker run -d --pull=never --name "$CONTAINER" --network "$NETWORK" \
    --label "$LABEL" --label "$FULL_LABEL" -p 127.0.0.1::5432 \
    -e "POSTGRES_DB=$TEST_DATABASE" -e "POSTGRES_USER=$TEST_USER" \
    -e "POSTGRES_PASSWORD=$TEST_PASSWORD" "$IMAGE" \
    >"$ARTIFACT_DIR/container-create.txt" 2>&1
else
  docker run -d --pull=never --name "$CONTAINER" --network "$NETWORK" \
    --label "$LABEL" -p 127.0.0.1::5432 \
    -e "POSTGRES_DB=$TEST_DATABASE" -e "POSTGRES_USER=$TEST_USER" \
    -e "POSTGRES_PASSWORD=$TEST_PASSWORD" "$IMAGE" \
    >"$ARTIFACT_DIR/container-create.txt" 2>&1
fi
container_created=1

ready=0
attempt=0
while [ "$attempt" -lt 60 ]; do
  attempt=$((attempt + 1))
  if docker exec "$CONTAINER" pg_isready -U "$TEST_USER" -d "$TEST_DATABASE" \
      >/dev/null 2>&1; then
    ready=1
    break
  fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  echo "PostgreSQL did not become ready within 60 seconds" >&2
  exit 68
fi

docker exec "$CONTAINER" postgres --version >"$ARTIFACT_DIR/postgres-version.txt" 2>&1
printf 'ready=true\nattempts=%s\n' "$attempt" >"$ARTIFACT_DIR/readiness.txt"

PORT_MAPPING="$(docker port "$CONTAINER" 5432/tcp)"
PORT="${PORT_MAPPING##*:}"
case "$PORT" in
  ''|*[!0-9]*) echo "Docker assigned an invalid loopback port" >&2; exit 67 ;;
esac

DATABASE_URL="$(printf '%s://%s:%s@127.0.0.1:%s/%s' \
  "postgresql" "$TEST_USER" "$TEST_PASSWORD" "$PORT" "$TEST_DATABASE")"
DATABASE_URL_WRONG="$(printf '%s://%s:%s@127.0.0.1:%s/%s' \
  "postgresql" "$TEST_USER" "$WRONG_PASSWORD" "$PORT" "$TEST_DATABASE")"
export DATABASE_URL DATABASE_URL_WRONG
export DATABASE_INTERNAL_URL="postgresql://${TEST_USER}:${TEST_PASSWORD}@${CONTAINER}:5432/${TEST_DATABASE}"
export DATABASE_INTERNAL_URL_WRONG="postgresql://${TEST_USER}:${WRONG_PASSWORD}@${CONTAINER}:5432/${TEST_DATABASE}"
export FCA_PG_TEST_CONTAINER_NAME="$CONTAINER"
export FCA_PG_TEST_NETWORK="$NETWORK"
export FCA_PG_RUN_ID="$RUN_ID"
export FCA_PG_SCHEMA_PREFIX="fca_it_"
"$@"
