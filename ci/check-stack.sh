#!/usr/bin/env bash
#
# End-to-end check of the package on the images of VERSION: builds the
# release package of this checkout (ci/package.sh, with the clab of VERSION
# from the tap in bin/, or the clab of CHECK_CLAB_DIR), installs it the way
# the documentation says - the one-line installer piped into sh, from a
# local copy of the releases, with git out of reach and no clab in PATH - in
# proxy mode into a scratch directory, exercises the stack the way an
# administrator and an agent would, backs it up, restores it, and tears it
# down. CI runs it on every pull request; it runs the same way on any Linux
# or macOS machine with Docker.
#
# The scripts of the package are wrappers of clab server of the clab in the
# package (decision 0057): one implementation, so the check no longer runs
# the same scenarios twice for parity. What it checks of the wrappers: the
# installation, backups, restore, verify, fetch and upgrades through them
# with the old flags, their exit codes (1 for the refusals: .env exists, a
# taken name or port, another installation name, restore without --yes and a
# terminal, a backup of an external database that is down; 2 for an unknown
# flag), the cron lines install.sh prints run from an empty environment as
# cron runs them, the printed rollback runs as printed without clab in PATH,
# and no "older than the target" from the clab of the package. clab server
# status of the clab of the package reports the installation; an external
# clab of the same version (outside bin/) serves the installation of the
# wrappers (status, backup), and the second installation it installs with
# clab server install has the .env of the first one, key for key.
#
# The starter project (CLAB-199, bundled database): a third installation by
# clab server install --team starter --with-starter --project START (of
# CLAB_BIN, else of the clab of the package) ends with the project in its
# team, the starter roles and both cycles active and a task and an epic
# created; clab server starter repeats it with nothing changed, and on the
# first installation finds the project CHECK, set up by hand, unchanged. A
# clab without --with-starter skips this with a note before VERSION v0.14.0
# and fails from it. With CHECK_SECRETS=files the first installation holds
# the administrator token only in secrets/admin_token, 65532:65532 and mode
# 400 as docs/admin.md says (CLAB-252): clab server starter reads it with a
# one-off alpine:3 container, prints no token and leaves no container.
#
#   ci/check-stack.sh
#
#   CHECK_HTTP_PORT       host port of the stack, default 8080; a second
#                         installation takes the next port, the installation
#                         of the starter project the port 3 above it
#   COMPOSE_PROJECT_NAME  name of the installation (its compose project),
#                         default cadence-check, never cadence; the second
#                         one is NAME-2
#   CLAB_BIN              clab of the people and agents in the scenarios of
#                         the API (sign-in, teams, tasks); default: the clab
#                         of the package for this machine
#   CHECK_CLAB_DIR        a directory with clab-<os>-<arch> of the four
#                         platforms of the package (CLAB_PLATFORMS in
#                         ci/lib.sh), each built with -X main.version= the
#                         VERSION of this checkout: the package of the
#                         installation and the packages of the upgrades
#                         (v98.0.0, v99.0.0) carry them instead of the clab
#                         of the tap (ci/package.sh --clab), so the wrappers,
#                         the external clab and the starter project run a
#                         clab of a branch of the backend - its CI checks a
#                         change of clab server this way (CLAB-253). Absolute
#                         or relative to where the check is started; unset or
#                         empty - the clab of the tap, as before
#   CHECK_KEEP=1          leave the stack (and its directory) after the check
#   CHECK_DB              bundled (default) - the postgres container of the
#                         stack; external - a stand-in for the PostgreSQL of
#                         a customer (ci/external-db.sh: a pgvector container
#                         of its own with TLS and a CA of its own, a role that
#                         is no superuser), installed with --external-db and
#                         --external-db-ca: the refusals of the precheck,
#                         backup, restore, the upgrade check and its printed
#                         rollback (with a package of this checkout as
#                         v99.0.0), status. Needs images of v0.10.0 or newer
#                         (/api dbcheck).
#   CHECK_S3_PORT         host port of the stand-in bucket of the off-machine
#                         copy (ci/s3.sh), default CHECK_HTTP_PORT + 4
#   CHECK_DB_PORT         port of the stand-in, default CHECK_HTTP_PORT + 2;
#                         the PostgreSQL 14 of the version refusal takes the
#                         next one
#   CHECK_SECRETS         env (default) - the secrets stay in .env, as the
#                         installer writes them; files - right after the
#                         install the installation moves to secrets in files
#                         the way docs/admin.md ("Secrets in files") says:
#                         compose.secrets.yml with the password of the bundled
#                         database and the administrator token, the URL of an
#                         external database in SDLC_DATABASE_URL_FILE, the
#                         keys of the bucket in BACKUP_S3_*_FILE, and empty
#                         values in .env. A missing file and a value left in
#                         .env stop the API, naming the variables; the rest of
#                         the check runs on the files, and at the end no value
#                         of a secret is in the logs of the stack. Needs
#                         images of v0.13.0 or newer, or images of a branch (a
#                         pin variable set).
#
# The installation name (CLAB-164): install.sh keeps it in .env, so after the
# install every command runs without COMPOSE_PROJECT_NAME, as from cron or a
# new terminal; a second installation under the same name is refused; a
# COMPOSE_PROJECT_NAME of another installation makes backup, restore and
# upgrade refuse; a second installation runs next to
# the first one and each sees only itself.
#
# Images: docker-compose.yml pins the images of VERSION by digest (ci/pins.sh)
# and the check compares the containers with it. Images of a branch, built
# under the tag of VERSION into a local registry, have other digests: drop
# the pin with empty variables, and the stack pulls them by tag:
#
#   CADENCE_REGISTRY=localhost:5050 CADENCE_BACKEND_DIGEST= CADENCE_FRONTEND_DIGEST= \
#     COMPOSE_PROJECT_NAME=check-<name> CHECK_HTTP_PORT=<port> ci/check-stack.sh
#
# Images of a branch are no images of a release: their signatures are not
# ours to check, and they have no pin. Run such a check with
# CADENCE_VERIFY=off (with the default auto it warns "not pinned, not
# verified"; require refuses):
#
#   CADENCE_VERIFY=off CADENCE_REGISTRY=localhost:5050 CADENCE_BACKEND_DIGEST= CADENCE_FRONTEND_DIGEST= \
#     COMPOSE_PROJECT_NAME=check-<name> CHECK_HTTP_PORT=<port> ci/check-stack.sh
#
# Signatures (CADENCE_VERIFY, docs/admin.md "Verifying a release"): the package of this
# checkout is not signed, so with a real cosign 3.x in PATH (CI installs
# one) a wrapper (ci/verify-stubs.sh) accepts verify-blob of it and hands
# the images to the real cosign: the installer verifies the pinned images of
# VERSION at ghcr.io for real, and the check wants both "is signed by" lines.
# A stub cosign with a bad signature of the frontend image makes another
# installation refuse before its .env. Without cosign the installer warns
# and goes on. The upgrades
# of this check to made-up versions (v98.0.0, v99.0.0) run with
# CADENCE_VERIFY=off: their images are those of VERSION, signed for another
# tag.
#
# The metrics of api and worker, and the off-machine copy of backups with
# backup verify (a stand-in bucket, ci/s3.sh), are checked on images of
# VERSION v0.10.0 or later, and on images of a branch (a pin variable set)
# whatever VERSION is.
#
# The stacks are torn down with their volumes at the end: give them a
# COMPOSE_PROJECT_NAME and a CHECK_HTTP_PORT (and the port after it) of their
# own, never those of a running instance.
set -euo pipefail

# CHECK_CLAB_DIR from where the check is started, before the cd below:
# ci/package.sh --clab of every package this check builds.
clab_pkg=()
if [ -n "${CHECK_CLAB_DIR:-}" ]; then
  check_clab_dir="$(cd "$CHECK_CLAB_DIR" 2>/dev/null && pwd)" ||
    { printf '✗ CHECK_CLAB_DIR %s is no directory\n' "$CHECK_CLAB_DIR" >&2; exit 1; }
  clab_pkg=(--clab "$check_clab_dir")
fi

cd "$(dirname "$0")/.."
# shellcheck source=ci/lib.sh
. ./ci/lib.sh

port="${CHECK_HTTP_PORT:-8080}"
[ -z "${CADENCE_DRIVER:-}" ] || die "CADENCE_DRIVER is gone: the scripts are wrappers of clab server (decision 0057), one implementation to check"
case "$(uname -s)/$(uname -m)" in
Linux/x86_64 | Linux/amd64) platform=linux-amd64 ;;
Linux/aarch64 | Linux/arm64) platform=linux-arm64 ;;
Darwin/x86_64) platform=darwin-amd64 ;;
Darwin/arm64) platform=darwin-arm64 ;;
*) die "the package has no clab for $(uname -s)/$(uname -m)" ;;
esac
db="${CHECK_DB:-bundled}"
case "$db" in
bundled | external) ;;
*) die "CHECK_DB is '$db', expected bundled or external" ;;
esac
db_port="${CHECK_DB_PORT:-$((port + 2))}"
secrets_mode="${CHECK_SECRETS:-env}"
case "$secrets_mode" in
env | files) ;;
*) die "CHECK_SECRETS is '$secrets_mode', expected env or files" ;;
esac
base="http://127.0.0.1:$port"
version="$(tr -d '[:space:]' <VERSION)"
failures=0
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-cadence-check}"
name="$COMPOSE_PROJECT_NAME"
second_name="$name-2"
second_port=$((port + 1))
# The installation of the starter project (bundled database only).
starter_name="$name-3"
starter_port=$((port + 3))
# The stacks are torn down with their volumes: never the default name of a
# real installation.
[ "$name" != cadence ] || die "COMPOSE_PROJECT_NAME=cadence is the name of a real installation; the check tears its stacks down - give it a name of its own"
valid_name "$name" || die "COMPOSE_PROJECT_NAME '$name' is not a valid installation name"
repo="$(pwd)"
work="$(mktemp -d)"

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  failures=$((failures + 1))
}
check() {
  local what="$1"
  shift
  if "$@" >/dev/null; then pass "$what"; else fail "$what"; fi
}
http_code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
# contains TEXT PATTERN / lacks TEXT PATTERN: a fixed string in a response.
contains() { grep -qF -- "$2" <<<"$1"; }
lacks() { ! grep -qF -- "$2" <<<"$1"; }
html() { curl -sf "$base/" | grep -qi '<html'; }
client_error() { [ "$1" -ge 400 ] && [ "$1" -lt 500 ]; }

# fresh DIR CMD...: CMD in DIR as from a new terminal or cron - without
# COMPOSE_PROJECT_NAME and the rest of what this check and load_env exported;
# CADENCE_VERSION only for a direct docker compose.
fresh() {
  local d="$1"
  shift
  (cd "$d" && env -i PATH="$PATH" HOME="$HOME" ${DOCKER_HOST:+DOCKER_HOST="$DOCKER_HOST"} \
    ${DOCKER_CONTEXT:+DOCKER_CONTEXT="$DOCKER_CONTEXT"} CADENCE_VERSION="$version" "$@")
}

cleanup() {
  [ "${CHECK_KEEP:-}" != 1 ] || { info "kept: $work/cadence${second_up:+ and $work/second}${starter_up:+ and $work/starter}"; return; }
  # The stand-in bucket sits in the network of the installation: it goes
  # first, or compose could not remove that network.
  if declare -F s3_down >/dev/null; then s3_down; fi
  # By the names this check gave, never by what a .env says.
  local d n
  for d in cadence:"$name" second:"$second_name" starter:"$starter_name"; do
    n="${d#*:}"
    d="$work/${d%%:*}"
    if [ -f "$d/.env" ]; then
      info "tearing $n down"
      fresh "$d" docker compose -p "$n" down -v --remove-orphans >/dev/null 2>&1 || true
    fi
  done
  [ "$db" = bundled ] || ext_db_down
  # Files of the containers (backups of the blobs volume) may belong to
  # another uid; the stack is gone, so what is left is ours to remove.
  rm -rf "$work" "${clab_dir:-}" 2>/dev/null || true
}
trap cleanup EXIT

# A token known in advance, so CI can mask it before anything prints it.
admin_token="sdlc_$(openssl rand -hex 24)"
if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::add-mask::$admin_token"; fi
auth=(-H "Authorization: Bearer $admin_token")

# --- external database -------------------------------------------------------------
# install_db: the flags of the installation's database; the CA by a path
# relative to $work, where every installer of this check runs (get-cadence.sh
# changes into the new directory: the relative path must survive that).
install_db=()
if [ "$db" = external ]; then
  # shellcheck source=ci/external-db.sh
  . ./ci/external-db.sh
  info "external database: a stand-in $name-db on port $db_port"
  ext_db_up "$name-db" "$db_port" "$work/extdb"
  cp "$work/extdb/ca.pem" "$work/ca.pem"
  cp "$work/extdb/other-ca.pem" "$work/other-ca.pem"
  install_db=(--external-db "$(ext_db_url cadence)" --external-db-ca ca.pem)
  # The URL install.sh and clab server write to .env.
  external_url="$(ext_db_url cadence)&sslrootcert=/secrets/db-ca.pem"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::add-mask::$EXT_DB_PASSWORD"; fi
