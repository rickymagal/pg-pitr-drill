#!/usr/bin/env bash
# make drill — reproduce the whole drill from a clean clone: bring the stack up, create
# the stanza, run every scenario (each writes its own evidence under evidence/<id>/),
# build the criterion report and a global SHA-256 manifest, then tear down. A scenario
# exiting nonzero is recorded in its evidence and does not abort the run; the report's
# exit status reflects whether every criterion passed.
set -euo pipefail
cd "$(dirname "$0")/.."
make up
make stanza
for s in s0 s1 s2 s3 s4 s5 s6 s7 s8 s9 s10; do
  script="$(ls scripts/scenarios/${s}-*.sh)"
  echo "=== $script ==="
  bash "$script" || echo "scenario $s exited nonzero (recorded in its evidence)"
done
rc=0
python3 scripts/report.py || rc=$?
( cd evidence && find . -type f ! -path './MANIFEST.sha256' | sort | xargs sha256sum > MANIFEST.sha256 )
echo "wrote evidence/REPORT.md and evidence/MANIFEST.sha256"
make down
exit $rc
