#!/usr/bin/env bash
# Initialize this host for pgBackRest before running the real command: stage the
# host's mTLS material into a private, postgres-owned location (bind-mounted keys
# arrive with the host uid, but pgBackRest runs as the postgres user), and ensure
# the log and repository paths are writable. Driven by the hostname, so one
# script serves every host.
set -euo pipefail
h="$(hostname)"
cert="/etc/pgbackrest/cert"
install -d -o postgres -g postgres -m 0750 "$cert" /var/log/pgbackrest
install -o postgres -g postgres -m 0600 "/pki/$h.key" "$cert/$h.key"
install -o postgres -g postgres -m 0644 "/pki/$h.crt" "$cert/$h.crt"
install -o postgres -g postgres -m 0644 "/pki/ca.crt" "$cert/ca.crt"
[ -d /var/lib/pgbackrest ] && chown postgres:postgres /var/lib/pgbackrest || true
exec "$@"
