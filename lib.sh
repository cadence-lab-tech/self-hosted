# shellcheck shell=bash
#
# Shared helpers of install.sh, upgrade.sh, backup.sh and restore.sh. Not a
# command: the scripts source it after changing into their own directory.

# Backups and .env hold secrets: nothing the scripts create is meant for
# other users of the machine.
umask 077

say() { printf '%s\n' "$*"; }
info() { printf '▸ %s\n' "$*"; }
ok() { printf '✓ %s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }
die() {
  printf '✗ %s\n' "$*" >&2
  exit 1
}

# require_docker checks for Docker with the compose v2 plugin and a daemon
# that answers.
require_docker() {
  command -v docker >/dev/null 2>&1 ||
    die "Docker is not installed. Install Docker Engine with the compose plugin: https://docs.docker.com/engine/install/"
  docker compose version >/dev/null 2>&1 ||
    die "Docker Compose v2 is missing ('docker compose version' failed). Install the docker-compose-plugin package: https://docs.docker.com/compose/install/linux/"
  docker info >/dev/null 2>&1 ||
    die "The Docker daemon does not answer. Start it (systemctl start docker) or run as a user in the docker group."
}

# load_version reads VERSION and exports it as CADENCE_VERSION: the single
# source of the image version for compose.
load_version() {
  [ -f VERSION ] || die "no VERSION file in $(pwd)"
  CADENCE_VERSION="$(tr -d '[:space:]' <VERSION)"
  valid_version "$CADENCE_VERSION" || die "VERSION holds '$CADENCE_VERSION', expected vX.Y.Z"
  export CADENCE_VERSION
}

valid_version() {
  [[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
}

# version_lt A B: A is an older version than B.
version_lt() {
  [ "$1" != "$2" ] && [ "$(printf '%s\n%s\n' "${1#v}" "${2#v}" | sort -t. -k1,1n -k2,2n -k3,3n | head -n1)" = "${1#v}" ]
}

# load_env exports .env into the script, so the scripts read the same values
# compose does.
load_env() {
  [ -f .env ] || die "no .env in $(pwd): run ./install.sh first"
  # The installation name comes from .env alone: the variable of the caller
  # is only compared with it (load_name).
  local caller_name="${COMPOSE_PROJECT_NAME:-}"
  unset COMPOSE_PROJECT_NAME
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
  # The version always comes from VERSION, even if .env sets it.
  load_version
  load_name "$caller_name"
}

# --- installation name -------------------------------------------------------------
# The name of the installation on this machine is its Docker Compose project:
# the prefix of its containers, volumes and network. It has nothing to do with
# the projects inside Cadence Lab. install.sh writes it to .env as
# COMPOSE_PROJECT_NAME; an installation made before v0.7.1 has no such line
# and is "cadence", the name in docker-compose.yml. clab server follows the
# same rule (cmd/clab/server_name.go of the backend) with the same messages.
CADENCE_DEFAULT_NAME=cadence

# valid_name NAME: the rule of compose for a project name.
valid_name() {
  [[ "$1" =~ ^[a-z0-9][a-z0-9_-]*$ ]]
}

# name_rule prints the rule valid_name checks, for the refusals.
name_rule() {
  say "lowercase letters, digits, '-' and '_', starting with a letter or a digit"
}

# load_name CALLER: after .env is sourced, works out the name of this
# installation (COMPOSE_PROJECT_NAME of .env, else the default) and exports
# it, so that every docker compose of the script works with this installation
# only. CALLER - COMPOSE_PROJECT_NAME of the environment the script was run
# with - must be empty or the same name: another one means another
# installation, and the script refuses before it touches Docker.
load_name() {
  local caller="$1" name="${COMPOSE_PROJECT_NAME:-}" from=".env"
  if [ -z "$name" ]; then
    name="$CADENCE_DEFAULT_NAME"
    from="default"
  fi
  valid_name "$name" ||
    die "COMPOSE_PROJECT_NAME in .env is '$name', which is not a valid installation name: $(name_rule)"
  if [ -n "$caller" ] && [ "$caller" != "$name" ]; then
    die "$(name_mismatch "$caller" "$name" "$from" "$(pwd)")"
  fi
  export COMPOSE_PROJECT_NAME="$name"
}

# name_mismatch CALLER NAME FROM DIR prints the refusal for COMPOSE_PROJECT_NAME
# of the environment that names another installation than the one in DIR.
name_mismatch() {
  local caller="$1" name="$2" from="$3" dir="$4"
  if [ "$from" = .env ]; then
    printf '%s\n' "COMPOSE_PROJECT_NAME is '$caller' in the environment, but the installation in $dir is '$name' (COMPOSE_PROJECT_NAME in its .env).
  Nothing was done: '$caller' is another installation. Run the command without the variable:
    unset COMPOSE_PROJECT_NAME"
  else
    printf '%s\n' "COMPOSE_PROJECT_NAME is '$caller' in the environment, but the installation in $dir is '$name' (its .env has no COMPOSE_PROJECT_NAME: the default).
  Nothing was done. If '$caller' is another installation, run the command without the variable:
    unset COMPOSE_PROJECT_NAME
  If this installation was installed as '$caller' (before v0.7.1 the name was not kept in .env), add the name to its .env once:
    echo COMPOSE_PROJECT_NAME=$caller >> $dir/.env"
  fi
}

# name_in_use NAME prints where Docker on this machine already has the
# compose project NAME: the directory of an installation (from the labels of
# its containers) or "volumes" when only its volumes are left. Prints nothing
# when the name is free; fails when Docker cannot be asked.
name_in_use() {
  local name="$1" containers volumes dir
  containers="$(docker ps -a -q --filter "label=com.docker.compose.project=$name")" || return 1
  volumes="$(docker volume ls -q --filter "label=com.docker.compose.project=$name")" || return 1
  if [ -n "$containers" ]; then
    dir="$(docker inspect -f '{{index .Config.Labels "com.docker.compose.project.working_dir"}}' "$(head -n 1 <<<"$containers")" 2>/dev/null || true)"
    say "${dir:-containers}"
  elif [ -n "$volumes" ]; then
    say volumes
  fi
}

# container_of SERVICE prints the container ID of a compose service, running
# or stopped.
container_of() {
  docker compose ps -a -q "$1" 2>/dev/null | head -n1
}

# running SERVICE: the service has a running container.
running() {
  [ -n "$(docker compose ps -q --status running "$1" 2>/dev/null)" ]
}

# wait_ready [SECONDS] waits until the API reports ready (its healthcheck is
# /readyz: the service is up and the database answers) and the UI answers
# through Caddy.
wait_ready() {
  local timeout="${1:-180}" waited=0 api health
  while [ "$waited" -lt "$timeout" ]; do
    api="$(container_of api)"
    health=""
    [ -n "$api" ] && health="$(docker inspect -f '{{.State.Health.Status}}' "$api" 2>/dev/null || true)"
    if [ "$health" = healthy ] &&
      docker compose exec -T caddy wget -q -O /dev/null http://ui/ >/dev/null 2>&1; then
      return 0
    fi
    sleep 3
    waited=$((waited + 3))
  done
  return 1
}

# public_url prints the address people open in the browser.
public_url() {
  case "${CADENCE_MODE:-tls}" in
  proxy) say "http://${CADENCE_HTTP_ADDR:-127.0.0.1:8080} (behind your proxy: its public address)" ;;
  *) say "https://${SDLC_DOMAIN}" ;;
  esac
}

# check_mode verifies that CADENCE_MODE and COMPOSE_FILE agree.
check_mode() {
  case "${CADENCE_MODE:-tls}" in
  tls | proxy) ;;
  *) die "CADENCE_MODE in .env is '${CADENCE_MODE}', expected tls or proxy" ;;
  esac
  if [ "${CADENCE_MODE:-tls}" = tls ] && { [ -z "${SDLC_DOMAIN:-}" ] || [ -z "${ACME_EMAIL:-}" ]; }; then
    die "CADENCE_MODE=tls needs SDLC_DOMAIN and ACME_EMAIL in .env"
  fi
  case "${COMPOSE_FILE:-}" in
  *"compose.${CADENCE_MODE:-tls}.yml"*) ;;
  *) die "COMPOSE_FILE in .env ('${COMPOSE_FILE:-}') does not include compose.${CADENCE_MODE:-tls}.yml for CADENCE_MODE=${CADENCE_MODE:-tls}" ;;
  esac
  check_db_mode
}

