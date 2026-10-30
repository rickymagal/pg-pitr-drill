#!/usr/bin/env bash
# S7 — cross-project isolation under row-level security. Covers test 12.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/evidence.sh
ev_init s7 "Cross-project isolation under row-level security"
PRI="docker compose exec -T -u postgres pg-primary psql -U postgres -d pitr_drill -v ON_ERROR_STOP=1"
Q() { docker compose exec -T -u postgres pg-primary psql -U postgres -d pitr_drill -qtAc "$1"; }
ev_run "project A writes its row" $PRI -c "SET ROLE core_app; SET app.project_id='projA'; INSERT INTO memory.tenant_record(project_id,content) VALUES ('projA','a-secret');"
ev_run "project B writes its row" $PRI -c "SET ROLE core_app; SET app.project_id='projB'; INSERT INTO memory.tenant_record(project_id,content) VALUES ('projB','b-secret');"
A_OWN="$(Q "SET ROLE core_app; SET app.project_id='projA'; SELECT count(*) FROM memory.tenant_record WHERE content='a-secret';")"
A_OTHER="$(Q "SET ROLE core_app; SET app.project_id='projA'; SELECT count(*) FROM memory.tenant_record WHERE content='b-secret';")"
ev_measure a_sees_own "$A_OWN"; ev_measure a_sees_other "$A_OTHER"
if ev_expect_fail "A cannot forge a row for B" "row-level security|new row violates" \
     $PRI -c "SET ROLE core_app; SET app.project_id='projA'; INSERT INTO memory.tenant_record(project_id,content) VALUES ('projB','forged');"; then XW=PASS; else XW=FAIL; fi
if [ "$A_OWN" = "1" ] && [ "$A_OTHER" = "0" ] && [ "$XW" = PASS ]; then
  ev_verdict cross_project_isolation PASS "A saw its own row and not B's, and could not forge a row for B"
else
  ev_verdict cross_project_isolation FAIL "a_sees_own=$A_OWN a_sees_other=$A_OTHER cross_write=$XW"
fi
ev_manifest; echo "S7: own=$A_OWN other=$A_OTHER cross_write=$XW"; cat "$EV_DIR/verdict.tsv"
