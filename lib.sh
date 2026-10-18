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

# --- releases ----------------------------------------------------------------------
# Every release vX.Y.Z of this repository carries three assets:
#
#   cadence-self-hosted-vX.Y.Z.tar.gz   the package: the files of this
#                                       directory without ci/ and .github/,
#                                       and package.sha256 - the sha256 of
#                                       each of them, against which upgrade.sh
#                                       finds local edits
#   checksums.txt                       sha256 of the other two assets
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