fi

# --- install ---------------------------------------------------------------------
# The releases as the installer sees them: download/<version>/ and
# latest/download/ (ci/lib.sh, "releases").
info "release package of this checkout"
ci/package.sh --bundle ${clab_pkg[@]+"${clab_pkg[@]}"} "$work/releases/download/$version"
mkdir -p "$work/releases/latest"
cp -R "$work/releases/download/$version" "$work/releases/latest/download"
# git and clab must not be needed: a git and a clab that fail and leave a
# trace stand first in PATH.
mkdir -p "$work/nogit"
printf '#!/bin/sh\necho "git $*" >>"%s/git-calls"\nexit 1\n' "$work" >"$work/nogit/git"
printf '#!/bin/sh\necho "clab $*" >>"%s/clab-calls"\nexit 1\n' "$work" >"$work/nogit/clab"
chmod 755 "$work/nogit/git" "$work/nogit/clab"
# shellcheck source=ci/verify-stubs.sh
. ./ci/verify-stubs.sh
real_cosign=false
if stub_cosign_local "$work/cosign-local" "$work/cosign.log"; then
  real_cosign=true
  export PATH="$work/cosign-local:$PATH"
  info "cosign $(cosign version 2>&1 | sed -n 's/^GitVersion:[[:space:]]*//p' | head -n 1): the images are verified at ghcr.io"
fi

clab_dir="$(mktemp -d)"
export CLAB_CONFIG_DIR="$clab_dir/config"

info "get-cadence.sh | sh -s -- --mode proxy --http-addr 127.0.0.1:$port ${install_db[*]:+--external-db ... --external-db-ca ca.pem} --yes"
install_out="$(cd "$work" && PATH="$work/nogit:$PATH" CADENCE_RELEASES_URL="file://$work/releases" SDLC_ADMIN_TOKEN="$admin_token" \
  sh -s -- --mode proxy --http-addr "127.0.0.1:$port" ${install_db[@]+"${install_db[@]}"} --yes <"$repo/get-cadence.sh" 2>&1)" ||
  { printf '%s\n' "$install_out" >&2; die "get-cadence.sh failed"; }
printf '%s\n' "$install_out"
check "the stack is installed from the package into $work/cadence" [ -f "$work/cadence/.env" ]
# .env as install.sh wrote it, before this check edits it.
cp "$work/cadence/.env" "$work/env-of-install.sh"
check "install.sh says the stack is up" contains "$install_out" "Cadence Lab $version is up"
check "install.sh does not print a supplied token" lacks "$install_out" "$admin_token"
check "...and says it was supplied" contains "$install_out" "the one supplied in SDLC_ADMIN_TOKEN"
# The clab of the package; the clab of the people (CLAB_BIN) for the API.
pkg_clab="$work/cadence/bin/clab-$platform"
check "the package has its clab for this machine: bin/clab-$platform of $version" \
  [ "$("$pkg_clab" version 2>/dev/null | head -n 1)" = "clab $version" ]
clab="${CLAB_BIN:-$pkg_clab}"

# The cron lines install.sh prints are the scripts of the installation by
# their absolute paths, and run as cron runs them: from /, with the
# environment of cron - PATH, HOME, SHELL and LOGNAME, nothing else (PATH
# with the directory of docker, which cron of the machine would need too).
cron_lines="$(grep -oE "[0-9*]+ [0-9*]+ \* \* [0-9*]+ $work/cadence/backup\.sh( verify)? >> $work/cadence/backups/backup\.log 2>&1" <<<"$install_out" || true)"
check "install.sh prints the cron lines of backup.sh and backup.sh verify by their paths" [ "$(grep -c . <<<"$cron_lines")" = 2 ]
check "...and no clab server for cron" lacks "$install_out" "server backup --dir"
cron_env=(env -i PATH="$(dirname "$(command -v docker)"):/usr/bin:/bin" HOME="$HOME" SHELL=/bin/sh LOGNAME="$(id -un)")
cron_backup="$(head -n 1 <<<"$cron_lines" | cut -d' ' -f6-)"
dumps_before_cron="$(find "$work/cadence/backups" -maxdepth 1 -name 'cadence-*.sql.gz' | wc -l | tr -d ' ')"
if (cd / && "${cron_env[@]}" sh -c "$cron_backup"); then
  pass "the cron line of backup.sh runs as cron runs it: $cron_backup"
else
  fail "the cron line of backup.sh failed from an empty environment: $(tail -n 5 "$work/cadence/backups/backup.log" 2>/dev/null)"
fi
check "...writes a backup and its log" [ "$(find "$work/cadence/backups" -maxdepth 1 -name 'cadence-*.sql.gz' | wc -l | tr -d ' ')" -gt "$dumps_before_cron" ]
check "...into backups/backup.log" grep -qF "✓ " "$work/cadence/backups/backup.log"

# --- signatures ----------------------------------------------------------------------
# The installer verifies what it can: install.sh is clab server install of
# the clab of VERSION, which verifies.
verifies=true
pinned=true
[ -z "${CADENCE_BACKEND_DIGEST+set}${CADENCE_FRONTEND_DIGEST+set}" ] || pinned=false
if [ "$verifies" = true ] && [ "$real_cosign" = true ] && [ "$pinned" = true ] && [ "${CADENCE_VERIFY:-auto}" != off ]; then
  info "signatures"
  check "the installer verified the signature of checksums.txt (the stand-in of this checkout)" \
    contains "$install_out" "✓ the signature of checksums.txt of $version verified"
  for image in backend frontend; do
    check "the installer verified sdlc-pipeline-$image of $version at ghcr.io: signed by its release.yml on $version" \
      contains "$install_out" "is signed by https://github.com/cadence-lab-tech/sdlc-pipeline-$image/.github/workflows/release.yml@refs/tags/$version"
  done
else
  info "the signatures of the images are not checked for real: verification of the installer $verifies, real cosign $real_cosign, pinned $pinned, CADENCE_VERIFY=${CADENCE_VERIFY:-auto}"
fi
if [ "$verifies" = true ] && [ "$pinned" = true ]; then
  # Another installation with a stub cosign that rejects the frontend image:
  # refused before its .env. The port is the one of the first installation,
  # so even a verification that did not stop it would stop at the port.
  stub_cosign "$work/cosign-bad" "$work/cosign-bad.log"
  bad_env=(CADENCE_VERIFY=auto FAKE_COSIGN_BAD=sdlc-pipeline-frontend COMPOSE_PROJECT_NAME="$name-bad" PATH="$work/cosign-bad:$work/nogit:$PATH")
  out="$(cd "$work" && env "${bad_env[@]}" CADENCE_RELEASES_URL="file://$work/releases" \
    sh -s -- --dir badsig --mode proxy --http-addr "127.0.0.1:$port" --yes <"$repo/get-cadence.sh" 2>&1)" && bad_ok=1 || bad_ok=0
  if [ "$bad_ok" = 0 ] && contains "$out" "sdlc-pipeline-frontend $version) did not verify for" && [ ! -e "$work/badsig/.env" ]; then
    pass "a bad signature of the frontend image: the installation is refused before .env"
  else
    fail "a bad signature of the frontend image: $out"
  fi
fi
check "the installation is not a git clone" [ ! -e "$work/cadence/.git" ]
check "git was never called" [ ! -s "$work/git-calls" ]
check "no clab of PATH was called" [ ! -s "$work/clab-calls" ]
check "VERSION of the installation is $version" [ "$(tr -d '[:space:]' <"$work/cadence/VERSION")" = "$version" ]
cd "$work/cadence"

check ".env has mode 600" [ "$(stat -c %a .env 2>/dev/null || stat -f %Lp .env)" = 600 ]
secrets_distinct() {
  local pg admin hook
  pg="$(grep '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)"
  admin="$(grep '^SDLC_ADMIN_TOKEN=' .env | cut -d= -f2-)"
  hook="$(grep '^SDLC_GITHUB_WEBHOOK_SECRET=' .env | cut -d= -f2-)"
  # The external database has the password of its URL; POSTGRES_PASSWORD
  # stays empty.
  if [ "$db" = external ]; then pg="-"; fi
  [ -n "$pg" ] && [ -n "$admin" ] && [ -n "$hook" ] && [ "$pg" != "$admin" ] && [ "$pg" != "$hook" ] && [ "$admin" != "$hook" ]
}
check "secrets in .env are set and distinct" secrets_distinct
check "the installation has backups/ (700) and secrets/ (711)" \
  [ "$(stat -c %a backups secrets 2>/dev/null || stat -f %Lp backups secrets)" = "700"$'\n'"711" ]
check "compose.override.yml is there" [ -f compose.override.yml ]

before="$(sha256sum .env 2>/dev/null || shasum -a 256 .env)"
code=0
out="$(PATH="$work/nogit:$PATH" ./install.sh --mode proxy --http-addr "127.0.0.1:$port" --yes </dev/null 2>&1)" || code=$?
check "a second install.sh refuses to run: exit 1" [ "$code" = 1 ]
check "...pointing at ./upgrade.sh" contains "$out" "upgrade:    ./upgrade.sh"
check "a second install.sh leaves .env untouched" [ "$before" = "$(sha256sum .env 2>/dev/null || shasum -a 256 .env)" ]
for script in install upgrade backup restore; do
  code=0
  out="$(./$script.sh --no-such-flag </dev/null 2>&1)" || code=$?
  check "./$script.sh --no-such-flag: exit 2, unknown option" [ "$code" = 2 ]
done

load_env

# --- the database of the installation ------------------------------------------------
pg_sql() { docker compose exec -T postgres psql -X -At -U "${POSTGRES_USER:-sdlc}" -d "${POSTGRES_DB:-sdlc}" -c "$1"; }
# exited_with SERVICE CODE TEXT: the one-off SERVICE exited with CODE and its
# log has TEXT.
exited_with() {
  local c
  c="$(container_of "$1")"
  [ -n "$c" ] && [ "$(docker inspect -f '{{.State.Status}} {{.State.ExitCode}}' "$c")" = "exited $2" ] &&
    docker compose logs --no-log-prefix "$1" 2>&1 | tail -n 1 | grep -qF -- "$3"
}
# bundled_db_checks WHEN: the bundled database is PostgreSQL 18 on Debian 13
# with its data in the volume postgres, and nothing was moved
# (postgres/major-upgrade.sh, docs/admin.md "PostgreSQL 18").
bundled_db_checks() {
  local pg mounts
  pg="$(container_of postgres)"
  check "$1: postgres runs pgvector/pgvector:pg18-trixie" \
    [ "$(docker inspect -f '{{.Config.Image}}' "$pg")" = pgvector/pgvector:pg18-trixie ]
  check "...PostgreSQL 18 (SHOW server_version)" grep -q '^18\.' <<<"$(pg_sql 'SHOW server_version')"
  check "...on Debian 13" grep -q '^13\.' <<<"$(docker compose exec -T postgres cat /etc/debian_version)"
  # Volumes only: with secrets in files a Docker secret is a bind mount too.
  mounts="$(docker inspect -f '{{range .Mounts}}{{if eq .Type "volume"}}{{.Type}} {{.Name}} {{.Destination}}{{println}}{{end}}{{end}}' "$pg" | grep . || true)"
  check "...one volume, ${name}_postgres at /var/lib/postgresql: no anonymous volume" \
    [ "$mounts" = "volume ${name}_postgres /var/lib/postgresql" ]
  check "...its data directory is /var/lib/postgresql/18/docker" [ "$(pg_sql 'SHOW data_directory')" = /var/lib/postgresql/18/docker ]
  check "...no database with a collation version mismatch" \
    [ -z "$(pg_sql 'SELECT datname FROM pg_database WHERE datallowconn AND datcollversion IS DISTINCT FROM pg_database_collation_actual_version(oid)')" ]
  check "pg-upgrade-dump exited 0: nothing to move" exited_with pg-upgrade-dump 0 "nothing to move"
  check "pg-upgrade-load exited 0: nothing to do" exited_with pg-upgrade-load 0 "nothing to do"
}
dbline() { grep -E '^(Database|  Database):' <<<"$1" | head -n 1; }
if [ "$db" = external ]; then
  info "external database"
  check "the installer names the external database $EXT_DB_HOST:$db_port/cadence" \
    contains "$install_out" "Database:             external $EXT_DB_HOST:$db_port/cadence"
  check "the installer printed no password of the database" lacks "$install_out" "$EXT_DB_PASSWORD"
  check ".env: CADENCE_DB=external" grep -qxF "CADENCE_DB=external" .env
  check ".env: SDLC_DATABASE_URL with the CA in /secrets and verify-full" [ "${SDLC_DATABASE_URL:-}" = "$external_url" ]
  check ".env: POSTGRES_PASSWORD is empty" grep -qxF "POSTGRES_PASSWORD=" .env
  check ".env: COMPOSE_FILE lists compose.external-db.yml" \
    [ "$COMPOSE_FILE" = "docker-compose.yml:compose.proxy.yml:compose.external-db.yml:compose.override.yml" ]
  check "the CA is secrets/db-ca.pem (644), the one given by a relative path" \
    [ "$(stat -c %a secrets/db-ca.pem 2>/dev/null || stat -f %Lp secrets/db-ca.pem) $(sha256_of secrets/db-ca.pem)" = "644 $(sha256_of "$work/ca.pem")" ]
  check "no postgres container" [ -z "$(docker compose ps -a -q postgres 2>/dev/null)" ]
  check "no container of the move to PostgreSQL 18 (pg-upgrade-dump, pg-upgrade-load)" \
    [ -z "$(docker compose ps -a -q pg-upgrade-dump 2>/dev/null)$(docker compose ps -a -q pg-upgrade-load 2>/dev/null)" ]
  check "no pgdata volume, no postgres volume" \
    [ -z "$(docker volume ls -q --filter "name=^${name}_pgdata\$")$(docker volume ls -q --filter "name=^${name}_postgres\$")" ]
  check "the service applied the schema in the external database (schema_migrations)" \
    [ "$(ext_db_query cadence 'SELECT count(*) > 0 FROM schema_migrations')" = t ]
  check "the API reads the CA as uid 65532: /api dbcheck in the api container passes" \
    docker compose exec -T api /api dbcheck
  check "/api dbcheck --json reports the server and the schema" \
    contains "$(docker compose exec -T api /api dbcheck --json)" '"schema": "cadence"'
