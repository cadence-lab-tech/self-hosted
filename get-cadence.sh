#!/bin/sh
#
# Installs Cadence Lab from a release of the self-hosted package; git is not
# needed:
#
#   curl -fsSL https://github.com/cadence-lab-tech/self-hosted/releases/latest/download/get-cadence.sh | sh -s -- --domain cadence.example.com
#
# Downloads the package of the release and its checksums.txt, verifies the
# checksum, unpacks the package into a new directory and runs install.sh of
# the package there with the other flags (--mode, --domain, --email,
# --http-addr, --team, --team-name, --name, --external-db, --external-db-ca,
# --yes; see docs/admin.md, "Install"). A second installation on the same machine needs its own --dir
# and its own --name (docs/admin.md, "Several installations on one machine").
# Without a terminal - as above, where the script itself comes on stdin -
# install.sh asks nothing and takes the answers from the flags.
#
#   --version vX.Y.Z   the release to install, default the latest
#                      (or CADENCE_INSTALL_VERSION)
#   --dir DIR          where to unpack, default ./cadence (or
#                      CADENCE_INSTALL_DIR); must not exist or be empty
#
#   CADENCE_RELEASES_URL  where the releases are, default
#                         https://github.com/cadence-lab-tech/self-hosted/releases;
#                         a mirror or a directory (file:///path) with the
#                         layout download/vX.Y.Z/<asset>, latest/download/<asset>
#   CADENCE_VERIFY        auto (default), require or off: the signatures of
#                         the release (docs/admin.md, "Verifying a release")
#
# The checksum protects against a broken or altered download, not against a
# release replaced at its source; the signature does. With cosign 3.x in
# PATH the signature of checksums.txt (checksums.txt.sigstore.json of the
# release, by release.yml of self-hosted on main) is verified before anything
# is unpacked, and install.sh verifies the images; without cosign
# CADENCE_VERIFY=auto warns and goes on, require refuses, off skips it.
set -eu

say() { printf '%s\n' "$*"; }
info() { printf '▸ %s\n' "$*"; }
ok() { printf '✓ %s\n' "$*"; }
warn() { printf '! %s\n' "$*" >&2; }
die() {
  printf '✗ %s\n' "$*" >&2
  exit 1
}
need() {
  command -v "$1" >/dev/null 2>&1 || die "$1 is required: $2"
}
usage() {
  cat <<'USAGE'
get-cadence.sh [--version vX.Y.Z] [--dir DIR] [flags of install.sh]

  --version vX.Y.Z   the release to install, default the latest
  --dir DIR          where to unpack, default ./cadence
  other flags        go to install.sh of the package: --mode, --domain,
                     --email, --http-addr, --team, --team-name, --name, --yes;
                     --name NAME names the installation on this machine
                     (default cadence), a second one needs its own;
                     --external-db URL and --external-db-ca FILE put the data
                     into your own PostgreSQL (docs/admin.md, "External
                     PostgreSQL")

  CADENCE_RELEASES_URL   a mirror of the releases instead of GitHub
  CADENCE_VERIFY         auto (default): verify the signatures with cosign
                         3.x if it is installed; require: refuse without
                         them; off: do not verify (a closed network)
USAGE
}
valid_version() {
  expr "$1" : 'v[0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*$' >/dev/null
}
sha256_of() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum "$1" | awk '{print $1}'
  else
    shasum -a 256 "$1" | awk '{print $1}'
  fi
}
fetch() {
  curl -fsL --retry 2 -o "$2" "$1"
}
# version_before A B: A is an older version than B.
version_before() {
  awk -v a="${1#v}" -v b="${2#v}" 'BEGIN {
    split(a, x, "."); split(b, y, ".")
    for (i = 1; i <= 3; i++) { if (x[i] + 0 < y[i] + 0) exit 0; if (x[i] + 0 > y[i] + 0) exit 1 }
    exit 1
  }'
}

