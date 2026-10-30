#!/usr/bin/env bash
# S5 — recovery needs the owner-controlled key after the contractor's access is
# revoked: the wrong passphrase cannot decrypt, the owner's passphrase recovers.
# Covers test 15.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/evidence.sh
ev_init s5 "Recovery needs the owner-controlled key after revocation"
PRI="docker compose exec -T -u postgres pg-primary"
clean_rec() { docker compose exec -T -u root pg-recovery bash -c "rm -rf /var/lib/postgresql/data/* && chown postgres:postgres /var/lib/postgresql/data"; }
ev_run "base backup" $PRI pgbackrest --stanza=pitr-drill backup --type=full
ev_run "load"        ./scripts/load-gen.sh 20 0.05
ev_run "archive wal" $PRI psql -U postgres -d pitr_drill -c "SELECT pg_switch_wal();"
ev_run "stop stale recovery server" docker compose exec -T -u postgres pg-recovery bash -c "pg_ctl -D /var/lib/postgresql/data stop -m immediate -w 2>/dev/null || true"
ev_run "clean recovery pgdata" clean_rec
if ev_expect_fail "restore without the owner key fails" "CryptoError|no backup set found" \
     docker compose exec -T -e PGBACKREST_REPO1_CIPHER_PASS=wrong-revoked-key -u postgres pg-recovery \
       pgbackrest --stanza=pitr-drill --delta restore ; then FAULT=PASS; else FAULT=FAIL; fi
ev_run "clean recovery pgdata again" clean_rec
ev_run "restore with the owner key" docker compose exec -T -u postgres pg-recovery pgbackrest --stanza=pitr-drill --delta restore
ev_run "start recovered server" docker compose exec -T -u postgres pg-recovery pg_ctl -D /var/lib/postgresql/data -w -t 300 start
ROWS="$(docker compose exec -T -u postgres pg-recovery psql -U postgres -d pitr_drill -tAc "SELECT count(*) FROM memory.record;")"
ev_measure rows_recovered "${ROWS:-0}"
if [ "$FAULT" = PASS ] && [ -n "$ROWS" ] && [ "$ROWS" -gt 0 2>/dev/null ]; then
  ev_verdict owner_key_recovery PASS "restore failed without the key and recovered $ROWS rows with it"
else
  ev_verdict owner_key_recovery FAIL "fault=$FAULT rows_recovered=${ROWS:-empty}"
fi
ev_manifest; echo "S5: fault=$FAULT rows=${ROWS:-empty}"; cat "$EV_DIR/verdict.tsv"