# --- database ----------------------------------------------------------------------
# CADENCE_DB in .env: bundled - the postgres container of the stack; external
# - your own PostgreSQL at SDLC_DATABASE_URL, with compose.external-db.yml in
# COMPOSE_FILE (docs/admin.md, "External PostgreSQL"). clab server follows the
# same rules (cmd/clab/server_db.go of the backend) with the same messages.
EXTERNAL_DB_FILE=compose.external-db.yml
# Secrets in files (docs/admin.md, "Secrets in files"): Docker secrets of the
# bundled database password and the administrator token. In COMPOSE_FILE it
# goes before compose.external-db.yml, which turns the password file of the
# bundled database off again.
SECRETS_FILE=compose.secrets.yml
# depends_on.required of compose.external-db.yml came with Compose 2.20.
EXTERNAL_DB_MIN_COMPOSE=2.20.0
# pg_dump options of every backup, in both modes: a dump without owners,
# privileges and the extensions loads into an empty database as its owner,
# no superuser needed - the bundled one into an external one and back. The
# extensions are created before the load (restore.sh).
# shellcheck disable=SC2034 # used by backup.sh, which sources lib.sh
DUMP_OPTIONS=(--clean --if-exists --no-owner --no-privileges --exclude-extension=vector --exclude-extension=pgcrypto)

external_db() {
  [ "${CADENCE_DB:-bundled}" = external ]
}

