#!/usr/bin/env bash
# S8 — quarantined memory survives a restore, with its audit evidence. Covers tests 17, 18.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/evidence.sh
ev_init s8 "Quarantined memory survives a restore"
PRI="docker compose exec -T -u postgres pg-primary"
REC="docker compose exec -T -u postgres pg-recovery"
ev_run "quarantine a poisoned record" $PRI psql -U postgres -d pitr_drill -v ON_ERROR_STOP=1 -c "INSERT INTO memory.record(content, state) VALUES ('poisoned-1','quarantined'); INSERT INTO memory.record(content, state) VALUES ('clean-1','verified'); INSERT INTO audit.event(actor,action,detail) VALUES ('core','quarantine','poisoned-1');"
ev_measure quarantined_before "$($PRI psql -U postgres -d pitr_drill -tAc "SELECT count(*) FROM memory.record WHERE state='quarantined';")"
ev_run "backup"      $PRI pgbackrest --stanza=pitr-drill backup --type=full
ev_run "archive wal" $PRI psql -U postgres -d pitr_drill -c "SELECT pg_switch_wal();"
ev_run "stop stale recovery server" $REC bash -c "pg_ctl -D /var/lib/postgresql/data stop -m immediate -w 2>/dev/null || true"
ev_run "clean recovery pgdata" docker compose exec -T -u root pg-recovery bash -c "rm -rf /var/lib/postgresql/data/* && chown postgres:postgres /var/lib/postgresql/data"
ev_run "restore onto clean host" $REC pgbackrest --stanza=pitr-drill --delta restore
ev_run "start recovered server" $REC pg_ctl -D /var/lib/postgresql/data -w -t 300 start
QUAR="$($REC psql -U postgres -d pitr_drill -tAc "SELECT count(*) FROM memory.record WHERE state='quarantined' AND content='poisoned-1';")"
AUD="$($REC psql -U postgres -d pitr_drill -tAc "SELECT count(*) FROM audit.event WHERE action='quarantine' AND detail='poisoned-1';")"
ev_measure quarantined_after "$QUAR"; ev_measure audit_after "$AUD"
if [ "$QUAR" = "1" ] && [ "$AUD" = "1" ]; then
  ev_verdict quarantine_survives_restore PASS "the quarantined record and its audit evidence survived the restore with state intact"
else
  ev_verdict quarantine_survives_restore FAIL "quarantined_after=$QUAR audit_after=$AUD"
fi
ev_manifest; echo "S8: quarantined_after=$QUAR audit_after=$AUD"; cat "$EV_DIR/verdict.tsv"
