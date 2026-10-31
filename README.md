# PostgreSQL Recovery and Security Drill

A running database never holds still. Rows are written, changed, and deleted every second, and a backup is a photograph of one instant of that motion. If the database dies at three in the afternoon and the last photograph was taken at two in the morning, everything in between is gone, unless something kept a record of every change made since the photo. PostgreSQL keeps exactly that record. Before a change ever touches the real data files it is first written to an append-only journal called the write-ahead log, the WAL, so the WAL is the ordered story of everything that happened to the database.

Point-in-time recovery is what those two pieces make possible together. Take the last photograph, the base backup, then replay the journal forward one change at a time and stop at any instant you name. You can land the database at 2:59 and one second, the moment before a bad deploy or a mistaken `DELETE`, with every change up to that second present and nothing after it. This repository builds a small environment that performs that recovery for real, under the conditions that usually break it, and writes down what happened each time.

The day this capability is needed is the worst day the system has: a disk failed, someone dropped the wrong table, an attacker encrypted the host. In that moment two numbers decide how bad the day becomes. The first is how much committed data the failure took with it, the gap between the last change saved safely off the machine and the crash, called the recovery point, or RPO. The second is how long the database stays down while it is rebuilt, the recovery time, or RTO. A smaller recovery point means less lost work, a smaller recovery time means a shorter outage, and both are settled long before the incident by how the backups were built.

A backup earns trust the first time someone actually restores it, and everything before that first restore is a promise the system has never tested. Whether the stored files actually restore, whether the archived journal is whole, whether the person running the restore still holds the key to decrypt it, are all discovered at the instant of the attempt. Rehearsing turns each promise into a fact held in advance: the recovery point is under a second, the recovery time is seconds, the repository verifies, the owner's key works, and the restored database is sound and still walled off. Knowing how to build this, and keeping the evidence it produces, is the difference between a rehearsed procedure and a gamble taken during an outage.

## Repository layout

```
pg-pitr-drill/
├── Dockerfile               digest-pinned PostgreSQL 17 + version-pinned pgBackRest, one image for every host
├── docker-compose.yml       the three-host topology and the private network
├── Makefile                 every command below is a make target
├── .env.example             synthetic, disposable credentials (make up copies it to .env)
├── config/pgbackrest/       one pgBackRest config per host: TLS mesh, repo encryption, 30-day retention
├── sql/                     applied once at cluster init (data domains, least-privilege roles, RLS tenant table)
├── scripts/                 gen-pki, pgbr-init, pgbr-verify, load-gen, alert, evidence, report, drill
│   └── scenarios/           s0 through s10, one file each
└── evidence/                generated proof, one directory per scenario (+ REPORT.md, MANIFEST.sha256)
```

pgBackRest is the backup tool that ties the hosts together: it takes the base photograph, receives each WAL segment the primary finishes, stores both in an encrypted repository, and runs the restore. The `Makefile` is the shortest way in, `scripts/scenarios/` shows what each test actually does, and `evidence/REPORT.md` holds the results of the last run.

## The three hosts

The drill is three machines so that recovery can be proven the way it happens for real, from one healthy copy that lives somewhere else. `pg-primary` is the live database, PostgreSQL 17 with WAL archiving turned on, shipping each finished segment off the box as it is written. `backup-repo` is that somewhere else: a separate host running the pgBackRest server and holding the encrypted repository, and it never receives the encryption passphrase, so the machine that stores the backups cannot read them. `pg-recovery` starts empty and stands in for the clean replacement machine a restore lands on after the primary is lost. The three share one private network and one digest-pinned image, so the database and the backup tool are version-identical everywhere and a restore never fails on a version mismatch.

## The scenarios

Each scenario names a way recovery fails in the real world, forces that failure on purpose, and reads the result back out of the recovered database. A fault counts only when the system fails for the expected reason, checked against the command's own error, and every destructive step is repaired before the next so the repository is left valid.

- **s0, rewinding to just before the mistake.** Restores to two chosen timestamps, each landing exactly on the rows committed at or before it with none after, and times the recovery. This is the fat-fingered `DELETE` answered: land the database one second before it happened.
- **s1, a rotted piece of the journal.** The fear is a backup that looks fine and restores into garbage. An archived WAL segment is corrupted in the repository; verify has to catch it and fail, then pass again once the segment is restored.
- **s2, an unreadable segment during recovery.** On the path recovery uses to fetch WAL, a missing, a corrupted, and a zero-length segment are each refused, and each is repaired back to retrievable. Silent acceptance of bad WAL is what turns a recovery into a quiet data-loss event.
- **s3, a backup that is gone, altered, or aged out.** A set that is missing, one with an altered stored file, and one dropped by retention are each caught for the right reason and repaired.
- **s4, the whole server is gone.** The primary is hard-killed, and the database is rebuilt on the clean host from the off-box repository, with the recovery point (how much was lost) and the recovery time (how long it took) both measured and recorded.
- **s5, the person who set it up is gone.** A contractor's access is revoked: their key can no longer decrypt the repository, and the owner's key still recovers. Key custody is what keeps a backup from leaving with the person who built it.
- **s6, the restored system still has to say no.** The application cannot escalate into authority, an operator cannot open a session or read memory, and a credential revoked after exposure stops working.
- **s7, one customer must never see another.** Under row-level security a session scoped to one customer and project sees and writes only its own rows, a shared project name never leaks across customers, and a cross-tenant forge is refused.
- **s8, recovery must not quietly rewrite history.** A record held in quarantine and a contested edit resolved between two racing writers both survive the restore truthfully, with their state and audit trail intact.
- **s9, is the recovered database actually sound.** The restored database passes a full heap-and-index check with no corruption, so recovery yields a database proven sound down to its heap and indexes.
- **s10, does anyone find out when recovery breaks.** A failing verify raises an alert and a healthy one stays silent, because a backup failure discovered during the outage is a failure discovered too late.