# --- signatures: the rules of lib.sh ("signatures") in POSIX sh ---------------------
# This script runs before the package is unpacked, so it cannot source
# lib.sh: the same rules and messages are repeated here, for the package
# only; install.sh of the package verifies the images.
FIRST_SIGNED=v0.9.0
ISSUER=https://token.actions.githubusercontent.com
PACKAGE_IDENTITY=https://github.com/cadence-lab-tech/self-hosted/.github/workflows/release.yml@refs/heads/main
BUNDLE=checksums.txt.sigstore.json
NOTHING="Nothing was installed."

# verify_init: CADENCE_VERIFY and cosign, before anything is downloaded.
verify_init() {
  verify_mode="${CADENCE_VERIFY:-auto}"
  verify_cosign=""
  verify_why=""
  verify_noted=""
  case "$verify_mode" in
  auto | require) ;;
  off)
    info "signature verification is off (CADENCE_VERIFY=off)"
    verify_noted=1
    return 0
    ;;
  *) die "CADENCE_VERIFY is '$verify_mode', expected auto, require or off. $NOTHING" ;;
  esac
  if ! command -v cosign >/dev/null 2>&1; then
    verify_why="cosign 3.x is not installed"
  else
    cv="$(cosign version 2>&1 | sed -n 's/^GitVersion:[[:space:]]*\(v\{0,1\}[0-9][0-9.]*\).*/\1/p' | head -n 1)"
    case "${cv#v}" in
    "") verify_why="cosign of an unknown version is not 3.x" ;;
    [012].*) verify_why="cosign $cv is older than 3.x" ;;
    *) verify_cosign=1 ;;
    esac
  fi
  if [ "$verify_mode" = require ] && [ -z "$verify_cosign" ]; then
    die "CADENCE_VERIFY=require, but $verify_why: install cosign 3.x (https://docs.sigstore.dev/cosign/system_config/installation/), or set CADENCE_VERIFY=auto. $NOTHING"
  fi
}
verify_note() {
  [ -z "$verify_noted" ] || return 0
  verify_noted=1
  warn "$1"
}
# verify_package VERSION BASE DIR: the signature of DIR/checksums.txt of
# VERSION by the bundle of the release at BASE, downloaded next to it.
verify_package() {
  [ "$verify_mode" != off ] || return 0
  if version_before "$1" "$FIRST_SIGNED"; then
    [ "$verify_mode" = auto ] ||
      die "$1 is not signed (signatures start with $FIRST_SIGNED), and CADENCE_VERIFY=require refuses it. $NOTHING"
    verify_note "$1 is not signed (signatures start with $FIRST_SIGNED): its package and images are not verified"
    return 0
  fi
  if [ -z "$verify_cosign" ]; then
    verify_note "$verify_why: the signatures of the release are not verified (CADENCE_VERIFY=auto). Install cosign 3.x to verify them: docs/admin.md, \"Verifying a release\""
    return 0
  fi
  fetch "$2/$BUNDLE" "$3/$BUNDLE" ||
    die "the release $1 has no $BUNDLE at $releases: the signature of its checksums.txt cannot be verified.
  Copy $BUNDLE of the release to the mirror, or set CADENCE_VERIFY=off. $NOTHING"
  if ! out="$(cosign verify-blob --bundle "$3/$BUNDLE" --certificate-identity "$PACKAGE_IDENTITY" \
    --certificate-oidc-issuer "$ISSUER" "$3/checksums.txt" 2>&1)"; then
    printf '%s\n' "$out" | tail -n 5 >&2
    die "the signature of checksums.txt of $1 did not verify for $PACKAGE_IDENTITY: the release is altered or not ours.
  Do not use it and report it privately (SECURITY.md). $NOTHING"
  fi
  ok "the signature of checksums.txt of $1 verified: signed by $PACKAGE_IDENTITY"
}