else
  check ".env: the bundled database (CADENCE_DB=bundled)" grep -qxF "CADENCE_DB=bundled" .env
  bundled_db_checks "a fresh installation"
fi

# env_set KEY VALUE: KEY=VALUE in .env of the installation.
env_set() {
  if grep -q "^$1=" .env; then
    sed -i.bak "s|^$1=.*|$1=$2|" .env && rm -f .env.bak
  else
    printf '%s=%s\n' "$1" "$2" >>.env
  fi
}

# --- refusals of the external database ------------------------------------------------
# Each before .env: the directory of an unpacked package stays fit for the
# next attempt: ./install.sh runs there and installs in place.
if [ "$db" = external ]; then
  info "refusals of the external database"
  refusals="$work/refusals"
  mkdir -p "$refusals"
  tar -xpzf "$work/releases/download/$version/$(package_name "$version")" -C "$refusals"
  cp "$work/ca.pem" "$work/other-ca.pem" "$refusals/"
  # refuse WHAT EXPECTED ARGS...: an installation with ARGS is refused before
  # .env, the output has EXPECTED and no password of the database.
  refuse() {
    local what="$1" expected="$2" out code=0
    shift 2
    out="$(cd "$refusals" && env -u COMPOSE_PROJECT_NAME ./install.sh --name "$name-r" --mode proxy --http-addr "127.0.0.1:$second_port" \
      --yes "$@" </dev/null 2>&1)" || code=$?
    [ "$code" != 0 ] || { fail "$what must be refused"; return; }
    [ "$code" = 1 ] || fail "$what: exit $code, expected 1"
    if contains "$out" "$expected" && lacks "$out" "$EXT_DB_PASSWORD" && lacks "$out" "$EXT_DB_PASSWORD_URL" && [ ! -e "$refusals/.env" ]; then
      pass "$what is refused before .env: $expected"
    else
      fail "$what: no '$expected', a password in the output or .env written: $out"
    fi
  }
  refuse "a CA that did not sign the server" "TLS to $EXT_DB_HOST:$db_port/cadence failed" \
    --external-db "$(ext_db_url cadence)" --external-db-ca other-ca.pem
  wrong_url="$(ext_db_url cadence)"
  wrong_url="${wrong_url/$EXT_DB_PASSWORD_URL/Wrong-pw-$EXT_DB_PASSWORD_URL}"
  refuse "a wrong password" "the server refused the role" --external-db "$wrong_url" --external-db-ca ca.pem
  refuse "no sslmode and no CA" "sslmode is not set" --external-db "$(ext_db_url cadence "connect_timeout=5")"
  refuse "a parameter libpq does not know" "has the parameter pool_max_conns" \
    --external-db "$(ext_db_url cadence "sslmode=verify-full&pool_max_conns=5")" --external-db-ca ca.pem
  refuse "no vector, and the role cannot create it" "CREATE EXTENSION IF NOT EXISTS vector;" \
    --external-db "$(ext_db_url cadence_noext)" --external-db-ca ca.pem
  refuse "no CREATE on the schema public" "has no CREATE privilege on the schema public" \
    --external-db "$(ext_db_url cadence_nopriv)" --external-db-ca ca.pem
  refuse "tables that are not Cadence's" "the schema public holds tables that are not Cadence's (orders)" \
    --external-db "$(ext_db_url cadence_foreign)" --external-db-ca ca.pem
  ext_db_old_up "$name-db14" "$((db_port + 1))"
  refuse "PostgreSQL 14" "PostgreSQL 14." --external-db "$EXT_DB_OLD_URL"
  docker rm -f "$name-db14" >/dev/null 2>&1 || true
  # An older Compose than the overlay needs: docker answers 2.19.0.
  mkdir -p "$work/oldcompose"
  # shellcheck disable=SC2016 # the text of the shim, expanded when it runs
  printf '#!/bin/sh\nif [ "$1 $2" = "compose version" ]; then echo 2.19.0; exit 0; fi\nexec %s "$@"\n' "$(command -v docker)" >"$work/oldcompose/docker"
  chmod 755 "$work/oldcompose/docker"
  PATH="$work/oldcompose:$PATH" refuse "Docker Compose 2.19.0" "needs Docker Compose 2.20.0 or newer" \
    --external-db "$(ext_db_url cadence)" --external-db-ca ca.pem
  check "the refusals left no containers of $name-r" [ -z "$(docker ps -a -q --filter "label=com.docker.compose.project=$name-r")" ]
  check "...and no network" [ -z "$(docker network ls -q --filter "label=com.docker.compose.project=$name-r")" ]
fi

# --- secrets in files (CHECK_SECRETS=files) -------------------------------------------
# The move of docs/admin.md ("Secrets in files"), step by step, on the
# installed stack - after the refusals of the external database: their
# installers run from this shell, and the *_FILE it exports from .env would
# reach them. ext_label: how the scripts name the external database -
# the file of the URL is not read for a message.
ext_label="${EXT_DB_HOST:-}:$db_port/cadence"
ext_status="external $ext_label (sslmode=verify-full)"
# secret_set KEY VALUE: the secret KEY of the installation - in .env, or with
# CHECK_SECRETS=files in secrets/<key> (yours, mode 400: the bucket keys are
# read by /api backup-s3 as you) with KEY_FILE in .env and KEY empty.
secret_set() {
  if [ "$secrets_mode" = files ]; then
    local f
    f="$(tr '[:upper:]_' '[:lower:]-' <<<"$1")"
    rm -f "secrets/$f"
    if [ -n "$2" ]; then
      (umask 077 && printf '%s\n' "$2" >"secrets/$f")
      chmod 400 "secrets/$f"
      env_set "${1}_FILE" "/secrets/$f"
    else
      env_set "${1}_FILE" ""
    fi
    env_set "$1" ""
  else
    env_set "$1" "$2"
  fi
}
# api_log_has TEXT: the logs of api show TEXT within a minute.
api_log_has() {
  local _
  for _ in $(seq 1 30); do
    docker compose logs api 2>&1 | grep -qF -- "$1" && return 0
    sleep 2
  done
  return 1
}
if [ "$secrets_mode" = files ]; then
  if version_lt "$version" v0.13.0 && [ -z "${CADENCE_BACKEND_DIGEST+set}" ]; then
    die "CHECK_SECRETS=files needs images that read *_FILE (v0.13.0+); images of a branch are checked with CADENCE_BACKEND_DIGEST="
  fi
  info "secrets in files"
  # A missing file stops the API on start, naming the variable and the path,
  # never a value (before the overlay: the path comes from .env).
  env_set SDLC_ADMIN_TOKEN ""
  env_set SDLC_ADMIN_TOKEN_FILE /secrets/missing
  load_env
  docker compose up -d --no-deps api >/dev/null 2>&1 || true
  check "a missing SDLC_ADMIN_TOKEN_FILE stops the API, naming the variable and the path" \
    api_log_has "SDLC_ADMIN_TOKEN_FILE: stat /secrets/missing: no such file or directory"
  check "...and the API is not healthy" \
    [ "$(docker inspect -f '{{.State.Health.Status}}' "$(container_of api)" 2>/dev/null)" != healthy ]
  env_set SDLC_ADMIN_TOKEN_FILE ""
  env_set SDLC_ADMIN_TOKEN "$admin_token"
  # The headers of the exporter of traces are a secret too (CLAB-235, since
  # v0.13.0), read and checked on start with tracing off as well: a
  # malformed pair in the file stops the API, naming the variable and the
  # pair, never the key or the value. The stack below then runs with a good
  # file of headers, and its value joins "no secret in the logs".
  otlp_value="otlp$(openssl rand -hex 12)"
  otlp_file() {
    rm -f secrets/otlp-headers
    (umask 077 && printf '%s\n' "$1" >secrets/otlp-headers)
    docker run --rm -v "$PWD/secrets:/s" alpine:3 sh -c 'chown 65532:65532 /s/otlp-headers && chmod 400 /s/otlp-headers'
  }
  otlp_file "api-key: $otlp_value"
  env_set OTEL_EXPORTER_OTLP_HEADERS ""
  env_set OTEL_EXPORTER_OTLP_HEADERS_FILE /secrets/otlp-headers
  load_env
  docker compose up -d --no-deps api >/dev/null 2>&1 || true
  check "a malformed pair in OTEL_EXPORTER_OTLP_HEADERS_FILE stops the API, naming the variable and the pair" \
    api_log_has "OTEL_EXPORTER_OTLP_HEADERS_FILE: pair 1 has no '='"
  check "...and the log of api holds no part of the headers" lacks "$(docker compose logs api 2>&1)" "$otlp_value"
  otlp_file "x-cadence-check=$otlp_value"

  # Step 1: the values of .env into files of secrets/, handed over.
  # shellcheck source=/dev/null
  (umask 077 && set -a && . ./.env &&
    if [ "$CADENCE_DB" = bundled ]; then printf '%s\n' "$POSTGRES_PASSWORD" >secrets/postgres_password; fi &&
    printf '%s\n' "$SDLC_ADMIN_TOKEN" >secrets/admin_token)
  if [ "$db" = bundled ]; then
    # shellcheck source=/dev/null
    pg_password="$(set -a && . ./.env && printf '%s' "$POSTGRES_PASSWORD")"
    if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::add-mask::$pg_password"; fi
    docker run --rm -v "$PWD/secrets:/s" alpine:3 sh -c \
      'chown 65532:999 /s/postgres_password && chmod 440 /s/postgres_password &&
       chown 65532:65532 /s/admin_token && chmod 400 /s/admin_token && chmod 711 /s'
    env_set POSTGRES_PASSWORD ""
  else
    pg_password=""
    (umask 077 && printf '%s\n' "$SDLC_DATABASE_URL" >secrets/db-url)
    docker run --rm -v "$PWD/secrets:/s" alpine:3 sh -c \
      "chown 65532:65532 /s/admin_token && chmod 400 /s/admin_token && chown $(id -u):65532 /s/db-url && chmod 440 /s/db-url && chmod 711 /s"
    env_set SDLC_DATABASE_URL ""
    env_set SDLC_DATABASE_URL_FILE /secrets/db-url
    ext_label="(URL in /secrets/db-url)"
    ext_status="external $ext_label"
  fi
  # Step 2: the overlay right after the file of the mode.
  env_set COMPOSE_FILE "${COMPOSE_FILE/compose.proxy.yml/compose.proxy.yml:compose.secrets.yml}"
  # A value forgotten in .env stops the API, naming both forms.
  load_env
  docker compose up -d --no-deps api >/dev/null 2>&1 || true
  check "SDLC_ADMIN_TOKEN left in .env next to compose.secrets.yml stops the API, naming both" \
    api_log_has "both SDLC_ADMIN_TOKEN and SDLC_ADMIN_TOKEN_FILE are set: keep one of them"
  # Step 3: the value out of .env, and the stack on the files.
  env_set SDLC_ADMIN_TOKEN ""
  load_env
  docker compose up -d >/dev/null 2>&1 || true
  check "the stack is ready on the secrets in files" wait_ready 180
  check ".env holds no value of POSTGRES_PASSWORD, SDLC_ADMIN_TOKEN, SDLC_DATABASE_URL" \
    [ "$(grep -E '^(POSTGRES_PASSWORD|SDLC_ADMIN_TOKEN|SDLC_DATABASE_URL)=' .env | sort | tr '\n' ' ')" = \
      "POSTGRES_PASSWORD= SDLC_ADMIN_TOKEN= SDLC_DATABASE_URL= " ]
  check "COMPOSE_FILE lists compose.secrets.yml after the file of the mode" \
    contains "$(grep '^COMPOSE_FILE=' .env)" "compose.proxy.yml:compose.secrets.yml"
  check "api reads the administrator token from /run/secrets/admin_token" \
    [ "$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$(container_of api)" | grep -E '^SDLC_ADMIN_TOKEN(_FILE)?=' | sort | tr '\n' ' ')" = \
      "SDLC_ADMIN_TOKEN= SDLC_ADMIN_TOKEN_FILE=/run/secrets/admin_token " ]
  check "no container of the stack has a secret in its environment" \
    lacks "$(docker compose ps -q | xargs docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}')" "$admin_token"
  check "api reads the headers of traces from OTEL_EXPORTER_OTLP_HEADERS_FILE" \
    [ "$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$(container_of api)" | grep -E '^OTEL_EXPORTER_OTLP_HEADERS(_FILE)?=' | sort | tr '\n' ' ')" = \
      "OTEL_EXPORTER_OTLP_HEADERS= OTEL_EXPORTER_OTLP_HEADERS_FILE=/secrets/otlp-headers " ]
  check "...and no container has the headers in its environment" \
    lacks "$(docker compose ps -q | xargs docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}')" "$otlp_value"
  if [ "$db" = bundled ]; then
    check "postgres reads POSTGRES_PASSWORD_FILE" \
      contains "$(docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}' "$(container_of postgres)")" "POSTGRES_PASSWORD_FILE=/run/secrets/postgres_password"
    check "...and its password is not in the environment of a container" \
      lacks "$(docker compose ps -q | xargs docker inspect -f '{{range .Config.Env}}{{println .}}{{end}}')" "$pg_password"
  else
    check "the external database: api reads SDLC_DATABASE_URL_FILE" docker compose exec -T api /api dbcheck
  fi
  me="$(curl -sf "${auth[@]}" "$base/v1/auth/me" || true)"
  check "the administrator token of the file signs in (is_admin)" contains "$me" '"is_admin":true'
