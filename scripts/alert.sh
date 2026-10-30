#!/usr/bin/env bash
# alert.sh — dispatch a recovery/monitoring alert. Appends one JSON line to the sink
# named by ALERT_SINK and, when ALERT_WEBHOOK_URL is set, POSTs the same payload there.
# This is the hook a monitoring wrapper calls when a recovery or verify command fails;
# delivery to a real channel is configuration, not hard-coded here. Usage:
#   ALERT_SINK=<path> alert.sh <severity> <source> <message>
set -euo pipefail
sev="${1:?severity}"; src="${2:?source}"; msg="${3:?message}"
: "${ALERT_SINK:?ALERT_SINK must be set}"
mkdir -p "$(dirname "$ALERT_SINK")"
esc="$(printf '%s' "$msg" | sed 's/\\/\\\\/g; s/"/\\"/g')"
line="$(printf '{"ts":"%s","severity":"%s","source":"%s","message":"%s"}' "$(date -u +%FT%TZ)" "$sev" "$src" "$esc")"
printf '%s\n' "$line" >>"$ALERT_SINK"
if [ -n "${ALERT_WEBHOOK_URL:-}" ]; then
  curl -fsS -m 5 -X POST -H 'Content-Type: application/json' -d "$line" "$ALERT_WEBHOOK_URL" >/dev/null 2>&1 \
    || printf '%s\n' "$line" >>"${ALERT_SINK}.undelivered"
fi
echo "ALERT[$sev] $src: $msg"
