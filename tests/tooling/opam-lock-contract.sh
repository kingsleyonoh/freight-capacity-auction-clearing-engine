#!/usr/bin/env bash
# Deterministic adversarial contracts plus optional actual-client integration.
set -uo pipefail

ROOT=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd)
VERIFY="$ROOT/scripts/verify-opam-lock.sh"
WORK_RAW=$(mktemp -d "${TMPDIR:-/tmp}/fca-opam-contract.XXXXXX") || exit 1
WORK="$WORK_RAW/contract workspace"
mkdir -p "$WORK"
cleanup() { rm -rf -- "$WORK_RAW"; }
trap cleanup EXIT INT TERM

fail() { printf 'CONTRACT_FAIL %s\n' "$1" >&2; exit 1; }

FAKE_DIR="$WORK/fake bin"
mkdir -p "$FAKE_DIR"
FAKE="$FAKE_DIR/fake opam"
cat > "$FAKE" <<'FAKE'
#!/usr/bin/env bash
set -u
if [[ -n "${FAKE_ARG_LOG:-}" ]]; then
  {
    printf '%s\n' BEGIN
    printf '<%s>\n' "$@"
  } >> "$FAKE_ARG_LOG"
fi
args=" $* "
if [[ "$args" == *" --version "* ]]; then echo 2.5.2; exit 0; fi
if [[ "$args" == *" exec "* ]]; then
  [[ "${FAKE_MODE:-ok}" == compiler-mismatch ]] && echo 5.1.1 || echo 5.2.0
  exit 0
fi
if [[ "$args" == *" switch invariant "* ]]; then
  [[ "${FAKE_MODE:-ok}" == invariant-mismatch ]] \
    && echo '["ocaml-base-compiler" {= "5.1.1"}]' \
    || echo '["ocaml-base-compiler" {= "5.2.0"}]'
  exit 0
fi
if [[ "$args" == *" lint "* ]]; then exit 0; fi
if [[ "$args" == *" install "* ]]; then
  [[ "${FAKE_MODE:-ok}" == lock-check-fail ]] && exit 1
  exit 0
fi
if [[ "$args" == *" list "* ]]; then
  [[ "${FAKE_MODE:-ok}" == installed-alcotest-missing ]] || echo 'alcotest                1.9.1'
  [[ "${FAKE_MODE:-ok}" == installed-ounit2-missing ]] || echo 'ounit2                  2.2.7'
  exit 0
fi
if [[ "$args" == *" lock "* ]]; then
  src="${@: -1}"
  out="${src#./}.locked"
  cp "$FAKE_TRACKED_LOCK" "$out"
  [[ "${FAKE_MODE:-ok}" == drift ]] && printf '\n# deterministic drift\n' >> "$out"
  exit 0
fi
exit 99
FAKE
chmod +x "$FAKE"

expect_code() {
  local label="$1" expected="$2" mode="$3" source="$4" lock="$5"
  local tmpbase="$WORK/temp base $label" output code
  mkdir -p "$tmpbase"
  if output=$(OPAM_BIN="$FAKE" OPAM_PROJECT_DIR="$ROOT" \
    OPAM_LOCK_SOURCE="$source" OPAM_LOCK_FILE="$lock" \
    OPAM_SWITCH='fake switch with spaces' OPAM_LOCK_TMPDIR_BASE="$tmpbase" \
    FAKE_MODE="$mode" FAKE_TRACKED_LOCK="$lock" FAKE_ARG_LOG="$WORK/args.log" \
    bash "$VERIFY" 2>&1); then
    code=0
  else
    code=$?
  fi
  [[ $code -eq $expected ]] || fail "$label expected=$expected actual=$code output=$output"
  if find "$tmpbase" -mindepth 1 -maxdepth 1 -name 'fca-opam-lock.*' | grep -q .; then
    fail "$label temporary directory leaked"
  fi
  printf 'PASS %-28s code=%s %s\n' "$label" "$code" "${output%%$'\n'*}"
}

