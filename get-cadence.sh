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
# --http-addr, --team, --team-name, --yes; see docs/admin.md, "Install").
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
#
# The checksum protects against a broken or altered download, not against a
# release replaced at its source.
set -eu

say() { printf '%s\n' "$*"; }
info() { printf '▸ %s\n' "$*"; }
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
                     --email, --http-addr, --team, --team-name, --yes

  CADENCE_RELEASES_URL   a mirror of the releases instead of GitHub
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
  want="$(awk -v f="$name" '$2 == f {print $1}' "$tmp/checksums.txt")"
  have="$(sha256_of "$tmp/$name")"
  [ -n "$want" ] && [ "$want" = "$have" ] ||
    die "the checksum of $name does not match checksums.txt of $version: the download is broken or altered; nothing was installed"

  mkdir -p "$dir"
  tar -xpzf "$tmp/$name" -C "$dir"
  info "unpacked Cadence Lab $version into $dir"

  cd "$dir"
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
