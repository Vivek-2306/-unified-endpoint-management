#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
mkdir -p deploy/certs

openssl genrsa -out deploy/certs/dev-ca.key 4096
openssl req -x509 -new -nodes -key deploy/certs/dev-ca.key -sha256 -days 825 \
  -out deploy/certs/dev-ca.crt -subj "/CN=UEM Dev CA"

sign() {
  local name="$1"
  shift
  local san="DNS:localhost,IP:127.0.0.1"
  local extra
  for extra in "$@"; do
    san="${san},DNS:${extra}"
  done

  local ext
  ext="$(mktemp)"
  cat >"$ext" <<EOF
subjectAltName=${san}
basicConstraints=CA:FALSE
keyUsage=digitalSignature,keyEncipherment
extendedKeyUsage=serverAuth
EOF

  openssl genrsa -out "deploy/certs/${name}.key" 2048
  openssl req -new -key "deploy/certs/${name}.key" \
    -out "deploy/certs/${name}.csr" -subj "/CN=${name}"
  openssl x509 -req \
    -in "deploy/certs/${name}.csr" \
    -CA deploy/certs/dev-ca.crt \
    -CAkey deploy/certs/dev-ca.key \
    -CAcreateserial \
    -out "deploy/certs/${name}.crt" \
    -days 825 -sha256 \
    -extfile "$ext"
  rm -f "$ext" "deploy/certs/${name}.csr"
  chmod 600 "deploy/certs/${name}.key"
}

sign api
sign worker
sign relay
sign console
sign postgres postgres
sign redis redis
sign kafka kafka
sign clickhouse clickhouse

chmod 600 deploy/certs/dev-ca.key
rm -f deploy/certs/dev-ca.srl