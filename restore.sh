#!/usr/bin/env bash
#
# Restores the database (and the blobs volume, when the backup has it) from
# a backup made by backup.sh, then starts the stack and waits for it.
#
#   ./restore.sh backups/cadence-v0.5.0-20261008-030000.sql.gz
#   ./restore.sh --yes backups/cadence-v0.5.0-20261008-030000.sql.gz   # no prompt
#
# EVERYTHING written after the backup is lost: the database is dropped and
# recreated from the dump. With an external database (CADENCE_DB=external)
# nothing is dropped but the objects of Cadence Lab in the schema public:
# they go and the dump is loaded in one transaction, by the role of
# SDLC_DATABASE_URL - no superuser, no DROP DATABASE; a failed load leaves
# the database as it was.
#
# The backup must match the version in VERSION: migrations only go forward,
# and a dump of one schema under images of another version is not a state
# anybody tested. When they differ, put the package files of the version of
# the backup in place first - the command is printed: the copy upgrade.sh
# kept in backups/package-vX.Y.Z-<date>.tar.gz, or the package of the
# release - or pass --ignore-version if you know what you are doing.
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=lib.sh
. ./lib.sh

assume_yes=false
ignore_version=false
file=""
while [ $# -gt 0 ]; do
  case "$1" in
  -y | --yes) assume_yes=true; shift ;;
  --ignore-version) ignore_version=true; shift ;;
  -h | --help) sed -n '3,22p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  -*) die "unknown option: $1" ;;
  *) [ -z "$file" ] || die "one backup file at a time"; file="$1"; shift ;;
  esac
done

[ -n "$file" ] || die "which backup? ./restore.sh backups/cadence-<version>-<date>.sql.gz"
[ -f "$file" ] || die "no such file: $file"
case "$file" in
*.sql.gz) ;;
*) die "$file is not a database dump (*.sql.gz) made by backup.sh" ;;
esac
gzip -t "$file" 2>/dev/null || die "$file is not a valid gzip archive"

# .env first: a COMPOSE_PROJECT_NAME of another installation stops here,
# before Docker is asked anything.
load_env
require_docker
check_mode

# The version is part of the name backup.sh gives the file.
name="$(basename "$file")"
backup_version=""
if [[ "$name" =~ ^cadence-(v[0-9]+\.[0-9]+\.[0-9]+)-[0-9]{8}-[0-9]{6}\.sql\.gz$ ]]; then
  backup_version="${BASH_REMATCH[1]}"
fi
if [ "$backup_version" != "$CADENCE_VERSION" ] && [ "$ignore_version" = false ]; then
  if [ -z "$backup_version" ]; then
    die "cannot tell the version of $name (expected cadence-vX.Y.Z-YYYYmmdd-HHMMSS.sql.gz).
  Pass --ignore-version if you are sure it was taken on $CADENCE_VERSION."
  fi
  die "the backup was taken on $backup_version, the package is on $CADENCE_VERSION.
  Put the package files of $backup_version in place first, then restore:
    $(package_files_hint "$backup_version") && ./restore.sh $file"
fi

blobs="${file%.sql.gz}.blobs.tar.gz"
[ -f "$blobs" ] || blobs=""
if [ -z "$blobs" ] && [ -z "${SDLC_BLOB_S3_BUCKET:-}" ]; then
  warn "no ${name%.sql.gz}.blobs.tar.gz next to the dump: the blobs volume is left as it is"
fi

if [ "$assume_yes" = false ]; then
  [ -t 0 ] || die "restore replaces the database; run it in a terminal or pass --yes"
  say "This REPLACES the database${blobs:+ and the blobs volume} with $name."
  say "Everything written after the backup is lost."
  read -r -p "Type 'restore' to continue: " answer
  [ "$answer" = restore ] || die "cancelled"
fi

db="${POSTGRES_DB:-sdlc}"
user="${POSTGRES_USER:-sdlc}"

if external_db; then
  # Before anything stops: an unreachable database leaves the stack running.
  info "checking the external database $(db_target "$SDLC_DATABASE_URL")"
  db_client_check || die "the backup client cannot connect to the external database (see above); nothing was changed"
fi

info "stopping api and worker"
docker compose stop api worker >/dev/null

if external_db; then
  db_url_parts "$SDLC_DATABASE_URL"
  info "loading $name into $(db_target "$SDLC_DATABASE_URL") (one transaction)"
  # transaction_timeout exists since PostgreSQL 17; a dump of a 17 server
  # names it, a 15 or 16 server would refuse it.
  if ! { db_reset_sql; gunzip -c "$file" | sed '/^SET transaction_timeout = 0;$/d'; } |
    db_client psql -X -q -v ON_ERROR_STOP=1 --single-transaction -d "$DB_URL_SAFE" >/dev/null; then
    die "loading $name failed (see above); the transaction is rolled back and the database is as it was.
  Start the stack again: export CADENCE_VERSION=\$(cat VERSION) && docker compose up -d"
  fi
else
  info "starting postgres"
  docker compose up -d postgres >/dev/null
  for _ in $(seq 1 60); do
    docker compose exec -T postgres pg_isready -U "$user" -d postgres >/dev/null 2>&1 && break
    sleep 2
  done
  docker compose exec -T postgres pg_isready -U "$user" -d postgres >/dev/null 2>&1 ||
    die "postgres did not become ready"

  info "recreating database $db"
  docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -q -U "$user" -d postgres \
    -c "DROP DATABASE IF EXISTS \"$db\" WITH (FORCE)" \
    -c "CREATE DATABASE \"$db\" OWNER \"$user\"" >/dev/null

  # Dumps leave the extensions out (lib.sh, DUMP_OPTIONS): they are created
  # first. A dump of an older version still has them and recreates them
  # itself.
  docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -q -U "$user" -d "$db" \
    -c "CREATE EXTENSION IF NOT EXISTS vector" -c "CREATE EXTENSION IF NOT EXISTS pgcrypto" >/dev/null

  info "loading $name"
  gunzip -c "$file" |
    docker compose exec -T postgres psql -v ON_ERROR_STOP=1 -q -U "$user" -d "$db" >/dev/null
fi

if [ -n "$blobs" ]; then
  api="$(container_of api)"
  [ -n "$api" ] || die "the api container does not exist: cannot reach the blobs volume"
  info "restoring the blobs volume from $(basename "$blobs")"
  # The service runs as nonroot (uid 65532) and must be able to write there.
  docker run --rm --volumes-from "$api" -v "$(cd "$(dirname "$blobs")" && pwd):/backup:ro" alpine:3 \
    sh -c "find /blobs -mindepth 1 -delete &&
           tar -xzf '/backup/$(basename "$blobs")' -C /blobs &&
           chown -R 65532:65532 /blobs"
fi

info "starting the stack"
docker compose up -d --remove-orphans
if ! wait_ready "${CADENCE_READY_TIMEOUT:-300}"; then
  docker compose ps
  docker compose logs --tail 40 api || true
  die "the stack did not become ready after the restore; the logs are above"
fi
ok "restored $name; Cadence Lab $CADENCE_VERSION is up"
