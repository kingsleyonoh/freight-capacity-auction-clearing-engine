#!/usr/bin/env bash
set -euo pipefail

fail() { printf 'LOCAL_STORAGE_ERROR %s\n' "$1" >&2; exit "${2:-1}"; }
usage() {
  printf 'Usage: scripts/local-storage.sh <init|verify> [--repository-root PATH] [--replay-store-path ./data/replays/NAME.duckdb]\n' >&2
  exit 2
}

[[ $# -ge 1 ]] || usage
ACTION="$1"
shift
[[ "$ACTION" == init || "$ACTION" == verify ]] || usage
SCRIPT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
REPOSITORY_ROOT="$SCRIPT_ROOT"
REPLAY_STORE_PATH="./data/replays/replay.duckdb"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --repository-root) [[ $# -ge 2 ]] || usage; REPOSITORY_ROOT="$2"; shift 2 ;;
    --replay-store-path) [[ $# -ge 2 ]] || usage; REPLAY_STORE_PATH="$2"; shift 2 ;;
    *) usage ;;
  esac
done

[[ -d "$REPOSITORY_ROOT" && ! -L "$REPOSITORY_ROOT" ]] || fail "REPOSITORY_ROOT_INVALID" 3
ROOT="$(cd "$REPOSITORY_ROOT" && pwd -P)"
[[ -f "$ROOT/.gitignore" ]] || fail "REPOSITORY_MARKER_MISSING" 3
[[ -f "$ROOT/config/solver-artifact-manifest-v1.schema.json" ]] || fail "MANIFEST_SCHEMA_MISSING" 4
grep -Eq '^[[:space:]]*data/[[:space:]]*$' "$ROOT/.gitignore" || fail "DATA_IGNORE_RULE_MISSING" 3
[[ "$REPLAY_STORE_PATH" =~ ^\./data/replays/[A-Za-z0-9][A-Za-z0-9._-]*\.duckdb$ ]] || fail "REPLAY_STORE_PATH_UNSAFE" 3

assert_not_link() {
  local path="$1"
  [[ ! -L "$path" ]] || fail "SYMLINK_COMPONENT_REJECTED" 3
}
assert_private_directory() {
  local path="$1" mode
  [[ -d "$path" ]] || fail "DIRECTORY_MISSING" 4
  assert_not_link "$path"
  mode="$(stat -c '%a' "$path")"
  [[ "$mode" == 700 ]] || fail "DIRECTORY_MODE_UNSAFE" 5
}
assert_private_file() {
  local path="$1" mode
  [[ -f "$path" ]] || fail "FILE_MISSING" 4
  assert_not_link "$path"
  mode="$(stat -c '%a' "$path")"
  [[ "$mode" == 600 ]] || fail "FILE_MODE_UNSAFE" 5
}
ensure_directory() {
  local path="$1"
  if [[ -e "$path" && ! -d "$path" ]]; then fail "DIRECTORY_PATH_OCCUPIED" 3; fi
  assert_not_link "$path"
  if [[ ! -d "$path" ]]; then mkdir "$path"; fi
  assert_not_link "$path"
  chmod 700 "$path"
}

DATA="$ROOT/data"
REPLAYS="$DATA/replays"
DATASETS="$REPLAYS/datasets"
SOLVER="$DATA/solver-artifacts"
VERSION="$SOLVER/FORMAT_VERSION"
DIRECTORIES=(
  "$DATA"
  "$REPLAYS"
  "$DATASETS"
  "$DATASETS/incoming"
  "$DATASETS/frozen"
  "$DATASETS/work"
  "$SOLVER"
  "$SOLVER/v1"
)

if [[ "$ACTION" == init ]]; then
  umask 077
  for directory in "${DIRECTORIES[@]}"; do ensure_directory "$directory"; done
  if [[ -e "$VERSION" ]]; then
    assert_not_link "$VERSION"
    [[ -f "$VERSION" ]] || fail "FORMAT_VERSION_NOT_REGULAR" 3
  else
    temporary="$SOLVER/.FORMAT_VERSION.tmp.$$"
    trap 'rm -f "${temporary:-}"' EXIT INT TERM
    ( umask 077; printf '1\n' >"$temporary" )
    chmod 600 "$temporary"
    if ! ln "$temporary" "$VERSION" 2>/dev/null; then
      [[ -f "$VERSION" && ! -L "$VERSION" ]] || fail "FORMAT_VERSION_CREATE_FAILED" 5
    fi
    rm -f "$temporary"
    trap - EXIT INT TERM
  fi
fi

for directory in "${DIRECTORIES[@]}"; do assert_private_directory "$directory"; done
assert_private_file "$VERSION"
printf '1\n' | cmp -s - "$VERSION" || fail "FORMAT_VERSION_INCOMPATIBLE" 5
printf 'LOCAL_STORAGE_OK action=%s replay_store_path=%s format_version=1\n' "$ACTION" "$REPLAY_STORE_PATH"
