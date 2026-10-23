#!/usr/bin/env bash
#
# The closed network (docs/admin.md, "Air-gapped installation"; decision
# 0059 of CLAB-202): clab server images save on a machine with internet
# access, then on machines without any network clab server images load,
# the installation, its maintenance and an upgrade - and the refusal of the
# classic overlay2 storage. Docker of this machine is not touched: each
# machine is a Docker daemon of its own in a docker:28-dind container,
#
#   <name>-c   containerd image store; saves with network, then is cut off
#              (docker network disconnect) and loads, installs, backs up,
#              restores, verifies a backup and upgrades without network;
#   <name>-o   classic overlay2 storage, never on a network: load refuses.
#
# They are removed with their volumes at the end, whatever happens; <name>
# is COMPOSE_PROJECT_NAME (default check-airgap) - give it one of its own.
#
# The archive is of VERSION, with the images of ghcr.io and Docker Hub, and
# the package of VERSION is one of two (CHECK_AIRGAP_PACKAGE):
#
#   release    the published release of VERSION, from the releases of GitHub
#              (or CADENCE_RELEASES_URL): the real package, the real
#              signature of its checksums.txt, nothing stands in;
#   checkout   the package of this checkout, built by ci/package.sh --bundle
#              (clab of VERSION from the tap, checked against its sums) and
#              served to save as a release from a directory of its own
#              (file:///pkg on the machine). It is not signed and cannot be:
#              the identity of the signature is release.yml of self-hosted,
#              built into clab. So on the machines cosign is a stand-in
#              (ci/verify-stubs.sh, stub_cosign_package) that accepts
#              verify-blob of exactly the checksums.txt built in this run - by
#              its SHA-256 - and hands every other call to the real cosign:
#              the images, their OpenVEX and trusted_root.json of Sigstore are
#              verified for real, and installation and upgrade stay
#              CADENCE_VERIFY=require. Before anything is saved the check
#              makes sure that another checksums.txt goes to the real cosign
#              and is refused, and at the end that the images went there too.
#              What it does not prove is the signature of the package: there
#              is none yet;
#   auto       (default) release when download/VERSION/checksums.txt is
#              there, checkout when the releases answer 404 for it - a release
#              pull request (release/vX.Y.Z), where the release appears only
#              once it is merged. Any other answer or a network error stops
#              the check.
#
# The output names the package and why. With CHECK_AIRGAP_FROM=vA the archive
# of vA - always the published release - is saved too: vA is installed from it
# and upgraded to VERSION without network.
#
# The clab is CLAB_BIN - a linux clab for the architecture of Docker (the
# one of a branch) - else the clab of VERSION from the tap. A clab without
# "clab server images" (v0.14.1 and older) skips the check
# with a note: it starts with the release that brings the command. regctl
# and cosign are downloaded at the versions below and checked against the
# sums below (.cache/airgap of this checkout keeps them).
#
#   ci/check-airgap.sh
#   COMPOSE_PROJECT_NAME=check-clab-202 CLAB_BIN=/path/clab-linux-arm64 ci/check-airgap.sh
#   CHECK_AIRGAP_PACKAGE=checkout CLAB_BIN=/path/clab-linux-arm64 ci/check-airgap.sh
#
#   CLAB_BIN              linux clab with clab server images (default: the tap)
#   CHECK_AIRGAP_PACKAGE  auto (default), release or checkout: see above
#   CHECK_AIRGAP_FROM     a release to install first and upgrade from
#   CADENCE_RELEASES_URL  where the releases are (default GitHub)
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=ci/lib.sh
. ./ci/lib.sh
# shellcheck source=ci/verify-stubs.sh
. ./ci/verify-stubs.sh

REGCTL_VERSION=v0.9.2
COSIGN_VERSION=v3.1.3
# sha256_pinned TOOL ARCH: the sum of the binary of that release
sha256_pinned() {
  case "$1-$2" in
  regctl-amd64) echo 4da11cfe7009661a498ffafc11f510049864ffb4eb44961743618b3975db3c55 ;;
  regctl-arm64) echo db871e295c78b9b85b04eefd9332698fccb59298f5788aa18388e4e8d21c7420 ;;
  cosign-amd64) echo 4629c757b7618056f8ddd7e2625ae9fdd94c0372a65049520bc7d9df9efc7f71 ;;
  cosign-arm64) echo c5d324e091826b0d7a78eb16fef316450b4eb9aaec045611c08ba06f5e73220a ;;
  esac
}
DIND=docker:28-dind

