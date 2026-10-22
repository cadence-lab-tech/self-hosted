#!/usr/bin/env bash
#
# Checks of the signature verification of install.sh and upgrade.sh
# (CADENCE_VERIFY) that need no Docker: cosign and docker are stubs
# (ci/verify-stubs.sh), the releases are packages of this checkout built by
# ci/package.sh in a scratch directory. The scripts are the wrappers of
# clab server of the package (decision 0057): what is checked here is the
# verification of the clab of the package, through the wrappers. The docker
# stub writes every call to a log: "before .env", "before the precheck" and
# "before the pull" are a missing file and a missing call. CI runs it in the
# lint job; the one-line installer has its own checks
# (ci/check-get-cadence.sh).
#
# An unreachable ghcr.io is not checked here: clab server asks ghcr.io with
# its own HTTP client, which no stub in PATH stands in for (the bash scripts
# asked with curl). When a stub cosign rejects an image, clab server asks the
# real ghcr.io whether it answers - the check needs the network there. The
# warning of auto and the refusal of require for an unreachable ghcr.io are
# checked by the tests of clab server (cmd/clab/server_verify_test.go of the
# backend).
#
#   ci/check-verify.sh
#
# install.sh: both images verified at ghcr.io by the digests of
# docker-compose.yml, also with a registry mirror; a bad signature refuses
# before .env and before the precheck of an external database, and the next
# run after the fix goes on; an image without a pin, an unreachable ghcr.io,
# no cosign or an old one, an unsigned version - a warning with auto, a
# refusal with require; off - no cosign at all; an unknown value - refused.
# upgrade.sh: the signature of checksums.txt and of the images of the new
# version before the backup, the files and the pull - a bad one changes
# nothing; a release without the bundle is refused; CADENCE_VERIFY of .env
# wins over the environment and .env is not touched.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=ci/lib.sh
. ./ci/lib.sh
# shellcheck source=ci/pins.sh
. ./ci/pins.sh
# shellcheck source=ci/verify-stubs.sh
. ./ci/verify-stubs.sh

failures=0
pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  failures=$((failures + 1))
}
contains() { grep -qF -- "$2" <<<"$1"; }
lacks() { ! grep -qF -- "$2" <<<"$1"; }
# check WHAT CMD...: CMD is true.
check() {
  local what="$1"
  shift
  if "$@"; then pass "$what"; else fail "$what"; fi
}

version="$(tr -d '[:space:]' <VERSION)"
version_lt "$version" "$VERIFY_FIRST_SIGNED" && die "VERSION is $version: the checks need a signed version ($VERIFY_FIRST_SIGNED+)"
target=v99.0.0
nobundle=v99.1.0
unsigned_from=v0.7.0
unsigned=v0.8.0
backend_pin="$(pin_of backend)" || die "docker-compose.yml pins no backend digest"
frontend_pin="$(pin_of frontend)" || die "docker-compose.yml pins no frontend digest"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- releases --------------------------------------------------------------------
releases="$work/releases"
ci/package.sh --bundle "$releases/download/$version" >/dev/null
ci/package.sh --bundle --version "$target" "$releases/download/$target" >/dev/null
ci/package.sh --version "$nobundle" "$releases/download/$nobundle" >/dev/null
ci/package.sh --version "$unsigned_from" "$releases/download/$unsigned_from" >/dev/null
ci/package.sh --version "$unsigned" "$releases/download/$unsigned" >/dev/null
export CADENCE_RELEASES_URL="file://$releases"

# --- stubs -------------------------------------------------------------------------
# $work/bin: docker; $work/cosign: cosign, put into PATH or left out.
bin="$work/bin"
mkdir -p "$bin"
stub_compose_images "$bin/compose-images"
cat >"$bin/docker" <<SH
#!/bin/sh
echo "docker \$*" >>"\$FAKE_DOCKER_LOG"
case "\$*" in
"compose version" | info) exit 0 ;;
"compose version --short") echo 2.29.1; exit 0 ;;
"ps -a -q --filter "* | "volume ls -q --filter "*) exit 0 ;;
*" config --images") exec "$bin/compose-images" "\$@" ;;
"compose ps -q --status running postgres") exit 0 ;;
*) echo "docker stub: \$*" >&2; exit 1 ;;
esac
SH
chmod 755 "$bin/docker"
cosign_dir="$work/cosign"
stub_cosign "$cosign_dir" "$work/cosign.log"
base_path="$(path_without_cosign)"
unset COMPOSE_PROJECT_NAME CADENCE_VERIFY CADENCE_VERIFY_NOTED CADENCE_REGISTRY CADENCE_BACKEND_DIGEST CADENCE_FRONTEND_DIGEST

