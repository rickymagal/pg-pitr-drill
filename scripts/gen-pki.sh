#!/usr/bin/env bash
# Generate a disposable PKI for the pgBackRest TLS mesh: one CA and one
# dual-purpose (serverAuth + clientAuth) certificate per host, because each host
# both initiates and accepts pgBackRest TLS connections. Private keys never leave
# the working tree and are gitignored; only this generator is committed, so a
# clean clone rebuilds an equivalent mesh with `make pki`.
set -euo pipefail

PKI_DIR="${PKI_DIR:-pki}"
HOSTS=(backup-repo pg-primary pg-recovery)
DAYS=3650

rm -rf "$PKI_DIR"
mkdir -p "$PKI_DIR/ca"

ca_cnf="$(mktemp)"
cat > "$ca_cnf" <<'EOF'
[req]
distinguished_name = dn
prompt = no
x509_extensions = v3_ca
[dn]
CN = pg-pitr-drill-ca
[v3_ca]
basicConstraints = critical, CA:TRUE
keyUsage = critical, keyCertSign, cRLSign
EOF
openssl genrsa -out "$PKI_DIR/ca/ca.key" 4096 2>/dev/null
openssl req -x509 -new -nodes -key "$PKI_DIR/ca/ca.key" -sha256 -days "$DAYS" \
  -config "$ca_cnf" -out "$PKI_DIR/ca/ca.crt"
rm -f "$ca_cnf"
chmod 600 "$PKI_DIR/ca/ca.key"

for h in "${HOSTS[@]}"; do
  mkdir -p "$PKI_DIR/$h"
  cnf="$(mktemp)"
  cat > "$cnf" <<EOF
[req]
distinguished_name = dn
prompt = no
[dn]
CN = $h
[v3]
basicConstraints = critical, CA:FALSE
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = DNS:$h
EOF
  openssl genrsa -out "$PKI_DIR/$h/$h.key" 2048 2>/dev/null
  openssl req -new -key "$PKI_DIR/$h/$h.key" -subj "/CN=$h" -out "$PKI_DIR/$h/$h.csr"
  openssl x509 -req -in "$PKI_DIR/$h/$h.csr" \
    -CA "$PKI_DIR/ca/ca.crt" -CAkey "$PKI_DIR/ca/ca.key" -CAcreateserial \
    -days "$DAYS" -sha256 -extensions v3 -extfile "$cnf" -out "$PKI_DIR/$h/$h.crt" 2>/dev/null
  cp "$PKI_DIR/ca/ca.crt" "$PKI_DIR/$h/ca.crt"
  rm -f "$PKI_DIR/$h/$h.csr" "$cnf"
  chmod 600 "$PKI_DIR/$h/$h.key"
done

echo "PKI generated under $PKI_DIR/ for: ${HOSTS[*]}"
