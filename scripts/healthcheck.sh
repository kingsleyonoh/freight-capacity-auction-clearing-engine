#!/bin/sh
set -eu

# The worker is a long-running process without an HTTP listener.  Keep the
# image healthcheck useful for both entrypoints instead of reporting a healthy
# worker as unhealthy because it does not expose the server readiness route.
for cmdline in /proc/[0-9]*/cmdline; do
  if [ -r "$cmdline" ] && tr '\000' ' ' < "$cmdline" | grep -q '/app/bin/worker.exe'; then
    exit 0
  fi
done

curl --fail --silent "http://127.0.0.1:${APP_PORT:-8080}/health/ready" >/dev/null
