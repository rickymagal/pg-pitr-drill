#!/usr/bin/env bash
# S0 — timed point-in-time recovery onto a clean host. Take a base backup, drive
# timed writes, mark a recovery target, write more data past it, restore the marked
# point onto pg-recovery, and prove the recovered database holds exactly the data
# committed at or before the target. Records recovery duration (RTO) and the
# landing precision. Covers tests 1, 2, 5, 16.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/evidence.sh
ev_init s0 "Timed point-in-time recovery onto a clean host"

Qp() { docker compose exec -T -u postgres pg-primary  psql -U postgres -d pitr_drill -tAc "$1"; }
Qr() { docker compose exec -T -u postgres pg-recovery psql -U postgres -d pitr_drill -tAc "$1"; }

ev_run "base backup" docker compose exec -T -u postgres pg-primary \
  pgbackrest --stanza=pitr-drill backup --type=full

ev_run "load pre-target" ./scripts/load-gen.sh 30 0.1
ROWS_AT_TARGET="$(Qp "SELECT count(*) FROM memory.record;")"
TARGET="$(Qp "SELECT current_timestamp;")"
ev_measure target_time "$TARGET"
ev_measure rows_at_target "$ROWS_AT_TARGET"

ev_run "archive target WAL" docker compose exec -T -u postgres pg-primary \
  psql -U postgres -d pitr_drill -c "SELECT pg_switch_wal();"

ev_run "load post-target" ./scripts/load-gen.sh 20 0.1
ev_run "archive post-target WAL" docker compose exec -T -u postgres pg-primary \
  pgbackrest --stanza=pitr-drill check
ev_measure rows_primary_end "$(Qp "SELECT count(*) FROM memory.record;")"

RTO_START="$(date +%s)"
ev_run "stop stale recovery server" docker compose exec -T -u postgres pg-recovery \
  bash -c "pg_ctl -D /var/lib/postgresql/data stop -m immediate -w 2>/dev/null || true"
ev_run "clean recovery pgdata" docker compose exec -T -u root pg-recovery \
  bash -c "rm -rf /var/lib/postgresql/data/* && chown postgres:postgres /var/lib/postgresql/data"
ev_run "pitr restore to target" docker compose exec -T -u postgres pg-recovery \
  pgbackrest --stanza=pitr-drill --delta --type=time "--target=$TARGET" --target-action=promote restore
ev_run "start recovered server" docker compose exec -T -u postgres pg-recovery \
  pg_ctl -D /var/lib/postgresql/data -w -t 300 start
RTO_END="$(date +%s)"
ev_measure rto_seconds "$((RTO_END - RTO_START))"

ROWS_RECOVERED="$(Qr "SELECT count(*) FROM memory.record;")"
POST_TARGET="$(Qr "SELECT count(*) FROM memory.record WHERE created_at > '$TARGET';")"
ev_measure rows_recovered "$ROWS_RECOVERED"
ev_measure post_target_rows "$POST_TARGET"
ev_measure recovered_max_commit "$(Qr "SELECT coalesce(max(created_at)::text,'none') FROM memory.record;")"

if [ "$ROWS_RECOVERED" = "$ROWS_AT_TARGET" ] && [ "$POST_TARGET" = "0" ]; then
  ev_verdict actual_pitr PASS "recovered $ROWS_RECOVERED rows, equal to rows at target, with zero post-target rows"
else
  ev_verdict actual_pitr FAIL "recovered=$ROWS_RECOVERED target=$ROWS_AT_TARGET post_target=$POST_TARGET"
fi
ev_manifest
echo "S0: recovered=$ROWS_RECOVERED at_target=$ROWS_AT_TARGET post_target=$POST_TARGET rto=$((RTO_END-RTO_START))s"
cat "$EV_DIR/verdict.tsv"