fi

# --- installation name -------------------------------------------------------------
info "installation name"
check ".env keeps the installation name: COMPOSE_PROJECT_NAME=$name" grep -qxF "COMPOSE_PROJECT_NAME=$name" .env
# From here on nothing carries the name but .env, as in cron or a new
# terminal: before v0.7.1 this export alone kept the commands on this stack.
unset COMPOSE_PROJECT_NAME
# projects_in DIR: the compose projects docker compose sees from DIR.
projects_in() { fresh "$1" docker compose ps -a --format '{{.Project}}' | sort -u | tr '\n' ' '; }
check "docker compose here without the variable sees only $name" [ "$(projects_in "$work/cadence")" = "$name " ]
# started DIR: the containers of DIR with their start times.
started() {
  fresh "$1" docker compose ps -a -q | xargs docker inspect -f '{{.Name}} {{.State.StartedAt}}' | sort
}
started_before="$(started "$work/cadence")"
info "get-cadence.sh --dir same-name with COMPOSE_PROJECT_NAME=$name: the name is taken"
code=0
out="$(cd "$work" && PATH="$work/nogit:$PATH" CADENCE_RELEASES_URL="file://$work/releases" COMPOSE_PROJECT_NAME="$name" \
  sh -s -- --dir same-name --mode proxy --http-addr "127.0.0.1:$second_port" --yes <"$repo/get-cadence.sh" 2>&1)" || code=$?
if [ "$code" = 0 ]; then
  fail "a second installation under the name $name must be refused"
else
  check "...exit 1" [ "$code" = 1 ]
  check "a second installation under the name $name is refused, naming it and --name" \
    contains "$out" "the installation name '$name' is taken on this machine: the installation in $work/cadence uses it"
  check "...and the refusal suggests --name" contains "$out" "--name $name-2"
fi
check "the refused installation wrote no .env" [ ! -e "$work/same-name/.env" ]
# A free name on the port of the first installation: the port is busy.
code=0
out="$(cd "$work" && PATH="$work/nogit:$PATH" CADENCE_RELEASES_URL="file://$work/releases" \
  sh -s -- --dir busy-port --name "$second_name" --mode proxy --http-addr "127.0.0.1:$port" --yes <"$repo/get-cadence.sh" 2>&1)" || code=$?
check "an installation on the port of the first one is refused: port $port is in use, exit 1" \
  [ "$code" = 1 ]
check "...naming the port" contains "$out" "port $port is already in use"
check "the refused installation on a busy port wrote no .env" [ ! -e "$work/busy-port/.env" ]
check "the first installation was not touched (same containers, same start times)" [ "$(started "$work/cadence")" = "$started_before" ]

# --- local compose changes -------------------------------------------------------
info "compose.override.yml"
check "COMPOSE_FILE lists compose.override.yml" contains "$COMPOSE_FILE" ":compose.override.yml"
cp compose.override.yml "$work/override.orig"
cat >>compose.override.yml <<'YAML'
  api:
    extra_hosts: ["host.docker.internal:host-gateway"]
YAML
sed -i.bak 's/^services: {}$/services:/' compose.override.yml && rm -f compose.override.yml.bak
check "docker compose picks the override up with no edit of .env (extra_hosts of api)" \
  contains "$(docker compose config --format json | jq -c '.services.api.extra_hosts')" "host.docker.internal"
cp "$work/override.orig" compose.override.yml

# --- platform ------------------------------------------------------------------------
# The images are built for linux/amd64 and linux/arm64 and compose pins no
# platform: the containers must run natively, not under emulation.
info "platform"
case "$(docker info --format '{{.Architecture}}')" in
x86_64 | amd64) host_platform=linux/amd64 ;;
aarch64 | arm64) host_platform=linux/arm64 ;;
*) host_platform="linux/$(docker info --format '{{.Architecture}}')" ;;
esac
for service in api ui caddy; do
  check "$service runs natively ($host_platform)" \
    [ "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$(docker compose images -q "$service")")" = "$host_platform" ]
done

# --- images --------------------------------------------------------------------------
# The containers run what compose names: the tag of VERSION with the digest
# the package pins, or the tag alone with the pin dropped (images of a branch).
# caddy runs the frontend image, as ui does (since CLAB-234).
info "images"
compose_json="$(docker compose config --format json)"
for service in api worker ui caddy; do
  want="$(jq -r ".services.$service.image" <<<"$compose_json")"
  check "$service runs $want" [ "$(docker inspect --format '{{.Config.Image}}' "$(docker compose ps -q "$service")")" = "$want" ]
done
for image in backend frontend; do
  var="CADENCE_$(tr '[:lower:]' '[:upper:]' <<<"$image")_DIGEST"
  if [ -z "${!var+set}" ]; then
    check "$image is pinned by digest ($version@sha256:...)" contains "$compose_json" "/sdlc-pipeline-$image:$version@sha256:"
  else
    info "$var is set (${!var:-empty}): $image as the variable says"
  fi
done

# --- users ---------------------------------------------------------------------------
# CLAB-236: the frontend image runs as uid 65532 from v0.14.0, ui runs as the
# user of its image and caddy as root (user "0:0" in compose: its volumes
# hold the certificates of existing installations, owned by root). The uid
# is that of the process, PID 1 of the container.
info "users"
uid_of() { docker exec "$(docker compose ps -q "$1")" awk '/^Uid:/ { print $2 }' /proc/1/status 2>/dev/null; }
ui_uid="$(uid_of ui)"
ui_image_user="$(docker image inspect --format '{{.Config.User}}' "$(docker compose images -q ui)")"
ui_image_uid="${ui_image_user%%:*}"
check "ui runs as the user of its image (uid ${ui_uid:-?}, image user '${ui_image_user}')" [ -n "$ui_uid" -a "$ui_uid" = "${ui_image_uid:-0}" ]
check "caddy runs as root (uid $(uid_of caddy))" [ "$(uid_of caddy)" = 0 ]
if version_lt "$version" v0.14.0; then
  info "VERSION is $version: the frontend image runs as root before v0.14.0, the non-root ui is not checked"
else
  check "ui is no root: uid 65532 ($ui_uid)" [ "$ui_uid" = 65532 ]
fi
# CLAB-248: the frontend image listens on :8080 since v0.14.0 and on :8080
# only since v0.16.0, with no file capability on its Caddy binary. Asked
# from the caddy container, as the Caddyfile of the package goes there.
# Images of a branch (CADENCE_FRONTEND_DIGEST set, even empty) are checked
# as the next release whatever VERSION says.
ui_get() { docker compose exec -T caddy wget -q -T 3 -O /dev/null "http://ui:$1/" >/dev/null 2>&1; }
ui_closed() { ! ui_get "$1"; }
if version_lt "$version" v0.14.0; then
  info "VERSION is $version: the frontend image listens on :80 only before v0.14.0, its ports are not checked"
else
  check "ui answers on :8080" ui_get 8080
  if version_lt "$version" v0.16.0 && [ -z "${CADENCE_FRONTEND_DIGEST+set}" ]; then
    info "VERSION is $version: the frontend image of v0.14.x and v0.15.x answers on :80 too, :80 closed is checked from v0.16.0 (or on images of a branch, CADENCE_FRONTEND_DIGEST=)"
  else
    check "ui does not answer on :80" ui_closed 80
    # shellcheck disable=SC2016 # expanded in the container
    check "the Caddy binary of ui has no file capability" \
      docker compose exec -T ui sh -c 'command -v getcap && [ -z "$(getcap /usr/bin/caddy)" ]'
  fi
fi
check "no permission denied in the logs of ui and caddy" \
  lacks "$(docker compose logs ui caddy 2>&1 | tr '[:upper:]' '[:lower:]')" "permission denied"

# --- proxy mode and routing ----------------------------------------------------------
info "proxy mode"
check "/readyz answers 200" [ "$(http_code "$base/readyz")" = 200 ]
check "/healthz answers 200" [ "$(http_code "$base/healthz")" = 200 ]
check "/ serves the UI" html
webhook_code="$(http_code -X POST -H 'X-GitHub-Event: ping' -d '{}' "$base/webhooks/github")"
check "/webhooks/github reaches the API and rejects an unsigned delivery ($webhook_code)" client_error "$webhook_code"
check "caddy does not try ACME in proxy mode" lacks "$(docker compose logs caddy 2>&1 | tr '[:upper:]' '[:lower:]')" acme

# --- agent kit and /docs --------------------------------------------------------------
# clab setup takes the agent kit from the instance (since v0.12.0): an open
# GET /v1/agent-kit with the version of the server, reaching the API through
# the same /v1/* route of Caddy. The page /docs is a route of the UI. Images
# of a branch (a pin variable set) are checked whatever VERSION says.
info "agent kit"
check "/docs serves the UI" bash -c "curl -sf '$base/docs' | grep -qi '<html'"
if version_lt "$version" v0.12.0 && [ -z "${CADENCE_BACKEND_DIGEST+set}" ]; then
  info "skipped: the images of $version have no agent kit (v0.12.0+); images of a branch are checked with CADENCE_BACKEND_DIGEST="
else
  check "/v1/agent-kit answers 200 without a token" [ "$(http_code "$base/v1/agent-kit")" = 200 ]
  kit="$(curl -sf "$base/v1/agent-kit" || true)"
  check "the agent kit has the version of the stack: $version" [ "$(jq -r '.version' <<<"$kit" 2>/dev/null)" = "$version" ]
  check "the agent kit has clab-work, clab-guide and the agent clab-stage" \
    [ "$(jq -r '[.skills[].name, .agents[].name] | map(select(. == "clab-work" or . == "clab-guide" or . == "clab-stage")) | length' <<<"$kit" 2>/dev/null)" = 3 ]
fi

# --- metrics -------------------------------------------------------------------------
# Prometheus metrics (since v0.10.0): each process listens on :9090 inside the
# network, nothing is published, Caddy does not serve them. Read from the
# caddy container - its busybox has wget. The images of VERSION before
# v0.10.0 have no listener; images of a branch (a pin variable set) are
# checked whatever VERSION says, since that is how a branch with metrics is
# checked before its release.
info "metrics"
if version_lt "$version" v0.10.0 && [ -z "${CADENCE_BACKEND_DIGEST+set}" ]; then
  info "skipped: the images of $version have no metrics (v0.10.0+); images of a branch are checked with CADENCE_BACKEND_DIGEST="