# check_db_mode verifies that CADENCE_DB, SDLC_DATABASE_URL (or
# SDLC_DATABASE_URL_FILE) and COMPOSE_FILE agree. It reads no secret file:
# db_conn does, where the URL is needed.
check_db_mode() {
  local listed=false cf
  case ":${COMPOSE_FILE:-}:" in *":$EXTERNAL_DB_FILE:"*) listed=true ;; esac
  [ -z "${SDLC_DATABASE_URL:-}" ] || [ -z "${SDLC_DATABASE_URL_FILE:-}" ] ||
    die "both SDLC_DATABASE_URL and SDLC_DATABASE_URL_FILE are set in .env: keep one of them"
  case "${CADENCE_DB:-bundled}" in
  bundled)
    [ "$listed" = false ] ||
      die "COMPOSE_FILE in .env ('${COMPOSE_FILE:-}') lists $EXTERNAL_DB_FILE, but CADENCE_DB is bundled: set CADENCE_DB=external with SDLC_DATABASE_URL, or drop the file from COMPOSE_FILE"
    ;;
  external)
    [ -n "${SDLC_DATABASE_URL:-}${SDLC_DATABASE_URL_FILE:-}" ] ||
      die "CADENCE_DB=external needs SDLC_DATABASE_URL or SDLC_DATABASE_URL_FILE in .env"
    [ "$listed" = true ] ||
      die "COMPOSE_FILE in .env ('${COMPOSE_FILE:-}') does not include $EXTERNAL_DB_FILE for CADENCE_DB=external: add it after compose.${CADENCE_MODE:-tls}.yml"
    cf=":${COMPOSE_FILE:-}:"
    case ":${cf#*":$EXTERNAL_DB_FILE:"}" in
    *":$SECRETS_FILE:"*)
      die "COMPOSE_FILE in .env ('${COMPOSE_FILE:-}') lists $SECRETS_FILE after $EXTERNAL_DB_FILE: put it before, otherwise the password file of the bundled database reaches the service"
      ;;
    esac
    ;;
  *) die "CADENCE_DB in .env is '${CADENCE_DB}', expected bundled or external" ;;
  esac
}

# --- secrets in files --------------------------------------------------------------
# A secret X of the service may come as X_FILE: the path of a file inside the
# containers (docs/admin.md, "Secrets in files"). The scripts read such a file
# on this machine only where they need the value - the URL and the password
# of an external database for the backup client - and know only the files of
# ./secrets: /secrets/<file> (the directory mounted into api, worker and
# db-client) and /run/secrets/<name> (Docker secrets, whose file is
# ./secrets/<name> in compose.secrets.yml and in the sample of admin.md).
# clab server follows the same rules (cmd/clab/server_db.go of the backend).

# host_secret_path NAME PATH sets SECRET_PATH - the file of PATH (the value of
# NAME) on this machine - or refuses a path outside ./secrets.
host_secret_path() {
  local name="$1" p="$2" rel=""
  case "$p" in
  /secrets/*) rel="${p#/secrets/}" ;;
  /run/secrets/*) rel="${p#/run/secrets/}" ;;
  esac
  case "/$rel/" in //* | */../* | */./* | *//*) rel="" ;; esac
  [ -n "$rel" ] ||
    die "$name is '$p': the scripts read this file on this machine and know only the files in secrets/ of the installation (/secrets/<file> or /run/secrets/<name> in the containers). Move the file into secrets/ and set $name=/secrets/<file> (docs/admin.md, \"Secrets in files\")"
  SECRET_PATH="$PWD/secrets/$rel"
}

# read_secret_file NAME PATH sets SECRET_VALUE to the content of the file
# without the trailing newlines (\n, \r\n). An error names NAME and the file,
# never the content.
read_secret_file() {
  local name="$1" value
  host_secret_path "$name" "$2"
  [ ! -d "$SECRET_PATH" ] || die "$name: $SECRET_PATH is a directory, not a file"
  [ -e "$SECRET_PATH" ] || die "$name: stat $SECRET_PATH: no such file or directory"
  [ -r "$SECRET_PATH" ] || die "$name: open $SECRET_PATH: permission denied (it must be readable by $(id -un), docs/admin.md, \"Secrets in files\")"
  value="$(cat "$SECRET_PATH" && printf x)" || die "$name: cannot read $SECRET_PATH"
  value="${value%x}"
  while [[ "$value" == *$'\n' || "$value" == *$'\r' ]]; do value="${value%?}"; done
  [ -n "$value" ] || die "$name: $SECRET_PATH is empty"
  SECRET_VALUE="$value"
}

# compose_version prints the version of Docker Compose without the leading v
# and any suffix (2.38.1-desktop.1 -> 2.38.1).
compose_version() {
  docker compose version --short 2>/dev/null | sed 's/^v//; s/[-+].*//'
}

# require_compose_for_external_db: the external mode needs a newer Compose
# than the bundled one.
require_compose_for_external_db() {
  local v
  v="$(compose_version)"
  if [ -z "$v" ] || version_lt "v$v" "v$EXTERNAL_DB_MIN_COMPOSE"; then
    die "the external database needs Docker Compose $EXTERNAL_DB_MIN_COMPOSE or newer ($EXTERNAL_DB_FILE uses depends_on.required); this machine has ${v:-an unknown version}.
  Update the docker-compose-plugin package: https://docs.docker.com/compose/install/linux/"
  fi
}

