#!/usr/bin/env bash
# S6 — unauthorized database actions and connections are denied, each for the right
# reason, and a credential revoked after exposure stops working. The local socket is
# trust, so every refusal below is the role's own login/privilege check, not pg_hba.
# Covers tests 10, 11, 13.
set -euo pipefail
cd "$(dirname "$0")/../.."
source scripts/evidence.sh
ev_init s6 "Unauthorized actions and connections are denied"
PRI="docker compose exec -T -u postgres pg-primary psql -U postgres -d pitr_drill -v ON_ERROR_STOP=1"
SESSION() { docker compose exec -T -u postgres pg-primary psql -U "$1" -d pitr_drill -c "SELECT 1"; }

# Role-action boundary (test 13): the app cannot escalate into authority, the operator
# cannot read memory, and the app's own authorized write still succeeds.
if ev_expect_fail "core_app cannot write authority" "permission denied for table policy" \
     $PRI -c "SET ROLE core_app; INSERT INTO authority.policy(name,decided_by) VALUES ('x','y');"; then A=PASS; else A=FAIL; fi
if ev_expect_fail "operator cannot read memory" "permission denied for schema memory" \
     $PRI -c "SET ROLE ai_operator; SELECT 1 FROM memory.record;"; then B=PASS; else B=FAIL; fi
if ev_run "core_app can write memory" $PRI -c "SET ROLE core_app; INSERT INTO memory.record(content) VALUES ('ok');"; then C=PASS; else C=FAIL; fi
if [ "$A" = PASS ] && [ "$B" = PASS ] && [ "$C" = PASS ]; then
  ev_verdict protected_write_denied PASS "authority-write and operator-read denied for the right reason; the authorized write succeeded"
else
  ev_verdict protected_write_denied FAIL "authority_denied=$A operator_denied=$B legit_write=$C"
fi

# Connection boundary (test 10): the operator role has no direct database path.
if ev_expect_fail "operator cannot open a session" "not permitted to log in" SESSION ai_operator; then D=PASS; else D=FAIL; fi
if [ "$D" = PASS ]; then
  ev_verdict unauthorized_connection_denied PASS "ai_operator (NOLOGIN) cannot open a direct session; it reaches data only through the Core"
else
  ev_verdict unauthorized_connection_denied FAIL "operator session was not refused for the login-permission reason"
fi

# Stolen-credential response (test 11): a contractor login that works is revoked after
# exposure, and the same credential can no longer open a session.
ev_run "create contractor login" $PRI -c "DROP ROLE IF EXISTS drill_contractor; CREATE ROLE drill_contractor LOGIN;"
if ev_run "contractor can connect" SESSION drill_contractor; then E1=PASS; else E1=FAIL; fi
ev_run "revoke contractor access" $PRI -c "ALTER ROLE drill_contractor NOLOGIN;"
if ev_expect_fail "revoked contractor cannot connect" "not permitted to log in" SESSION drill_contractor; then E2=PASS; else E2=FAIL; fi
ev_run "drop contractor" $PRI -c "DROP ROLE IF EXISTS drill_contractor;"
if [ "$E1" = PASS ] && [ "$E2" = PASS ]; then
  ev_verdict stolen_credential_denied PASS "a working contractor credential, revoked after exposure, could no longer open a session"
else
  ev_verdict stolen_credential_denied FAIL "connected_before=$E1 denied_after_revoke=$E2"
fi

ev_manifest
echo "S6: action(A=$A B=$B C=$C) connect(D=$D) credential(before=$E1 after=$E2)"
cat "$EV_DIR/verdict.tsv"
