#!/usr/bin/env bash
# A cold monorepo build can exhaust Hex's anonymous API quota. Keep the
# downloaded dependencies between attempts and wait for the quota to reset.
set -uo pipefail

log="$(mktemp)"
trap 'rm -f "$log"' EXIT

for attempt in 1 2 3; do
  "$@" 2>&1 | tee "$log"
  status=${PIPESTATUS[0]}
  if (( status == 0 )); then
    exit 0
  fi
  if (( attempt == 3 )) || ! grep -Fq 'The rate limit for the Hex API has been exceeded' "$log"; then
    exit "$status"
  fi
  echo "Hex API quota exceeded; retrying in 60 seconds (attempt $((attempt + 1))/3)." >&2
  sleep 60
done
