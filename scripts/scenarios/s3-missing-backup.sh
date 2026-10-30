#!/usr/bin/env bash
# S3 — the repository does not silently accept a bad backup. Three faults, each caught
# for the right reason and then repaired: every full set removed (missing), a stored
# file in a set altered (corrupted), and an old set dropped by retention (expired).
# Covers test 8.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/evidence.sh
ev_init s3 "Missing, corrupted, and expired backups are handled"
PRI="docker compose exec -T -u postgres pg-primary"
REPO="docker compose exec -T -u postgres backup-repo"
BDIR=/var/lib/pgbackrest/backup/pitr-drill

ev_run "base backup"     $PRI pgbackrest --stanza=pitr-drill backup --type=full
ev_run "verify baseline" ./scripts/pgbr-verify.sh
SETS="$($REPO bash -c "find $BDIR -mindepth 1 -maxdepth 1 -type d -name '*F' | sort | tr '\n' ' '")"
ev_measure backup_sets "${SETS:-none}"
[ -n "$SETS" ] || { ev_verdict backup_missing HOLD "no full backup set found"; ev_manifest; echo "S3 HOLD"; exit 0; }
M=FAIL; Mr=FAIL; C=FAIL; Cr=FAIL; X=FAIL

# Keep a clean copy of every set so each fault can be repaired back to a good repo.
ev_run "snapshot backup sets" $REPO bash -c "rm -rf /tmp/s3-sets && mkdir -p /tmp/s3-sets && cp -a $BDIR/*F /tmp/s3-sets/"

# Fault 1 — missing: remove every full set.
ev_run "remove all backup sets" $REPO bash -c "find $BDIR -mindepth 1 -maxdepth 1 -type d -name '*F' -exec rm -rf {} +"
if ev_expect_fail "verify detects missing backup" "not in the repository|status: error" ./scripts/pgbr-verify.sh; then M=PASS; fi
ev_run "repair: restore sets (missing)" $REPO bash -c "cp -a /tmp/s3-sets/*F $BDIR/"
if ev_run "verify after repair (missing)" ./scripts/pgbr-verify.sh; then Mr=PASS; fi

# Fault 2 — corrupted: alter one stored file inside the newest set.
NEWEST="$($REPO bash -c "find $BDIR -mindepth 1 -maxdepth 1 -type d -name '*F' | sort | tail -1")"
VICTIM="$($REPO bash -c "find '$NEWEST' -type f ! -name 'backup.manifest*' | sort | head -1")"
ev_measure corrupt_victim "${VICTIM:-none}"
if [ -n "$VICTIM" ]; then
  ev_run "corrupt a stored backup file" $REPO bash -c "printf 'CORRUPT' >> '$VICTIM'"
  if ev_expect_fail "verify detects corruption" "status: error" ./scripts/pgbr-verify.sh; then C=PASS; fi
  ev_run "repair: restore sets (corrupt)" $REPO bash -c "rm -rf $BDIR/*F && cp -a /tmp/s3-sets/*F $BDIR/"
  if ev_run "verify after repair (corrupt)" ./scripts/pgbr-verify.sh; then Cr=PASS; fi
fi

# Fault 3 — expired: a second full set, then retention by count keeps only the newest.
ev_run "second full backup" $PRI pgbackrest --stanza=pitr-drill backup --type=full
BEFORE="$($REPO bash -c "find $BDIR -mindepth 1 -maxdepth 1 -type d -name '*F' | wc -l")"
ev_run "expire to one full by count" $PRI pgbackrest --stanza=pitr-drill expire --repo1-retention-full-type=count --repo1-retention-full=1
AFTER="$($REPO bash -c "find $BDIR -mindepth 1 -maxdepth 1 -type d -name '*F' | wc -l")"
ev_measure full_sets_before_expire "$BEFORE"
ev_measure full_sets_after_expire "$AFTER"
if [ "$AFTER" -lt "$BEFORE" ] && ev_run "verify valid after expire" ./scripts/pgbr-verify.sh; then X=PASS; fi

M_ALL="$([ "$M" = PASS ] && [ "$Mr" = PASS ] && echo PASS || echo FAIL)"
C_ALL="$([ "$C" = PASS ] && [ "$Cr" = PASS ] && echo PASS || echo FAIL)"
ev_verdict backup_missing "$M_ALL" "missing sets detected ($M) and repaired ($Mr)"
ev_verdict backup_corrupt "$C_ALL" "corruption detected as a repository error ($C) and repaired ($Cr)"
ev_verdict backup_expired "$X" "second full set expired by retention to $AFTER from $BEFORE, repository still valid"

ev_manifest
echo "S3: missing($M/$Mr) corrupt($C/$Cr) expired($X before=$BEFORE after=$AFTER)"
cat "$EV_DIR/verdict.tsv"