else
  scrape() { docker compose exec -T caddy wget -qO- "http://$1:9090/metrics" 2>/dev/null; }
  # build_info SERVICE: its cadence_build_info line, labels in name order.
  build_info() { scrape "$1" | grep '^cadence_build_info{' || true; }
  # The worker starts once the API is healthy: give its listener a moment.
  for _ in $(seq 30); do
    [ -z "$(build_info worker)" ] || break
    sleep 1
  done
  for service in api worker; do
    line="$(build_info "$service")"
    check "$service serves /metrics on :9090 with cadence_build_info of $version" \
      contains "$line" "component=\"$service\""
    check "...version=\"$version\"" contains "$line" "version=\"$version\""
  done
  api_metrics="$(scrape api)"
  worker_metrics="$(scrape worker)"
  check "api counts requests by route template (/readyz)" contains "$api_metrics" 'route="/readyz"'
  check "api reports the database pool" contains "$api_metrics" "cadence_db_pool_max_connections "
  check "worker reports the index queue" contains "$worker_metrics" 'cadence_index_queue_runs{state="queued"}'
  check "worker reports leases" contains "$worker_metrics" 'cadence_leases{state="live"}'
  check "worker has passed lease_sweep" contains "$worker_metrics" 'cadence_worker_job_last_success_timestamp_seconds{job="lease_sweep"}'
  check "api has go_* and process_* metrics" contains "$api_metrics" "process_cpu_seconds_total "
  check "/metrics through caddy serves no metrics" lacks "$(curl -s "$base/metrics")" cadence_build_info
  # The table of docs/admin.md is the list: every cadence_* metric the
  # processes expose is in it, and everything in it is exposed. A row marked
  # "(from vX.Y.Z)" documents a metric ahead of its release: the images of an
  # older VERSION do not expose it yet, and the release PR that brings it
  # must not have to touch the table.
  exposed="$(printf '%s\n%s\n' "$api_metrics" "$worker_metrics" | sed -n 's/^# TYPE \(cadence_[a-z_]*\) .*/\1/p' | sort -u)"
  metric_rows="$(sed -n '/^## Monitoring/,/^## /p' "$repo/docs/admin.md" | grep '^| `cadence_' || true)"
  # shellcheck disable=SC2016 # backticks of the markdown table, not a command
  documented="$(sed -n 's/^| `\(cadence_[a-z_]*\)`.*/\1/p' <<<"$metric_rows" | sort -u)"
  released="$(while IFS= read -r row; do
    since="$(sed -n 's/.*(from \(v[0-9][0-9.]*\)).*/\1/p' <<<"$row")"
    if [ -n "$since" ] && version_lt "$version" "$since"; then continue; fi
    # shellcheck disable=SC2016 # backticks of the markdown table, not a command
    sed -n 's/^| `\(cadence_[a-z_]*\)`.*/\1/p' <<<"$row"
  done <<<"$metric_rows" | sort -u)"
  check "every exposed cadence_* metric is in the table of docs/admin.md" \
    [ -z "$(comm -23 <(printf '%s\n' "$exposed") <(printf '%s\n' "$documented"))" ]
  check "every metric in the table of docs/admin.md is exposed (rows from a later release aside)" \
    [ -z "$(comm -13 <(printf '%s\n' "$exposed") <(printf '%s\n' "$released"))" ]
  [ -n "$exposed" ] || fail "no cadence_* metrics exposed"
fi

info "tls mode configuration"
tls_json="$(docker compose run --rm --no-deps -T -e CADENCE_MODE=tls -e SDLC_DOMAIN=cadence.example.com \
  -e ACME_EMAIL=ops@example.com caddy caddy adapt --config /etc/caddy/Caddyfile 2>/dev/null)"
check "tls mode listens on :443" contains "$tls_json" '":443"'
check "tls mode serves the domain" contains "$tls_json" '"cadence.example.com"'
check "tls mode issues the certificate with ACME" contains "$tls_json" '"module":"acme"'
check "MCP is proxied without buffering" contains "$tls_json" '"flush_interval":-1'

# --- instance ------------------------------------------------------------------------------
info "instance"
instance="$(curl -sf "$base/v1/instance")"
check "/v1/instance reports version $version" contains "$instance" "\"version\":\"$version\""
check "/v1/instance reports tenancy single" contains "$instance" '"tenancy":"single"'
check "/v1/instance reports project_creation teams" contains "$instance" '"project_creation":"teams"'
me="$(curl -sf "${auth[@]}" "$base/v1/auth/me" || true)"
check "the administrator token signs in (is_admin)" contains "$me" '"is_admin":true'

# --- CLI ---------------------------------------------------------------------------------------
info "clab"
printf '%s\n' "$admin_token" | "$clab" auth login --host "$base" --with-token
check "clab version" "$clab" --host "$base" version
check "clab team create" "$clab" --host "$base" team create check --name "Package check"
check "clab project create --team" "$clab" --host "$base" project create CHECK --name "Package check" --team check

mcp="$(curl -s "${auth[@]}" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' "$base/mcp/projects/CHECK")"
check "MCP tools/list on /mcp/projects/CHECK lists sdlc_claim_task" contains "$mcp" '"sdlc_claim_task"'

# --- first cycle and roles: the starter bundle (docs/admin.md, "First cycle and roles") ------
info "starter bundle"
if "$clab" --host "$base" token create --project CHECK --name before-bundle --for agent:check-bot --roles developer >/dev/null 2>&1; then
  fail "a token with --roles on a project without roles must be refused"
else
  pass "a token with --roles on a project without roles is refused"
fi
check "clab import --dry-run reports the bundle" "$clab" --host "$base" import --project CHECK --file bundles/starter.json --dry-run
check "clab import applies the bundle" "$clab" --host "$base" import --project CHECK --file bundles/starter.json
roles="$("$clab" --host "$base" role show analyst --project CHECK --json 2>/dev/null || true)"
check "the project has the analyst role" contains "$roles" '"analyst"'
drafts="$("$clab" --host "$base" workflow list --project CHECK --json |
  jq -r '(if type == "array" then . else (.workflows // .items) end)[] | select(.state == "draft") | .id')"
check "the bundle brings two draft cycles (tasks and epics)" [ "$(grep -c . <<<"$drafts")" = 2 ]
for id in $drafts; do
  check "clab workflow activate $id" "$clab" --host "$base" workflow activate "$id" --project CHECK
done
active="$("$clab" --host "$base" workflow list --project CHECK --json |
  jq -r '(if type == "array" then . else (.workflows // .items) end)[] | select(.state == "active") | .task_types[]' | sort | tr '\n' ' ')"
check "active cycles cover task and epic ($active)" [ "$active" = "epic task " ]
# A second import changes nothing. Cycles report unchanged since v0.5.2
# (CLAB-108); v0.5.1 and older create a new draft of each cycle every time.
again="$("$clab" --host "$base" import --project CHECK --file bundles/starter.json --json)"
check "a second import leaves the roles unchanged" [ "$(jq -r '[.roles[].outcome] | unique | join(",")' <<<"$again")" = unchanged ]
cycles_again=unchanged
if version_lt "$version" v0.5.2; then cycles_again=draft_created; fi
check "a second import leaves the cycles $cycles_again" [ "$(jq -r '[.workflows[].outcome] | unique | join(",")' <<<"$again")" = "$cycles_again" ]

info "first task"
check "clab create a task" "$clab" --host "$base" create --project CHECK --title "First task"
check "clab create an epic" "$clab" --host "$base" create --project CHECK --title "First epic" --type epic
check "clab transition start" env SDLC_PROJECT=CHECK "$clab" --host "$base" transition CHECK-1 --to start
agent_token="$("$clab" --host "$base" token create --project CHECK --name check-agent --for agent:check-bot --roles analyst --json | jq -r .token)"
if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::add-mask::$agent_token"; fi
check "a token with --roles analyst is issued" [ "${agent_token#sdlc_}" != "$agent_token" ]
queue="$(env SDLC_API_URL="$base" SDLC_TOKEN="$agent_token" SDLC_PROJECT=CHECK "$clab" queue --json)"
check "the agent sees CHECK-1 in its queue" contains "$queue" '"CHECK-1"'
check "the agent claims CHECK-1 as analyst" env SDLC_API_URL="$base" SDLC_TOKEN="$agent_token" SDLC_PROJECT=CHECK "$clab" claim CHECK-1
gates="$(env SDLC_PROJECT=CHECK "$clab" --host "$base" gates CHECK-1 --json)"
check "analysis_done waits for the artifacts and a human approval" contains "$gates" 'human_approval'
# Order of tasks (CLAB-107): a task blocked by an open one does not start.
check "clab create a second task" "$clab" --host "$base" create --project CHECK --title "Second task"
check "clab relate CHECK-1 blocks CHECK-3" env SDLC_PROJECT=CHECK "$clab" --host "$base" relate CHECK-1 --to CHECK-3 --rel blocks
blocked="$(env SDLC_PROJECT=CHECK "$clab" --host "$base" transition CHECK-3 --to start 2>&1 || true)"
check "the start of a blocked task is held by dependencies_closed" contains "$blocked" 'dependencies_closed'

if [ "$db" = bundled ]; then
  info "docker compose down and up -d, without -v"
  # The data stays in the named volume postgres: no anonymous volume to lose.
  docker compose down >/dev/null 2>&1
  docker compose up -d >/dev/null 2>&1
  check "the stack is ready again" wait_ready 180
  check "...with the tasks created before" contains "$(env SDLC_PROJECT=CHECK "$clab" --host "$base" show CHECK-3 --json 2>/dev/null)" '"Second task"'
  bundled_db_checks "after down and up"
fi

# --- clab server -------------------------------------------------------------------------------------
# The clab of the package, from the installation, as docs/admin.md shows it.
clab_status() { "$pkg_clab" server status "$@"; }
info "clab server status (bin/clab-$platform)"
if true; then
  status="$(clab_status)"
  check "status names the installation directory" contains "$status" "$work/cadence"
  check "status reports the stack $version (VERSION)" contains "$status" "$version (VERSION)"
  clab_version="$(clab_status --json | jq -r '.clab // empty')"
  check "status reports the version of clab (${clab_version:-none})" grep -qE "^clab: +${clab_version:-none}\$" <<<"$status"
  check "status reports an installation from the package" contains "$status" "package"
  check "status names the clab of the package: $version" grep -qE "^clab: +$version\$" <<<"$status"
  check "status reports the services" contains "$status" "api"
  check "status names the installation: $name (.env)" grep -qE "^Name: +$name \(\.env\)\$" <<<"$status"
  if [ "$db" = external ]; then
    check "status names the external database with its sslmode" \
      [ "$(sed -nE 's/^Database: +//p' <<<"$status")" = "$ext_status" ]
    check "status --json .database" \
      [ "$(clab_status --json | jq -r .database)" = "$ext_status" ]
    check "status shows no password of the database" lacks "$status$(clab_status --json)" "$EXT_DB_PASSWORD_URL"
  else
    check "status names the bundled database" grep -qE "^Database: +bundled\$" <<<"$status"
  fi
  check "status --json reports .name $name from .env" \
    [ "$(clab_status --json | jq -r '"\(.name) \(.name_from)"')" = "$name .env" ]
  if out="$(COMPOSE_PROJECT_NAME=other clab_status 2>&1)"; then
    check "status with COMPOSE_PROJECT_NAME=other warns, naming both" \
      contains "$out" "! COMPOSE_PROJECT_NAME is 'other' in the environment, but this installation is '$name'"
    check "...and still lists the services of $name" contains "$out" "api"
  else
    fail "status with COMPOSE_PROJECT_NAME=other must not fail: $out"
  fi
  mkdir -p "$work/cadence/docs/sub"
  check "status from a subdirectory finds the installation" \
    contains "$(cd "$work/cadence/docs/sub" && clab_status)" "$work/cadence"
  check "status with CADENCE_DIR from / finds the installation" \
    contains "$(cd / && CADENCE_DIR="$work/cadence" clab_status)" "$work/cadence"
  rmdir "$work/cadence/docs/sub"
  if out="$(cd "$work" && clab_status 2>&1)"; then
    fail "status outside an installation must fail"
  else
    check "status outside an installation fails and points at --dir" contains "$out" "--dir"
  fi
fi

# An external clab of the same version - the clab of the tap, which the
# package carries byte for byte - outside the installation: it serves the
# installation the wrappers made, by --dir.
info "an external clab: clab server --dir"
mkdir -p "$work/ext"
cp "$pkg_clab" "$work/ext/clab"
ext_clab="$work/ext/clab"
ext_clab_status="$(cd "$work" && { "$ext_clab" server status --dir "$work/cadence" 2>&1 || true; })"
check "the external clab: status --dir names the installation and $version" contains "$ext_clab_status" "$version (VERSION)"
dumps_before_ext="$(find backups -maxdepth 1 -name 'cadence-*.sql.gz' | wc -l | tr -d ' ')"
sleep 1
if ext_out="$(cd "$work" && PATH="$work/nogit:$PATH" "$ext_clab" server backup --dir "$work/cadence" 2>&1)"; then
  pass "the external clab: backup --dir of the installation of the wrappers"
else
  fail "the external clab: backup --dir failed: $ext_out"
fi
check "...into its backups/" [ "$(find backups -maxdepth 1 -name 'cadence-*.sql.gz' | wc -l | tr -d ' ')" -gt "$dumps_before_ext" ]

# backup_cmd / restore_cmd: the scripts of the installation.
backup_cmd() { ./backup.sh; }
restore_cmd() { ./restore.sh "$@"; }

