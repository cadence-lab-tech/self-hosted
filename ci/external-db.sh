# shellcheck shell=bash
# shellcheck disable=SC2034 # the EXT_DB_* variables are for ci/check-stack.sh
#
# A stand-in for the external PostgreSQL of a customer, for ci/check-stack.sh
# with CHECK_DB=external. Not a command: sourced after lib.sh.
#
# A pgvector container outside the compose project of the installation,
# reachable the way a managed database is - by a host name and a port, over
# TLS with a certificate of a CA of its own:
#
#   Docker Desktop  host.docker.internal, port published on 127.0.0.1
#   Linux           the address of docker0 (172.17.0.1), the container in
#                   the host network listening on that address and on
#                   127.0.0.1 of the machine
#   EXT_DB_NETWORK  set: the container in that Docker network under the name
#                   EXT_DB_ALIAS (default extdb), nothing published - for
#                   the pods of a kind cluster (ci/check-helm.sh, the network
#                   "kind")
#
# The superuser works on it with docker exec psql -h 127.0.0.1: TCP, so the
# wait sees the real server, not the one initdb runs on the socket, and
# trust in pg_hba of the image, so no password. On Docker Desktop that is
# the loopback of the container; in the host network it is the loopback of
# the machine, so the server listens there too - the containers of the stack
# still reach it only by EXT_DB_HOST, under the certificate for that name.
#
# The role cadence owns the database cadence and is no superuser; vector and
# pgcrypto are created in advance by the superuser, as on a managed server.
# Next to it the databases of the refusals:
#
#   cadence_noext    owned by cadence, no extensions (vector cannot be created)
#   cadence_nopriv   extensions, but no CREATE on the schema public for cadence
#   cadence_foreign  owned by cadence, a table that is not Cadence's
#
# EXT_DB_* variables describe it; ext_db_down removes it with its files.

EXT_DB_IMAGE="${EXT_DB_IMAGE:-pgvector/pgvector:pg18}"

# ext_db_host prints the host name containers reach the stand-in by and sets
# EXT_DB_BIND (where it listens) and EXT_DB_MODE (desktop, linux or network).
ext_db_where() {
  if [ -n "${EXT_DB_NETWORK:-}" ]; then
    EXT_DB_MODE=network
    EXT_DB_HOST="${EXT_DB_ALIAS:-extdb}"
    EXT_DB_BIND=
  elif docker info --format '{{.OperatingSystem}}' 2>/dev/null | grep -q 'Docker Desktop'; then
    EXT_DB_MODE=desktop
    EXT_DB_HOST=host.docker.internal
    EXT_DB_BIND=127.0.0.1
  else
    EXT_DB_MODE=linux
    EXT_DB_HOST="$(docker network inspect bridge -f '{{(index .IPAM.Config 0).Gateway}}')"
    EXT_DB_BIND="$EXT_DB_HOST"
  fi
}

# ext_db_certs DIR makes a CA, a server certificate for EXT_DB_HOST signed by
# it, and a second CA that signed nothing (the wrong CA of a refusal).
ext_db_certs() {
  local dir="$1"
  mkdir -p "$dir"
  docker run --rm -v "$dir:/certs" -e HOST="$EXT_DB_HOST" --entrypoint sh "$EXT_DB_IMAGE" -c '
    set -e
    cd /certs
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=Cadence check CA" -keyout ca.key -out ca.pem 2>/dev/null
    openssl req -x509 -newkey rsa:2048 -nodes -days 2 -subj "/CN=Another CA" -keyout other-ca.key -out other-ca.pem 2>/dev/null
    case "$HOST" in
    *[!0-9.]*) san="DNS:$HOST,DNS:localhost,IP:127.0.0.1" ;;
    *) san="IP:$HOST,DNS:localhost,IP:127.0.0.1" ;;
    esac
    openssl req -newkey rsa:2048 -nodes -subj "/CN=$HOST" -keyout server.key -out server.csr 2>/dev/null
    printf "subjectAltName=%s\n" "$san" >server.ext
    openssl x509 -req -in server.csr -CA ca.pem -CAkey ca.key -CAcreateserial -days 2 -extfile server.ext -out server.pem 2>/dev/null
    chmod 644 ca.pem other-ca.pem server.pem server.key
  '
}

