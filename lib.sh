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
  set -a
  # shellcheck disable=SC1091
  . ./.env
  set +a
  # The version always comes from VERSION, even if .env sets it.
  load_version
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
}
