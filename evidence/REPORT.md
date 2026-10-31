# PostgreSQL recovery and security drill - criterion report

Generated 2026-10-31T01:25:36Z by `make drill`.

Environment: image `sha256:86bf518ca596dd74622`, pgBackRest 2.60.0, git `c0dc32a-dirty`.

Every PASS below is backed by a PASS verdict under `evidence/<scenario>/verdict.tsv`; this report is generated from those verdicts and cannot assert more than they record.

| # | Criterion | Scenarios | Status | Notes |
|---|-----------|-----------|--------|-------|
| 1 | Actual PostgreSQL point-in-time recovery | s0 | **PASS** |  |
| 2 | Restore to selected valid timestamps | s0, s0 | **PASS** |  |
| 3 | Simulated complete loss of Server 1 | s4 | **PASS** |  |
| 4 | Database restore onto a clean replacement host | s4 | **PASS** |  |
| 5 | Measured database RPO and recovery duration | s4 | **PASS** |  |
| 6 | Backup, WAL, checksum and consistency verification | s1, s3, s9 | **PASS** |  |
| 7 | 30-day retention configuration versus proven coverage | - | **HOLD** | retention is configured (repo1-retention-full-type=time, repo1-retention-full=30); a single run cannot prove 30 days of elapsed coverage. The expiry mechanism is exercised in s3. |
| 8 | Response to a missing, incomplete, expired or corrupted backup | s3, s3, s3 | **PASS** | Exercised: missing, corrupted, retention-expired. Not separately exercised: an interrupted/incomplete backup. |
| 9 | Response to missing, delayed, corrupt or unusable WAL | s2, s2, s2 | **PASS** | Exercised: missing, corrupt, zero-length/unusable. Not separately exercised: a delayed-but-present segment. |
| 10 | Unauthorized connections and role actions denied | s6, s6 | **PASS** |  |
| 11 | Unauthorized operator access and stolen-credential denial | s6, s6 | **PASS** |  |
| 12 | Project, operator and customer isolation | s7, s7 | **PASS** |  |
| 13 | Protected memory, policy and authority-write denial | s6 | **PASS** |  |
| 14 | Recovery errors detected and alerted | s10 | **PASS** |  |
| 15 | Owner-controlled key use after contractor access is removed | s5 | **PASS** |  |
| 16 | Reproducibility from source, config and commands | make drill | **PASS** | make drill reproduced all 11 scenarios from a clean clone. |
| 17 | Concurrent mutation, conflict and supersession lineage | s8 | **PASS** |  |
| 18 | Quarantined or poisoned memory state and evidence preservation | s8 | **PASS** |  |

PASS 17, HOLD 1, FAIL 0 of 18 criteria.

The five cross-project A-I integration tests are HOLD: they require the builder's cross-project host, which this self-contained drill does not provide.

