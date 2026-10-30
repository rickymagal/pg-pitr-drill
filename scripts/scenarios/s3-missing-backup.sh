#!/usr/bin/env bash
# S3 — a missing backup is detected, not silently accepted. Remove every full backup
# set from the repository and show the verify wrapper reports the sets missing; then
# restore them and show it passes. Covers test 8.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/evidence.sh
ev_init s3 "A missing backup is detected"
PRI="docker compose exec -T -u postgres pg-primary"
REPO="docker compose exec -T -u postgres backup-repo"
BDIR=/var/lib/pgbackrest/backup/pitr-drill
ev_run "base backup"     $PRI pgbackrest --stanza=pitr-drill backup --type=full
ev_run "verify baseline" ./scripts/pgbr-verify.sh
SETS="$($REPO bash -c "find $BDIR -mindepth 1 -maxdepth 1 -type d -name '*F' | sort | tr '\n' ' '")"
ev_measure backup_sets "${SETS:-none}"
[ -n "$SETS" ] || { ev_verdict backup_missing HOLD "no full backup set found"; ev_manifest; echo "S3 HOLD"; exit 0; }
ev_run "snapshot backup sets"   $REPO bash -c "rm -rf /tmp/s3-sets && mkdir -p /tmp/s3-sets && cp -a $BDIR/*F /tmp/s3-sets/"
ev_run "remove all backup sets" $REPO bash -c "find $BDIR -mindepth 1 -maxdepth 1 -type d -name '*F' -exec rm -rf {} +"
if ev_expect_fail "verify detects missing backup" "not in the repository|status: error" ./scripts/pgbr-verify.sh; then FAULT=PASS; else FAULT=FAIL; fi
ev_run "repair: restore backup sets" $REPO bash -c "cp -a /tmp/s3-sets/*F $BDIR/"
if ev_run "verify after repair" ./scripts/pgbr-verify.sh; then REPAIR=PASS; else REPAIR=FAIL; fi
if [ "$FAULT" = PASS ] && [ "$REPAIR" = PASS ]; then
  ev_verdict backup_missing PASS "verify reported the sets missing while they were gone, and passed once they were restored"
else
  ev_verdict backup_missing FAIL "fault=$FAULT repair=$REPAIR (see commands.log)"
fi
ev_manifest
echo "S3: fault=$FAULT repair=$REPAIR"
cat "$EV_DIR/verdict.tsv"
