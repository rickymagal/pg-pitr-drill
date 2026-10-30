#!/usr/bin/env bash
# S4 — total loss of Server 1: clean-host recovery from the independent repository,
# with the recovery-point objective measured as the unarchived write window lost to a
# hard host failure. Everything counted after the archive floor must recover exactly;
# only writes in the current unarchived segment may be lost. Covers tests 3, 4, 5.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/evidence.sh
ev_init s4 "Total loss of Server 1: clean-host recovery and measured RPO"
PRI="docker compose exec -T -u postgres pg-primary"
REC="docker compose exec -T -u postgres pg-recovery"
Qp() { $PRI psql -U postgres -d pitr_drill -tAc "$1" 2>/dev/null || true; }
Qr() { $REC psql -U postgres -d pitr_drill -tAc "$1" 2>/dev/null || true; }

ev_run "base backup" $PRI pgbackrest --stanza=pitr-drill backup --type=full
ev_run "load archived writes" ./scripts/load-gen.sh 40 0.02

# Close the current segment and wait until pgBackRest has it in the repository.
# Rows counted here are the durable floor: recovery must reproduce all of them.
SEG="$(Qp "SELECT pg_walfile_name(pg_current_wal_lsn());")"
ev_measure archive_floor_segment "$SEG"
ev_run "switch wal" $PRI psql -U postgres -d pitr_drill -c "SELECT pg_switch_wal();"
archived_ok=0
for _ in $(seq 1 60); do
  cur="$(Qp "SELECT coalesce(last_archived_wal,'') FROM pg_stat_archiver;" | tr -d '[:space:]')"
  if [ -n "$cur" ] && { [ "$cur" = "$SEG" ] || [ "$cur" \> "$SEG" ]; }; then archived_ok=1; break; fi
  sleep 1
done
[ "$archived_ok" = 1 ] || { echo "S4: segment $SEG not archived in time"; exit 1; }
ev_measure archive_floor_confirmed "$cur"
ROWS_ARCHIVED="$(Qp "SELECT count(*) FROM memory.record;")"
ev_measure rows_archived "$ROWS_ARCHIVED"

# Writes that land in the current, not-yet-archived segment. A hard host loss takes
# this segment with it; these define the RPO window.
ev_run "load in-flight writes" ./scripts/load-gen.sh 10 0.02
ROWS_BEFORE="$(Qp "SELECT count(*) FROM memory.record;")"
PRI_MAX_EPOCH="$(Qp "SELECT coalesce(extract(epoch FROM max(created_at)),0) FROM memory.record;")"
ev_measure rows_before_loss "$ROWS_BEFORE"

RTO_START="$(date +%s)"
ev_run "lose pg-primary (hard kill)" docker compose kill -s SIGKILL pg-primary
ev_run "stop stale recovery server" $REC bash -c "pg_ctl -D /var/lib/postgresql/data stop -m immediate -w 2>/dev/null || true"
ev_run "clean recovery pgdata" docker compose exec -T -u root pg-recovery bash -c "rm -rf /var/lib/postgresql/data/* && chown postgres:postgres /var/lib/postgresql/data"
ev_run "restore latest onto clean host" $REC pgbackrest --stanza=pitr-drill --delta restore
ev_run "start recovered server" $REC pg_ctl -D /var/lib/postgresql/data -w -t 300 start
RTO_END="$(date +%s)"; RTO_SECONDS="$((RTO_END - RTO_START))"
ev_measure rto_seconds "$RTO_SECONDS"

ROWS_RECOVERED="$(Qr "SELECT count(*) FROM memory.record;")"
REC_MAX_EPOCH="$(Qr "SELECT coalesce(extract(epoch FROM max(created_at)),0) FROM memory.record;")"
ROWS_LOST="$(( ROWS_BEFORE - ROWS_RECOVERED ))"
RPO_SECONDS="$(awk -v a="$PRI_MAX_EPOCH" -v b="$REC_MAX_EPOCH" 'BEGIN{d=a-b; if(d<0)d=0; printf "%.3f", d}')"
ev_measure rows_recovered "$ROWS_RECOVERED"
ev_measure rows_lost "$ROWS_LOST"
ev_measure rpo_seconds "$RPO_SECONDS"

ev_run "restart pg-primary" docker compose start pg-primary
ev_run "wait for pg-primary healthy" bash -c 'for i in $(seq 1 30); do docker compose exec -T -u postgres pg-primary pg_isready -U postgres -d pitr_drill >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1'

# Durable data must recover exactly; loss must be bounded to the in-flight segment.
if [ "$ROWS_RECOVERED" -ge "$ROWS_ARCHIVED" ] && [ "$ROWS_RECOVERED" -le "$ROWS_BEFORE" ]; then
  ev_verdict total_loss_recovery PASS "clean host recovered $ROWS_RECOVERED rows, all $ROWS_ARCHIVED durably-archived rows intact, in ${RTO_SECONDS}s"
  ev_verdict measured_rpo PASS "RPO = ${RPO_SECONDS}s / $ROWS_LOST rows: writes in the unarchived segment at host loss; no durably-archived data lost"
else
  ev_verdict total_loss_recovery FAIL "recovered=$ROWS_RECOVERED archived=$ROWS_ARCHIVED before=$ROWS_BEFORE"
  ev_verdict measured_rpo FAIL "loss exceeds the in-flight segment: recovered=$ROWS_RECOVERED archived=$ROWS_ARCHIVED before=$ROWS_BEFORE"
fi
ev_manifest
echo "S4: recovered=$ROWS_RECOVERED archived=$ROWS_ARCHIVED before=$ROWS_BEFORE lost=$ROWS_LOST rpo=${RPO_SECONDS}s rto=${RTO_SECONDS}s"
cat "$EV_DIR/verdict.tsv"
