#!/usr/bin/env bash
# S9 — the recovered database is internally consistent. Restore the latest backup onto a
# clean host and run a full heap-and-btree check (pg_amcheck --heapallindexed) across the
# recovered database; it must find no corruption. This is the consistency half of
# repository verification, alongside WAL-archive integrity (s1) and backup-file
# integrity (s3). Covers test 6.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/evidence.sh
ev_init s9 "The recovered database passes a full consistency check"
PRI="docker compose exec -T -u postgres pg-primary"
REC="docker compose exec -T -u postgres pg-recovery"

ev_run "base backup" $PRI pgbackrest --stanza=pitr-drill backup --type=full
ev_run "load"        ./scripts/load-gen.sh 60 0.02
ev_run "archive wal" $PRI psql -U postgres -d pitr_drill -c "SELECT pg_switch_wal();"
ev_run "stop stale recovery server" $REC bash -c "pg_ctl -D /var/lib/postgresql/data stop -m immediate -w 2>/dev/null || true"
ev_run "clean recovery pgdata" docker compose exec -T -u root pg-recovery bash -c "rm -rf /var/lib/postgresql/data/* && chown postgres:postgres /var/lib/postgresql/data"
ev_run "restore latest onto clean host" $REC pgbackrest --stanza=pitr-drill --delta restore
ev_run "start recovered server" $REC pg_ctl -D /var/lib/postgresql/data -w -t 300 start

TABLES="$($REC psql -U postgres -d pitr_drill -qtAc "SELECT count(*) FROM pg_tables WHERE schemaname IN ('workflow','memory','source_docs','audit','runtime','authority');")"
ev_measure recovered_tables "${TABLES:-0}"

if ev_run "pg_amcheck heap+index on recovered db" $REC pg_amcheck -U postgres -d pitr_drill --install-missing --heapallindexed; then AC=PASS; else AC=FAIL; fi
if [ "$AC" = PASS ]; then
  ev_verdict recovered_consistency PASS "pg_amcheck found no heap or btree corruption in the recovered database ($TABLES application tables)"
else
  ev_verdict recovered_consistency FAIL "pg_amcheck reported corruption or could not run (see commands.log)"
fi
ev_manifest
echo "S9: pg_amcheck=$AC tables=$TABLES"
cat "$EV_DIR/verdict.tsv"
