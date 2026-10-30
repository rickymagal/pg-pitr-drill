#!/usr/bin/env bash
# Synthetic load: insert timestamped rows through core_app at a fixed cadence, so
# later scenarios can measure how much committed data a recovery loses (RPO). Each
# row commits on its own; the optional interval paces the commits. One connection.
set -euo pipefail
ROWS="${1:-100}"
INTERVAL="${2:-0}"
{
  echo "SET ROLE core_app;"
  for n in $(seq 1 "$ROWS"); do
    echo "INSERT INTO memory.record(content) VALUES('load-row-$n');"
    if [ "$INTERVAL" != "0" ]; then echo "SELECT pg_sleep($INTERVAL);"; fi
  done
} | docker compose exec -T -u postgres pg-primary psql -U postgres -d pitr_drill -q -v ON_ERROR_STOP=1
echo "inserted $ROWS rows (interval=${INTERVAL}s)"