backend_identity="$(verify_identity sdlc-pipeline-backend "$version")"
frontend_identity="$(verify_identity sdlc-pipeline-frontend "$version")"
backend_ref="$VERIFY_REGISTRY/sdlc-pipeline-backend@$backend_pin"
frontend_ref="$VERIFY_REGISTRY/sdlc-pipeline-frontend@$frontend_pin"

# run DIR SCRIPT [NAME=VALUE...] -- ARGS...: SCRIPT of DIR with the stubs and
# cosign in PATH (NOCOSIGN=1 leaves it out); output in $out, status in
# $status, the calls in $docker_log and $cosign_log.
run() {
  local d="$1" script="$2" path="$bin:$cosign_dir:$base_path" vars=()
  shift 2
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    case "$1" in
    NOCOSIGN=1) path="$bin:$base_path" ;;
    *) vars+=("$1") ;;
    esac
    shift
  done
  [ $# -eq 0 ] || shift
  : >"$work/docker.log"
  : >"$work/cosign.log"
  out="$(cd "$d" && env PATH="$path" FAKE_DOCKER_LOG="$work/docker.log" ${vars[@]+"${vars[@]}"} "./$script" "$@" </dev/null 2>&1)" && status=0 || status=$?
  docker_log="$(cat "$work/docker.log")"
  cosign_log="$(cat "$work/cosign.log")"
}
show() { while IFS= read -r line; do printf '      %s\n' "$line"; done <<<"$out" >&2; }

# --- install.sh --------------------------------------------------------------------
# unpacked VERSION: a fresh directory with the unpacked package of VERSION.
unpacked() {
  local d
  d="$(mktemp -d "$work/i.XXXXXX")"
  tar -xpzf "$releases/download/$1/$(package_name "$1")" -C "$d"
  printf '%s\n' "$d"
}
install_args=(--mode proxy --http-addr 127.0.0.1:1 --yes)
# installed_on: install.sh went past the verification - it wrote .env and
# stopped at the pull of the docker stub.
installed_on() { [ -f "$1/.env" ] && contains "$out" "could not pull the images of"; }
# refused_before_env DIR TEXT: install.sh failed with TEXT, wrote no .env and
# pulled nothing.
refused_before_env() {
  if [ "$status" != 0 ] && contains "$out" "$2" && [ ! -e "$1/.env" ] && lacks "$docker_log" " pull"; then
    pass "$3"
  else
    fail "$3: status $status, no \"$2\", or .env / a pull"
    show
  fi
}

info "install.sh: the images of $version"
d="$(unpacked "$version")"
run "$d" install.sh -- "${install_args[@]}"
check "both images verified, install.sh goes on to .env and the pull" installed_on "$d"
for image in backend frontend; do
  ref="${image}_ref"
  id="${image}_identity"
  check "cosign verify of $image: its digest at ghcr.io, the identity of its release.yml on $version" \
    contains "$cosign_log" "cosign [verify] [--certificate-identity] [${!id}] [--certificate-oidc-issuer] [$VERIFY_ISSUER] [${!ref}]"
  check "...and the output says so: ✓ ${!ref} is signed by ${!id}" contains "$out" "✓ ${!ref} is signed by ${!id}"
done
check "...before .env is written: no 'writing .env' before the verification" \
  [ "$(grep -n 'is signed by' <<<"$out" | tail -n 1 | cut -d: -f1)" -lt "$(grep -n 'writing .env' <<<"$out" | cut -d: -f1)" ]

d="$(unpacked "$version")"
run "$d" install.sh CADENCE_REGISTRY=localhost:5050 -- "${install_args[@]}"
check "a registry mirror (CADENCE_REGISTRY=localhost:5050): the images are verified at ghcr.io by the same digests" \
  contains "$cosign_log" "[$backend_ref]"
check "...and the output names ghcr.io" contains "$out" "✓ $frontend_ref is signed by"
check "...nothing is verified at the mirror" lacks "$cosign_log" "localhost:5050"