# Everything runs from main(): with curl | sh the shell reads the script from
# the pipe as it goes, so nothing must run before all of it has arrived.
main() {
  version="${CADENCE_INSTALL_VERSION:-}"
  dir="${CADENCE_INSTALL_DIR:-cadence}"
  releases="${CADENCE_RELEASES_URL:-https://github.com/cadence-lab-tech/self-hosted/releases}"
  releases="${releases%/}"

  # Own flags out, the rest stays in "$@" for install.sh.
  n=$#
  while [ "$n" -gt 0 ]; do
    arg="$1"
    shift
    n=$((n - 1))
    case "$arg" in
    --version | --dir)
      [ "$n" -gt 0 ] || die "$arg needs a value"
      case "$arg" in
      --version) version="$1" ;;
      --dir) dir="$1" ;;
      esac
      shift
      n=$((n - 1))
      ;;
    --external-db-ca)
      # install.sh runs in the new directory: a relative path to the CA
      # would no longer be found there.
      [ "$n" -gt 0 ] || die "$arg needs a value"
      case "$1" in
      /*) ca="$1" ;;
      *) ca="$(pwd)/$1" ;;
      esac
      shift
      n=$((n - 1))
      set -- "$@" "$arg" "$ca"
      ;;
    -h | --help)
      usage
      return 0
      ;;
    *) set -- "$@" "$arg" ;;
    esac
  done

  need curl "to download the package"
  need tar "to unpack the package"
  need bash "install.sh of the package is a bash script"
  need docker "install Docker Engine with the compose plugin: https://docs.docker.com/engine/install/"
  command -v sha256sum >/dev/null 2>&1 || command -v shasum >/dev/null 2>&1 ||
    die "sha256sum (coreutils) or shasum is required to verify the download"
  verify_init

  if [ -e "$dir/.env" ]; then
    die "$dir/.env exists: Cadence Lab is already installed there. To upgrade it: cd $dir && ./upgrade.sh"
  fi
  if [ -d "$dir" ] && [ -n "$(ls -A "$dir" 2>/dev/null)" ]; then
    die "$dir is not empty: pick a new directory with --dir"
  fi
  [ ! -e "$dir" ] || [ -d "$dir" ] || die "$dir exists and is not a directory"

  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT

  if [ -z "$version" ]; then
    fetch "$releases/latest/download/checksums.txt" "$tmp/checksums.txt" ||
      die "could not reach the latest release at $releases"
    version="$(sed -n 's/^[0-9a-f]\{64\}  cadence-self-hosted-\(v[0-9]*\.[0-9]*\.[0-9]*\)\.tar\.gz$/\1/p' "$tmp/checksums.txt" | head -n 1)"
    [ -n "$version" ] || die "the latest release at $releases has no package"
  fi
  valid_version "$version" || die "'$version' is not a version: expected vX.Y.Z"

  name="cadence-self-hosted-$version.tar.gz"
  base="$releases/download/$version"
  info "downloading $name"
  fetch "$base/checksums.txt" "$tmp/checksums.txt" || die "there is no release $version at $releases"
  fetch "$base/$name" "$tmp/$name" || die "the release $version has no $name"
  verify_package "$version" "$base" "$tmp"
  want="$(awk -v f="$name" '$2 == f {print $1}' "$tmp/checksums.txt")"
  have="$(sha256_of "$tmp/$name")"
  if [ -z "$want" ] || [ "$want" != "$have" ]; then
    die "the checksum of $name does not match checksums.txt of $version: the download is broken or altered; nothing was installed"
  fi

  mkdir -p "$dir"
  tar -xpzf "$tmp/$name" -C "$dir"
  info "unpacked Cadence Lab $version into $dir"

  cd "$dir"
  # What the mode means for this release is said: install.sh does not repeat it.
  if [ -n "$verify_noted" ]; then
    CADENCE_VERIFY_NOTED=1
    export CADENCE_VERIFY_NOTED
  fi
  # stdin may be this very script (curl | sh): install.sh must not read it.
  if [ -t 0 ]; then
    bash ./install.sh "$@"
  else
    bash ./install.sh "$@" </dev/null
  fi
  say ""
  say "The installation lives in $(pwd): run ./upgrade.sh, ./backup.sh and docker compose there."
}

main "$@"
