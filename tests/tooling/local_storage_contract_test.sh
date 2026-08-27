#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd -P)"
STORAGE="$ROOT/scripts/local-storage.sh"
SCHEMA="$ROOT/config/solver-artifact-manifest-v1.schema.json"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/fca-local-storage-contract.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT INT TERM

fail() { printf 'LOCAL_STORAGE_POSIX_CONTRACT_FAIL: %s\n' "$*" >&2; exit 1; }
expect_fail() { if "$@" >/dev/null 2>&1; then fail "unsafe operation unexpectedly succeeded: $*"; fi; }
new_fixture() {
  local name="$1"
  local path="$WORK/$name"
  mkdir -p "$path/config"
  cp "$ROOT/.gitignore" "$path/.gitignore"
  cp "$SCHEMA" "$path/config/solver-artifact-manifest-v1.schema.json"
  printf '%s\n' "$path"
}
mode_of() { stat -c '%a' "$1"; }

[[ -f "$STORAGE" ]] || fail "implementation missing: scripts/local-storage.sh"
[[ -f "$SCHEMA" ]] || fail "implementation missing: solver artifact manifest schema"

fixture="$(new_fixture primary)"
expect_fail "$STORAGE" verify --repository-root "$fixture"
[[ ! -e "$fixture/data" ]] || fail "verify created missing storage"
"$STORAGE" init --repository-root "$fixture" >/dev/null
for path in \
  data data/replays data/replays/datasets data/replays/datasets/incoming \
  data/replays/datasets/frozen data/replays/datasets/work \
  data/solver-artifacts data/solver-artifacts/v1; do
  [[ -d "$fixture/$path" ]] || fail "missing directory $path"
  [[ "$(mode_of "$fixture/$path")" == 700 ]] || fail "directory mode is not 0700: $path"
done
version="$fixture/data/solver-artifacts/FORMAT_VERSION"
[[ "$(mode_of "$version")" == 600 ]] || fail "FORMAT_VERSION mode is not 0600"
printf '1\n' | cmp -s - "$version" || fail "FORMAT_VERSION bytes are not exact"

sentinel="$fixture/data/replays/datasets/incoming/operator-sentinel.bin"
printf '\000\001\002\376\377' >"$sentinel"
chmod 600 "$sentinel"
before="$(sha256sum "$sentinel" | cut -d' ' -f1)"
"$STORAGE" init --repository-root "$fixture" >/dev/null
[[ "$(sha256sum "$sentinel" | cut -d' ' -f1)" == "$before" ]] || fail "idempotent init changed operator data"
"$STORAGE" verify --repository-root "$fixture" >/dev/null

printf '2\n' >"$version"
expect_fail "$STORAGE" verify --repository-root "$fixture"
expect_fail "$STORAGE" init --repository-root "$fixture"
printf '2\n' | cmp -s - "$version" || fail "init overwrote incompatible format version"

for unsafe in '../outside.duckdb' './data/replays/../escape.duckdb' './data/other.duckdb' '/tmp/outside.duckdb'; do
  unsafe_fixture="$(new_fixture "unsafe-$RANDOM")"
  expect_fail "$STORAGE" init --repository-root "$unsafe_fixture" --replay-store-path "$unsafe"
done

link_fixture="$(new_fixture reparse)"
mkdir -p "$link_fixture/data" "$WORK/outside"
ln -s "$WORK/outside" "$link_fixture/data/replays"
expect_fail "$STORAGE" init --repository-root "$link_fixture"
[[ ! -e "$WORK/outside/datasets" ]] || fail "symlink traversal wrote outside repository storage"

chmod 770 "$fixture/data/replays"
expect_fail "$STORAGE" verify --repository-root "$fixture"

printf 'LOCAL_STORAGE_POSIX_CONTRACT_PASS directories=8 unsafe_paths=4 symlink=reject broad_write=reject version=1\n'