info "install.sh: a bad signature"
d="$(unpacked "$version")"
run "$d" install.sh FAKE_COSIGN_BAD=sdlc-pipeline-frontend -- "${install_args[@]}"
refused_before_env "$d" "the signature of $frontend_ref (sdlc-pipeline-frontend $version) did not verify for $frontend_identity" \
  "a bad signature of the frontend image is refused before .env, naming the image and the identity"
check "...with the answer of cosign" contains "$out" "no matching signatures"
check "...and 'Nothing was installed.'" contains "$out" "Nothing was installed."
run "$d" install.sh -- "${install_args[@]}"
check "the same directory installs on the next run, once the signature verifies" installed_on "$d"

d="$(unpacked "$version")"
run "$d" install.sh FAKE_COSIGN_BAD=sdlc-pipeline-backend -- --external-db "postgres://u:p@db.example.com:5432/cadence?sslmode=verify-full" --yes --mode proxy --http-addr 127.0.0.1:1
refused_before_env "$d" "did not verify for $backend_identity" "with --external-db a bad signature is refused before .env"
check "...and before the precheck: the backend image did not run (no api dbcheck)" lacks "$docker_log" "dbcheck"
run "$d" install.sh -- --external-db "postgres://u:p@db.example.com:5432/cadence?sslmode=verify-full" --yes --mode proxy --http-addr 127.0.0.1:1
check "...while a verified image goes on to the precheck" contains "$docker_log" "api dbcheck --install"

info "install.sh: an image without a pin"
for mode in auto require; do
  d="$(unpacked "$version")"
  run "$d" install.sh CADENCE_VERIFY="$mode" CADENCE_BACKEND_DIGEST= -- "${install_args[@]}"
  unpinned="ghcr.io/cadence-lab-tech/sdlc-pipeline-backend:$version is not pinned to a digest (an empty CADENCE_BACKEND_DIGEST, or compose.override.yml)"
  if [ "$mode" = auto ]; then
    check "auto: an empty CADENCE_BACKEND_DIGEST - a warning 'not pinned, not verified'" contains "$out" "! $unpinned: not pinned, not verified"
    check "...the frontend is still verified" contains "$out" "✓ $frontend_ref is signed by"
    check "...and install.sh goes on" installed_on "$d"
  else
    refused_before_env "$d" "$unpinned, and CADENCE_VERIFY=require verifies images by digest only" "require: an image without a pin is refused before .env"
  fi
done
d="$(unpacked "$version")"
printf 'services:\n  api:\n    image: registry.example.com/mine/sdlc-pipeline-backend:custom\n' >"$d/compose.override.yml"
run "$d" install.sh -- "${install_args[@]}"
check "auto: an image of compose.override.yml put there before the installation - 'not pinned, not verified'" \
  contains "$out" "! registry.example.com/mine/sdlc-pipeline-backend:custom is not pinned to a digest"

info "install.sh: cosign"
d="$(unpacked "$version")"
run "$d" install.sh NOCOSIGN=1 -- "${install_args[@]}"
check "auto without cosign: one warning about cosign" [ "$(grep -c '^! .*cosign' <<<"$out")" = 1 ]
check "...it says what is not verified" contains "$out" "! cosign 3.x is not installed: the signatures of the release are not verified (CADENCE_VERIFY=auto)"
check "...and install.sh goes on" installed_on "$d"
d="$(unpacked "$version")"
run "$d" install.sh NOCOSIGN=1 CADENCE_VERIFY=require -- "${install_args[@]}"
refused_before_env "$d" "CADENCE_VERIFY=require, but cosign 3.x is not installed: install cosign 3.x" "require without cosign: refused before .env"
check "...before Docker is asked anything" [ -z "$docker_log" ]
d="$(unpacked "$version")"
run "$d" install.sh FAKE_COSIGN_VERSION=v2.4.1 -- "${install_args[@]}"
check "cosign v2.4.1 counts as none: 'cosign v2.4.1 is older than 3.x'" contains "$out" "! cosign v2.4.1 is older than 3.x: the signatures of the release are not verified"
check "...it is not asked to verify" lacks "$cosign_log" "[verify]"
d="$(unpacked "$version")"
run "$d" install.sh CADENCE_VERIFY=off -- "${install_args[@]}"
check "off: no cosign at all" [ -z "$cosign_log" ]
check "...one line '▸ signature verification is off (CADENCE_VERIFY=off)'" [ "$(grep -c '^▸ signature verification is off (CADENCE_VERIFY=off)$' <<<"$out")" = 1 ]
check "...and no warning about signatures" lacks "$out" "! "
check "...install.sh goes on" installed_on "$d"
d="$(unpacked "$version")"
run "$d" install.sh CADENCE_VERIFY=yes -- "${install_args[@]}"
refused_before_env "$d" "CADENCE_VERIFY is 'yes', expected auto, require or off" "CADENCE_VERIFY=yes is refused with the values it takes"