# url_decode TEXT decodes %XX of a URL.
url_decode() {
  printf '%b' "${1//%/\\x}"
}

# db_url_parts URL sets DB_URL_SAFE - the URL without the password - and
# DB_PASSWORD, decoded. The backup client gets the password as PGPASSWORD:
# a command line is visible to every user of the machine (ps).
db_url_parts() {
  local re='^(postgres(ql)?://)([^:@/?#]*)(:([^@/?#]*))?@(.*)$'
  DB_URL_SAFE="$1"
  DB_PASSWORD=""
  if [[ "$1" =~ $re ]]; then
    DB_URL_SAFE="${BASH_REMATCH[1]}${BASH_REMATCH[3]}@${BASH_REMATCH[6]}"
    DB_PASSWORD="$(url_decode "${BASH_REMATCH[5]}")"
  fi
}

# db_target URL prints host:port/database of the URL - what the scripts name,
# never the password.
db_target() {
  local s="${1#*://}"
  s="${s##*@}"
  printf '%s\n' "${s%%\?*}"
}

# db_label prints the external database for the messages: host:port/database
# of SDLC_DATABASE_URL, or the file of SDLC_DATABASE_URL_FILE - which is not
# read for a message.
db_label() {
  if [ -n "${SDLC_DATABASE_URL:-}" ] || [ -z "${SDLC_DATABASE_URL_FILE:-}" ]; then
    db_target "${SDLC_DATABASE_URL:-}"
  else
    printf '(URL in %s)\n' "$SDLC_DATABASE_URL_FILE"
  fi
}

