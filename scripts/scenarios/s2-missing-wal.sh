#!/usr/bin/env bash
# S2 — bad WAL in the archive is not silently accepted during recovery. archive-get is
# the path recovery uses to fetch WAL; against the same finished segment it must succeed
# when the segment is good and refuse to deliver it when the segment is missing,
# corrupted, or truncated to an unusable size. Each fault is repaired back to a
# retrievable segment. Covers test 9.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/evidence.sh
ev_init s2 "Missing, corrupt, and unusable WAL are refused by archive-get"
PRI="docker compose exec -T -u postgres pg-primary"
REPO="docker compose exec -T -u postgres backup-repo"

AGET() { $PRI bash -c "rm -f /tmp/s2out; pgbackrest --stanza=pitr-drill --log-level-console=info archive-get $WALNAME /tmp/s2out"; }
reject_content() {  # 0 iff archive-get failed AND not because the segment was absent
  local label="$1" out rc=0
  out="$(AGET 2>&1)" || rc=$?
  printf '## [%s] %s (expect content reject)\n%s\n# exit=%s\n' "$(date -u +%FT%TZ)" "$label" "$out" "$rc" >>"$EV_LOG"
  [ "$rc" -ne 0 ] && ! grep -qiE "unable to find .* in the archive" <<<"$out"
}

ev_run "base backup"      $PRI pgbackrest --stanza=pitr-drill backup --type=full
ev_run "load"             ./scripts/load-gen.sh 20 0.05
ev_run "archive and wait" $PRI pgbackrest --stanza=pitr-drill check
WALFILE="$($REPO bash -c "find /var/lib/pgbackrest/archive/pitr-drill -type f -regextype egrep -regex '.*/[0-9A-F]{24}-[0-9a-f]{40}\.gz' | sort | tail -1")"
WALNAME="$(basename "${WALFILE:-x}" | cut -c1-24)"
ev_measure target_wal "${WALFILE:-none}"; ev_measure wal_name "${WALNAME:-none}"
[ -n "$WALFILE" ] || { ev_verdict wal_missing HOLD "no finished WAL segment found"; ev_manifest; echo "S2 HOLD"; exit 0; }
MISS=FAIL; MISSr=FAIL; CORR=FAIL; CORRr=FAIL; UNUS=FAIL; UNUSr=FAIL

ev_run "archive-get baseline" $PRI bash -c "rm -f /tmp/s2base; pgbackrest --stanza=pitr-drill --log-level-console=info archive-get $WALNAME /tmp/s2base"
ev_run "snapshot pristine segment" $REPO bash -c "cp '$WALFILE' /tmp/s2-wal.orig"

# Missing: the segment is gone.
ev_run "remove segment" $REPO bash -c "rm -f '$WALFILE'"
if ev_expect_fail "archive-get detects missing wal" "unable to find .* in the archive" \
     $PRI bash -c "rm -f /tmp/s2b; pgbackrest --stanza=pitr-drill --log-level-console=info archive-get $WALNAME /tmp/s2b"; then MISS=PASS; fi
ev_run "repair (missing)" $REPO bash -c "cp -f /tmp/s2-wal.orig '$WALFILE'"
if ev_run "archive-get after repair (missing)" $PRI bash -c "rm -f /tmp/s2c; pgbackrest --stanza=pitr-drill --log-level-console=info archive-get $WALNAME /tmp/s2c"; then MISSr=PASS; fi

# Corrupt: the segment is present but its bytes are scrambled.
ev_run "corrupt segment" $REPO bash -c "dd if=/dev/urandom of='$WALFILE' bs=1 count=16 seek=16 conv=notrunc status=none"
if reject_content "archive-get refuses corrupt wal"; then CORR=PASS; fi
ev_run "repair (corrupt)" $REPO bash -c "cp -f /tmp/s2-wal.orig '$WALFILE'"
if ev_run "archive-get after repair (corrupt)" $PRI bash -c "rm -f /tmp/s2c2; pgbackrest --stanza=pitr-drill --log-level-console=info archive-get $WALNAME /tmp/s2c2"; then CORRr=PASS; fi

# Unusable: the segment is present but truncated to zero length.
ev_run "truncate segment to zero" $REPO bash -c "truncate -s 0 '$WALFILE'"
if reject_content "archive-get refuses unusable wal"; then UNUS=PASS; fi
ev_run "repair (unusable)" $REPO bash -c "cp -f /tmp/s2-wal.orig '$WALFILE'"
if ev_run "archive-get after repair (unusable)" $PRI bash -c "rm -f /tmp/s2c3; pgbackrest --stanza=pitr-drill --log-level-console=info archive-get $WALNAME /tmp/s2c3"; then UNUSr=PASS; fi

ev_verdict wal_missing  "$([ "$MISS" = PASS ] && [ "$MISSr" = PASS ] && echo PASS || echo FAIL)"  "archive-get failed on the absent segment ($MISS) and retrieved it after repair ($MISSr)"
ev_verdict wal_corrupt  "$([ "$CORR" = PASS ] && [ "$CORRr" = PASS ] && echo PASS || echo FAIL)"  "archive-get refused the corrupted segment for a content reason ($CORR) and retrieved it after repair ($CORRr)"
ev_verdict wal_unusable "$([ "$UNUS" = PASS ] && [ "$UNUSr" = PASS ] && echo PASS || echo FAIL)"  "archive-get refused the zero-length segment ($UNUS) and retrieved it after repair ($UNUSr)"

ev_manifest
echo "S2: missing($MISS/$MISSr) corrupt($CORR/$CORRr) unusable($UNUS/$UNUSr) wal=$WALNAME"
cat "$EV_DIR/verdict.tsv"
