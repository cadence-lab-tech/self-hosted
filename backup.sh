#!/usr/bin/env bash
#
# Backup of the database and, when artifact content lives in the `blobs`
# volume (SDLC_BLOB_S3_BUCKET is empty), of that volume; old backups are
# rotated; with BACKUP_S3_BUCKET set the backup is copied to an S3 bucket.
# verify checks that a backup restores, fetch downloads one from the bucket.
#
#   ./backup.sh [--no-upload]
#   ./backup.sh verify [--ignore-version] [FILE]
#   ./backup.sh fetch [NAME]
#
# Files: backups/cadence-<version>-<YYYYmmdd-HHMMSS>.sql.gz (mode 600) and,
# next to it, the same name with .blobs.tar.gz. The version in the name is
# what restore.sh checks. The dump is the same in both database modes: plain
# SQL without owners, privileges and extensions, so a backup of the bundled
# database restores into an external one and back. With an external database
# (CADENCE_DB=external) pg_dump runs in the backup client db-client of
# compose.external-db.yml against SDLC_DATABASE_URL.
#
# Off-machine copy: with BACKUP_S3_BUCKET set, every backup goes to the bucket
# too - the dump, the blobs archive and a .sha256 of both - and the bucket
# keeps the newest BACKUP_S3_KEEP backups (backups before an upgrade count
# too). Only objects named cadence-vX.Y.Z-<date>.* right under the prefix
# are ever deleted. A failed upload exits with status 1 and keeps the local
# backup; the backup of upgrade.sh only warns. --no-upload keeps this backup
# on the machine only. The bucket is reached by /api backup-s3 of the backend
# image, with the keys in its environment, never on a command line.
#
# verify loads a backup into a throwaway PostgreSQL next to the stack - the
# running stack and its database are not touched - checks the schema with
# the images of this version and prints the number of projects, tasks and
# artifacts. It takes FILE, else the newest backup of this version in the
# bucket, else the newest one in backups/. --ignore-version checks a backup
# of another version. Exit status 0 - the backup restores, 1 - it does not.
#
# fetch downloads a backup from the bucket into backups/ - NAME
# (cadence-vX.Y.Z-<date>), else the newest one - and checks its checksums;
# restore it with restore.sh.
#
#   BACKUP_DIR                   where to write, default ./backups
#   KEEP_DAYS                    how long to keep backups on this machine, default 14
#   BACKUP_S3_BUCKET             the bucket of the off-machine copy; empty - none
#   BACKUP_S3_ENDPOINT           e.g. https://s3.eu-central-1.amazonaws.com, default
#                                the AWS endpoint of BACKUP_S3_REGION
#   BACKUP_S3_REGION             default us-east-1
#   BACKUP_S3_PREFIX             a "directory" in the bucket, e.g. cadence/
#   BACKUP_S3_ACCESS_KEY_ID      the keys of the bucket
#   BACKUP_S3_SECRET_ACCESS_KEY
#   BACKUP_S3_PATH_STYLE         true (default) - endpoint/bucket/key; false - bucket.endpoint/key
#   BACKUP_S3_KEEP               how many backups the bucket keeps, default 14
#
# For cron:
#
#   0 3 * * * /path/to/self-hosted/backup.sh >> /path/to/self-hosted/backups/backup.log 2>&1
#   0 5 * * 0 /path/to/self-hosted/backup.sh verify >> /path/to/self-hosted/backups/backup.log 2>&1
#
# Without BACKUP_S3_BUCKET backups stay on this machine: they protect against
# a bad upgrade or a mistaken deletion, not against losing the machine
# (docs/admin.md, "Backups").
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=lib.sh
. ./lib.sh

no_upload=false
ignore_version=false
sub=""
arg=""
while [ $# -gt 0 ]; do
  case "$1" in
  --no-upload) no_upload=true ;;
  --ignore-version) ignore_version=true ;;
  -h | --help) sed -n '3,59p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  -*) die "unknown option: $1" ;;
  *)
    if [ -z "$sub" ] && { [ "$1" = verify ] || [ "$1" = fetch ]; }; then
      sub="$1"
    elif [ -n "$sub" ] && [ -z "$arg" ]; then
      arg="$1"
    else
      die "unexpected argument: $1"
    fi
    ;;
  esac
  shift
done
[ "$sub" = verify ] || [ "$ignore_version" = false ] || die "--ignore-version is an option of verify"
[ -z "$sub" ] || [ "$no_upload" = false ] || die "--no-upload is an option of the backup itself"

# .env first: a COMPOSE_PROJECT_NAME of another installation stops here,
# before Docker is asked anything.
load_env
require_docker

