#!/usr/bin/env bash
set -euo pipefail

: "${DATABASE_URL:?DATABASE_URL is required}"
: "${SECRET_KEY_BASE:?SECRET_KEY_BASE is required}"

migrate_exe="${FCA_MIGRATE_EXE:-_build/default/bin/migrate.exe}"
if [[ ! -x "$migrate_exe" ]]; then
  printf 'compiled migrate executable is unavailable\n' >&2
  exit 66
fi

"$migrate_exe"
"$migrate_exe"
