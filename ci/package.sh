#!/usr/bin/env bash
#
# Builds the release assets of the package (ci/lib.sh, "releases"):
#
#   ci/package.sh dist                      # the version in VERSION
#   ci/package.sh --version v0.6.0 dist     # VERSION inside the package set
#                                           # to v0.6.0 - for upgrade checks
#   ci/package.sh --bundle dist             # also a stand-in
#                                           # checksums.txt.sigstore.json
#   ci/package.sh --clab DIR dist           # clab from DIR, not from the tap
#   ci/package.sh --clab-version v0.12.0 dist
#                                           # clab of another release of
#                                           # the tap (upgrade checks)
#   ci/package.sh --verify-clab dist        # also verify the signature of
#                                           # checksums.txt of the tap
#
# writes into the output directory
#
#   cadence-self-hosted-vX.Y.Z.tar.gz   the files of PACKAGE_FILES below, the
#                                       clab of each platform as
#                                       bin/clab-<os>-<arch> and
#                                       package.sha256, with no top
#                                       directory: it unpacks into the
#                                       current one
#   get-cadence.sh                      the one-line installer
#   checksums.txt                       sha256 of the two, as sha256sum prints
#   checksums.txt.sigstore.json         with --bundle: a stand-in for the
#                                       signature that release.yml makes - not
#                                       a signature, for checks whose cosign
#                                       is a stub or accepts verify-blob of
#                                       this package (ci/verify-stubs.sh)
#
# The package is a list, not "everything but": ci/, .github/, .git, .env,
# backups/, secrets/ and the local compose.override.yml never get in.
# Scripts and the clab binaries are 755 and everything else 644 whatever
# the umask.
#
# clab in the package (decision 0057). install.sh, upgrade.sh, backup.sh and
# restore.sh are wrappers of clab server: the package carries clab - the
# binary only, not clab-runner - for linux and darwin, amd64 and arm64, of
# the release of the tap of the version in VERSION (--clab-version: another
# one). The archives clab_vX.Y.Z_<os>_<arch>.tar.gz come from the release
# vX.Y.Z of cadence-lab-tech/homebrew-tap, where release.yml of the backend
# publishes them, and are checked against checksums.txt of that release
# before anything is packed; with --verify-clab also that checksums.txt
# against its signature (cosign 3.x, keyless, signed by release.yml of the
# backend on the tag vX.Y.Z) - release.yml of this repository does it. No
# archive of the version, or a sum that does not match: the build stops,
# naming it, and writes no package. The signature of checksums.txt of the
# package covers the binaries through package.sha256.
#
# --clab DIR takes clab-<os>-<arch> of the four platforms from DIR instead -
# a clab of a branch of the backend, built for the check of a package:
#
#   (cd backend && for p in linux/amd64 linux/arm64 darwin/amd64 darwin/arm64; do
#     CGO_ENABLED=0 GOOS=${p%/*} GOARCH=${p#*/} go build -ldflags "-X main.version=vX.Y.Z" \
#       -o /tmp/clab-bin/clab-${p%/*}-${p#*/} ./cmd/clab; done)
#   ci/package.sh --clab /tmp/clab-bin dist
#
#   CADENCE_TAP_RELEASES_URL  the releases of the tap, default
#                             https://github.com/cadence-lab-tech/homebrew-tap/releases
#                             (a mirror or file:///path, layout download/vX.Y.Z/<asset>)
#   CADENCE_CLAB_CACHE        where the downloaded archives are kept between
#                             builds, default .cache/clab of this checkout;
#                             they are checked against checksums.txt every time
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=ci/lib.sh
. ./ci/lib.sh

# Files of the package. A file added to the repository for the installation
# goes here too, and into the required list of ci/check-config.sh.
PACKAGE_FILES=(
  VERSION
  docker-compose.yml compose.tls.yml compose.proxy.yml compose.external-db.yml compose.secrets.yml Caddyfile .env.example
  install.sh upgrade.sh backup.sh restore.sh
  postgres/major-upgrade.sh
  README.md LICENSE SECURITY.md
)
# Directories that go in whole.
PACKAGE_DIRS=(bundles docs)

