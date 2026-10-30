#!/usr/bin/env bash
# S6 — unauthorized database actions are denied, each for the right reason. Covers tests 10, 11, 13.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/evidence.sh
ev_init s6 "Unauthorized database actions are denied"
PRI="docker compose exec -T -u postgres pg-primary psql -U postgres -d pitr_drill -v ON_ERROR_STOP=1"
if ev_expect_fail "core_app cannot write authority" "permission denied for table policy" \
     $PRI -c "SET ROLE core_app; INSERT INTO authority.policy(name,decided_by) VALUES ('x','y');"; then A=PASS; else A=FAIL; fi
if ev_expect_fail "operator cannot read memory" "permission denied for schema memory" \
     $PRI -c "SET ROLE ai_operator; SELECT 1 FROM memory.record;"; then B=PASS; else B=FAIL; fi
if ev_run "core_app can write memory" $PRI -c "SET ROLE core_app; INSERT INTO memory.record(content) VALUES ('ok');"; then C=PASS; else C=FAIL; fi
if [ "$A" = PASS ] && [ "$B" = PASS ] && [ "$C" = PASS ]; then
  ev_verdict unauthorized_denied PASS "authority-write and operator-read denied for the right reason; the authorized write succeeded"
else
  ev_verdict unauthorized_denied FAIL "authority_denied=$A operator_denied=$B legit_write=$C"
fi
ev_manifest; echo "S6: authority=$A operator=$B legit=$C"; cat "$EV_DIR/verdict.tsv"