# portable_dump FILE: no owners, privileges or extensions in the dump.
portable_dump() {
  ! gunzip -c "$1" | grep -qE '^(ALTER .* OWNER TO|GRANT |REVOKE |CREATE EXTENSION|COMMENT ON EXTENSION)'
}

# --- backup and restore ----------------------------------------------------------------------------
info "backup"
if [ "$db" = external ]; then
  # Every command line of the machine while the backup runs: the password of
  # the database must be in none of them (ps shows them to every user; on
  # Linux the processes of containers too).
  (while :; do ps -eo args 2>/dev/null; sleep 0.1; done) >"$work/ps.log" &
  sampler=$!
  backup_out="$(backup_cmd 2>&1)" || { printf '%s\n' "$backup_out" >&2; fail "backup of the external database failed"; }
  kill "$sampler" 2>/dev/null || true
  wait "$sampler" 2>/dev/null || true
  printf '%s\n' "$backup_out"
  check "backup names the external database" contains "$backup_out" "dumping the external database $ext_label"
  check "backup prints no password" lacks "$backup_out" "$EXT_DB_PASSWORD"
  check "no command line during the backup carried the password ($(grep -c . "$work/ps.log") lines sampled)" \
    lacks "$(cat "$work/ps.log")" "$EXT_DB_PASSWORD"
  check "...nor its URL-encoded form" lacks "$(cat "$work/ps.log")" "$EXT_DB_PASSWORD_URL"
  check "pg_dump of the backup client ran" grep -q 'pg_dump -d postgres://cadence@' "$work/ps.log"
else
  backup_cmd
fi
dump="$(find backups -maxdepth 1 -name "cadence-$version-*.sql.gz" | sort | tail -n 1)"
check "backup writes cadence-$version-*.sql.gz" [ -n "$dump" ]
check "the dump is larger than 1 KB" [ "$(wc -c <"${dump:-/dev/null}" | tr -d ' ')" -gt 1024 ]
check "the dump has mode 600" [ "$(stat -c %a "${dump:-/dev/null}" 2>/dev/null || stat -f %Lp "${dump:-/dev/null}")" = 600 ]
check "the blobs volume is archived next to it" [ -f "${dump%.sql.gz}.blobs.tar.gz" ]
check "the dump carries no owners, privileges or extensions (portable between the modes)" \
  portable_dump "$dump"

if [ "$db" = external ]; then
  info "backup of an unreachable external database"
  dumps_before="$(find backups -maxdepth 1 -name 'cadence-*.sql.gz' | sort)"
  docker stop "$EXT_DB_NAME" >/dev/null
  sleep 1
  code=0
  out="$(backup_cmd 2>&1)" || code=$?
  check "backup of an unreachable database fails: exit 1" [ "$code" = 1 ]
  check "...and leaves no dump" [ "$(find backups -maxdepth 1 -name 'cadence-*.sql.gz' | sort)" = "$dumps_before" ]
  check "...and prints no password" lacks "$out" "$EXT_DB_PASSWORD"
  docker start "$EXT_DB_NAME" >/dev/null
  for _ in $(seq 1 60); do
    ext_db_query cadence 'SELECT 1' >/dev/null 2>&1 && break
    sleep 1
  done
  # The API may have lost its connections: wait until it answers again.
  for _ in $(seq 1 30); do
    [ "$(http_code "$base/readyz")" = 200 ] && break
    sleep 2
  done
fi

"$clab" --host "$base" project create AFTER --name "Created after the backup" --team check >/dev/null
check "a project created after the backup exists" contains "$("$clab" --host "$base" project list --json)" '"AFTER"'

info "restore"
# stdin is /dev/null, as under cron: a character device, but not a terminal.
code=0
out="$(restore_cmd "$dump" </dev/null 2>&1)" || code=$?
check "./restore.sh without a terminal and --yes refuses: exit 1" [ "$code" = 1 ]
check "...and asks for --yes" contains "$out" "run it in a terminal or pass --yes"
check "the refusal leaves the project created after the backup" contains "$("$clab" --host "$base" project list --json)" '"AFTER"'
restore_cmd --yes "$dump"
projects="$("$clab" --host "$base" project list --json)"
check "after restore the project from before the backup is there" contains "$projects" '"CHECK"'
check "after restore the project created after the backup is gone" lacks "$projects" '"AFTER"'
check "/readyz answers 200 after restore" [ "$(http_code "$base/readyz")" = 200 ]

# --- off-machine copy and verify (CLAB-132) --------------------------------------------
# A stand-in bucket (ci/s3.sh) in the network of the installation: the copy
# after every backup, the retention of BACKUP_S3_KEEP, a multipart upload,
# the refusals of a wrong key and an unreachable endpoint, verify from the
# bucket and from a file - the stack keeps running, nothing is left behind -
# and its refusals, fetch, and the warning of an upgrade. Needs /api
# backup-s3 (v0.10.0+): images of VERSION from v0.10.0 on, or images of a
# branch (a pin variable set).
backup_with() { ./backup.sh "$@"; }
# shellcheck disable=SC2120 # FILE is passed through check
verify_cmd() { ./backup.sh verify "$@"; }
fetch_cmd() { ./backup.sh fetch "$@"; }
upgrade_cmd() { ./upgrade.sh "$@"; }
counts_sql="SELECT (SELECT count(*) FROM projects) || ' ' || (SELECT count(*) FROM tasks) || ' ' || (SELECT count(*) FROM artifacts)"
live_counts() {
  if [ "$db" = external ]; then
    ext_db_query cadence "$counts_sql"
  else
    docker compose exec -T postgres psql -X -At -U "${POSTGRES_USER:-sdlc}" -d "${POSTGRES_DB:-sdlc}" -c "$counts_sql"
  fi
}
# verify_left: what a verify of this installation could leave - containers
# and networks with its label, and dangling volumes.
verify_left() {
  docker ps -a -q --filter "label=com.cadence.verify=$name"
  docker network ls -q --filter "label=com.cadence.verify=$name"
  docker volume ls -q --filter dangling=true | sort
}
# with_ps CMD...: CMD with every command line of the machine sampled into
# $work/ps.log (the secret of the bucket must be in none of them).
with_ps() {
  local sampler rc=0
  (while :; do ps -eo args 2>/dev/null; sleep 0.1; done) >>"$work/ps.log" &
  sampler=$!
  "$@" || rc=$?
  kill "$sampler" 2>/dev/null || true
  wait "$sampler" 2>/dev/null || true
  return "$rc"
}

if version_lt "$version" v0.10.0 && [ -z "${CADENCE_BACKEND_DIGEST+set}" ]; then
  info "skipped: the images of $version have no /api backup-s3 (v0.10.0+); images of a branch are checked with CADENCE_BACKEND_DIGEST="
