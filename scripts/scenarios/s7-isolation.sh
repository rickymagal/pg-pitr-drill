#!/usr/bin/env bash
# S7 — tenant isolation under row-level security across two axes, customer and project,
# with the operator walled off entirely. A session scoped to one (customer, project)
# sees and writes only its own rows: a shared project label does not leak across
# customers, and a shared customer does not leak across projects. Covers test 12.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/evidence.sh
ev_init s7 "Tenant isolation across customer and project under RLS"
PRI="docker compose exec -T -u postgres pg-primary psql -U postgres -d pitr_drill -v ON_ERROR_STOP=1"
Q() { docker compose exec -T -u postgres pg-primary psql -U postgres -d pitr_drill -qtAc "$1"; }
ins()  { ev_run "write ($1,$2)" $PRI -c "SET ROLE core_app; SET app.customer_id='$1'; SET app.project_id='$2'; INSERT INTO memory.tenant_record(customer_id,project_id,content) VALUES ('$1','$2','$3');"; }
seen() { Q "SET ROLE core_app; SET app.customer_id='$1'; SET app.project_id='$2'; SELECT count(*) FROM memory.tenant_record WHERE content='$3';"; }

ev_run "reset tenant table" $PRI -c "TRUNCATE memory.tenant_record RESTART IDENTITY;"

# Same project label 'projA' under two customers, plus a second project under C1.
ins C1 projA c1-a
ins C1 projB c1-b
ins C2 projA c2-a

# Session (C1,projA) must see only its own row.
OWN="$(seen C1 projA c1-a)"
OTHER_PROJECT="$(seen C1 projA c1-b)"
OTHER_CUSTOMER="$(seen C1 projA c2-a)"
ev_measure sees_own "$OWN"
ev_measure sees_other_project "$OTHER_PROJECT"
ev_measure sees_other_customer "$OTHER_CUSTOMER"

# (C1,projA) cannot forge a row for another customer that shares the project label.
if ev_expect_fail "C1/projA cannot forge a row for C2/projA" "row-level security|new row violates" \
     $PRI -c "SET ROLE core_app; SET app.customer_id='C1'; SET app.project_id='projA'; INSERT INTO memory.tenant_record(customer_id,project_id,content) VALUES ('C2','projA','forged');"; then XW=PASS; else XW=FAIL; fi

# The operator has no path to tenant data at all.
if ev_expect_fail "operator cannot read tenant records" "permission denied for schema memory" \
     $PRI -c "SET ROLE ai_operator; SELECT count(*) FROM memory.tenant_record;"; then OP=PASS; else OP=FAIL; fi

if [ "$OWN" = "1" ] && [ "$OTHER_PROJECT" = "0" ] && [ "$OTHER_CUSTOMER" = "0" ] && [ "$XW" = PASS ]; then
  ev_verdict tenant_isolation PASS "a (customer,project) session saw only its own row; no leak across project label or customer, and a cross-tenant forge was refused"
else
  ev_verdict tenant_isolation FAIL "own=$OWN other_project=$OTHER_PROJECT other_customer=$OTHER_CUSTOMER forge_denied=$XW"
fi
if [ "$OP" = PASS ]; then
  ev_verdict operator_isolation PASS "ai_operator cannot read tenant records"
else
  ev_verdict operator_isolation FAIL "operator read was not denied for the right reason"
fi
ev_manifest
echo "S7: own=$OWN other_project=$OTHER_PROJECT other_customer=$OTHER_CUSTOMER forge=$XW operator=$OP"
cat "$EV_DIR/verdict.tsv"
