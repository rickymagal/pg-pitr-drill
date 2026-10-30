.PHONY: up down ps psql logs pki stanza load backup verify info s0 s1 s2 s3 s4 s5 s6 s7 s8 s9 s10

ROWS ?= 100
INTERVAL ?= 0

pki:
	./scripts/gen-pki.sh

up: pki
	@test -f .env || cp .env.example .env
	docker compose up -d --wait

stanza:
	docker compose exec -u postgres pg-primary pgbackrest --stanza=pitr-drill stanza-create
	docker compose exec -u postgres pg-primary pgbackrest --stanza=pitr-drill check

load:
	./scripts/load-gen.sh $(ROWS) $(INTERVAL)

backup:
	docker compose exec -u postgres pg-primary pgbackrest --stanza=pitr-drill backup --type=full

verify:
	./scripts/pgbr-verify.sh

info:
	docker compose exec -u postgres pg-primary pgbackrest --stanza=pitr-drill info

s0:
	./scripts/scenarios/s0-pitr.sh

s1:
	./scripts/scenarios/s1-corrupt-wal.sh

s3:
	./scripts/scenarios/s3-missing-backup.sh

s2:
	./scripts/scenarios/s2-missing-wal.sh

s4:
	./scripts/scenarios/s4-total-loss.sh

s5:
	./scripts/scenarios/s5-owner-key.sh

s6:
	./scripts/scenarios/s6-unauthorized-denied.sh

s7:
	./scripts/scenarios/s7-isolation.sh

s8:
	./scripts/scenarios/s8-quarantine-restore.sh

s9:
	./scripts/scenarios/s9-consistency.sh

s10:
	./scripts/scenarios/s10-alerting.sh

down:
	docker compose down -v

ps:
	docker compose ps

psql:
	docker compose exec pg-primary psql -U postgres -d pitr_drill

logs:
	docker compose logs -f
