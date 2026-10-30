#!/usr/bin/env bash
# pgbackrest verify that fails when the repository is invalid. pgBackRest 2.60
# exits 0 even on a corrupt or missing segment and only reports the problem as a
# "status: error" block (with --output=text), so a bare verify cannot tell a clean
# repository from a broken one. This wrapper surfaces a reported problem, or a
# verify that could not run, as a nonzero exit.
set -uo pipefail
out="$(docker compose exec -T -u postgres pg-primary pgbackrest --stanza=pitr-drill verify --output=text 2>&1)"; rc=$?
printf '%s\n' "$out"
if [ "$rc" -ne 0 ] || grep -q 'status: error' <<<"$out"; then
  exit 1
fi
exit 0
