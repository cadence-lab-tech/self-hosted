# shellcheck shell=bash
#
# Helpers of the checks in ci/ and of the workflows. Not a command: they
# source it after changing into the root of the repository. It is no file
# of the package: from the release after v0.13.0 the scripts of the package
# are wrappers of clab server of the clab in the package (decision 0057),
# and the logic of the installation lives in clab server (cmd/clab/server*.go
# of the backend) - lib.sh of the package, with the bash version of it, went
# away with them. What is here is what the checks need: the output of the
# scripts, versions, the installation name of an installation for docker
# compose, readiness, and the names and constants of the releases and the
# signatures.

# Backups and .env hold secrets: nothing the checks create is meant for
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

# load_env exports .env of the installation in the current directory into
# the check, so that docker compose of the check works with that
# installation - the rules of clab server (cmd/clab/server_name.go).
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
# COMPOSE_PROJECT_NAME of its .env, else "cadence", the name in
# docker-compose.yml. clab server applies the rule (cmd/clab/server_name.go
# of the backend); load_env follows it for the checks.
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

# container_of SERVICE prints the container ID of a compose service, running
# or stopped.
container_of() {
  docker compose ps -a -q "$1" 2>/dev/null | head -n1
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

# --- database ----------------------------------------------------------------------
# The overlays of compose that the checks name.
# shellcheck disable=SC2034 # used by the scripts that source ci/lib.sh
EXTERNAL_DB_FILE=compose.external-db.yml
# shellcheck disable=SC2034 # used by the scripts that source ci/lib.sh
SECRETS_FILE=compose.secrets.yml

# --- releases ----------------------------------------------------------------------
# Every release vX.Y.Z of this repository carries four assets (the bundle
# from v0.9.0 on):
#
#   cadence-self-hosted-vX.Y.Z.tar.gz   the package (ci/package.sh): the
#                                       files of the installation, clab of
#                                       each platform in bin/ and
#                                       package.sha256 - the sha256 of each of
#                                       them, against which upgrade.sh finds
#                                       local edits
#   checksums.txt                       sha256 of the package and the installer
#   checksums.txt.sigstore.json         the signature of checksums.txt
#                                       (cosign keyless, see "signatures")
#   get-cadence.sh                      the one-line installer
#
# The names are a contract: the scripts of every later version, clab and
# the Helm chart download them by these names. Do not rename them.
#
# CADENCE_RELEASES_URL points the installers at a mirror of the releases (or
# a directory, file:///path) with the same layout: download/vX.Y.Z/<asset>
# and latest/download/<asset>; the checks serve their packages so.
# shellcheck disable=SC2034 # used by the scripts that source ci/lib.sh
CADENCE_RELEASES_DEFAULT=https://github.com/cadence-lab-tech/self-hosted/releases
# shellcheck disable=SC2034 # used by the scripts that source ci/lib.sh
PACKAGE_MANIFEST=package.sha256

# clab in the package (decision 0057): the binary of each of these platforms
# as bin/clab-<os>-<arch>, from the archives of the release of the same
# version in the tap, where release.yml of the backend publishes them.
# shellcheck disable=SC2034 # used by the scripts that source ci/lib.sh
CLAB_PLATFORMS="linux-amd64 linux-arm64 darwin-amd64 darwin-arm64"
CADENCE_TAP_RELEASES_DEFAULT=https://github.com/cadence-lab-tech/homebrew-tap/releases

tap_releases_url() {
  local url="${CADENCE_TAP_RELEASES_URL:-$CADENCE_TAP_RELEASES_DEFAULT}"
  printf '%s\n' "${url%/}"
}

# clab_archive VERSION OS-ARCH prints the name of the archive of clab
# VERSION for OS-ARCH in the release of the tap.
clab_archive() {
  printf 'clab_%s_%s_%s.tar.gz\n' "$1" "${2%-*}" "${2#*-}"
}

# The last release whose install.sh, upgrade.sh, backup.sh and restore.sh
# are bash scripts with lib.sh (decision 0057): the checks build "a release
# before the wrappers" with its own ci/package.sh, from its tag in git.
LAST_BASH_RELEASE=v0.13.0

# bash_package ARGS... OUT: ci/package.sh of LAST_BASH_RELEASE with ARGS
# (--version, --bundle) into the absolute directory OUT - the package of a
# release before the wrappers. Needs the tag in this clone.
bash_package() {
  local src rc=0
  src="$(mktemp -d)"
  if git archive "$LAST_BASH_RELEASE" | tar -x -C "$src"; then
    "$src/ci/package.sh" "$@" >/dev/null || rc=$?
  else
    rc=1
  fi
  rm -rf "$src"
  return "$rc"
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

# The first version released with a package. Earlier ones (v0.5.x) were
# installed as git clones and have no package in their release.
# shellcheck disable=SC2034 # used by the scripts that source ci/lib.sh
FIRST_PACKAGE_VERSION=v0.6.0

# --- signatures --------------------------------------------------------------------
# From v0.9.0 the release workflows sign checksums.txt of the package and
# both images with cosign keyless (docs/admin.md, "Verifying a release");
# clab server verifies them (CADENCE_VERIFY), get-cadence.sh the package. The
# identities and the names the checks verify with, the same as theirs
# (ci/check-config.sh compares them with get-cadence.sh).
# shellcheck disable=SC2034 # used by the scripts that source ci/lib.sh
VERIFY_FIRST_SIGNED=v0.9.0
# shellcheck disable=SC2034 # used by the scripts that source ci/lib.sh
VERIFY_ISSUER=https://token.actions.githubusercontent.com
VERIFY_SOURCE=https://github.com/cadence-lab-tech
# shellcheck disable=SC2034 # used by the scripts that source ci/lib.sh
VERIFY_REGISTRY=ghcr.io/cadence-lab-tech
# shellcheck disable=SC2034 # used by the scripts that source ci/lib.sh
VERIFY_PACKAGE_IDENTITY=$VERIFY_SOURCE/self-hosted/.github/workflows/release.yml@refs/heads/main
# shellcheck disable=SC2034 # used by the scripts that source ci/lib.sh
VERIFY_BUNDLE=checksums.txt.sigstore.json

# verify_identity REPO VERSION: the identity that signs the image REPO of
# VERSION - release.yml of its repository on the tag.
verify_identity() {
  printf '%s/%s/.github/workflows/release.yml@refs/tags/%s\n' "$VERIFY_SOURCE" "$1" "$2"
}