else
  info "off-machine copy"
  out="$(backup_cmd 2>&1)"
  check "without BACKUP_S3_BUCKET backup says nothing about S3" lacks "$out" "s3://"
  check "...and uploads nothing" lacks "$out" "upload"

  # shellcheck source=ci/s3.sh
  . "$repo/ci/s3.sh"
  s3_up "$name-s3" "${CHECK_S3_PORT:-$((port + 4))}" "${name}_default"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::add-mask::$S3_SECRET"; fi
  env_set BACKUP_S3_BUCKET "$S3_BUCKET"
  env_set BACKUP_S3_ENDPOINT "$S3_ENDPOINT"
  env_set BACKUP_S3_PREFIX nightly/
  secret_set BACKUP_S3_ACCESS_KEY_ID "$S3_ACCESS_KEY"
  secret_set BACKUP_S3_SECRET_ACCESS_KEY "$S3_SECRET"
  env_set BACKUP_S3_KEEP 2
  if [ "$secrets_mode" = files ]; then
    check ".env holds no value of the bucket keys, only their files" \
      [ "$(grep -E '^BACKUP_S3_(ACCESS_KEY_ID|SECRET_ACCESS_KEY)(_FILE)?=' .env | LC_ALL=C sort | tr '\n' ' ')" = \
        "BACKUP_S3_ACCESS_KEY_ID= BACKUP_S3_ACCESS_KEY_ID_FILE=/secrets/backup-s3-access-key-id BACKUP_S3_SECRET_ACCESS_KEY= BACKUP_S3_SECRET_ACCESS_KEY_FILE=/secrets/backup-s3-secret-access-key " ]
  fi
  printf 'not a backup\n' >"$work/other.txt"
  s3_put "$work/other.txt" nightly/other.txt
  s3_put "$work/other.txt" "elsewhere/cadence-$version-20000101-000000.sql.gz"
  s3_put "$work/other.txt" "nightly/deeper/cadence-$version-20000101-000000.sql.gz"
  : >"$work/ps.log"

  if out="$(with_ps backup_cmd 2>&1)"; then pass "backup with the bucket succeeds"; else fail "backup with the bucket failed: $out"; fi
  printf '%s\n' "$out" | tail -n 3
  dump="$(find backups -maxdepth 1 -name "cadence-$version-*.sql.gz" | sort | tail -n 1)"
  stem="$(basename "${dump%.sql.gz}")"
  check "it prints ✓ uploaded to s3://$S3_BUCKET/nightly/" contains "$out" "✓ uploaded $stem.sql.gz, $stem.blobs.tar.gz, $stem.sha256 to s3://$S3_BUCKET/nightly/"
  keys="$(s3_keys nightly/)"
  for suffix in .sql.gz .blobs.tar.gz .sha256; do
    check "the bucket has nightly/$stem$suffix" grep -qxF "nightly/$stem$suffix" <<<"$keys"
  done
  s3_get "nightly/$stem.sql.gz" "$work/from-s3.sql.gz"
  check "the dump in the bucket is the local dump byte for byte" [ "$(sha256_of "$work/from-s3.sql.gz")" = "$(sha256_of "$dump")" ]
  s3_get "nightly/$stem.sha256" "$work/from-s3.sha256"
  check ".sha256 in the bucket holds the sum of the dump" grep -qxF "$(sha256_of "$dump")  $stem.sql.gz" "$work/from-s3.sha256"

  # A dump larger than a part goes up in parts and comes back whole.
  mkdir -p "$work/big"
  head -c $((12 * 1024 * 1024 + 4321)) /dev/urandom >"$work/big/cadence-$version-20000101-000001.sql.gz"
  chmod 600 "$work/big/cadence-$version-20000101-000001.sql.gz"
  BACKUP_S3_BUCKET="$S3_BUCKET" BACKUP_S3_ENDPOINT="$S3_ENDPOINT" BACKUP_S3_PREFIX=big/ BACKUP_S3_KEEP=5 \
    BACKUP_S3_ACCESS_KEY_ID="$S3_ACCESS_KEY" BACKUP_S3_SECRET_ACCESS_KEY="$S3_SECRET" \
    docker compose run --rm --no-deps -T --user "$(id -u):$(id -g)" -e BACKUP_S3_BUCKET -e BACKUP_S3_ENDPOINT \
    -e BACKUP_S3_PREFIX -e BACKUP_S3_KEEP -e BACKUP_S3_ACCESS_KEY_ID -e BACKUP_S3_SECRET_ACCESS_KEY \
    -v "$work/big:/backups" api backup-s3 put --part-size 5242880 "/backups/cadence-$version-20000101-000001.sql.gz" >/dev/null
  s3_get "big/cadence-$version-20000101-000001.sql.gz" "$work/big.back"
  check "a 12 MB dump goes up in 5 MiB parts and comes back whole" \
    [ "$(sha256_of "$work/big.back")" = "$(sha256_of "$work/big/cadence-$version-20000101-000001.sql.gz")" ]

  # Retention: BACKUP_S3_KEEP=2 after four backups.
  for _ in 1 2 3; do
    sleep 1
    with_ps backup_cmd >/dev/null 2>&1 || fail "a backup with the bucket failed"
  done
  # Right under the prefix: the objects of nightly/deeper/ are not backups.
  keys="$(s3_keys nightly/ | grep -E '^nightly/[^/]+$')"
  check "the bucket keeps BACKUP_S3_KEEP=2 backups" [ "$(grep -c '\.sha256$' <<<"$keys")" = 2 ]
  check "...each with its dump and blobs archive" \
    [ "$(grep -c '\.sql\.gz$' <<<"$keys")$(grep -c '\.blobs\.tar\.gz$' <<<"$keys")" = 22 ]
  newest="$(find backups -maxdepth 1 -name "cadence-$version-*.sql.gz" | sort | tail -n 2 | xargs -n 1 basename | sed 's/\.sql\.gz$//' | sort)"
  check "...the newest two" [ "$(grep '\.sha256$' <<<"$keys" | sed 's:^nightly/::; s/\.sha256$//' | sort)" = "$newest" ]
  check "...and leaves a foreign object of the prefix" grep -qxF nightly/other.txt <<<"$keys"
  check "...and the objects of a deeper prefix" [ -n "$(s3_keys nightly/deeper/)" ]
  check "...and the objects outside the prefix" [ -n "$(s3_keys elsewhere/)" ]

  # Refusals: the local backup stays, the bucket is untouched, status 1.
  for broken in "BACKUP_S3_SECRET_ACCESS_KEY:wrong$(openssl rand -hex 8)" "BACKUP_S3_ENDPOINT:http://s3stand-nowhere:7070"; do
    key="${broken%%:*}"
    if [ "$key" = BACKUP_S3_SECRET_ACCESS_KEY ]; then secret_set "$key" "${broken#*:}"; else env_set "$key" "${broken#*:}"; fi
    sleep 1
    dumps_before="$(find backups -maxdepth 1 -name 'cadence-*.sql.gz' | wc -l | tr -d ' ')"
    if out="$(with_ps backup_cmd 2>&1)"; then
      fail "backup with a broken $key must exit with status 1"
    else
      pass "backup with a broken $key exits with status 1"
    fi
    check "...prints why the copy failed" contains "$out" "✗ the off-machine copy of"
    check "...keeps the local backup" [ "$(find backups -maxdepth 1 -name 'cadence-*.sql.gz' | wc -l | tr -d ' ')" -gt "$dumps_before" ]
    check "...and the copies in the bucket" [ "$(s3_keys nightly/ | grep -E '^nightly/[^/]+$')" = "$keys" ]
    if [ "$key" = BACKUP_S3_SECRET_ACCESS_KEY ]; then
      check "...with the answer of S3: 403" contains "$out" "403"
      secret_set "$key" "$S3_SECRET"
    else
      check "...naming the endpoint it could not reach" contains "$out" "s3stand-nowhere"
      env_set "$key" "$S3_ENDPOINT"
    fi
    check "...and no secret" lacks "$out" "$S3_SECRET"
    printf '%s\n' "$out" | grep -E '^✗' | head -n 2
  done
  sleep 1
  with_ps backup_cmd >/dev/null 2>&1 || fail "backup after the refusals failed"
  check "--no-upload takes a backup without the copy" lacks "$(sleep 1; backup_with --no-upload 2>&1)" "upload"

  info "verify"
  expected="$(live_counts)"
  read -r e_projects e_tasks e_artifacts <<<"$expected"
  started_before="$(started "$work/cadence")"
  left_before="$(verify_left)"
  (while :; do http_code "$base/readyz"; echo; sleep 0.5; done) >"$work/readyz.log" &
  poller=$!
  [ "$db" = bundled ] || dbs_before="$(ext_db_query postgres 'SELECT string_agg(datname, $$ $$ ORDER BY datname) FROM pg_database')"
  if out="$(with_ps verify_cmd 2>&1)"; then pass "verify of the newest backup succeeds"; else fail "verify failed: $out"; fi
  kill "$poller" 2>/dev/null || true
  wait "$poller" 2>/dev/null || true
  printf '%s\n' "$out"
  newest="$(grep '\.sha256$' <<<"$(s3_keys nightly/)" | sed 's:^nightly/::; s/\.sha256$//' | sort | tail -n 1)"
  check "verify takes the newest backup from the bucket" contains "$out" "▸ verifying $newest.sql.gz"
  check "...names the bucket" contains "$out" "from s3://$S3_BUCKET/nightly/"
  check "...names the schema of the images" contains "$out" "the schema of the images of $version"
  check "...counts what the database holds: $e_projects projects, $e_tasks tasks, $e_artifacts artifacts" \
    contains "$out" "$e_projects projects, $e_tasks tasks, $e_artifacts artifacts"
  check "...reads the blobs archive" contains "$out" "✓ blobs archive $newest.blobs.tar.gz:"
  check "/readyz answered 200 all along ($(grep -c . "$work/readyz.log") probes)" [ -z "$(grep -v '^200$' "$work/readyz.log")" ]
  check "...no container of the stack restarted" [ "$(started "$work/cadence")" = "$started_before" ]
  check "...and nothing is left: containers, networks, volumes" [ "$(verify_left)" = "$left_before" ]
  check "...nor the download in backups/" [ -z "$(find backups -maxdepth 1 -name '.verify-*')" ]
  if [ "$db" = external ]; then
    check "...and no database was created on the external server" \
      [ "$(ext_db_query postgres 'SELECT string_agg(datname, $$ $$ ORDER BY datname) FROM pg_database')" = "$dbs_before" ]
  fi
  check "verify FILE checks a local backup" verify_cmd "$dump"

  # A damaged copy: refused by its sum. A dump that does not load (with a
  # sum that matches): refused with the error of psql.
  s3_get "nightly/$newest.sql.gz" "$work/good.sql.gz"
  s3_get "nightly/$newest.sha256" "$work/good.sha256"
  cat "$work/good.sql.gz" >"$work/bad.sql.gz"
  printf 'tampered' >>"$work/bad.sql.gz"
  s3_put "$work/bad.sql.gz" "nightly/$newest.sql.gz"
  if out="$(verify_cmd 2>&1)"; then fail "verify of a damaged copy must fail"; else pass "verify of a damaged copy fails"; fi
  check "...by its checksum" contains "$out" "does not match"
  check "...and leaves nothing behind" [ "$(verify_left)" = "$left_before" ]
  gunzip -c "$work/good.sql.gz" >"$work/good.sql"
  head -c 4000 "$work/good.sql" | gzip >"$work/cut.sql.gz"
  printf '%s  %s.sql.gz\n' "$(sha256_of "$work/cut.sql.gz")" "$newest" >"$work/cut.sha256"
  grep -F '.blobs.tar.gz' "$work/good.sha256" >>"$work/cut.sha256" || true
  s3_put "$work/cut.sql.gz" "nightly/$newest.sql.gz"
  s3_put "$work/cut.sha256" "nightly/$newest.sha256"
  if out="$(verify_cmd 2>&1)"; then fail "verify of a dump that does not load must fail"; else pass "verify of a dump that does not load fails"; fi
  check "...with the error of psql" contains "$out" "psql"
  check "...and says it does not restore" contains "$out" "does not restore"
  check "...and leaves nothing behind" [ "$(verify_left)" = "$left_before" ]
  s3_put "$work/good.sql.gz" "nightly/$newest.sql.gz"
  s3_put "$work/good.sha256" "nightly/$newest.sha256"

  # Nothing to verify: an empty prefix and an empty BACKUP_DIR.
  env_set BACKUP_S3_PREFIX empty/
  env_set BACKUP_DIR "$work/no-backups"
  if out="$(verify_cmd 2>&1)"; then fail "verify with nothing to verify must fail"; else
    check "verify with nothing to verify fails: nothing to verify" contains "$out" "nothing to verify"
  fi
  env_set BACKUP_S3_PREFIX nightly/
  env_set BACKUP_DIR ""
  rm -rf "$work/no-backups"

  info "fetch"
  rm -f "backups/$newest.sql.gz" "backups/$newest.blobs.tar.gz"
  if out="$(fetch_cmd "$newest" 2>&1)"; then pass "fetch $newest succeeds"; else fail "fetch failed: $out"; fi
  check "...puts the dump into backups/ as it was uploaded" [ "$(sha256_of "backups/$newest.sql.gz")" = "$(sha256_of "$work/good.sql.gz")" ]
  check "...with the blobs archive" [ -f "backups/$newest.blobs.tar.gz" ]
  check "...and prints the restore command" contains "$out" "--yes backups/$newest.sql.gz"

  check "no command line carried the secret of the bucket ($(grep -c . "$work/ps.log") lines sampled)" \
    lacks "$(cat "$work/ps.log")" "$S3_SECRET"
  check "...and the docker run of the copy passed it by name" grep -q -- '-e BACKUP_S3_SECRET_ACCESS_KEY ' "$work/ps.log"

  # The backup of an upgrade: copied to the bucket, and an unreachable one is
  # only a warning. A package of this checkout as v98.0.0, whose images do
  # not exist: the upgrade gets past the backup and stops at the pull, with
  # the files of $version back. The package keeps the pins of $version, and
  # by a digest Docker pulls the images of $version whatever the tag says:
  # the upgrade drops the pins (empty CADENCE_*_DIGEST, as for images of a
  # branch) and goes by the tag v98.0.0, which no registry has.
  if [ "$db" = bundled ]; then
    info "the backup of an upgrade"
    up=v98.0.0
    "$repo/ci/package.sh" --version "$up" ${clab_pkg[@]+"${clab_pkg[@]}"} "$work/releases/download/$up" >/dev/null
    sleep 1
    out="$(CADENCE_VERIFY=off CADENCE_BACKEND_DIGEST="" CADENCE_FRONTEND_DIGEST="" CADENCE_RELEASES_URL="file://$work/releases" upgrade_cmd "$up" 2>&1 || true)"
    check "the upgrade copies its backup to the bucket" contains "$out" "✓ uploaded cadence-$version-"
    env_set BACKUP_S3_ENDPOINT "http://s3stand-nowhere:7070"
    sleep 1
    out="$(CADENCE_VERIFY=off CADENCE_BACKEND_DIGEST="" CADENCE_FRONTEND_DIGEST="" CADENCE_RELEASES_URL="file://$work/releases" upgrade_cmd "$up" 2>&1 || true)"
    check "an unreachable bucket is a warning of the upgrade" contains "$out" "! the off-machine copy of cadence-$version-"
    check "...and the upgrade goes on" contains "$out" "the upgrade goes on: its rollback uses the local backup"
    check "...past the backup to the images of $up" contains "$out" "$up"
    check "...and stops at them with the files of $version back" [ "$(tr -d '[:space:]' <VERSION)" = "$version" ]
    check "...with no 'older than the target' of the clab of the package, which the upgrade replaces" lacks "$out" "is older than the target"
    printf '%s\n' "$out" | grep -E '^(!|✗)' | head -n 4
    env_set BACKUP_S3_ENDPOINT "$S3_ENDPOINT"
  fi

  for k in BUCKET ENDPOINT PREFIX KEEP; do env_set "BACKUP_S3_$k" ""; done
  secret_set BACKUP_S3_ACCESS_KEY_ID ""
  secret_set BACKUP_S3_SECRET_ACCESS_KEY ""
  s3_down
fi

# --- another installation name in the environment ------------------------------------
# backup, restore and upgrade of this installation with COMPOSE_PROJECT_NAME
# of another one refuse before they touch Docker: no dump, no restart.
info "COMPOSE_PROJECT_NAME=other"
started_before="$(started "$work/cadence")"
dumps_before="$(find backups -maxdepth 1 -name 'cadence-*.sql.gz' | sort)"
for cmd in "backup_cmd" "restore_cmd --yes $dump" "upgrade_cmd $version"; do
  what="${cmd%%_cmd*}"
  code=0
  # shellcheck disable=SC2086 # the command and its arguments
  out="$(COMPOSE_PROJECT_NAME=other $cmd 2>&1)" || code=$?
  if [ "$code" = 0 ]; then
    fail "$what with COMPOSE_PROJECT_NAME=other must refuse"
  elif [ "$code" = 1 ] && contains "$out" "COMPOSE_PROJECT_NAME is 'other' in the environment, but the installation in $work/cadence is '$name'" &&
    contains "$out" "unset COMPOSE_PROJECT_NAME"; then
    pass "$what with COMPOSE_PROJECT_NAME=other refuses with exit 1, naming both and unset"
  else
    fail "$what with COMPOSE_PROJECT_NAME=other refused without both names: $out"
  fi
done
check "the refusals took no backup" [ "$(find backups -maxdepth 1 -name 'cadence-*.sql.gz' | sort)" = "$dumps_before" ]
check "the refusals restarted nothing" [ "$(started "$work/cadence")" = "$started_before" ]
COMPOSE_PROJECT_NAME="" backup_cmd >/dev/null
check "an empty COMPOSE_PROJECT_NAME is no variable: backup works" \
  [ "$(find backups -maxdepth 1 -name 'cadence-*.sql.gz' | wc -l)" -gt "$(grep -c . <<<"$dumps_before")" ]

