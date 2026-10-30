.PHONY: up down ps psql logs pki stanza load backup verify info s0 s1 s3

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

down:
	docker compose down -v

ps:
	docker compose ps

psql:
	docker compose exec pg-primary psql -U postgres -d pitr_drill

logs:
	docker compose logs -f