# db_conn sets DB_URL_SAFE and DB_PASSWORD of the external database: from
# SDLC_DATABASE_URL or the file of SDLC_DATABASE_URL_FILE, the password from
# the URL or from the file of SDLC_DATABASE_PASSWORD_FILE. Both forms of one
# value refuse, like the service does.
db_conn() {
  local url="${SDLC_DATABASE_URL:-}"
  if [ -n "${SDLC_DATABASE_URL_FILE:-}" ]; then
    [ -z "$url" ] || die "both SDLC_DATABASE_URL and SDLC_DATABASE_URL_FILE are set in .env: keep one of them"
    read_secret_file SDLC_DATABASE_URL_FILE "$SDLC_DATABASE_URL_FILE"
    url="$SECRET_VALUE"
  fi
  [ -n "$url" ] || die "CADENCE_DB=external needs SDLC_DATABASE_URL or SDLC_DATABASE_URL_FILE in .env"
  db_url_parts "$url"
  if [ -n "${SDLC_DATABASE_PASSWORD_FILE:-}" ]; then
    [[ "$url" =~ ^postgres(ql)?://[^/?#]+ ]] ||
      die "SDLC_DATABASE_PASSWORD_FILE needs SDLC_DATABASE_URL as a URL postgres://USER@HOST:PORT/DATABASE; the URL does not parse as one"
    [ -z "$DB_PASSWORD" ] ||
      die "both SDLC_DATABASE_PASSWORD_FILE and a password in the URL of SDLC_DATABASE_URL (or SDLC_DATABASE_URL_FILE) are set: keep one of them"
    read_secret_file SDLC_DATABASE_PASSWORD_FILE "$SDLC_DATABASE_PASSWORD_FILE"
    DB_PASSWORD="$SECRET_VALUE"
  fi
}

# db_check [ARGS...]: the check of the database in the backend image
# (/api dbcheck) - the driver and the TLS of the service: the URL, the
# connection, the server version, the extensions, the privileges, the schema.
db_check() {
  docker compose run --rm --no-deps -T api dbcheck "$@"
}

# db_client ARGS...: a command of the backup client (db-client of
# compose.external-db.yml) with the password of the database (db_conn) in
# PGPASSWORD; the URL on its command line is DB_URL_SAFE.
db_client() {
  db_conn
  PGPASSWORD="$DB_PASSWORD" docker compose run --rm --no-deps -T -e PGPASSWORD db-client "$@"
}

# db_client_check: the backup client (libpq) connects with the same URL - a
# URL the service takes but pg_dump does not would surface only at the first
# backup.
db_client_check() {
  db_conn
  db_client psql -X -q -At -d "$DB_URL_SAFE" -c 'SELECT 1' >/dev/null
}

# db_reset_sql prints what restore.sh runs before the dump in an external
# database: the extensions (created if this role may, kept if they exist)
# and no objects of the application left in the schema public - without
# DROP DATABASE and without the database postgres, which a role of a managed
# server may not touch. The list is collected first: casting a dropped
# function to text would fail.
db_reset_sql() {
  cat <<'SQL'
SET client_min_messages = warning;
CREATE EXTENSION IF NOT EXISTS vector;
CREATE EXTENSION IF NOT EXISTS pgcrypto;
DO $cadence$
DECLARE
  stmts text[];
  stmt text;
BEGIN
  SELECT coalesce(array_agg(s ORDER BY o), '{}') INTO stmts FROM (
    SELECT 1 AS o, format('DROP %s IF EXISTS public.%I CASCADE',
             CASE c.relkind WHEN 'v' THEN 'VIEW' WHEN 'm' THEN 'MATERIALIZED VIEW'
               WHEN 'S' THEN 'SEQUENCE' WHEN 'f' THEN 'FOREIGN TABLE' ELSE 'TABLE' END, c.relname) AS s
    FROM pg_class c JOIN pg_namespace n ON n.oid = c.relnamespace
    WHERE n.nspname = 'public' AND c.relkind IN ('r', 'p', 'v', 'm', 'S', 'f')
      AND NOT EXISTS (SELECT 1 FROM pg_depend d
                      WHERE d.classid = 'pg_class'::regclass AND d.objid = c.oid AND d.deptype = 'e')
    UNION ALL
    SELECT 2, format('DROP %s IF EXISTS %s CASCADE',
             CASE p.prokind WHEN 'p' THEN 'PROCEDURE' WHEN 'a' THEN 'AGGREGATE' ELSE 'FUNCTION' END,
             p.oid::regprocedure)
    FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'public' AND p.prokind IN ('f', 'p', 'a')
      AND NOT EXISTS (SELECT 1 FROM pg_depend d
                      WHERE d.classid = 'pg_proc'::regclass AND d.objid = p.oid AND d.deptype = 'e')
    UNION ALL
    SELECT 3, format('DROP %s IF EXISTS public.%I CASCADE', CASE t.typtype WHEN 'd' THEN 'DOMAIN' ELSE 'TYPE' END, t.typname)
    FROM pg_type t JOIN pg_namespace n ON n.oid = t.typnamespace
    WHERE n.nspname = 'public' AND t.typtype IN ('c', 'd', 'e', 'r')
      AND (t.typrelid = 0 OR (SELECT c.relkind FROM pg_class c WHERE c.oid = t.typrelid) = 'c')
      AND NOT EXISTS (SELECT 1 FROM pg_depend d
                      WHERE d.classid = 'pg_type'::regclass AND d.objid = t.oid AND d.deptype = 'e')
  ) x;
  FOREACH stmt IN ARRAY stmts LOOP
    EXECUTE stmt;
  END LOOP;
END
$cadence$;
SQL
}

# --- off-machine backups -----------------------------------------------------------
# BACKUP_S3_* in .env: a copy of every backup in an S3 bucket - the dump, the
# blobs archive and a .sha256 of both - and the newest BACKUP_S3_KEEP backups
# kept there (docs/admin.md, "Off-machine copy"). The bucket is reached by
# /api backup-s3 of the backend image (v0.10.0+): the host needs no aws or
# rclone, and no other image is pulled. clab server follows the same rules
# (cmd/clab/server_offsite.go of the backend) with the same messages.
# The keys may come as files (BACKUP_S3_*_FILE, a path inside the container):
# /api backup-s3 reads them as the caller.
BACKUP_S3_VARS=(BACKUP_S3_BUCKET BACKUP_S3_ENDPOINT BACKUP_S3_REGION BACKUP_S3_PREFIX
  BACKUP_S3_ACCESS_KEY_ID BACKUP_S3_ACCESS_KEY_ID_FILE BACKUP_S3_SECRET_ACCESS_KEY BACKUP_S3_SECRET_ACCESS_KEY_FILE
  BACKUP_S3_PATH_STYLE BACKUP_S3_KEEP)

backup_s3_configured() {
  [ -n "${BACKUP_S3_BUCKET:-}" ]
}

# backup_s3_location prints s3://bucket/prefix/ for the messages.
backup_s3_location() {
  local prefix
  prefix="$(printf '%s' "${BACKUP_S3_PREFIX:-}" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//; s:^/*::; s:/*$::')"
  printf 's3://%s/%s\n' "${BACKUP_S3_BUCKET:-}" "${prefix:+$prefix/}"
}

# backup_s3 DIR ARGS...: /api backup-s3 of the backend image in a throwaway
# container, DIR mounted as /backups, run as the caller (backups are mode 600
# of the caller; the image is nonroot). The variables go by name only: their
# values reach the container through the environment of docker, never a
# command line (ps shows those to every user of the machine).
backup_s3() {
  local dir="$1" env=() v
  shift
  for v in "${BACKUP_S3_VARS[@]}"; do env+=(-e "$v"); done
  docker compose run --rm --no-deps -T --user "$(id -u):$(id -g)" "${env[@]}" -v "$dir:/backups" api backup-s3 "$@"
}

# backup_upload DUMP: the copy of DUMP (and the blobs archive next to it) in
# the bucket, then the retention of BACKUP_S3_KEEP. False when it failed;
# the local backup stays either way.
backup_upload() {
  local dump="$1" dir
  # An absolute path: a bare name after -v is a volume, not a directory.
  dir="$(cd "$(dirname "$dump")" && pwd)"
  info "uploading $(basename "$dump") to $(backup_s3_location)"
  backup_s3 "$dir" put "/backups/$(basename "$dump")"
}

# upload_failed DUMP prints the refusal of a failed upload.
upload_failed() {
  printf '%s\n' "the off-machine copy of $(basename "$1") to $(backup_s3_location) failed (see above); the local backup is kept: $1"
}

# --- releases ----------------------------------------------------------------------
# Every release vX.Y.Z of this repository carries four assets (the bundle
# from v0.9.0 on):
#
#   cadence-self-hosted-vX.Y.Z.tar.gz   the package: the files of this
#                                       directory without ci/ and .github/,
#                                       and package.sha256 - the sha256 of
#                                       each of them, against which upgrade.sh
#                                       finds local edits
#   checksums.txt                       sha256 of the package and the installer
#   checksums.txt.sigstore.json         the signature of checksums.txt
#                                       (cosign keyless, see "signatures")
#   get-cadence.sh                      the one-line installer
#
# The names are a contract: the scripts of every later version, clab and
# the Helm chart download them by these names. Do not rename them.
#
# CADENCE_RELEASES_URL points the scripts at a mirror of the releases (or a
# directory, file:///path) with the same layout: download/vX.Y.Z/<asset>
# and latest/download/<asset>.
CADENCE_RELEASES_DEFAULT=https://github.com/cadence-lab-tech/self-hosted/releases
# shellcheck disable=SC2034 # used by the scripts that source lib.sh
PACKAGE_MANIFEST=package.sha256

releases_url() {
  local url="${CADENCE_RELEASES_URL:-$CADENCE_RELEASES_DEFAULT}"
  printf '%s\n' "${url%/}"
}

# package_name VERSION prints the name of the package archive of VERSION.
package_name() {
  printf 'cadence-self-hosted-%s.tar.gz\n' "$1"
}

# sha256_of FILE prints the sha256 of FILE.
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}

# fetch URL FILE downloads URL into FILE; false when there is no such file.
fetch() {
  curl -fsL --retry 2 -o "$2" "$1"
}

# latest_version prints the version of the latest release: the name of the
# package in its checksums.txt (GitHub redirects latest/download/ to the
# latest release; a mirror keeps a copy there).
latest_version() {
  local tmp version
  tmp="$(mktemp)"
  if ! fetch "$(releases_url)/latest/download/checksums.txt" "$tmp"; then
    rm -f "$tmp"
    return 1
  fi
  version="$(sed -n 's/^[0-9a-f]\{64\}  cadence-self-hosted-\(v[0-9]*\.[0-9]*\.[0-9]*\)\.tar\.gz$/\1/p' "$tmp" | head -n 1)"
  rm -f "$tmp"
  [ -n "$version" ] && printf '%s\n' "$version"
}

# download_package VERSION DIR downloads the package of VERSION with its
# checksums.txt into DIR and verifies the checksum. Exit status: 0 - done,
# 2 - there is no such release (or it has no package), 3 - the checksum does
# not match.
download_package() {
  local version="$1" dir="$2" base name want
  base="$(releases_url)/download/$version"
  name="$(package_name "$version")"
  fetch "$base/checksums.txt" "$dir/checksums.txt" || return 2
  fetch "$base/$name" "$dir/$name" || return 2
  want="$(awk -v f="$name" '$2 == f {print $1}' "$dir/checksums.txt")"
  if [ -z "$want" ] || [ "$want" != "$(sha256_of "$dir/$name")" ]; then
    return 3
  fi
}

# The first version released with a package. Earlier ones (v0.5.x) were
# installed as git clones and have no package in their release.
FIRST_PACKAGE_VERSION=v0.6.0
# The repository of the package, for the source archive of a tag.
CADENCE_REPO_URL=https://github.com/cadence-lab-tech/self-hosted

# git_clone: this directory is a working git clone (git is there and knows it).
git_clone() {
  [ -e .git ] && command -v git >/dev/null 2>&1 && git rev-parse --git-dir >/dev/null 2>&1
}

# package_files_hint VERSION prints the command that puts the package files
# of VERSION into this directory: the copy upgrade.sh kept in backups/, or
# the package of the release. A version before FIRST_PACKAGE_VERSION has no
# package: its files come from git in a clone (--force: the files of later
# packages differ from the tag), or else from the source archive of its tag
# on GitHub - mirrors carry only releases, so CADENCE_RELEASES_URL does not
# apply to it.
package_files_hint() {
  local version="$1" saved name checkout
  saved="$(find "${BACKUP_DIR:-backups}" -maxdepth 1 -name "package-$version-*.tar.gz" -print 2>/dev/null | sort | tail -n 1)"
  checkout="git -c advice.detachedHead=false checkout --force $version"
  if [ -n "$saved" ]; then
    printf 'tar -xpzf %s\n' "$saved"
  elif ! version_lt "$version" "$FIRST_PACKAGE_VERSION"; then
    name="$(package_name "$version")"
    printf 'curl -fsSLO %s/download/%s/%s && tar -xpzf %s && rm %s\n' "$(releases_url)" "$version" "$name" "$name" "$name"
  elif git_clone; then
    if git rev-parse -q --verify "refs/tags/$version^{commit}" >/dev/null 2>&1; then
      printf '%s\n' "$checkout"
    else
      printf 'git fetch --tags %s && %s\n' "${CADENCE_GIT_REMOTE:-origin}" "$checkout"
    fi
  else
    printf 'curl -fsSL %s/archive/refs/tags/%s.tar.gz | tar -xpzf - --strip-components=1\n' "$CADENCE_REPO_URL" "$version"
  fi
}

# --- signatures --------------------------------------------------------------------
# From v0.9.0 the release workflows sign checksums.txt of the package and
# both images with cosign keyless (docs/admin.md, "Verifying a release").
# CADENCE_VERIFY - from the environment, for an installation from its .env
# over the environment, like every variable of the package - says what the
# scripts do with the signatures before they install or upgrade:
#
#   auto     the default: verify with cosign 3.x when it is installed, warn
#            once when it is not; a signature that does not verify stops
#   require  also stop on no cosign, an unsigned version (before v0.9.0), an
#            image without a digest and an unreachable ghcr.io
#   off      no verification, one line says so (a closed network)
#
# cosign is the external tool from PATH; one older than 3.x counts as none.
# get-cadence.sh (POSIX sh, before the package is unpacked) and clab server
# (cmd/clab/server_verify.go of the backend) follow the same rules with the
# same messages.
VERIFY_FIRST_SIGNED=v0.9.0
VERIFY_ISSUER=https://token.actions.githubusercontent.com
VERIFY_SOURCE=https://github.com/cadence-lab-tech
VERIFY_REGISTRY=ghcr.io/cadence-lab-tech
VERIFY_PACKAGE_IDENTITY=$VERIFY_SOURCE/self-hosted/.github/workflows/release.yml@refs/heads/main
VERIFY_BUNDLE=checksums.txt.sigstore.json
VERIFY_IMAGES="sdlc-pipeline-backend sdlc-pipeline-frontend"
VERIFY_COSIGN_URL=https://docs.sigstore.dev/cosign/system_config/installation/
VERIFY_MODE=""
VERIFY_COSIGN="" # a usable cosign was found
VERIFY_WHY=""    # ...or why there is none
VERIFY_NOTED=""  # the notice of the mode is printed

# verify_identity REPO VERSION: the identity that signs the image REPO of
# VERSION - release.yml of its repository on the tag.
verify_identity() {
  printf '%s/%s/.github/workflows/release.yml@refs/tags/%s\n' "$VERIFY_SOURCE" "$1" "$2"
}

# verify_init NOTHING reads CADENCE_VERIFY and looks for cosign, before the
# script does anything: an unknown value is refused, and so is require
# without cosign. NOTHING ends every refusal: what was not done.
# CADENCE_VERIFY_NOTED=1 comes from get-cadence.sh, which has already said
# what the mode means for this release.
verify_init() {
  local nothing="$1" v
  VERIFY_MODE="${CADENCE_VERIFY:-auto}"
  VERIFY_NOTED="${CADENCE_VERIFY_NOTED:-}"
  VERIFY_COSIGN="" VERIFY_WHY=""
  case "$VERIFY_MODE" in
  auto | require) ;;
  off)
    [ -n "$VERIFY_NOTED" ] || info "signature verification is off (CADENCE_VERIFY=off)"
    VERIFY_NOTED=1
    return 0
    ;;
  *) die "CADENCE_VERIFY is '$VERIFY_MODE', expected auto, require or off. $nothing" ;;
  esac
  if ! command -v cosign >/dev/null 2>&1; then
    VERIFY_WHY="cosign 3.x is not installed"
  else
    v="$(cosign version 2>&1 | sed -n 's/^GitVersion:[[:space:]]*\(v\{0,1\}[0-9][0-9.]*\).*/\1/p' | head -n 1 || true)"
    case "${v#v}" in
    "") VERIFY_WHY="cosign of an unknown version is not 3.x" ;;
    [012].*) VERIFY_WHY="cosign $v is older than 3.x" ;;
    *) VERIFY_COSIGN=1 ;;
    esac
  fi
  if [ "$VERIFY_MODE" = require ] && [ -z "$VERIFY_COSIGN" ]; then
    die "CADENCE_VERIFY=require, but $VERIFY_WHY: install cosign 3.x ($VERIFY_COSIGN_URL), or set CADENCE_VERIFY=auto. $nothing"
  fi
}

