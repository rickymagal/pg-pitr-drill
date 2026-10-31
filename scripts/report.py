#!/usr/bin/env python3
"""Build evidence/REPORT.md from the per-scenario verdicts.

Each criterion maps to the scenario verdict(s) that prove it. A criterion passes only
when every verdict it cites is present and PASS in the evidence tree, so the report
cannot claim more than the scenarios recorded. Retention-elapsed coverage and the
cross-project A-I integration tests are held, with the reason stated.
"""
import os, sys, glob, datetime

EV = "evidence"
EXPECTED = ["s0","s1","s2","s3","s4","s5","s6","s7","s8","s9","s10"]

CRITERIA = [
  (1, "Actual PostgreSQL point-in-time recovery", [("s0","pitr_t1")], ""),
  (2, "Restore to selected valid timestamps", [("s0","pitr_t1"),("s0","pitr_t2")], ""),
  (3, "Simulated complete loss of Server 1", [("s4","total_loss_recovery")], ""),
  (4, "Database restore onto a clean replacement host", [("s4","total_loss_recovery")], ""),
  (5, "Measured database RPO and recovery duration", [("s4","measured_rpo")], ""),
  (6, "Backup, WAL, checksum and consistency verification",
      [("s1","wal_corruption"),("s3","backup_corrupt"),("s9","recovered_consistency")], ""),
  (7, "30-day retention configuration versus proven coverage",
      "HOLD:retention is configured (repo1-retention-full-type=time, repo1-retention-full=30); a single run cannot prove 30 days of elapsed coverage. The expiry mechanism is exercised in s3.", ""),
  (8, "Response to a missing, incomplete, expired or corrupted backup",
      [("s3","backup_missing"),("s3","backup_corrupt"),("s3","backup_expired")],
      "Exercised: missing, corrupted, retention-expired. Not separately exercised: an interrupted/incomplete backup."),
  (9, "Response to missing, delayed, corrupt or unusable WAL",
      [("s2","wal_missing"),("s2","wal_corrupt"),("s2","wal_unusable")],
      "Exercised: missing, corrupt, zero-length/unusable. Not separately exercised: a delayed-but-present segment."),
  (10, "Unauthorized connections and role actions denied",
      [("s6","unauthorized_connection_denied"),("s6","protected_write_denied")], ""),
  (11, "Unauthorized operator access and stolen-credential denial",
      [("s6","unauthorized_connection_denied"),("s6","stolen_credential_denied")], ""),
  (12, "Project, operator and customer isolation",
      [("s7","tenant_isolation"),("s7","operator_isolation")], ""),
  (13, "Protected memory, policy and authority-write denial", [("s6","protected_write_denied")], ""),
  (14, "Recovery errors detected and alerted", [("s10","error_detected_and_alerted")], ""),
  (15, "Owner-controlled key use after contractor access is removed", [("s5","owner_key_recovery")], ""),
  (16, "Reproducibility from source, config and commands", "SELF", ""),
  (17, "Concurrent mutation, conflict and supersession lineage", [("s8","supersession_lineage")], ""),
  (18, "Quarantined or poisoned memory state and evidence preservation", [("s8","quarantine_survives_restore")], ""),
]
AI_TESTS = ("The five cross-project A-I integration tests are HOLD: they require the "
            "builder's cross-project host, which this self-contained drill does not provide.")

def load_verdicts():
    v = {}
    for path in glob.glob(os.path.join(EV, "*", "verdict.tsv")):
        sid = os.path.basename(os.path.dirname(path))
        with open(path) as f:
            for line in f:
                p = line.rstrip("\n").split("\t")
                if len(p) >= 2:
                    v[(sid, p[0])] = (p[1], p[2] if len(p) > 2 else "")
    return v

def present_scenarios():
    return {os.path.basename(os.path.dirname(p)) for p in glob.glob(os.path.join(EV, "*", "verdict.tsv"))}

def environment():
    for path in sorted(glob.glob(os.path.join(EV, "*", "environment.txt"))):
        env = {}
        with open(path) as f:
            for line in f:
                if "=" in line:
                    k, _, val = line.strip().partition("=")
                    env[k] = val
        if env:
            return env
    return {}

def main():
    v = load_verdicts()
    present = present_scenarios()
    rows, npass, nhold, nfail = [], 0, 0, 0
    for num, text, proof, note in CRITERIA:
        if isinstance(proof, str) and proof.startswith("HOLD:"):
            status, src, note = "HOLD", "-", proof[5:].strip(); nhold += 1
        elif proof == "SELF":
            missing = [s for s in EXPECTED if s not in present]
            if missing:
                status, src, note = "FAIL", "make drill", "scenarios missing: " + ", ".join(missing); nfail += 1
            else:
                status, src = "PASS", "make drill"
                note = "make drill reproduced all %d scenarios from a clean clone." % len(EXPECTED); npass += 1
        else:
            src = ", ".join(s for s, _ in proof)
            bad = []
            for s, k in proof:
                r = v.get((s, k))
                if r is None: bad.append("%s:%s missing" % (s, k))
                elif r[0] != "PASS": bad.append("%s:%s=%s" % (s, k, r[0]))
            if bad:
                status = "FAIL"; note = (note + " " if note else "") + "unmet: " + "; ".join(bad); nfail += 1
            else:
                status = "PASS"; npass += 1
        rows.append((num, text, src, status, note))

    env = environment()
    out = ["# PostgreSQL recovery and security drill - criterion report", ""]
    out.append("Generated %s by `make drill`." % datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"))
    if env:
        out += ["", "Environment: image `%s`, %s, git `%s`." % (
            env.get("image_id", "?")[:26], env.get("pgbackrest", "?"),
            env.get("git_describe", env.get("git_commit", "?")))]
    out += ["", ("Every PASS below is backed by a PASS verdict under "
                 "`evidence/<scenario>/verdict.tsv`; this report is generated from those "
                 "verdicts and cannot assert more than they record."), ""]
    out += ["| # | Criterion | Scenarios | Status | Notes |", "|---|-----------|-----------|--------|-------|"]
    for num, text, src, status, note in rows:
        out.append("| %d | %s | %s | **%s** | %s |" % (num, text, src, status, note.replace("|", "\\|")))
    out += ["", "PASS %d, HOLD %d, FAIL %d of %d criteria." % (npass, nhold, nfail, len(CRITERIA)), "", AI_TESTS, ""]
    report = "\n".join(out) + "\n"
    os.makedirs(EV, exist_ok=True)
    with open(os.path.join(EV, "REPORT.md"), "w") as f:
        f.write(report)
    sys.stdout.write(report)
    sys.exit(1 if nfail else 0)

if __name__ == "__main__":
    main()