Base="$WORK/base path with spaces"
mkdir -p "$Base"
BaseSource="$Base/source manifest.opam"
BaseLock="$BaseSource.locked"
cp "$ROOT/freight_capacity_auction_clearing_engine.opam" "$BaseSource"
cp "$ROOT/freight_capacity_auction_clearing_engine.opam.locked" "$BaseLock"

tracked_hashes() {
  sha256sum \
    "$ROOT/freight_capacity_auction_clearing_engine.opam" \
    "$ROOT/freight_capacity_auction_clearing_engine.opam.locked" \
    "$VERIFY"
}
before=$(tracked_hashes)

expect_code compiler-mismatch 21 compiler-mismatch "$BaseSource" "$BaseLock"
expect_code invariant-mismatch 22 invariant-mismatch "$BaseSource" "$BaseLock"
expect_code lock-check-fail 24 lock-check-fail "$BaseSource" "$BaseLock"
expect_code lock-drift 26 drift "$BaseSource" "$BaseLock"
expect_code installed-alcotest-missing 25 installed-alcotest-missing "$BaseSource" "$BaseLock"
expect_code installed-ounit2-missing 25 installed-ounit2-missing "$BaseSource" "$BaseLock"

unsafe_case() {
  local label="$1" content="$2" dir source lock
  dir="$WORK/$label"
  mkdir -p "$dir"
  source="$dir/source.opam"
  lock="$source.locked"
  cp "$BaseSource" "$source"
  cp "$BaseLock" "$lock"
  printf '\n%s\n' "$content" >> "$lock"
  expect_code "$label" 27 ok "$source" "$lock"
}
unsafe_case unsafe-local-pin 'pin-depends: [ ["bad.dev" "git+https://example.invalid/bad.git"] ]'
unsafe_case unsafe-file-url 'url { src: "file:///tmp/private.tgz" }'
unsafe_case unsafe-posix-absolute 'url { src: "/srv/private/package.tgz" }'
unsafe_case unsafe-windows-absolute 'url { src: "C:\\private\\package.tgz" }'
unsafe_case unsafe-credential-url 'url { src: "https://token@example.invalid/package.tgz" }'
unsafe_case unsafe-credential-query 'url { src: "https://example.invalid/package.tgz?api_key=redacted" }'

for dep in alcotest ounit2; do
  Missing="$WORK/missing lock test dependency $dep"
  mkdir -p "$Missing"
  MissingSource="$Missing/source.opam"
  MissingLock="$MissingSource.locked"
  cp "$BaseSource" "$MissingSource"
  grep -v '"'"$dep"'"' "$BaseLock" > "$MissingLock"
  expect_code "lock-$dep-missing" 25 ok "$MissingSource" "$MissingLock"
done

expect_code quoted-args-success 0 ok "$BaseSource" "$BaseLock"
for expected_arg in \
  "<$BaseSource>" \
  "<$BaseLock>" \
  '<--switch=fake switch with spaces>' \
  '<--deps-only>' \
  '<--locked>' \
  '<--check>' \
  '<./source manifest.opam>'; do
  grep -Fqx -- "$expected_arg" "$WORK/args.log" \
    || fail "quoted argument not preserved: $expected_arg"
done
printf 'PASS args-and-quoting-preserved\n'

[[ "$(tracked_hashes)" == "$before" ]] || fail 'verifier mutated protected repository files'
printf 'PASS no-protected-repository-mutation\n'

if [[ "${OPAM_LOCK_CONTRACT_SKIP_INTEGRATION:-0}" != 1 ]]; then
  bash "$VERIFY" || fail "actual-client integration"
  printf 'PASS actual-client-integration\n'
else
  printf 'SKIP actual-client-integration OPAM_LOCK_CONTRACT_SKIP_INTEGRATION=1\n'
fi

printf 'OPAM_LOCK_CONTRACT_OK\n'