failures=0
pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  failures=$((failures + 1))
}
check() {
  local what="$1"
  shift
  if "$@" >/dev/null 2>&1; then pass "$what"; else fail "$what"; fi
}
contains() { grep -qF -- "$2" <<<"$1"; }
lacks() { ! grep -qF -- "$2" <<<"$1"; }

load_version
version="$CADENCE_VERSION"
from="${CHECK_AIRGAP_FROM:-}"
[ -z "$from" ] || valid_version "$from" || die "CHECK_AIRGAP_FROM is '$from', expected vX.Y.Z"
[ -z "$from" ] || version_lt "$from" "$version" || die "CHECK_AIRGAP_FROM ($from) must be older than VERSION ($version)"
name="${COMPOSE_PROJECT_NAME:-check-airgap}"
package="${CHECK_AIRGAP_PACKAGE:-auto}"
case "$package" in
auto | release | checkout) ;;
*) die "CHECK_AIRGAP_PACKAGE is '$package', expected auto, release or checkout" ;;
esac
releases="${CADENCE_RELEASES_URL:-}"
releases_url="${releases:-$CADENCE_RELEASES_DEFAULT}"
releases_url="${releases_url%/}"
command -v docker >/dev/null 2>&1 || die "Docker is required"
case "$(docker version --format '{{.Server.Arch}}')" in
amd64 | x86_64) arch=amd64 ;;
arm64 | aarch64) arch=arm64 ;;
*) die "Docker of this machine runs $(docker version --format '{{.Server.Arch}}'): the check knows amd64 and arm64" ;;
esac

work="$(mktemp -d "${TMPDIR:-/tmp}/check-airgap.XXXXXX")"
c="$name-c"
o="$name-o"
cleanup() {
  docker rm -f -v "$c" "$o" >/dev/null 2>&1 || true
  # The daemons ran as root in the containers: their files under $work too.
  docker run --rm -v "$work:/w" --entrypoint sh "$DIND" -c 'rm -rf /w/*' >/dev/null 2>&1 || true
  rm -rf "$work"
}
trap cleanup EXIT

# --- tools ------------------------------------------------------------------------
mkdir -p "$work/tools"
cache="$(pwd)/.cache/airgap"
mkdir -p "$cache"
tool() { # tool NAME URL SHA256
  local f="$cache/$1-$arch"
  [ -f "$f" ] && [ "$(sha256_of "$f")" = "$3" ] || fetch "$2" "$f" || die "could not download $1 from $2"
  [ "$(sha256_of "$f")" = "$3" ] || die "the sum of $1 ($2) is not the pinned one: the download is broken or altered"
  install -m 755 "$f" "$work/tools/$1"
}
tool regctl "https://github.com/regclient/regclient/releases/download/$REGCTL_VERSION/regctl-linux-$arch" "$(sha256_pinned regctl "$arch")"
tool cosign "https://github.com/sigstore/cosign/releases/download/$COSIGN_VERSION/cosign-linux-$arch" "$(sha256_pinned cosign "$arch")"
if [ -n "${CLAB_BIN:-}" ]; then
  install -m 755 "$CLAB_BIN" "$work/tools/clab"
else
  archive="$(clab_archive "$version" "linux-$arch")"
  base="$(tap_releases_url)/download/$version"
  fetch "$base/checksums.txt" "$work/clab-sums" || die "the tap has no release $version: set CLAB_BIN"
  fetch "$base/$archive" "$work/$archive" || die "the tap has no $archive: set CLAB_BIN"
  [ "$(awk -v f="$archive" '$2 == f {print $1}' "$work/clab-sums")" = "$(sha256_of "$work/$archive")" ] ||
    die "the sum of $archive does not match checksums.txt of the tap"
  tar -xzf "$work/$archive" -C "$work" "${archive%.tar.gz}/clab"
  install -m 755 "$work/${archive%.tar.gz}/clab" "$work/tools/clab"
