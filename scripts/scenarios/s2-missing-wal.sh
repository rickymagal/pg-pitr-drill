#!/usr/bin/env bash
# S2 — a missing WAL segment is detected: pgBackRest cannot retrieve it from the
# archive, which is how recovery fetches WAL. Covers tests 9, 14.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/evidence.sh
ev_init s2 "A missing WAL segment is detected"
PRI="docker compose exec -T -u postgres pg-primary"
REPO="docker compose exec -T -u postgres backup-repo"
ev_run "base backup"      $PRI pgbackrest --stanza=pitr-drill backup --type=full
ev_run "load"             ./scripts/load-gen.sh 20 0.05
ev_run "archive and wait" $PRI pgbackrest --stanza=pitr-drill check
# a finished archived segment (<24 hex>-<40 hex sha>.gz), never a .pgbackrest.tmp in flight
WALFILE="$($REPO bash -c "find /var/lib/pgbackrest/archive/pitr-drill -type f -regextype egrep -regex '.*/[0-9A-F]{24}-[0-9a-f]{40}\.gz' | sort | tail -1")"
WALNAME="$(basename "${WALFILE:-x}" | cut -c1-24)"
ev_measure removed_wal "${WALFILE:-none}"; ev_measure wal_name "${WALNAME:-none}"
[ -n "$WALFILE" ] || { ev_verdict wal_missing HOLD "no finished WAL segment found"; ev_manifest; echo "S2 HOLD"; exit 0; }
ev_run "archive-get baseline" $PRI bash -c "rm -f /tmp/s2a; pgbackrest --stanza=pitr-drill --log-level-console=info archive-get $WALNAME /tmp/s2a"
ev_run "snapshot segment" $REPO bash -c "cp '$WALFILE' /tmp/s2-wal.orig"
ev_run "remove segment"   $REPO bash -c "rm -f '$WALFILE'"
if ev_expect_fail "archive-get detects missing wal" "unable to find .* in the archive" \
     $PRI bash -c "rm -f /tmp/s2b; pgbackrest --stanza=pitr-drill --log-level-console=info archive-get $WALNAME /tmp/s2b"; then FAULT=PASS; else FAULT=FAIL; fi
ev_run "repair: restore segment" $REPO bash -c "mv /tmp/s2-wal.orig '$WALFILE'"
if ev_run "archive-get after repair" $PRI bash -c "rm -f /tmp/s2c; pgbackrest --stanza=pitr-drill --log-level-console=info archive-get $WALNAME /tmp/s2c"; then REPAIR=PASS; else REPAIR=FAIL; fi
if [ "$FAULT" = PASS ] && [ "$REPAIR" = PASS ]; then
  ev_verdict wal_missing PASS "pgBackRest retrieved the segment, failed once it was removed, and retrieved it again after repair"
else
  ev_verdict wal_missing FAIL "fault=$FAULT repair=$REPAIR (see commands.log)"
fi
ev_manifest; echo "S2: fault=$FAULT repair=$REPAIR wal=$WALNAME"; cat "$EV_DIR/verdict.tsv"
