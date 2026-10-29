.PHONY: up down ps psql logs

up:
	@test -f .env || cp .env.example .env
	docker compose up -d

down:
	docker compose down -v

ps:
	docker compose ps

psql:
	docker compose exec pg-primary psql -U postgres -d pitr_drill

logs:
	docker compose logs -f
