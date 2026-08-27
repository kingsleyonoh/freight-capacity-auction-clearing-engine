#!/usr/bin/env bash
# Verify the exact OCaml switch and the tracked, test-inclusive opam lock.
# Stable exit codes are part of the tooling contract; see docs/dependency-lock.md.
set -uo pipefail

E_INPUT=10
E_OPAM=20
E_COMPILER=21
E_INVARIANT=22
E_LINT=23
E_LOCK_CHECK=24
E_TEST_DEPS=25
E_DRIFT=26
E_UNSAFE=27

fail() {
  local code="$1" label="$2" detail="${3:-}"
  printf '%s: %s\n' "$label" "$detail" >&2
  exit "$code"
}

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
REPO_ROOT=$(cd -- "$SCRIPT_DIR/.." && pwd)
PROJECT_DIR=${OPAM_PROJECT_DIR:-$REPO_ROOT}
SOURCE=${OPAM_LOCK_SOURCE:-$PROJECT_DIR/freight_capacity_auction_clearing_engine.opam}
LOCK=${OPAM_LOCK_FILE:-$PROJECT_DIR/freight_capacity_auction_clearing_engine.opam.locked}
OPAM=${OPAM_BIN:-opam}
SWITCH=${OPAM_SWITCH:-.}
EXPECTED_OCAML=${OPAM_EXPECTED_OCAML:-5.2.0}
TMP=""

cleanup() {
  if [[ -n "$TMP" && -d "$TMP" ]]; then
    rm -rf -- "$TMP"
  fi
}
trap cleanup EXIT INT TERM

[[ -f "$SOURCE" ]] || fail "$E_INPUT" INPUT_MISSING "$SOURCE"
[[ -f "$LOCK" ]] || fail "$E_INPUT" INPUT_MISSING "$LOCK"
command -v "$OPAM" >/dev/null 2>&1 || [[ -x "$OPAM" ]] || fail "$E_OPAM" OPAM_UNAVAILABLE "$OPAM"

# Reject host-local pins, file URLs, any quoted absolute host path,
# credential-shaped URLs/query values, and cache/build paths.
if grep -Ein 'file://|pin-depends|"/[A-Za-z0-9._-]|(^|["[:space:]])[A-Za-z]:[\\/]|://[^/@[:space:]]+@|://[^/@[:space:]]+:[^/@[:space:]]+@|(token|password|secret|api[_-]?key)=|\.opam-switch|download-cache|(^|[\\/])_opam([\\/]|$)' "$LOCK" >/dev/null; then
  fail "$E_UNSAFE" LOCK_UNSAFE "local/file/absolute path, credential-shaped URL, pin, or cache artifact"
fi

# The source and generated lock must retain exact, conditional test dependencies.
for dep in alcotest ounit2; do
  grep -E '"'"$dep"'"[^\n]*with-test' "$SOURCE" >/dev/null \
    || fail "$E_TEST_DEPS" TEST_DEP_MISSING "$dep missing with-test in source manifest"
  grep -E '"'"$dep"'"[^\n]*with-test' "$LOCK" >/dev/null \
    || fail "$E_TEST_DEPS" TEST_DEP_MISSING "$dep missing with-test in lock"
done

actual=$("$OPAM" --cli=2.2 exec --switch="$SWITCH" -- ocamlc -version 2>/dev/null) \
  || fail "$E_OPAM" OPAM_EXEC_FAILED "could not execute ocamlc through switch $SWITCH"
[[ "$actual" == "$EXPECTED_OCAML" ]] \
  || fail "$E_COMPILER" OCAML_VERSION_MISMATCH "expected $EXPECTED_OCAML, got $actual"

invariant=$("$OPAM" --cli=2.2 switch invariant --switch="$SWITCH" 2>/dev/null) \
  || fail "$E_OPAM" OPAM_INVARIANT_FAILED "switch $SWITCH"
if [[ ! "$invariant" =~ ocaml-base-compiler.*5\.2\.0 ]]; then
  fail "$E_INVARIANT" SWITCH_INVARIANT_MISMATCH "$invariant"
fi

"$OPAM" --cli=2.2 lint "$SOURCE" "$LOCK" >/dev/null \
  || fail "$E_LINT" OPAM_LINT_FAILED "source or lock"

(
  cd -- "$PROJECT_DIR" || exit 1
  # opam expands a full transitive lock into direct constraints. Combining
  # --with-test with --deps-only would therefore request every locked package's
  # own tests, not just this project's conditional test dependencies. The
  # locked closure is checked here; the exact installed project test deps and
  # retained with-test filters are checked immediately below.
  "$OPAM" --cli=2.2 install . --switch="$SWITCH" --deps-only --locked --check
) >/dev/null || fail "$E_LOCK_CHECK" LOCK_CHECK_FAILED "locked dependency reconciliation"

installed=$("$OPAM" --cli=2.2 list --switch="$SWITCH" --installed --columns=name,version --short 2>/dev/null) \
  || fail "$E_OPAM" OPAM_LIST_FAILED "switch $SWITCH"
printf '%s\n' "$installed" | grep -E '^alcotest[[:space:]]+1\.9\.1$' >/dev/null \
  || fail "$E_TEST_DEPS" TEST_DEP_MISSING "alcotest 1.9.1 not installed"
printf '%s\n' "$installed" | grep -E '^ounit2[[:space:]]+2\.2\.7$' >/dev/null \
  || fail "$E_TEST_DEPS" TEST_DEP_MISSING "ounit2 2.2.7 not installed"

TMP=$(mktemp -d "${OPAM_LOCK_TMPDIR_BASE:-${TMPDIR:-/tmp}}/fca-opam-lock.XXXXXX") \
  || fail "$E_INPUT" TEMP_CREATE_FAILED "mktemp"
tmp_source="$TMP/$(basename -- "$SOURCE")"
tmp_lock="$tmp_source.locked"
cp -- "$SOURCE" "$tmp_source" || fail "$E_INPUT" TEMP_COPY_FAILED "$SOURCE"
(
  cd -- "$TMP" || exit 1
  "$OPAM" --cli=2.2 lock --switch="$SWITCH" "./$(basename -- "$tmp_source")"
) >/dev/null || fail "$E_DRIFT" LOCK_GENERATION_FAILED "temporary lock"
[[ -f "$tmp_lock" ]] || fail "$E_DRIFT" LOCK_GENERATION_FAILED "$tmp_lock absent"

tr -d '\r' < "$LOCK" > "$TMP/tracked.normalized"
tr -d '\r' < "$tmp_lock" > "$TMP/generated.normalized"
cmp -s "$TMP/tracked.normalized" "$TMP/generated.normalized" \
  || fail "$E_DRIFT" LOCK_DRIFT "regenerate and review freight_capacity_auction_clearing_engine.opam.locked"

printf 'OPAM_LOCK_OK opam=%s compiler=%s switch=%s\n' "$("$OPAM" --version)" "$actual" "$invariant"
