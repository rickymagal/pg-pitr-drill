#!/usr/bin/env bash
# S4 — recovery after total loss of Server 1 onto a clean host, from the independent
# repository. Covers tests 3, 4.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/evidence.sh
ev_init s4 "Recovery after total loss of Server 1 onto a clean host"
PRI="docker compose exec -T -u postgres pg-primary"
REC="docker compose exec -T -u postgres pg-recovery"
ev_run "base backup" $PRI pgbackrest --stanza=pitr-drill backup --type=full
ev_run "load"        ./scripts/load-gen.sh 40 0.02
ROWS_BEFORE="$($PRI psql -U postgres -d pitr_drill -tAc "SELECT count(*) FROM memory.record;")"
ev_measure rows_before_loss "$ROWS_BEFORE"
ev_run "archive wal" $PRI psql -U postgres -d pitr_drill -c "SELECT pg_switch_wal();"
ev_run "stop (lose) pg-primary" docker compose stop pg-primary
RTO_START="$(date +%s)"
ev_run "stop stale recovery server" $REC bash -c "pg_ctl -D /var/lib/postgresql/data stop -m immediate -w 2>/dev/null || true"
ev_run "clean recovery pgdata" docker compose exec -T -u root pg-recovery bash -c "rm -rf /var/lib/postgresql/data/* && chown postgres:postgres /var/lib/postgresql/data"
ev_run "restore latest onto clean host" $REC pgbackrest --stanza=pitr-drill --delta restore
ev_run "start recovered server" $REC pg_ctl -D /var/lib/postgresql/data -w -t 300 start
RTO_END="$(date +%s)"; ev_measure rto_seconds "$((RTO_END - RTO_START))"
ROWS_RECOVERED="$($REC psql -U postgres -d pitr_drill -tAc "SELECT count(*) FROM memory.record;")"
ev_measure rows_recovered "$ROWS_RECOVERED"
ev_run "restart pg-primary" docker compose start pg-primary
ev_run "wait for pg-primary healthy" bash -c 'for i in $(seq 1 30); do docker compose exec -T -u postgres pg-primary pg_isready -U postgres -d pitr_drill >/dev/null 2>&1 && exit 0; sleep 1; done; exit 1'
if [ "$ROWS_RECOVERED" = "$ROWS_BEFORE" ]; then
  ev_verdict total_loss_recovery PASS "recovered $ROWS_RECOVERED rows on the clean host after Server 1 loss, equal to before"
else
  ev_verdict total_loss_recovery FAIL "recovered=$ROWS_RECOVERED before=$ROWS_BEFORE"
fi
ev_manifest; echo "S4: recovered=$ROWS_RECOVERED before=$ROWS_BEFORE rto=$((RTO_END-RTO_START))s"; cat "$EV_DIR/verdict.tsv"
