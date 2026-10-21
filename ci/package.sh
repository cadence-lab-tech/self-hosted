#!/usr/bin/env bash
#
# Builds the release assets of the package (lib.sh, "releases"):
#
#   ci/package.sh dist                      # the version in VERSION
#   ci/package.sh --version v0.6.0 dist     # VERSION inside the package set
#                                           # to v0.6.0 - for upgrade checks
#
# writes into the output directory
#
#   cadence-self-hosted-vX.Y.Z.tar.gz   the files of PACKAGE_FILES below and
#                                       package.sha256, with no top directory:
#                                       it unpacks into the current one
#   get-cadence.sh                      the one-line installer
#   checksums.txt                       sha256 of the two, as sha256sum prints
#
# The package is a list, not "everything but": ci/, .github/, .git, .env,
# backups/, secrets/ and the local compose.override.yml never get in.
# Scripts are 755 and everything else 644 whatever the umask.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=lib.sh
. ./lib.sh

# Files of the package. A file added to the repository for the installation
# goes here too, and into the required list of ci/check-config.sh.
PACKAGE_FILES=(
  VERSION
  docker-compose.yml compose.tls.yml compose.proxy.yml compose.external-db.yml compose.secrets.yml Caddyfile .env.example
  install.sh upgrade.sh backup.sh restore.sh lib.sh
  README.md LICENSE SECURITY.md
)
# Directories that go in whole.
PACKAGE_DIRS=(bundles docs)

version=""
out=""
while [ $# -gt 0 ]; do
  case "$1" in
  --version) version="${2:?--version needs vX.Y.Z}"; shift 2 ;;
  -h | --help) sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
  -*) die "unknown option: $1" ;;
  *) [ -z "$out" ] || die "one output directory"; out="$1"; shift ;;
  esac
done
[ -n "$out" ] || die "usage: ci/package.sh [--version vX.Y.Z] <output directory>"
[ -n "$version" ] || version="$(tr -d '[:space:]' <VERSION)"
valid_version "$version" || die "'$version' is not a version: expected vX.Y.Z"

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
  # lib.sh is sourced, not run: it is not executable in the repository either.
  [ "$f" = lib.sh ] && mode=644
  cp "$f" "$stage/$f"
  chmod "$mode" "$stage/$f"
done
printf '%s\n' "$version" >"$stage/VERSION"
chmod 644 "$stage/VERSION"

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

ok "$out/$name ($(wc -c <"$out/$name" | tr -d ' ') bytes), get-cadence.sh, checksums.txt"