# ext_db_up NAME PORT DIR: the stand-in under the container name NAME on PORT;
# certificates and passwords under DIR. Sets EXT_DB_PASSWORD (of cadence,
# with characters a URL must percent-encode) and EXT_DB_PASSWORD_URL.
ext_db_up() {
  local name="$1" port="$2" dir="$3" net=() publish=() listen
  ext_db_where
  ext_db_certs "$dir"
  EXT_DB_NAME="$name"
  EXT_DB_PORT="$port"
  EXT_DB_SUPER_PASSWORD="$(openssl rand -hex 16)"
  EXT_DB_PASSWORD="Cad@nce/$(openssl rand -hex 8)%x"
  EXT_DB_PASSWORD_URL="$(printf '%s' "$EXT_DB_PASSWORD" | sed 's/%/%25/g; s/@/%40/g; s:/:%2F:g')"
  case "$EXT_DB_MODE" in
  linux)
    net=(--network host)
    listen="$EXT_DB_BIND,127.0.0.1"
    ;;
  network)
    net=(--network "$EXT_DB_NETWORK" --network-alias "$EXT_DB_HOST")
    listen='*'
    ;;
  *)
    publish=(-p "$EXT_DB_BIND:$port:$port")
    listen='*'
    ;;
  esac
  docker run -d --name "$name" ${net[@]+"${net[@]}"} ${publish[@]+"${publish[@]}"} \
    -e POSTGRES_PASSWORD="$EXT_DB_SUPER_PASSWORD" -v "$dir:/certs-src:ro" \
    --entrypoint sh "$EXT_DB_IMAGE" -c "
      mkdir -p /etc/pgcerts && cp /certs-src/server.pem /certs-src/server.key /etc/pgcerts/ &&
      chown -R postgres /etc/pgcerts && chmod 600 /etc/pgcerts/server.key &&
      exec docker-entrypoint.sh postgres -p $port -c listen_addresses='$listen' -c ssl=on \
        -c ssl_cert_file=/etc/pgcerts/server.pem -c ssl_key_file=/etc/pgcerts/server.key" >/dev/null
  local i
  for i in $(seq 1 60); do
    if docker exec "$name" pg_isready -q -h 127.0.0.1 -p "$port" -U postgres 2>/dev/null &&
      docker exec "$name" psql -q -h 127.0.0.1 -p "$port" -U postgres -c 'SELECT 1' >/dev/null 2>&1; then
      break
    fi
    sleep 1
  done
  ext_db_sql postgres "CREATE ROLE cadence LOGIN PASSWORD '$EXT_DB_PASSWORD'" \
    "CREATE DATABASE cadence OWNER cadence" "CREATE DATABASE cadence_noext OWNER cadence" \
    "CREATE DATABASE cadence_nopriv" "CREATE DATABASE cadence_foreign OWNER cadence"
  ext_db_sql cadence "CREATE EXTENSION vector" "CREATE EXTENSION pgcrypto"
  ext_db_sql cadence_nopriv "CREATE EXTENSION vector" "CREATE EXTENSION pgcrypto" "REVOKE ALL ON SCHEMA public FROM PUBLIC"
  ext_db_sql cadence_foreign "CREATE EXTENSION vector" "CREATE EXTENSION pgcrypto" \
    "SET ROLE cadence" "CREATE TABLE orders (id int)"
}

# ext_db_sql DB SQL...: statements as the superuser.
ext_db_sql() {
  local db="$1" args=() s
  shift
  for s in "$@"; do args+=(-c "$s"); done
  docker exec "$EXT_DB_NAME" psql -X -q -v ON_ERROR_STOP=1 -h 127.0.0.1 -p "$EXT_DB_PORT" -U postgres -d "$db" "${args[@]}" >/dev/null
}

# ext_db_query DB SQL: one value, as the superuser.
ext_db_query() {
  docker exec "$EXT_DB_NAME" psql -X -q -At -h 127.0.0.1 -p "$EXT_DB_PORT" -U postgres -d "$1" -c "$2"
}

# ext_db_url [DB] [PARAMS]: the URL of the role cadence; PARAMS replace the
# default sslmode=verify-full (the CA is added by --external-db-ca).
ext_db_url() {
  printf 'postgres://cadence:%s@%s:%s/%s?%s\n' "$EXT_DB_PASSWORD_URL" "$EXT_DB_HOST" "$EXT_DB_PORT" "${1:-cadence}" "${2:-sslmode=verify-full}"
}

ext_db_down() {
  [ -z "${EXT_DB_NAME:-}" ] || docker rm -f "$EXT_DB_NAME" >/dev/null 2>&1 || true
  [ -z "${EXT_DB_OLD_NAME:-}" ] || docker rm -f "$EXT_DB_OLD_NAME" >/dev/null 2>&1 || true
}

# ext_db_old_up NAME PORT: PostgreSQL 14 - below the supported range - without
# TLS, for the refusal of the version. Sets EXT_DB_OLD_URL.
ext_db_old_up() {
  local name="$1" port="$2" pw net=() publish=() listen
  pw="$(openssl rand -hex 12)"
  EXT_DB_OLD_NAME="$name"
  if [ "$EXT_DB_MODE" = linux ]; then
    net=(--network host)
    listen="$EXT_DB_BIND,127.0.0.1"
  else
    publish=(-p "$EXT_DB_BIND:$port:$port")
    listen='*'
  fi
  docker run -d --name "$name" ${net[@]+"${net[@]}"} ${publish[@]+"${publish[@]}"} -e POSTGRES_PASSWORD="$pw" -e POSTGRES_DB=cadence \
    pgvector/pgvector:pg14 postgres -p "$port" -c listen_addresses="$listen" >/dev/null
  for _ in $(seq 1 60); do
    docker exec "$name" psql -q -h 127.0.0.1 -p "$port" -U postgres -c 'SELECT 1' >/dev/null 2>&1 && break
    sleep 1
  done
  EXT_DB_OLD_URL="postgres://postgres:$pw@$EXT_DB_HOST:$port/cadence?sslmode=disable"
}
