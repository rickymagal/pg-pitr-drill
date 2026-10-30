#!/usr/bin/env bash
# pgbackrest verify that fails when the repository is invalid. pgBackRest 2.60 exits
# 0 both on a corrupt segment (reported only as a "status: error" block with
# --output=text) and on a backup set missing from the repository (reported only as a
# "not in the repository" WARN). This wrapper surfaces either, or a verify that could
# not run, as a nonzero exit. It does not detect a missing WAL segment: verify in
# 2.60 ignores gaps in the archive, so that case is covered by a recovery scenario.
set -uo pipefail
out="$(docker compose exec -T -u postgres pg-primary pgbackrest --stanza=pitr-drill verify --output=text 2>&1)"; rc=$?
printf '%s\n' "$out"
if [ "$rc" -ne 0 ] || grep -qE 'status: error|not in the repository' <<<"$out"; then
  exit 1
fi
exit 0