version=""
out=""
bundle=false
clab_dir=""
clab_version=""
verify_clab=false
while [ $# -gt 0 ]; do
  case "$1" in
  --version) version="${2:?--version needs vX.Y.Z}"; shift 2 ;;
  --bundle) bundle=true; shift ;;
  --clab) clab_dir="${2:?--clab needs a directory}"; shift 2 ;;
  --clab-version) clab_version="${2:?--clab-version needs vX.Y.Z}"; shift 2 ;;
  --verify-clab) verify_clab=true; shift ;;
  -h | --help) sed -n '3,65p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  -*) die "unknown option: $1" ;;
  *) [ -z "$out" ] || die "one output directory"; out="$1"; shift ;;
  esac
done
[ -n "$out" ] || die "usage: ci/package.sh [--version vX.Y.Z] [--clab DIR | --clab-version vX.Y.Z] [--verify-clab] [--bundle] <output directory>"
[ -n "$version" ] || version="$(tr -d '[:space:]' <VERSION)"
valid_version "$version" || die "'$version' is not a version: expected vX.Y.Z"
[ -n "$clab_version" ] || clab_version="$(tr -d '[:space:]' <VERSION)"
valid_version "$clab_version" || die "'$clab_version' is not a version of clab: expected vX.Y.Z"
[ -z "$clab_dir" ] || [ "$verify_clab" = false ] || die "--verify-clab checks the clab of the tap, not of --clab DIR"

files=("${PACKAGE_FILES[@]}")
for d in "${PACKAGE_DIRS[@]}"; do
  [ -d "$d" ] || die "no directory $d"
  while IFS= read -r f; do files+=("$f"); done < <(find "$d" -type f ! -name '.*' | sort)
done

stage="$(mktemp -d)"
trap 'rm -rf "$stage"' EXIT
for f in "${files[@]}"; do
  [ -f "$f" ] || die "package file $f is missing"
  mkdir -p "$stage/$(dirname "$f")"
  case "$f" in
  *.sh) mode=755 ;;
  *) mode=644 ;;
  esac
  cp "$f" "$stage/$f"
  chmod "$mode" "$stage/$f"
done
printf '%s\n' "$version" >"$stage/VERSION"
chmod 644 "$stage/VERSION"

# --- clab ------------------------------------------------------------------------------
# clab_from_tap VERSION DIR: the clab of every platform of the release
# VERSION of the tap into DIR as clab-<os>-<arch>, each archive checked
# against checksums.txt of the release (and its signature with
# --verify-clab).
clab_from_tap() {
  local v="$1" into="$2" base cache p archive want have out
  base="$(tap_releases_url)/download/$v"
  cache="${CADENCE_CLAB_CACHE:-$(pwd)/.cache/clab}/$v"
  mkdir -p "$cache"
  fetch "$base/checksums.txt" "$cache/checksums.txt" ||
    die "the release $v of the tap has no checksums.txt ($base/checksums.txt): the archives of clab $v are not published.
  release.yml of the backend publishes them; build the package once they are there."
  if [ "$verify_clab" = true ]; then
    command -v cosign >/dev/null 2>&1 || die "--verify-clab needs cosign 3.x in PATH"
    fetch "$base/$VERIFY_BUNDLE" "$cache/$VERIFY_BUNDLE" ||
      die "the release $v of the tap has no $VERIFY_BUNDLE: the signature of its checksums.txt cannot be verified"
    if ! out="$(cosign verify-blob --bundle "$cache/$VERIFY_BUNDLE" --certificate-identity "$(verify_identity sdlc-pipeline-backend "$v")" \
      --certificate-oidc-issuer "$VERIFY_ISSUER" "$cache/checksums.txt" 2>&1)"; then
      printf '%s\n' "$out" | tail -n 5 >&2
      die "the signature of checksums.txt of clab $v did not verify for $(verify_identity sdlc-pipeline-backend "$v"): no package is built"
    fi
    ok "the signature of checksums.txt of clab $v verified: signed by $(verify_identity sdlc-pipeline-backend "$v")"
  fi
  for p in $CLAB_PLATFORMS; do
    archive="$(clab_archive "$v" "$p")"
    want="$(awk -v f="$archive" '$2 == f {print $1}' "$cache/checksums.txt")"
    [ -n "$want" ] || die "checksums.txt of the release $v of the tap has no $archive: the archives of clab $v are not all published"
    # A kept archive is used when its sum still matches, else downloaded again.
    have=""
    [ ! -f "$cache/$archive" ] || have="$(sha256_of "$cache/$archive")"
    if [ "$have" != "$want" ]; then
      fetch "$base/$archive" "$cache/$archive" ||
        die "the release $v of the tap has no $archive ($base/$archive): the archives of clab $v are not all published"
      have="$(sha256_of "$cache/$archive")"
    fi
    [ "$have" = "$want" ] ||
      die "the sum of $archive does not match checksums.txt of the release $v of the tap: the download is broken or altered; no package is built"
    rm -rf "$cache/x"
    mkdir -p "$cache/x"
    tar -xzf "$cache/$archive" -C "$cache/x" "${archive%.tar.gz}/clab" 2>/dev/null ||
      die "$archive has no ${archive%.tar.gz}/clab"
    mv "$cache/x/${archive%.tar.gz}/clab" "$into/clab-$p"
    rm -rf "$cache/x"
  done
}