info "install.sh: a version before the signatures ($unsigned)"
d="$(unpacked "$unsigned")"
run "$d" install.sh -- "${install_args[@]}"
check "auto: '! $unsigned is not signed' and install.sh goes on" contains "$out" "! $unsigned is not signed (signatures start with $VERIFY_FIRST_SIGNED): its package and images are not verified"
check "...cosign verifies nothing" lacks "$cosign_log" "[verify"
check "...installed" installed_on "$d"
d="$(unpacked "$unsigned")"
run "$d" install.sh CADENCE_VERIFY=require -- "${install_args[@]}"
refused_before_env "$d" "$unsigned is not signed (signatures start with $VERIFY_FIRST_SIGNED), and CADENCE_VERIFY=require refuses it" \
  "require: an unsigned version is refused before .env"

# --- upgrade.sh --------------------------------------------------------------------
# installation VERSION [LINE...]: an installation of VERSION as install.sh
# leaves it, with LINEs added to its .env.
installation() {
  local d v="$1"
  shift
  d="$(unpacked "$v")"
  {
    printf '%s\n' COMPOSE_PROJECT_NAME=cadence-verify CADENCE_MODE=proxy CADENCE_HTTP_ADDR=127.0.0.1:1 \
      COMPOSE_FILE=docker-compose.yml:compose.proxy.yml:compose.override.yml CADENCE_DB=bundled POSTGRES_PASSWORD=secret
    printf '%s\n' "$@"
  } >"$d/.env"
  chmod 600 "$d/.env"
  printf 'services: {}\n' >"$d/compose.override.yml"
  mkdir -p "$d/backups"
  printf '%s\n' "$d"
}
# state DIR: the files of the installation with their sums, backups/ and the
# scratch directories of upgrade.sh included.
state() { (cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s  %s\n' "$(sha256_of "$f")" "$f"; done); }
# went_on: upgrade.sh passed the verification and stopped at the stack that
# the docker stub does not run - right before the backup.
went_on() { contains "$out" "the stack is not running"; }
# unchanged DIR BEFORE WHAT: a refused upgrade left everything as it was.
unchanged() {
  if [ "$status" != 0 ] && [ "$(state "$1")" = "$2" ] && lacks "$docker_log" " pull" && contains "$out" "Nothing has changed."; then
    pass "$3"
  else
    fail "$3: status $status, the files changed, a pull, or no 'Nothing has changed.'"
    show
  fi
}

info "upgrade.sh $version -> $target"
d="$(installation "$version")"
run "$d" upgrade.sh -- "$target"
check "the signature of checksums.txt of $target is verified" \
  contains "$out" "✓ the signature of checksums.txt of $target verified: signed by $VERIFY_PACKAGE_IDENTITY"
check "...by cosign verify-blob with the bundle of the release and the identity of self-hosted on main" \
  contains "$cosign_log" "[verify-blob] [--bundle] [$d/.upgrade."
check "...$VERIFY_BUNDLE, $VERIFY_PACKAGE_IDENTITY, $VERIFY_ISSUER" \
  contains "$cosign_log" "/$VERIFY_BUNDLE] [--certificate-identity] [$VERIFY_PACKAGE_IDENTITY] [--certificate-oidc-issuer] [$VERIFY_ISSUER] ["
check "the images of $target are verified with the identity of the tag $target" \
  contains "$out" "✓ $backend_ref is signed by $(verify_identity sdlc-pipeline-backend "$target")"
check "...the package first, then the images" [ "$(grep -n '\[verify-blob\]' <<<"$cosign_log" | head -n 1 | cut -d: -f1)" -lt "$(grep -n '\[verify\]' <<<"$cosign_log" | head -n 1 | cut -d: -f1)" ]
check "...and the upgrade goes on to the backup" went_on

d="$(installation "$version")"
before="$(state "$d")"
run "$d" upgrade.sh FAKE_COSIGN_BAD=package -- "$target"
unchanged "$d" "$before" "a bad signature of checksums.txt of $target: refused, nothing has changed (VERSION, files, no backup, no .upgrade.*)"
check "...naming checksums.txt, the version and the identity" \
  contains "$out" "the signature of checksums.txt of $target did not verify for $VERIFY_PACKAGE_IDENTITY"
check "...the images are not even looked at" lacks "$cosign_log" "[verify]"

d="$(installation "$version" CADENCE_DB=external "SDLC_DATABASE_URL='postgres://u:p@db.example.com:5432/cadence?sslmode=verify-full'")"
sed -i.bak 's/^COMPOSE_FILE=.*/COMPOSE_FILE=docker-compose.yml:compose.proxy.yml:compose.external-db.yml:compose.override.yml/; /^CADENCE_DB=bundled$/d' "$d/.env" && rm -f "$d/.env.bak"
before="$(state "$d")"
run "$d" upgrade.sh FAKE_COSIGN_BAD=sdlc-pipeline-backend -- "$target"
unchanged "$d" "$before" "a bad signature of the backend image of $target: refused, nothing has changed"
check "...before the external database is checked by the new images (no dbcheck)" lacks "$docker_log" "dbcheck"
check "...naming the image and the identity of $target" \
  contains "$out" "the signature of $backend_ref (sdlc-pipeline-backend $target) did not verify for $(verify_identity sdlc-pipeline-backend "$target")"
run "$d" upgrade.sh -- "$target"
check "...while verified images go on to the check of the external database" contains "$docker_log" "api dbcheck"

d="$(installation "$version")"
run "$d" upgrade.sh -- "$nobundle"
check "a release of $nobundle without $VERIFY_BUNDLE: refused with cosign at hand" \
  contains "$out" "the release $nobundle has no $VERIFY_BUNDLE at file://$releases: the signature of its checksums.txt cannot be verified"
check "...with what to do: copy it to the mirror or CADENCE_VERIFY=off" \
  contains "$out" "Copy $VERIFY_BUNDLE of the release to the mirror, or set CADENCE_VERIFY=off. Nothing has changed."
run "$d" upgrade.sh CADENCE_VERIFY=require -- "$nobundle"
check "...with require too" contains "$out" "the release $nobundle has no $VERIFY_BUNDLE"

d="$(installation "$version" CADENCE_VERIFY=off)"
env_before="$(sha256_of "$d/.env")"
run "$d" upgrade.sh CADENCE_VERIFY=require -- "$target"
check "CADENCE_VERIFY=off in .env wins over require in the environment: no cosign" [ -z "$cosign_log" ]
check "...'▸ signature verification is off (CADENCE_VERIFY=off)'" contains "$out" "▸ signature verification is off (CADENCE_VERIFY=off)"
check "...the upgrade goes on" went_on
check "...and .env is not touched" [ "$(sha256_of "$d/.env")" = "$env_before" ]
d="$(installation "$version" CADENCE_VERIFY=require)"
run "$d" upgrade.sh NOCOSIGN=1 -- "$target"
check "CADENCE_VERIFY=require in .env without cosign: refused" contains "$out" "CADENCE_VERIFY=require, but cosign 3.x is not installed"

info "upgrade.sh $unsigned_from -> $unsigned (before the signatures)"
d="$(installation "$unsigned_from")"
run "$d" upgrade.sh -- "$unsigned"
check "auto: '! $unsigned is not signed' once, the upgrade goes on" \
  [ "$(grep -c "^! $unsigned is not signed" <<<"$out")" = 1 ]
check "...no cosign verify" lacks "$cosign_log" "[verify"
check "...goes on" went_on
d="$(installation "$unsigned_from")"
before="$(state "$d")"
run "$d" upgrade.sh CADENCE_VERIFY=require -- "$unsigned"
unchanged "$d" "$before" "require: an upgrade to the unsigned $unsigned is refused, nothing has changed"

[ "$failures" -eq 0 ] || die "$failures check(s) failed"
ok "signature verification checks passed"