fi
docker pull -q "$DIND" >/dev/null
if ! docker run --rm -v "$work/tools:/t:ro" --entrypoint /t/clab "$DIND" server images --help >/dev/null 2>&1; then
  ok "skipped: clab $(docker run --rm -v "$work/tools:/t:ro" --entrypoint /t/clab "$DIND" version 2>/dev/null | head -n 1 | cut -d' ' -f2) has no clab server images; the check starts with the release that brings it (or CLAB_BIN)"
  exit 0
fi

# --- the package of VERSION ------------------------------------------------------------
# published: the releases have download/VERSION/checksums.txt (true) or
# answer 404 for it (false); anything else stops the check - a network error
# is not "no release".
published() {
  local url="$releases_url/download/$version/checksums.txt" code
  case "$url" in
  file://*)
    [ -f "${url#file://}" ]
    return
    ;;
  esac
  code="$(curl -sL --retry 2 -o /dev/null -w '%{http_code}' "$url")" ||
    die "could not ask $releases_url whether the release $version is published ($url)"
  case "$code" in
  200) return 0 ;;
  404) return 1 ;;
  *) die "$url answered $code: cannot tell whether the release $version is published" ;;
  esac
}
case "$package" in
release)
  published || die "CHECK_AIRGAP_PACKAGE=release, but there is no release $version at $releases_url (no download/$version/checksums.txt there): nothing to check"
  why="CHECK_AIRGAP_PACKAGE=release"
  ;;
checkout) why="CHECK_AIRGAP_PACKAGE=checkout" ;;
auto)
  if published; then
    package=release
    why="it is published"
  else
    package=checkout
    why="there is no release $version at $releases_url yet, as on a release pull request"
  fi
  ;;
esac
mkdir -p "$work/pkg" "$work/log"
cosign_log="$work/log/cosign.log"
if [ "$package" = release ]; then
  info "the package: the published release $version at $releases_url ($why)"
  save_releases="$releases"
else
  info "the package: of this checkout, not a release ($why)"
  ./ci/package.sh --bundle "$work/pkg/download/$version" >/dev/null ||
    die "ci/package.sh could not build the package of $version of this checkout"
  package_sum="$(sha256_of "$work/pkg/download/$version/checksums.txt")"
  stub_cosign_package "$work/tools/cosign-package" /usr/local/libexec/cosign "$package_sum" /log/cosign.log
  save_releases="file:///pkg"
  say "  built by ci/package.sh, served to save as $save_releases; its checksums.txt (sha256 $package_sum)"
  say "  is not signed: a stand-in cosign accepts it, every other call goes to the real cosign"
fi

# --- the two machines -----------------------------------------------------------------
mkdir -p "$work/c" "$work/o" "$work/share"
printf '{"features":{"containerd-snapshotter":true}}\n' >"$work/c/daemon.json"
printf '{"features":{"containerd-snapshotter":false},"storage-driver":"overlay2"}\n' >"$work/o/daemon.json"
machine() { # machine NAME CONFIG [docker run flags]
  local n="$1" cfg="$2"
  shift 2
  docker rm -f -v "$n" >/dev/null 2>&1 || true
  docker run -d --privileged --name "$n" "$@" -v "$cfg:/etc/docker/daemon.json:ro" \
    -v "$work/share:/share" -v "$work/tools:/tools:ro" -v "$work/pkg:/pkg:ro" -v "$work/log:/log" "$DIND" >/dev/null
  local i
  for i in $(seq 60); do
    docker exec "$n" docker info >/dev/null 2>&1 && break
    [ "$i" -lt 60 ] || die "the Docker daemon of $n did not start"
    sleep 1
  done
  # The package of this checkout: the stand-in as cosign, the real one behind it.
  docker exec "$n" sh -c 'install -m 755 /tools/regctl /tools/clab /usr/local/bin/ &&
    if [ -f /tools/cosign-package ]; then
      install -D -m 755 /tools/cosign /usr/local/libexec/cosign && install -m 755 /tools/cosign-package /usr/local/bin/cosign
    else
      install -m 755 /tools/cosign /usr/local/bin/
    fi'
}
# on NAME SCRIPT: sh -c SCRIPT on the machine NAME; the clab of the check
# runs the scripts of the package too (CADENCE_CLAB).
on() {
  docker exec -e CADENCE_CLAB=/usr/local/bin/clab -e CADENCE_RELEASES_URL="${3:-}" "$1" sh -c "$2"
}