# --- upgrade on the external database ------------------------------------------------
# A package of this checkout as v99.0.0 with the same images: the images of
# the new version check the database before the backup, and the rollback the
# upgrade prints restores into the external database.
if [ "$db" = external ]; then
  info "upgrade on the external database"
  next=v99.0.0
  "$repo/ci/package.sh" --version "$next" ${clab_pkg[@]+"${clab_pkg[@]}"} "$work/releases/download/$next" >/dev/null
  registry="${CADENCE_REGISTRY:-ghcr.io/cadence-lab-tech}"
  if [ -n "${CADENCE_BACKEND_DIGEST+set}" ] && [ -z "${CADENCE_BACKEND_DIGEST}" ]; then
    # Images of a branch go by the tag: give the same images the tag of
    # $next where they live - in the local registry of the branch.
    for image in backend frontend; do
      docker buildx imagetools create -t "$registry/sdlc-pipeline-$image:$next" "$registry/sdlc-pipeline-$image:$version" >/dev/null 2>&1 ||
        info "could not tag $registry/sdlc-pipeline-$image:$version as $next"
    done
  fi
  upgrade_state() { printf '%s %s\n' "$(tr -d '[:space:]' <VERSION)" "$(find backups -maxdepth 1 -name 'cadence-*.sql.gz' | sort | tr '\n' ' ')"; }
  before_upgrade="$(upgrade_state)"
  docker stop "$EXT_DB_NAME" >/dev/null
  if out="$(CADENCE_VERIFY=off CADENCE_RELEASES_URL="file://$work/releases" upgrade_cmd "$next" 2>&1)"; then
    fail "an upgrade with the external database down must stop"
  else
    check "an upgrade with the external database down stops at the check of $next" \
      contains "$out" "the external database is not ready for $next"
  fi
  check "...before the backup and before any file changed" [ "$(upgrade_state)" = "$before_upgrade" ]
  check "...without asking for the postgres container" lacks "$out" "postgres container"
  docker start "$EXT_DB_NAME" >/dev/null
  for _ in $(seq 1 60); do
    ext_db_query cadence 'SELECT 1' >/dev/null 2>&1 && break
    sleep 1
  done
  for _ in $(seq 1 30); do
    [ "$(http_code "$base/readyz")" = 200 ] && break
    sleep 2
  done

  "$clab" --host "$base" project create UPG --name "Before the upgrade" --team check >/dev/null
  # compose up waits for the API to be healthy before it starts the worker,
  # so only a zero timeout makes "not ready" certain. No clab in PATH: the
  # printed rollback is the scripts.
  if out="$(PATH="$work/nogit:$PATH" CADENCE_VERIFY=off CADENCE_RELEASES_URL="file://$work/releases" CADENCE_READY_TIMEOUT=0 upgrade_cmd "$next" 2>&1)"; then
    fail "the upgrade to $next with a zero timeout must report it is not ready"
  else
    printf '%s\n' "$out" | tail -n 8
    check "it checked the external database with the images of $next before the backup" \
      [ "$(grep -nF "checking the external database $ext_label with the images of $next" <<<"$out" | cut -d: -f1)" -lt \
        "$(grep -nF "backup of $version" <<<"$out" | cut -d: -f1)" ]
    rollback="$(grep -E '^  (tar -xpzf |\./restore\.sh --yes )' <<<"$out" || true)"
    if [ "$(grep -c . <<<"$rollback")" = 2 ]; then
      pass "it prints the rollback: package files and the backup, by the scripts"
      info "running the rollback as printed, without clab in PATH"
      "$clab" --host "$base" project create LOST --name "Lost by the rollback" --team check >/dev/null 2>&1 || true
      PATH="$work/nogit:$PATH" bash -euc "$rollback" >/dev/null
      check "after the rollback VERSION is $version" [ "$(tr -d '[:space:]' <VERSION)" = "$version" ]
      check "...and bin/clab-$platform is the clab of $version again" [ "$("$pkg_clab" version 2>/dev/null | head -n 1)" = "clab $version" ]
      projects="$("$clab" --host "$base" project list --json)"
      check "after the rollback the project from before the upgrade is there" contains "$projects" '"UPG"'
      check "after the rollback the project written after the backup is gone" lacks "$projects" '"LOST"'
      check "/readyz answers 200 after the rollback" [ "$(http_code "$base/readyz")" = 200 ]
    else
      fail "the rollback is not two commands: $out"
    fi
  fi
fi

# --- no secret in the logs (CHECK_SECRETS=files) ------------------------------------
if [ "$secrets_mode" = files ]; then
  info "no secret in the logs"
  logs="$(docker compose logs api worker 2>&1)"
  out="$(backup_cmd 2>&1)"
  for secret in "$admin_token" ${pg_password:+"$pg_password"} ${EXT_DB_PASSWORD:+"$EXT_DB_PASSWORD"} ${S3_SECRET:+"$S3_SECRET"} "$otlp_value"; do
    check "the logs of api and worker hold no value of a secret (${#secret} characters)" lacks "$logs" "$secret"
    check "...nor the output of a backup" lacks "$out" "$secret"
  done
fi

# --- two installations on one machine ------------------------------------------------
if [ "$db" = bundled ]; then
  info "a second installation by the external clab: clab server install --name $second_name on port $second_port"
  # The *_FILE that load_env exported from the .env of the first one are
  # paths in its secrets/, not the second one's (CHECK_SECRETS=files):
  # compose would take them over the .env of the second installation.
  first_files=()
  for v in $(compgen -e | grep '_FILE$' || true); do first_files+=(-u "$v"); done
  (cd "$work" && env ${first_files[@]+"${first_files[@]}"} PATH="$work/nogit:$PATH" CADENCE_RELEASES_URL="file://$work/releases" \
    "$ext_clab" server install --dir "$work/second" --name "$second_name" --mode proxy --http-addr "127.0.0.1:$second_port" --yes </dev/null >/dev/null)
  second_up=1
  # The .env of clab server install and of the wrapper install.sh: the same
  # keys in the same order, the same form of the lines, mode 600.
  env_keys() { sed -E 's/=.*//' "$1"; }
  env_form() { sed -E 's/=.+/=x/' "$1"; }
  check "the .env of clab server install has the keys of the .env of install.sh, in order" \
    [ "$(env_keys "$work/second/.env")" = "$(env_keys "$work/env-of-install.sh")" ]
  check "...and the same form of every line (KEY=value, empty values alike)" \
    [ "$(env_form "$work/second/.env")" = "$(env_form "$work/env-of-install.sh")" ]
  check "...and mode 600" [ "$(stat -c %a "$work/second/.env" 2>/dev/null || stat -f %Lp "$work/second/.env")" = 600 ]
  check "the second installation keeps its name: COMPOSE_PROJECT_NAME=$second_name" \
    grep -qxF "COMPOSE_PROJECT_NAME=$second_name" "$work/second/.env"
  check "the second installation answers on $second_port" [ "$(http_code "http://127.0.0.1:$second_port/readyz")" = 200 ]
  check "docker compose in the first installation sees only $name" [ "$(projects_in "$work/cadence")" = "$name " ]
  check "docker compose in the second installation sees only $second_name" [ "$(projects_in "$work/second")" = "$second_name " ]
  first_dumps="$(find backups -maxdepth 1 -name 'cadence-*.sql.gz' | wc -l | tr -d ' ')"
  fresh "$work/second" ./backup.sh >/dev/null
  check "./backup.sh of the second installation writes into its own backups/" \
    [ "$(find "$work/second/backups" -maxdepth 1 -name 'cadence-*.sql.gz' | wc -l | tr -d ' ')" = 1 ]
  check "...and nothing into the backups/ of the first" \
    [ "$(find backups -maxdepth 1 -name 'cadence-*.sql.gz' | wc -l | tr -d ' ')" = "$first_dumps" ]
  fresh "$work/cadence" ./backup.sh >/dev/null
  check "./backup.sh of the first installation writes into its own backups/" \
    [ "$(find backups -maxdepth 1 -name 'cadence-*.sql.gz' | wc -l | tr -d ' ')" = "$((first_dumps + 1))" ]
  check "...and nothing into the backups/ of the second" \
    [ "$(find "$work/second/backups" -maxdepth 1 -name 'cadence-*.sql.gz' | wc -l | tr -d ' ')" = 1 ]
  check "the first installation still answers on $port" [ "$(http_code "$base/readyz")" = 200 ]
fi

# --- the starter project in one command (docs/admin.md, "First cycle and roles") ----
if [ "$db" = bundled ]; then
  starter_clab="${CLAB_BIN:-$pkg_clab}"
  if ! "$starter_clab" server install --help 2>/dev/null | grep -qF -- --with-starter; then
    if version_lt "$version" v0.14.0; then
      info "skipped the starter project: $("$starter_clab" version 2>/dev/null | head -n 1) has no install --with-starter (v0.14.0+); CLAB_BIN=<clab with it> checks it"
    else
      fail "clab server install of $version has no --with-starter"
    fi
  else
    info "the starter project: clab server install --team starter --with-starter --project START on port $starter_port"
    sbase="http://127.0.0.1:$starter_port"
    config_before="$(find "$CLAB_CONFIG_DIR" -type f -exec cksum {} + 2>/dev/null | sort || true)"
    starter_out="$(cd "$work" && env ${first_files[@]+"${first_files[@]}"} PATH="$work/nogit:$PATH" CADENCE_RELEASES_URL="file://$work/releases" \
      SDLC_ADMIN_TOKEN="$admin_token" "$starter_clab" server install --dir "$work/starter" --name "$starter_name" --mode proxy \
      --http-addr "127.0.0.1:$starter_port" --team starter --with-starter --project START --project-name "Starter check" --yes </dev/null 2>&1)" &&
      code=0 || code=$?
    starter_up=1
    printf '%s\n' "$starter_out"
    check "install --with-starter exits with 0" [ "$code" = 0 ]
    check "...creates the project START in the team starter" contains "$starter_out" "project START created in team starter"
    check "...activates both cycles" [ "$(grep -o 'created, activated' <<<"$starter_out" | wc -l | tr -d ' ')" = 2 ]
    check "...prints the address of the project" contains "$starter_out" "$sbase/p/START"
    check "...and the invite of a team lead" contains "$starter_out" "clab invite create --team starter --role lead"
    check "...and does not print a supplied token" lacks "$starter_out" "$admin_token"
    project="$(curl -sf "${auth[@]}" "$sbase/v1/projects/START" || true)"
    check "START belongs to the team starter" [ "$(jq -r '.project.owner_team_key' <<<"$project" 2>/dev/null)" = starter ]
    workflows_of() { curl -sf "${auth[@]}" "$sbase/v1/projects/START/workflows"; }
    flows="$(workflows_of || true)"
    check "its active cycles cover task and epic" \
      [ "$(jq -r '[.workflows[] | select(.state == "active") | .task_types[]] | sort | join(" ")' <<<"$flows" 2>/dev/null)" = "epic task" ]
    check "...and no draft is left" [ "$(jq -r '[.workflows[] | select(.state == "draft")] | length' <<<"$flows" 2>/dev/null)" = 0 ]
    sclab=(env SDLC_API_URL="$sbase" SDLC_TOKEN="$admin_token" SDLC_PROJECT=START "$clab")
    check "the project has the analyst role" contains "$("${sclab[@]}" role show analyst --json 2>/dev/null || true)" '"analyst"'
    check "a task is created in it" "${sclab[@]}" create --title "First task"
    check "an epic is created in it" "${sclab[@]}" create --title "First epic" --type epic

    again="$(cd "$work" && PATH="$work/nogit:$PATH" "$starter_clab" server starter --dir "$work/starter" --project START 2>&1)" && code=0 || code=$?
    [ "$code" = 0 ] || printf '%s\n' "$again" >&2
    check "clab server starter again exits with 0" [ "$code" = 0 ]
    check "...finds the project" contains "$again" "project START already exists (team starter)"
    check "...leaves the roles and cycles unchanged and active" \
      [ "$(grep -o 'unchanged, already active' <<<"$again" | wc -l | tr -d ' ')" = 2 ]
    check "...and makes no new version of a cycle" [ "$(workflows_of | jq '.workflows | length')" = "$(jq '.workflows | length' <<<"$flows")" ]

    if [ "$secrets_mode" = files ]; then
      # The token is in the file only, handed over to the service: the host
      # user cannot read it (on Linux; Docker Desktop shows the files as
      # yours), the owner and mode are seen from a container.
      check "secrets/admin_token of the first installation is 65532:65532, mode 400, when the step runs" \
        [ "$(docker run --rm -v "$work/cadence/secrets:/s:ro" alpine:3 stat -c '%u:%g %a' /s/admin_token)" = "65532:65532 400" ]
      check "...and .env has no value of SDLC_ADMIN_TOKEN" [ "$(grep -E '^SDLC_ADMIN_TOKEN=' "$work/cadence/.env")" = "SDLC_ADMIN_TOKEN=" ]
    fi
    first="$(cd "$work" && PATH="$work/nogit:$PATH" "$starter_clab" server starter --dir "$work/cadence" --team check --project CHECK 2>&1)" && code=0 || code=$?
    [ "$code" = 0 ] || printf '%s\n' "$first" >&2
    check "clab server starter on CHECK, set up by hand on the first installation, exits with 0" [ "$code" = 0 ]
    check "...and changes nothing there" [ "$(grep -o 'unchanged, already active' <<<"$first" | wc -l | tr -d ' ')" = 2 ]
    check "...and does not print the token" lacks "$first" "$admin_token"
    if [ "$secrets_mode" = files ]; then
      check "...and leaves no alpine:3 container on secrets/ behind" \
        [ -z "$(docker ps -a -q --filter ancestor=alpine:3 --filter volume="$work/cadence/secrets")" ]
    fi
    check "the starter project steps write nothing into the configuration of clab" \
      [ "$(find "$CLAB_CONFIG_DIR" -type f -exec cksum {} + 2>/dev/null | sort || true)" = "$config_before" ]
  fi
fi

if [ "$failures" -gt 0 ]; then
  docker compose ps || true
  docker compose logs --tail 30 api caddy || true
  die "$failures check(s) failed"
fi
ok "all checks passed on $version (the wrappers of bin/clab-$platform, database $db, secrets in $secrets_mode)"