keep_days="${KEEP_DAYS:-14}"
dir="${BACKUP_DIR:-$(pwd)/backups}"
mkdir -p "$dir"
dir="$(cd "$dir" && pwd)"

# rel PATH: PATH relative to this directory when it is inside it.
rel() {
  case "$1" in
  "$(pwd)"/*) printf '%s\n' "${1#"$(pwd)"/}" ;;
  *) printf '%s\n' "$1" ;;
  esac
}

# --- fetch -------------------------------------------------------------------------
fetch_backup() {
  local got rc
  backup_s3_configured ||
    die "BACKUP_S3_BUCKET is not set in .env: there is no bucket to fetch from (docs/admin.md, \"Off-machine copy\")"
  set +e
  got="$(backup_s3 "$dir" get --dir /backups ${arg:+"$arg"})"
  rc=$?
  set -e
  case "$rc" in
  0) ;;
  3) die "nothing to fetch from $(backup_s3_location)" ;;
  *) die "fetching from $(backup_s3_location) failed (see above)" ;;
  esac
  got="$(rel "$dir/$(head -n 1 <<<"$got")")"
  ok "$got; restore it with: ./restore.sh --yes $got"
}

# --- verify ------------------------------------------------------------------------
VERIFY_COUNTS_SQL="SELECT (SELECT count(*) FROM projects) || ' ' || (SELECT count(*) FROM tasks) || ' ' || (SELECT count(*) FROM artifacts)"
verify_tmp=""
scratch=""

# The throwaway container (with its volume) and network go, whatever happened.
verify_cleanup() {
  if [ -n "$scratch" ]; then
    docker rm -f -v "$scratch" >/dev/null 2>&1 || true
    docker network rm "$scratch" >/dev/null 2>&1 || true
  fi
  [ -z "$verify_tmp" ] || rm -rf "$verify_tmp"
}

# image_of SERVICE prints the image of a compose service of the installation.
# Not "config --images SERVICE": it adds the services SERVICE depends on, in
# no fixed order.
image_of() {
  local image
  image="$(docker compose config "$1" | awk -v s="  $1:" '$0 == s { on = 1; next } on && /^  [^ ]/ { exit }
    on && /^    image: / { sub(/^    image: /, ""); gsub(/"/, ""); print; exit }')" || true
  [ -n "$image" ] || die "cannot tell the image of $1: docker compose config $1 failed (see above)"
  printf '%s\n' "$image"
}

# json_field JSON NAME: a top-level field of the indented JSON of dbcheck.
json_field() {
  sed -n "s/^  \"$2\": \"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}\$/\1/p" <<<"$1" | head -n 1
}

verify_backup() {
  local dump="" from="" got rc name backup_version service pg_image api_image label start json
  local schema schema_version image_version counts projects tasks artifacts blobs listing files where
  check_db_mode
  trap verify_cleanup EXIT
  trap 'exit 130' INT TERM
  if [ -n "$arg" ]; then
    [ -f "$arg" ] || die "no such file: $arg"
    case "$arg" in
    *.sql.gz) ;;
    *) die "$arg is not a database dump (*.sql.gz) made by backup" ;;
    esac
    dump="$arg"
    from="$arg"
  elif backup_s3_configured; then
    verify_tmp="$(mktemp -d "$dir/.verify-XXXXXX")"
    set +e
    got="$(backup_s3 "$verify_tmp" get --dir /backups --version "$CADENCE_VERSION")"
    rc=$?
    set -e
    case "$rc" in
    0)
      dump="$verify_tmp/$(head -n 1 <<<"$got")"
      from="$(backup_s3_location)"
      ;;
    3) warn "no backup of $CADENCE_VERSION in $(backup_s3_location): verifying the newest local one" ;;
    *) die "fetching the backup from $(backup_s3_location) failed (see above)" ;;
    esac
  fi
  if [ -z "$dump" ]; then
    dump="$(find "$dir" -maxdepth 1 -name "cadence-$CADENCE_VERSION-*.sql.gz" | sort | tail -n 1)"
    if [ -z "$dump" ]; then
      where="$(rel "$dir")/"
      if backup_s3_configured; then where="$(backup_s3_location) or $where"; fi
      die "nothing to verify: no backup of $CADENCE_VERSION in $where"
    fi
    from="$(rel "$dump")"
  fi
  name="$(basename "$dump")"

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
  Pass --ignore-version to check it with the images of $CADENCE_VERSION, or put the package files of $backup_version in place first:
    $(package_files_hint "$backup_version")"
  fi

  info "verifying $name ($(du -h "$dump" | cut -f1 | tr -d ' ')) from $from"
  service=postgres
  if external_db; then service=db-client; fi
  pg_image="$(image_of "$service")"
  api_image="$(image_of api)"
  scratch="$COMPOSE_PROJECT_NAME-verify-$(od -An -N4 -tx1 /dev/urandom | tr -d ' \n')"
  label="com.cadence.verify=$COMPOSE_PROJECT_NAME"

  info "loading it into a throwaway PostgreSQL ($pg_image); the stack keeps running"
  docker network create --label "$label" "$scratch" >/dev/null ||
    die "docker network create $scratch failed (see above)"
  docker run -d --name "$scratch" --network "$scratch" --label "$label" \
    -e POSTGRES_HOST_AUTH_METHOD=trust -e POSTGRES_DB=verify "$pg_image" >/dev/null ||
    die "starting the throwaway PostgreSQL failed (see above)"
  # Over TCP: while it initializes, the image runs the server on the socket only.
  for _ in $(seq 1 60); do
    docker exec "$scratch" pg_isready -q -h 127.0.0.1 -U postgres -d verify >/dev/null 2>&1 && break
    sleep 1
  done
  docker exec "$scratch" pg_isready -q -h 127.0.0.1 -U postgres -d verify >/dev/null 2>&1 ||
    die "the throwaway PostgreSQL did not become ready"
  docker exec "$scratch" psql -X -q -v ON_ERROR_STOP=1 -U postgres -d verify \
    -c "CREATE EXTENSION IF NOT EXISTS vector" -c "CREATE EXTENSION IF NOT EXISTS pgcrypto" >/dev/null ||
    die "creating the extensions in the throwaway PostgreSQL failed (see above)"

  start=$SECONDS
  if ! gunzip -c "$dump" | docker exec -i "$scratch" psql -X -q -v ON_ERROR_STOP=1 -U postgres -d verify >/dev/null; then
    die "backup $name does not restore: loading it failed (the error of psql or gzip is above)"
  fi
  ok "loaded in $((SECONDS - start))s"

  # The URL names the throwaway server only; it has no password (trust on
  # its own network).
  json="$(SDLC_DATABASE_URL="postgres://postgres@$scratch:5432/verify?sslmode=disable" \
    docker run --rm --network "$scratch" -e SDLC_DATABASE_URL "$api_image" dbcheck --json 2>/dev/null || true)"
  schema="$(json_field "$json" schema)"
  schema_version="$(json_field "$json" schema_version)"
  image_version="$(json_field "$json" image_schema_version)"
  if [ "$(json_field "$json" ok)" != true ] || [ "$schema" != cadence ]; then
    SDLC_DATABASE_URL="postgres://postgres@$scratch:5432/verify?sslmode=disable" \
      docker run --rm --network "$scratch" -e SDLC_DATABASE_URL "$api_image" dbcheck || true
    die "backup $name does not restore: the images of $CADENCE_VERSION do not accept its schema (see above)"
  fi
  schema_version="${schema_version:-0}"
  if [ "$schema_version" = "$image_version" ]; then
    ok "schema $schema_version: the schema of the images of $CADENCE_VERSION"
  elif [ "$ignore_version" = true ]; then
    warn "schema $schema_version: the images of $CADENCE_VERSION apply up to $image_version (--ignore-version)"
  else
    die "backup $name does not match its version: schema $schema_version, the images of $CADENCE_VERSION apply up to $image_version"
  fi

  counts="$(docker exec "$scratch" psql -X -q -At -U postgres -d verify -c "$VERIFY_COUNTS_SQL" || true)"
  read -r projects tasks artifacts <<<"$counts" || true
  if ! [[ "${artifacts:-}" =~ ^[0-9]+$ ]]; then
    die "backup $name does not restore: counting its projects, tasks and artifacts failed (see above)"
  fi

  blobs="${dump%.sql.gz}.blobs.tar.gz"
  if [ -f "$blobs" ]; then
    listing="$(tar -tvzf "$blobs" 2>&1)" || die "the blobs archive $(basename "$blobs") is damaged: $(tail -n 1 <<<"$listing")"
    files="$(grep -c '^-' <<<"$listing" || true)"
    ok "blobs archive $(basename "$blobs"): $files files"
  elif [ -z "${SDLC_BLOB_S3_BUCKET:-}" ]; then
    warn "no $(basename "$blobs") next to the dump: this backup has no blobs volume"
  fi
  ok "backup $name restores: schema $schema_version, $projects projects, $tasks tasks, $artifacts artifacts"
}

case "$sub" in
fetch)
  fetch_backup
  exit 0
  ;;
verify)
  verify_backup
  exit 0
  ;;
esac

# --- backup ------------------------------------------------------------------------
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

if [ "$no_upload" = false ] && backup_s3_configured; then
  backup_upload "$dump" || die "$(upload_failed "$dump")"
fi