info "machine $c (containerd image store): save with network"
machine "$c" "$work/c/daemon.json"
check "$c runs the containerd image store" contains "$(docker exec "$c" docker info 2>/dev/null)" "io.containerd.snapshotter.v1"
# curl for get-cadence.sh: the machine will have no network to add it.
docker exec "$c" apk add -q curl >/dev/null || die "could not add curl to $c"
if [ "$package" = checkout ]; then
  # The stand-in is bound to the package of this run: another checksums.txt
  # goes to the real cosign, which refuses the stand-in bundle.
  docker exec "$c" sh -c "cp /pkg/download/$version/checksums.txt /tmp/altered.txt && echo altered >>/tmp/altered.txt"
  blob="cosign verify-blob --bundle /pkg/download/$version/$VERIFY_BUNDLE --certificate-identity $VERIFY_PACKAGE_IDENTITY --certificate-oidc-issuer $VERIFY_ISSUER"
  check "stand-in cosign: another checksums.txt is refused" sh -c "! docker exec $c $blob /tmp/altered.txt"
  check "...by the real cosign" grep -qF "real [verify-blob]" "$cosign_log"
  check "stand-in cosign: checksums.txt of this package passes" docker exec "$c" sh -c "$blob /pkg/download/$version/checksums.txt"
  check "stand-in cosign: cosign version is the real one" contains "$(docker exec "$c" cosign version 2>&1)" "$COSIGN_VERSION"
fi
saved_sum=""
for v in $from $version; do
  rel="$releases"
  [ "$v" != "$version" ] || rel="$save_releases"
  out="$(on "$c" "cd /share && clab server images save --version $v --output cadence-$v-airgap.tar" "$rel" 2>&1)" ||
    { printf '%s\n' "$out" | tail -n 20 >&2; die "clab server images save --version $v failed"; }
  sum="$(sha256_of "$work/share/cadence-$v-airgap.tar")"
  check "save $v prints the SHA-256 of the archive" contains "$out" "$sum"
  [ "$v" != "$version" ] || saved_sum="$sum"
done
check "save puts no image into Docker" [ -z "$(docker exec "$c" docker image ls -q)" ]
docker network disconnect bridge "$c"
check "$c has no network" sh -c "! docker exec $c wget -q -T 5 -O /dev/null https://ghcr.io/v2/"

info "machine $o (classic overlay2 storage), never on a network"
machine "$o" "$work/o/daemon.json" --network none
out="$(on "$o" "cd /share && clab server images load cadence-$version-airgap.tar" 2>&1)" && code=0 || code=$?
check "overlay2: load without --registry refuses with 1" [ "$code" = 1 ]
check "...and names the containerd image store" contains "$out" "containerd image store"
check "...and --registry" contains "$out" "--registry HOST[/PATH]"
check "...and leaves no image and no container" [ -z "$(docker exec "$o" sh -c 'docker image ls -q; docker ps -aq')" ]
docker rm -f -v "$o" >/dev/null

info "machine $c without network: load, install, maintenance"
mirror="file:///share"
first="${from:-$version}"
out="$(on "$c" "cd /share && clab server images load cadence-$first-airgap.tar" 2>&1)" ||
  { printf '%s\n' "$out" | tail -n 20 >&2; die "clab server images load of $first failed"; }
check "load $first verifies checksums.txt offline" contains "$out" "verified offline with trusted_root.json of the archive"
check "load $first verifies sdlc-pipeline-backend offline" contains "$out" "sdlc-pipeline-backend/.github/workflows/release.yml@refs/tags/$first (verified offline"
check "load $first verifies the OpenVEX of sdlc-pipeline-backend offline" contains "$out" "the OpenVEX of 127.0.0.1:"
check "load $first leaves no temporary registry" [ -z "$(docker exec "$c" docker ps -aq --filter label=cadence.images-load)" ]
for img in $(on "$c" "tar -xOf /share/cadence-$first-airgap.tar cadence-images.json" | grep -o '"ref": "[^"]*"' | cut -d'"' -f4); do
  check "the compose reference $img is in Docker" docker exec "$c" docker image inspect "$img"
