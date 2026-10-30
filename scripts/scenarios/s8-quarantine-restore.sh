#!/usr/bin/env bash
# S8 — memory lifecycle state survives a restore. Two properties are set up on the
# primary, captured in a backup, and rechecked on the recovered host: a quarantined
# record keeps its state and audit evidence (test 18), and a supersession lineage with a
# resolved write conflict is preserved (test 17). The conflict is optimistic: two writers
# race to supersede the same current record; a guarded update lets exactly one win, and
# the loser, seeing zero rows changed, withdraws its version. Covers tests 17, 18.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/evidence.sh
ev_init s8 "Quarantine and supersession lineage survive a restore"
PRI="docker compose exec -T -u postgres pg-primary"
REC="docker compose exec -T -u postgres pg-recovery"
Qp() { $PRI psql -U postgres -d pitr_drill -v ON_ERROR_STOP=1 -qtAc "$1"; }
Qr() { $REC psql -U postgres -d pitr_drill -v ON_ERROR_STOP=1 -qtAc "$1"; }

# Supersession lineage with a resolved concurrent conflict (test 17), source_id doc-2.
ev_run "doc-2 v1 becomes current"     $PRI psql -U postgres -d pitr_drill -v ON_ERROR_STOP=1 -c "INSERT INTO memory.record(content,source_id,state) VALUES ('doc2-v1','doc-2','current');"
ev_run "writer A publishes a version" $PRI psql -U postgres -d pitr_drill -v ON_ERROR_STOP=1 -c "INSERT INTO memory.record(content,source_id,state) VALUES ('doc2-v2-A','doc-2','current');"
W1="$(Qp "WITH u AS (UPDATE memory.record SET state='superseded', superseded_by=(SELECT id FROM memory.record WHERE content='doc2-v2-A' AND source_id='doc-2') WHERE content='doc2-v1' AND source_id='doc-2' AND state='current' RETURNING 1) SELECT count(*) FROM u;")"
ev_run "writer B publishes a version" $PRI psql -U postgres -d pitr_drill -v ON_ERROR_STOP=1 -c "INSERT INTO memory.record(content,source_id,state) VALUES ('doc2-v2-B','doc-2','current');"
W2="$(Qp "WITH u AS (UPDATE memory.record SET state='superseded', superseded_by=(SELECT id FROM memory.record WHERE content='doc2-v2-B' AND source_id='doc-2') WHERE content='doc2-v1' AND source_id='doc-2' AND state='current' RETURNING 1) SELECT count(*) FROM u;")"
ev_measure w1_superseded_rows "$W1"
ev_measure w2_superseded_rows "$W2"
if [ "$W2" = "0" ]; then ev_run "writer B loses the race, withdraws its version" $PRI psql -U postgres -d pitr_drill -v ON_ERROR_STOP=1 -c "UPDATE memory.record SET state='rejected' WHERE content='doc2-v2-B' AND source_id='doc-2';"; fi

# Quarantined record plus its audit evidence (test 18).
ev_run "quarantine a poisoned record" $PRI psql -U postgres -d pitr_drill -v ON_ERROR_STOP=1 -c "INSERT INTO memory.record(content, state) VALUES ('poisoned-1','quarantined'); INSERT INTO memory.record(content, state) VALUES ('clean-1','verified'); INSERT INTO audit.event(actor,action,detail) VALUES ('core','quarantine','poisoned-1');"
ev_measure quarantined_before "$(Qp "SELECT count(*) FROM memory.record WHERE state='quarantined';")"

ev_run "backup"      $PRI pgbackrest --stanza=pitr-drill backup --type=full
ev_run "archive wal" $PRI psql -U postgres -d pitr_drill -c "SELECT pg_switch_wal();"
ev_run "stop stale recovery server" $REC bash -c "pg_ctl -D /var/lib/postgresql/data stop -m immediate -w 2>/dev/null || true"
ev_run "clean recovery pgdata" docker compose exec -T -u root pg-recovery bash -c "rm -rf /var/lib/postgresql/data/* && chown postgres:postgres /var/lib/postgresql/data"
ev_run "restore onto clean host" $REC pgbackrest --stanza=pitr-drill --delta restore
ev_run "start recovered server" $REC pg_ctl -D /var/lib/postgresql/data -w -t 300 start

QUAR="$(Qr "SELECT count(*) FROM memory.record WHERE state='quarantined' AND content='poisoned-1';")"
AUD="$(Qr "SELECT count(*) FROM audit.event WHERE action='quarantine' AND detail='poisoned-1';")"
ev_measure quarantined_after "$QUAR"; ev_measure audit_after "$AUD"

CUR="$(Qr "SELECT count(*) FROM memory.record WHERE source_id='doc-2' AND state='current';")"
CUR_IS_A="$(Qr "SELECT count(*) FROM memory.record WHERE source_id='doc-2' AND state='current' AND content='doc2-v2-A';")"
LINK="$(Qr "SELECT count(*) FROM memory.record v JOIN memory.record a ON v.superseded_by=a.id WHERE v.content='doc2-v1' AND v.state='superseded' AND a.content='doc2-v2-A';")"
REJ="$(Qr "SELECT count(*) FROM memory.record WHERE content='doc2-v2-B' AND state='rejected';")"
ev_measure doc2_current_after "$CUR"; ev_measure doc2_current_is_A "$CUR_IS_A"
ev_measure doc2_lineage_ok "$LINK"; ev_measure doc2_loser_rejected "$REJ"

if [ "$QUAR" = "1" ] && [ "$AUD" = "1" ]; then
  ev_verdict quarantine_survives_restore PASS "the quarantined record and its audit evidence survived the restore with state intact"
else
  ev_verdict quarantine_survives_restore FAIL "quarantined_after=$QUAR audit_after=$AUD"
fi
if [ "$W1" = "1" ] && [ "$W2" = "0" ] && [ "$CUR" = "1" ] && [ "$CUR_IS_A" = "1" ] && [ "$LINK" = "1" ] && [ "$REJ" = "1" ]; then
  ev_verdict supersession_lineage PASS "one writer superseded the record (w1=$W1), the other lost the race (w2=$W2) and withdrew; after restore a single current version remains, linked from the superseded original"
else
  ev_verdict supersession_lineage FAIL "w1=$W1 w2=$W2 current=$CUR current_is_A=$CUR_IS_A lineage=$LINK rejected=$REJ"
fi
ev_manifest
echo "S8: quarantine($QUAR/$AUD) supersession(w1=$W1 w2=$W2 cur=$CUR link=$LINK rej=$REJ)"
cat "$EV_DIR/verdict.tsv"
