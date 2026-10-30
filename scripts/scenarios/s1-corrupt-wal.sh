#!/usr/bin/env bash
# S1 — a corrupted WAL archive is detected, not silently accepted. Take a backup,
# archive a WAL segment, corrupt that segment in the repository, and show that the
# verify wrapper fails for an integrity reason; then restore the segment and show it
# passes. The cycle is fault -> expected failure -> repair -> fresh pass.
# Covers tests 6 and 9.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/evidence.sh
ev_init s1 "A corrupted WAL archive is detected"

PRI="docker compose exec -T -u postgres pg-primary"
REPO="docker compose exec -T -u postgres backup-repo"

ev_run "base backup"     $PRI pgbackrest --stanza=pitr-drill backup --type=full
ev_run "load"            ./scripts/load-gen.sh 20 0.05
ev_run "archive wal"     $PRI psql -U postgres -d pitr_drill -c "SELECT pg_switch_wal();"
ev_run "verify baseline" ./scripts/pgbr-verify.sh

WAL="$($REPO bash -c "find /var/lib/pgbackrest/archive/pitr-drill -type f -regextype egrep -regex '.*/[0-9A-F]{24}.*' | sort | tail -1")"
ev_measure corrupted_wal "${WAL:-none}"
if [ -z "$WAL" ]; then
  ev_verdict wal_corruption HOLD "no archived WAL segment found to corrupt"
  ev_manifest; echo "S1 HOLD: no WAL segment in archive"; exit 0
fi

ev_run "snapshot pristine segment"    $REPO bash -c "cp '$WAL' /tmp/s1-wal.orig"
ev_run "corrupt one archived segment" $REPO bash -c "dd if=/dev/urandom of='$WAL' bs=1 count=16 seek=16 conv=notrunc status=none"

if ev_expect_fail "verify detects corruption" "status: error|invalid result|FormatError|data error" \
     ./scripts/pgbr-verify.sh ; then FAULT=PASS; else FAULT=FAIL; fi

ev_run "repair: restore pristine segment" $REPO bash -c "mv /tmp/s1-wal.orig '$WAL'"
if ev_run "verify after repair" ./scripts/pgbr-verify.sh ; then REPAIR=PASS; else REPAIR=FAIL; fi

if [ "$FAULT" = PASS ] && [ "$REPAIR" = PASS ]; then
  ev_verdict wal_corruption PASS "verify failed on the corrupted segment and passed once it was restored"
else
  ev_verdict wal_corruption FAIL "fault=$FAULT repair=$REPAIR (see commands.log)"
fi
ev_manifest
echo "S1: fault=$FAULT repair=$REPAIR wal=$WAL"
cat "$EV_DIR/verdict.tsv"