# verify_note TEXT: the warning of the mode, once per run.
verify_note() {
  [ -z "$VERIFY_NOTED" ] || return 0
  VERIFY_NOTED=1
  warn "$1"
}

# verify_skip VERSION NOTHING: true when there is nothing to verify for
# VERSION - the mode is off, VERSION is older than the signatures, or
# (auto) there is no cosign - and says why once. require refuses an
# unsigned version.
verify_skip() {
  local version="$1" nothing="$2"
  [ "$VERIFY_MODE" != off ] || return 0
  if version_lt "$version" "$VERIFY_FIRST_SIGNED"; then
    [ "$VERIFY_MODE" = auto ] ||
      die "$version is not signed (signatures start with $VERIFY_FIRST_SIGNED), and CADENCE_VERIFY=require refuses it. $nothing"
    verify_note "$version is not signed (signatures start with $VERIFY_FIRST_SIGNED): its package and images are not verified"
    return 0
  fi
  if [ -z "$VERIFY_COSIGN" ]; then
    verify_note "$VERIFY_WHY: the signatures of the release are not verified (CADENCE_VERIFY=auto). Install cosign 3.x to verify them: docs/admin.md, \"Verifying a release\""
    return 0
  fi
  return 1
}

# verify_package VERSION DIR NOTHING: the signature of DIR/checksums.txt of
# VERSION by the bundle of the same release, downloaded next to it - before
# the package is unpacked. A release of v0.9.0 or later without the bundle
# is refused: a mirror that drops the signature is no reason to skip it.
verify_package() {
  local version="$1" dir="$2" nothing="$3" out
  verify_skip "$version" "$nothing" && return 0
  fetch "$(releases_url)/download/$version/$VERIFY_BUNDLE" "$dir/$VERIFY_BUNDLE" ||
    die "the release $version has no $VERIFY_BUNDLE at $(releases_url): the signature of its checksums.txt cannot be verified.
  Copy $VERIFY_BUNDLE of the release to the mirror, or set CADENCE_VERIFY=off. $nothing"
  if ! out="$(cosign verify-blob --bundle "$dir/$VERIFY_BUNDLE" --certificate-identity "$VERIFY_PACKAGE_IDENTITY" \
    --certificate-oidc-issuer "$VERIFY_ISSUER" "$dir/checksums.txt" 2>&1)"; then
    printf '%s\n' "$out" | tail -n 5 >&2
    die "the signature of checksums.txt of $version did not verify for $VERIFY_PACKAGE_IDENTITY: the release is altered or not ours.
  Do not use it and report it privately (SECURITY.md). $nothing"
  fi
  ok "the signature of checksums.txt of $version verified: signed by $VERIFY_PACKAGE_IDENTITY"
}

