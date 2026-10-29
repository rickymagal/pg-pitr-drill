# Reproducible image shared by every drill host: the digest-pinned PostgreSQL 17
# base plus a version-pinned pgBackRest, so database and backup tooling are
# version-identical on pg-primary, pg-recovery, and backup-repo. The archive APT
# source keeps the pinned pgBackRest installable after it rotates out of the
# current PGDG repo, so a clean clone still builds months from now.
FROM postgres:17-bookworm@sha256:839fbb5a4942a7758dd93e18b42ea5649807491a0545b5eeeb8f0b8bb11857a5

# Verified installable version from the pinned base image's PGDG repo (Step 0b).
ENV PGBACKREST_VERSION=2.60.0-1.pgdg12+1

# ca-certificates first: the archive source is HTTPS and the base image has no
# system certificates. Error-Mode=any makes a broken or unverifiable source fail
# the build instead of passing with a silent warning.
RUN set -eux; \
    apt-get update; \
    apt-get install -y --no-install-recommends ca-certificates; \
    sb="$(sed -n 's/.*signed-by=\([^] ]*\).*/\1/p' /etc/apt/sources.list.d/*.list 2>/dev/null | grep -m1 . || true)"; \
    if [ -n "$sb" ]; then opt="[signed-by=$sb] "; else opt=""; fi; \
    echo "deb ${opt}https://apt-archive.postgresql.org/pub/repos/apt bookworm-pgdg-archive main" \
      > /etc/apt/sources.list.d/pgdg-archive.list; \
    apt-get -o APT::Update::Error-Mode=any update; \
    apt-get install -y --no-install-recommends "pgbackrest=${PGBACKREST_VERSION}"; \
    pgbackrest version; \
    rm -rf /var/lib/apt/lists/*