mkdir -p "$stage/bin"
if [ -n "$clab_dir" ]; then
  for p in $CLAB_PLATFORMS; do
    [ -f "$clab_dir/clab-$p" ] || die "--clab $clab_dir has no clab-$p: the package carries clab for $CLAB_PLATFORMS"
    cp "$clab_dir/clab-$p" "$stage/bin/clab-$p"
  done
  clab_source="$clab_dir"
else
  clab_from_tap "$clab_version" "$stage/bin"
  clab_source="the tap, $clab_version"
fi
for p in $CLAB_PLATFORMS; do
  chmod 755 "$stage/bin/clab-$p"
  files+=("bin/clab-$p")
done

# The reference of the package files: what upgrade.sh compares the
# installation with before replacing the files.
(
  cd "$stage"
  for f in "${files[@]}"; do
    printf '%s  %s\n' "$(sha256_of "$f")" "$f"
  done
) >"$stage/$PACKAGE_MANIFEST"
chmod 644 "$stage/$PACKAGE_MANIFEST"

mkdir -p "$out"
out="$(cd "$out" && pwd)"
name="$(package_name "$version")"
# Files belong to root:root in the archive, not to whoever built it; an
# unprivileged tar unpacks them as the user who runs it anyway.
# COPYFILE_DISABLE keeps macOS tar from adding ._ metadata files.
if tar --version 2>/dev/null | grep -q 'GNU tar'; then
  owner=(--owner=0 --group=0 --numeric-owner)
else
  owner=(--uid 0 --gid 0 --uname root --gname root)
fi
COPYFILE_DISABLE=1 tar "${owner[@]}" -C "$stage" -czf "$out/$name" "$PACKAGE_MANIFEST" "${files[@]}"
cp get-cadence.sh "$out/get-cadence.sh"
chmod 755 "$out/get-cadence.sh"
(
  cd "$out"
  for f in "$name" get-cadence.sh; do
    printf '%s  %s\n' "$(sha256_of "$f")" "$f"
  done
) >"$out/checksums.txt"
chmod 644 "$out/$name" "$out/checksums.txt"
if [ "$bundle" = true ]; then
  printf '{"note": "a stand-in for checks, not a signature: ci/package.sh --bundle"}\n' >"$out/$VERIFY_BUNDLE"
  chmod 644 "$out/$VERIFY_BUNDLE"
fi

ok "$out/$name ($(wc -c <"$out/$name" | tr -d ' ') bytes, clab from $clab_source), get-cadence.sh, checksums.txt"