# registry_reachable: ghcr.io answers HTTP at all (401 without a token is an
# answer), so a check that failed there is about the signature, not the
# network.
registry_reachable() {
  curl -s -o /dev/null --max-time 15 "https://${VERIFY_REGISTRY%%/*}/v2/"
}

# verify_images VERSION NOTHING COMPOSE_ARGS...: the signatures of the
# images of sdlc-pipeline-backend and sdlc-pipeline-frontend that
# `docker compose COMPOSE_ARGS... config --images` names for VERSION - the
# final configuration, with CADENCE_REGISTRY, the pin variables and the
# local override. Each is verified at ghcr.io by its digest, whatever
# registry it is pulled from: a mirror keeps the digests.
verify_images() {
  local version="$1" nothing="$2" images err repo refs ref digest identity out pin
  shift 2
  verify_skip "$version" "$nothing" && return 0
  err="$(mktemp)"
  if ! images="$(CADENCE_VERSION="$version" docker compose "$@" config --images 2>"$err")"; then
    tail -n 5 "$err" >&2
    rm -f "$err"
    die "could not read the images of $version from the compose configuration (see above). $nothing"
  fi
  rm -f "$err"
  info "verifying the signatures of the images of $version"
  for repo in $VERIFY_IMAGES; do
    pin="CADENCE_$(printf '%s' "${repo#sdlc-pipeline-}" | tr '[:lower:]' '[:upper:]')_DIGEST"
    refs="$(grep -E "(^|/)$repo([:@]|$)" <<<"$images" | sort -u || true)"
    if [ -z "$refs" ]; then
      [ "$VERIFY_MODE" = auto ] ||
        die "the compose configuration runs no image of $repo (compose.override.yml replaces it?), and CADENCE_VERIFY=require verifies only the images of the release. $nothing"
      warn "the compose configuration runs no image of $repo (compose.override.yml replaces it?): not pinned, not verified"
      continue
    fi
    while IFS= read -r ref; do
      case "$ref" in
      *@sha256:*) digest="${ref##*@}" ;;
      *)
        [ "$VERIFY_MODE" = auto ] ||
          die "$ref is not pinned to a digest (an empty $pin, or compose.override.yml), and CADENCE_VERIFY=require verifies images by digest only. $nothing"
        warn "$ref is not pinned to a digest (an empty $pin, or compose.override.yml): not pinned, not verified"
        continue
        ;;
      esac
      identity="$(verify_identity "$repo" "$version")"
      if out="$(cosign verify --certificate-identity "$identity" --certificate-oidc-issuer "$VERIFY_ISSUER" \
        "$VERIFY_REGISTRY/$repo@$digest" 2>&1 >/dev/null)"; then
        ok "$VERIFY_REGISTRY/$repo@$digest is signed by $identity"
        continue
      fi
      if ! registry_reachable; then
        [ "$VERIFY_MODE" = auto ] ||
          die "the images cannot be verified: ghcr.io is unreachable from this host, and CADENCE_VERIFY=require needs it (the signatures are checked there by digest). $nothing"
        warn "images not verified: ghcr.io is unreachable from this host (a registry mirror in a closed network?); verify them where it is reachable: docs/admin.md, \"Verifying a release\""
        return 0
      fi
      printf '%s\n' "$out" | tail -n 5 >&2
      die "the signature of $VERIFY_REGISTRY/$repo@$digest ($repo $version) did not verify for $identity: the image is altered or not ours.
  Do not run it and report it privately (SECURITY.md). $nothing"
    done <<<"$refs"
  done
}
