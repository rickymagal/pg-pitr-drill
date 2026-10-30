#!/usr/bin/env bash
# S0 — timed point-in-time recovery onto a clean host. Prove the database restores to
# two distinct, operator-selected timestamps, each landing exactly on the data committed
# at or before it with nothing after, and record the recovery duration. Covers tests 1, 2.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/evidence.sh
ev_init s0 "Timed point-in-time recovery to two selected timestamps"

Qp() { docker compose exec -T -u postgres pg-primary  psql -U postgres -d pitr_drill -tAc "$1" 2>/dev/null || true; }
Qr() { docker compose exec -T -u postgres pg-recovery psql -U postgres -d pitr_drill -tAc "$1" 2>/dev/null || true; }

# restore_to <tag> <target-timestamp> <expected-rows>: fresh restore of the marked point
# onto the clean host, then report exact landing (rows at target, none after).
restore_to() {
  local tag="$1" target="$2" expect="$3" t0 t1 got post
  ev_run "stop stale recovery server ($tag)" docker compose exec -T -u postgres pg-recovery \
    bash -c "pg_ctl -D /var/lib/postgresql/data stop -m immediate -w 2>/dev/null || true"
  ev_run "clean recovery pgdata ($tag)" docker compose exec -T -u root pg-recovery \
    bash -c "rm -rf /var/lib/postgresql/data/* && chown postgres:postgres /var/lib/postgresql/data"
  t0="$(date +%s)"
  ev_run "pitr restore to $tag" docker compose exec -T -u postgres pg-recovery \
    pgbackrest --stanza=pitr-drill --delta --type=time "--target=$target" --target-action=promote restore
  ev_run "start recovered server ($tag)" docker compose exec -T -u postgres pg-recovery \
    pg_ctl -D /var/lib/postgresql/data -w -t 300 start
  t1="$(date +%s)"
  got="$(Qr "SELECT count(*) FROM memory.record;")"
  post="$(Qr "SELECT count(*) FROM memory.record WHERE created_at > '$target';")"
  ev_measure "${tag}_target_time" "$target"
  ev_measure "${tag}_rows_expected" "$expect"
  ev_measure "${tag}_rows_recovered" "$got"
  ev_measure "${tag}_post_target_rows" "$post"
  ev_measure "${tag}_rto_seconds" "$((t1 - t0))"
  if [ "$got" = "$expect" ] && [ "$post" = "0" ]; then
    ev_verdict "pitr_$tag" PASS "recovered $got rows at $tag, equal to the $expect committed at or before the target, with none after"
  else
    ev_verdict "pitr_$tag" FAIL "$tag recovered=$got expected=$expect post_target=$post"
  fi
}

ev_run "base backup" docker compose exec -T -u postgres pg-primary \
  pgbackrest --stanza=pitr-drill backup --type=full

ev_run "load before target 1" ./scripts/load-gen.sh 30 0.05
sleep 1
ROWS_T1="$(Qp "SELECT count(*) FROM memory.record;")"; T1="$(Qp "SELECT current_timestamp;")"
sleep 1
ev_run "load before target 2" ./scripts/load-gen.sh 20 0.05
sleep 1
ROWS_T2="$(Qp "SELECT count(*) FROM memory.record;")"; T2="$(Qp "SELECT current_timestamp;")"
sleep 1
ev_run "load after both targets" ./scripts/load-gen.sh 20 0.05

# Complete and archive the tail segment so the WAL covering both targets is in the repo
# before any restore. Both targets are mid-history, not the end.
SEG="$(Qp "SELECT pg_walfile_name(pg_current_wal_lsn());")"
ev_run "switch wal" docker compose exec -T -u postgres pg-primary \
  psql -U postgres -d pitr_drill -c "SELECT pg_switch_wal();"
archived_ok=0
for _ in $(seq 1 60); do
  cur="$(Qp "SELECT coalesce(last_archived_wal,'') FROM pg_stat_archiver;" | tr -d '[:space:]')"
  if [ -n "$cur" ] && { [ "$cur" = "$SEG" ] || [ "$cur" \> "$SEG" ]; }; then archived_ok=1; break; fi
  sleep 1
done
[ "$archived_ok" = 1 ] || { echo "S0: segment $SEG not archived in time"; exit 1; }
ev_measure rows_primary_end "$(Qp "SELECT count(*) FROM memory.record;")"

restore_to t1 "$T1" "$ROWS_T1"
restore_to t2 "$T2" "$ROWS_T2"

ev_manifest
echo "S0: t1 expect=$ROWS_T1 @ $T1 ; t2 expect=$ROWS_T2 @ $T2"
cat "$EV_DIR/verdict.tsv"
