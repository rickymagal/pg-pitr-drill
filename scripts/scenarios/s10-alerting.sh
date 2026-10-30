#!/usr/bin/env bash
# S10 — a detected recovery error raises an alert, and a clean run does not. A monitoring
# wrapper runs pgBackRest verify; on failure it dispatches a critical alert through
# scripts/alert.sh to a sink (and, when configured, a webhook). A healthy verify must
# raise no alert; a verify against a removed backup must raise one. The removed-backup
# fault is only the trigger; detection itself is proven in s3. Covers test 14.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/evidence.sh
ev_init s10 "A detected recovery error raises an alert"
PRI="docker compose exec -T -u postgres pg-primary"
REPO="docker compose exec -T -u postgres backup-repo"
BDIR=/var/lib/pgbackrest/backup/pitr-drill
export ALERT_SINK="$EV_DIR/alerts.jsonl"; : >"$ALERT_SINK"

# monitored <label> <cmd...>: run cmd; on failure, dispatch a critical alert and keep the
# failure. This is the detect->alert wiring a real monitoring cron would use.
monitored() {
  local label="$1"; shift
  if ev_run "$label" "$@"; then return 0; fi
  ev_run "dispatch alert for: $label" ./scripts/alert.sh critical recovery "$label failed"
  return 1
}

ev_run "base backup" $PRI pgbackrest --stanza=pitr-drill backup --type=full

# Clean run: verify passes, so no alert is raised.
monitored "verify (healthy repo)" ./scripts/pgbr-verify.sh || true
ALERTS_AFTER_OK="$(wc -l <"$ALERT_SINK" | tr -d ' ')"
ev_measure alerts_after_healthy "$ALERTS_AFTER_OK"

# Fault: remove the backup sets so verify fails; the monitor must raise one alert.
ev_run "snapshot backup sets"   $REPO bash -c "rm -rf /tmp/s10-sets && mkdir -p /tmp/s10-sets && cp -a $BDIR/*F /tmp/s10-sets/"
ev_run "remove all backup sets" $REPO bash -c "find $BDIR -mindepth 1 -maxdepth 1 -type d -name '*F' -exec rm -rf {} +"
monitored "verify (broken repo)" ./scripts/pgbr-verify.sh || true
ALERTS_AFTER_FAULT="$(wc -l <"$ALERT_SINK" | tr -d ' ')"
ev_measure alerts_after_fault "$ALERTS_AFTER_FAULT"
ev_run "repair: restore backup sets" $REPO bash -c "cp -a /tmp/s10-sets/*F $BDIR/"

RAISED="$(( ALERTS_AFTER_FAULT - ALERTS_AFTER_OK ))"
ev_measure alerts_raised_by_fault "$RAISED"
if [ "$ALERTS_AFTER_OK" = "0" ] && [ "$RAISED" -ge "1" ]; then
  ev_verdict error_detected_and_alerted PASS "a healthy verify raised no alert; the failing verify raised $RAISED via scripts/alert.sh"
else
  ev_verdict error_detected_and_alerted FAIL "alerts_after_healthy=$ALERTS_AFTER_OK raised_by_fault=$RAISED"
fi
ev_manifest
echo "S10: healthy=$ALERTS_AFTER_OK fault=$ALERTS_AFTER_FAULT raised=$RAISED"
cat "$EV_DIR/verdict.tsv"
