#!/usr/bin/env bash
#
# Backup of the database and, when artifact content lives in the `blobs`
# volume (SDLC_BLOB_S3_BUCKET is empty), of that volume. Old backups are
# rotated. For cron:
#
#   0 3 * * * /path/to/self-hosted/backup.sh >> /path/to/self-hosted/backups/backup.log 2>&1
#
#   BACKUP_DIR  where to write, default ./backups
#   KEEP_DAYS   how long to keep backups, default 14
#
# Files: cadence-<version>-<YYYYmmdd-HHMMSS>.sql.gz and, next to it, the same
# name with .blobs.tar.gz. The version in the name is what restore.sh checks.
# The dump is the same in both database modes: plain SQL without owners,
# privileges and extensions, so a backup of the bundled database restores
# into an external one and back (docs/admin.md, "Backups").
#
# With an external database (CADENCE_DB=external) pg_dump runs in the backup
# client db-client of compose.external-db.yml against SDLC_DATABASE_URL; the
# postgres container is not needed.
#
# Backups stay on this machine: they protect against a bad upgrade or a
# mistaken deletion, not against losing the machine. Copy the directory
# elsewhere (docs/admin.md, "Backups").
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=lib.sh
. ./lib.sh

# .env first: a COMPOSE_PROJECT_NAME of another installation stops here,
# before Docker is asked anything.
load_env
require_docker

keep_days="${KEEP_DAYS:-14}"
dir="${BACKUP_DIR:-$(pwd)/backups}"
mkdir -p "$dir"
dir="$(cd "$dir" && pwd)"

check_db_mode
if ! external_db; then
  running postgres || die "the postgres container is not running: nothing to back up"
fi

stem="$dir/cadence-${CADENCE_VERSION}-$(date +%Y%m%d-%H%M%S)"
dump="$stem.sql.gz"

# pg_dump runs INSIDE a container: the host has no Postgres client, and a
# client of another version breaks the dump. Bundled: the database container
# itself; external: the backup client, whose pg_dump is of the newest
# supported server version.
if external_db; then
  db_url_parts "$SDLC_DATABASE_URL"
  info "dumping the external database $(db_target "$SDLC_DATABASE_URL") to $dump"
  if ! db_client pg_dump -d "$DB_URL_SAFE" "${DUMP_OPTIONS[@]}" | gzip >"$dump"; then
    rm -f "$dump"
    die "pg_dump of the external database failed (see above)"
  fi
else
  info "dumping the database to $dump"
  if ! docker compose exec -T postgres \
    pg_dump -U "${POSTGRES_USER:-sdlc}" -d "${POSTGRES_DB:-sdlc}" "${DUMP_OPTIONS[@]}" |
    gzip >"$dump"; then
    rm -f "$dump"
    die "pg_dump failed"
  fi
fi

# An empty dump is a failure that would otherwise surface only on restore.
size="$(wc -c <"$dump" | tr -d ' ')"
if [ "$size" -lt 1024 ]; then
  rm -f "$dump"
  die "the dump is suspiciously small ($size bytes): $dump"
fi

if [ -z "${SDLC_BLOB_S3_BUCKET:-}" ]; then
  api="$(container_of api)"
  [ -n "$api" ] || die "the api container does not exist: cannot reach the blobs volume"
  info "archiving the blobs volume to $stem.blobs.tar.gz"
  # The service image has no shell: a throwaway container borrows the volume.
  # It runs as root to read every file, then hands the archive to the caller.
  docker run --rm --volumes-from "$api:ro" -v "$dir:/backup" alpine:3 \
    sh -c "tar -czf '/backup/$(basename "$stem").blobs.tar.gz' -C /blobs . &&
           chown $(id -u):$(id -g) '/backup/$(basename "$stem").blobs.tar.gz' &&
           chmod 600 '/backup/$(basename "$stem").blobs.tar.gz'"
fi

find "$dir" -maxdepth 1 -name 'cadence-*.sql.gz' -mtime "+$keep_days" -delete
find "$dir" -maxdepth 1 -name 'cadence-*.blobs.tar.gz' -mtime "+$keep_days" -delete

ok "$(date '+%F %T') $dump ($(du -h "$dump" | cut -f1))"