done
before="$(docker exec "$c" docker image ls -q | sort | tr '\n' ' ')"
check "load $first drops nothing of a genuine archive (no \"not carried\")" lacks "$out" "not carried"
check "load again: done" on "$c" "cd /share && clab server images load cadence-$first-airgap.tar"
check "...and nothing new in Docker" [ "$(docker exec "$c" docker image ls -q | sort | tr '\n' ' ')" = "$before" ]

# Into a registry of the closed network (--registry): the registry is the
# image of the temporary registry of the archive. Only the image and its
# verified Sigstore bundles - the signature and the OpenVEX - reach it.
regtar="$(on "$c" "tar -xOf /share/cadence-$first-airgap.tar cadence-images.json" | grep -o "\"linux/$arch\": \"[^\"]*\"" | cut -d'"' -f4)"
on "$c" "tar -xOf /share/cadence-$first-airgap.tar $regtar | docker load -q" >/dev/null || die "could not load the registry image of the archive"
regimg="$(on "$c" "tar -xOf /share/cadence-$first-airgap.tar cadence-images.json" | grep -o '"name": "[^"]*"' | head -n 1 | cut -d'"' -f4)"
on "$c" "docker run -d --name admin-registry -p 127.0.0.1:5001:5000 $regimg" >/dev/null || die "could not start a registry on $c"
for i in $(seq 30); do
  on "$c" "wget -q -O /dev/null http://127.0.0.1:5001/v2/" 2>/dev/null && break
  [ "$i" -lt 30 ] || die "the registry on $c does not answer"
  sleep 1
done
# A plain-http registry for regctl of the administrator, as docs/admin.md says.
on "$c" "regctl registry set --tls disabled 127.0.0.1:5001" >/dev/null || die "could not configure regctl for the registry on $c"
out="$(on "$c" "cd /share && clab server images load cadence-$first-airgap.tar --registry 127.0.0.1:5001/cadence" 2>&1)" ||
  { printf '%s\n' "$out" | tail -n 20 >&2; die "clab server images load --registry of $first failed"; }
host="--host reg=127.0.0.1:5001,tls=disabled"
check "load --registry: sdlc-pipeline-backend has its pin there" [ "$(on "$c" "regctl $host image digest 127.0.0.1:5001/cadence/sdlc-pipeline-backend:$first")" = \
  "$(on "$c" "tar -xOf /share/cadence-$first-airgap.tar cadence-images.json" | grep -o "sdlc-pipeline-backend:$first@sha256:[0-9a-f]*" | head -n 1 | cut -d@ -f2)" ]
check "...and exactly its two Sigstore bundles as referrers" [ "$(on "$c" "regctl $host artifact list 127.0.0.1:5001/cadence/sdlc-pipeline-backend:$first --format '{{range .Descriptors}}{{println .ArtifactType}}{{end}}'" | sort | uniq -c | tr -s ' ')" = \
  " 2 application/vnd.dev.sigstore.bundle.v0.3+json" ]
check "...which cosign verifies there offline" on "$c" "cosign verify --offline --trusted-root /share/download/$first/trusted_root.json --allow-http-registry --certificate-identity https://github.com/cadence-lab-tech/sdlc-pipeline-backend/.github/workflows/release.yml@refs/tags/$first --certificate-oidc-issuer https://token.actions.githubusercontent.com 127.0.0.1:5001/cadence/sdlc-pipeline-backend:$first"
on "$c" "docker rm -f -v admin-registry; docker rmi $regimg" >/dev/null 2>&1 || true

# The one-line installer of a package with the wrappers; clab server install
# for a release before them.
if on "$c" "tar -tzf /share/download/$first/$(package_name "$first")" | grep -q '^\(\./\)\{0,1\}bin/clab-'; then
  install="sh /share/download/$first/get-cadence.sh --version $first --dir /root/cadence --mode proxy --http-addr 127.0.0.1:8080 --yes"
else
  install="clab server install --version $first --dir /root/cadence --mode proxy --http-addr 127.0.0.1:8080 --yes"
fi
out="$(on "$c" "cd /root && CADENCE_VERIFY=require $install" "$mirror" 2>&1)" ||
  { printf '%s\n' "$out" | tail -n 30 >&2; die "the installation of $first without network failed"; }
check "install $first: checksums.txt verified with trusted_root.json of the mirror" contains "$out" "verified offline with trusted_root.json of the mirror"
check "install $first: the images verified when loaded (require)" contains "$out" "verified when loaded: same digest as the pin of the signed package"
check "install $first: nothing pulled" contains "$out" "images are on this machine: nothing to pull"
check "install $first: /readyz answers 200" docker exec "$c" wget -q -O /dev/null http://127.0.0.1:8080/readyz

# Maintenance from an empty environment, as from cron.
bare="env -i PATH=/usr/local/bin:/usr/bin:/bin HOME=/root"
if docker exec "$c" test -x /root/cadence/bin/clab-linux-"$arch"; then
  backup="$bare CADENCE_CLAB=/usr/local/bin/clab ./backup.sh"
  restore="CADENCE_CLAB=/usr/local/bin/clab ./restore.sh --yes"
else
  backup="$bare clab server backup"
  restore="clab server restore --yes"
fi
check "backup without network from an empty environment" docker exec -w /root/cadence "$c" sh -c "$backup"
check "backup verify without network" docker exec -w /root/cadence "$c" clab server backup verify
check "restore without network" docker exec -w /root/cadence "$c" sh -c "$restore \$(ls backups/*.sql.gz | tail -n 1)"
check "status without network" docker exec -w /root/cadence "$c" clab server status
check "after restore: /readyz answers 200" docker exec "$c" wget -q -O /dev/null http://127.0.0.1:8080/readyz

if [ -n "$from" ]; then
  info "upgrade $from -> $version without network"
  out="$(on "$c" "cd /share && clab server images load cadence-$version-airgap.tar" 2>&1)" ||
    { printf '%s\n' "$out" | tail -n 20 >&2; die "clab server images load of $version failed"; }
  out="$(on "$c" "cd /root/cadence && CADENCE_VERIFY=require clab server upgrade $version" "$mirror" 2>&1)" ||
    { printf '%s\n' "$out" | tail -n 30 >&2; die "the upgrade to $version without network failed"; }
  check "upgrade: the version is $version" [ "$(docker exec "$c" cat /root/cadence/VERSION)" = "$version" ]
  check "upgrade: /readyz answers 200" docker exec "$c" wget -q -O /dev/null http://127.0.0.1:8080/readyz
  check "upgrade: the images of $from stay for the rollback" docker exec "$c" docker image inspect "ghcr.io/cadence-lab-tech/sdlc-pipeline-backend:$from"
else
  info "no CHECK_AIRGAP_FROM: the upgrade without network is not checked"
fi

if [ "$package" = checkout ]; then
  # What the stand-in let through: verify-blob of this package only; the
  # images, their OpenVEX and the root of Sigstore went to the real cosign.
  check "stand-in cosign: it accepted verify-blob of this package only" sh -c "! grep -E '^(stub|refused) ' '$cosign_log' | grep -qvE '^(stub|refused) \[verify-blob\]'"
  check "...and refused it off the network without trusted_root.json" grep -q '^refused \[verify-blob\]' "$cosign_log"
  check "the real cosign verified the images" grep -q '^real \[verify\]' "$cosign_log"
  check "...and their OpenVEX" grep -q '^real \[verify-attestation\]' "$cosign_log"
  check "...and fetched trusted_root.json of Sigstore" grep -q '^real \[initialize\]' "$cosign_log"
fi

[ "$failures" -eq 0 ] || die "$failures check(s) failed"
if [ "$package" = checkout ]; then
  ok "the closed network works on $version (archive $saved_sum; the package of this checkout, its checksums.txt not signed)"
else
  ok "the closed network works on $version (archive $saved_sum; the published release at $releases_url)"
fi
