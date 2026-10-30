# evidence.sh — sourced by scenario scripts. Records each step of a scenario under
# evidence/<id>/ with UTC timestamps, exit statuses, measurements, a per-criterion
# verdict, and the environment identity needed to reproduce it. Scenarios source
# it; it is not executed directly.

EVIDENCE_ROOT="${EVIDENCE_ROOT:-evidence}"

ev_init() {                        # ev_init <id> [title]
  EV_ID="$1"; EV_TITLE="${2:-$1}"
  EV_DIR="$EVIDENCE_ROOT/$EV_ID"
  rm -rf "$EV_DIR"; mkdir -p "$EV_DIR"
  EV_LOG="$EV_DIR/commands.log"
  EV_MEAS="$EV_DIR/measurements.tsv"
  EV_VERDICT="$EV_DIR/verdict.tsv"
  : >"$EV_LOG"; : >"$EV_MEAS"; : >"$EV_VERDICT"
  _ev_environment >"$EV_DIR/environment.txt"
  printf '# %s  (%s)\n' "$EV_TITLE" "$(date -u +%FT%TZ)" >>"$EV_LOG"
}

_ev_val() {                        # run args, return a single trimmed line, or 'unknown'
  local v; v="$("$@" 2>/dev/null | tr '\r\n' '  ')"
  v="$(printf '%s' "$v" | sed -e 's/[[:space:]]\{1,\}/ /g' -e 's/^ //' -e 's/ $//')"
  [ -n "$v" ] && printf '%s' "$v" || printf 'unknown'
}

_ev_environment() {
  printf 'utc=%s\n'          "$(date -u +%FT%TZ)"
  printf 'git_commit=%s\n'   "$(_ev_val git rev-parse HEAD)"
  printf 'git_describe=%s\n' "$(_ev_val git describe --always --dirty)"
  printf 'image_id=%s\n'     "$(_ev_val docker image inspect -f '{{.Id}}' pg-pitr-drill:local)"
  printf 'pgbackrest=%s\n'   "$(_ev_val docker compose exec -T -u postgres pg-primary pgbackrest version)"
}

ev_run() {                         # ev_run <label> <cmd...>  -> returns the command's exit code
  local label="$1"; shift
  printf '## [%s] %s\n$ %s\n' "$(date -u +%FT%TZ)" "$label" "$*" >>"$EV_LOG"
  local rc=0
  "$@" >>"$EV_LOG" 2>&1 || rc=$?
  printf '# exit=%s\n' "$rc" >>"$EV_LOG"
  return $rc
}

ev_measure() { printf '%s\t%s\n' "$1" "$2" >>"$EV_MEAS"; }   # ev_measure <key> <value>

ev_verdict() {                     # ev_verdict <criterion> <PASS|FAIL|HOLD> <reason>
  printf '%s\t%s\t%s\n' "$1" "$2" "$3" >>"$EV_VERDICT"
  printf 'VERDICT %s: %s (%s)\n' "$1" "$2" "$3" >>"$EV_LOG"
}

ev_manifest() {                    # ev_manifest — hash every evidence file in the scenario dir
  ( cd "$EV_DIR" && find . -type f ! -name MANIFEST.sha256 | sort | xargs sha256sum >MANIFEST.sha256 )
}