## The criteria

An independent reviewer judges the run against eighteen acceptance criteria, and the drill is built so the judgment rests on the recorded evidence. `scripts/report.py` maps each criterion to the scenario verdict or verdicts that prove it and builds `evidence/REPORT.md`, and a criterion passes only when every verdict it cites is present and PASS, so the report can never assert more than the scenarios recorded.

| # | Criterion | Scenario | Status |
|---|-----------|----------|--------|
| 1 | Actual point-in-time recovery | s0 | PASS |
| 2 | Restore to selected valid timestamps | s0 | PASS |
| 3 | Simulated complete loss of the primary | s4 | PASS |
| 4 | Restore onto a clean replacement host | s4 | PASS |
| 5 | Measured RPO and recovery duration | s4 | PASS |
| 6 | Backup, WAL, checksum and consistency verification | s1, s3, s9 | PASS |
| 7 | 30-day retention, configured versus proven coverage | - | HOLD |
| 8 | Missing, incomplete, expired or corrupted backup | s3 | PASS |
| 9 | Missing, delayed, corrupt or unusable WAL | s2 | PASS |
| 10 | Unauthorized connections and role actions denied | s6 | PASS |
| 11 | Unauthorized operator access and stolen-credential denial | s6 | PASS |
| 12 | Project, operator and customer isolation | s7 | PASS |
| 13 | Protected memory, policy and authority-write denial | s6 | PASS |
| 14 | Recovery errors detected and alerted | s10 | PASS |
| 15 | Owner-controlled key use after contractor access removed | s5 | PASS |
| 16 | Reproducibility from source, config and commands | make drill | PASS |
| 17 | Concurrent mutation, conflict and supersession lineage | s8 | PASS |
| 18 | Quarantined or poisoned state and evidence preservation | s8 | PASS |

Two things are held rather than passed, and the report states why. The 30-day retention (criterion 7) is configured and its expiry mechanism is exercised in s3, and a single run cannot witness thirty days of elapsed coverage. Five cross-project integration tests are held because they need a builder's cross-project host that this self-contained drill does not provide. A held criterion is an honest gap named in the open, which is the posture the whole drill is built for.

## Precautions

Each safeguard here closes a way the rehearsal could lie or a real recovery could fail. The image is reproducible, a digest-pinned PostgreSQL 17 base and a version-pinned pgBackRest installed from an archive source that keeps the pinned version available, so a clean clone still builds the same thing months from now. Every pgBackRest connection runs over mutual TLS with a per-host certificate from a disposable authority, so the backup stream cannot be read or tampered with in transit, and the private keys stay out of version control while only their generator is committed. The repository is AES-256 encrypted under a passphrase the owner holds and passes through the environment, written into no committed file and never sent to the repository host, so holding the stored bytes leaves the data inside them locked. The database starts default-deny: the public role holds nothing, the application cannot write authority, evidence is append-only, the untrusted operator has no direct path to the data, and tenant rows are isolated by customer and project, so a restore brings the security posture back intact. Every credential and value in the tree is synthetic and disposable and no production system is touched. Each scenario records its commands, UTC timestamps, exit codes, measurements, a per-criterion verdict, and the environment identity (git commit, image id, pgBackRest version), then hashes the whole set into a SHA-256 manifest, so anyone can check the evidence against its own hashes.

## Running and reproducing

The only prerequisite is Docker with Compose. From a clean clone:

```
make drill
```

This builds the image, generates the PKI, starts the three hosts, creates the pgBackRest stanza (the per-cluster backup configuration), runs every scenario, builds the report and the global manifest, and tears the stack down. Its exit status is nonzero if any criterion fails, and a scenario that exits nonzero is recorded in its own evidence without aborting the run.

The pieces run on their own as well: `make up` and `make stanza` bring the stack up and initialize the stanza, `make s0` through `make s10` run one scenario each, and `make backup`, `make load`, `make verify`, `make info`, `make report`, `make psql`, and `make down` cover the ordinary operations. Reproducibility rests on the pinned image and the recorded environment: the line at the top of `REPORT.md` names the image id, the pgBackRest version, and the git description the evidence came from, so a rerun on the same commit rebuilds the same image digest and repeats the measurements.

## Results and measurements

The last recorded run passed 17 criteria, held 1, and failed none. Point-in-time recovery landed both chosen instants exactly, 30 rows at the first and 50 at the second, with zero rows after either target and about six seconds to recover each. The total-loss scenario rebuilt the database on the clean host with every one of the 150 durably archived rows intact, a recovery point of 0.874 seconds and 10 rows (the writes still in the open, unarchived segment when the host was killed), and a recovery time of 7 seconds. Those two numbers are the ones an incident is judged by, and here they come straight out of the recovered database. Every figure lives in `evidence/<scenario>/measurements.tsv`, every judgment in `verdict.tsv`, and a hash of all of it in `evidence/MANIFEST.sha256`.
