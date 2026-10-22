#!/bin/sh
#
# Upgrades the whole stack to a new version: verifies the release, backs up,
# puts the package files of the new version in place (VERSION, compose,
# Caddyfile, scripts, clab in bin/, docs), pulls the new images, starts them
# and waits for readiness. If the new version does not become ready it
# prints the commands that return to the previous one and its backup.
#
#   ./upgrade.sh                  # the latest release
#   ./upgrade.sh v0.14.0          # a specific release
#   ./upgrade.sh --force v0.14.0  # also replace package files edited here
#
# A wrapper: it runs clab server upgrade of the clab in bin/
# of this package - bin/clab-<os>-<arch> of this machine - on this directory,
# with the arguments as given. The upgrade replaces that clab too, with the
# one of the new version. The flags, the variables (CADENCE_VERIFY,
# CADENCE_RELEASES_URL, CADENCE_READY_TIMEOUT, ...) and the exit codes (0
# done, 1 refused or failed, 2 a wrong argument) are those of clab server
# upgrade: ./upgrade.sh --help lists them; docs/admin.md, "Upgrades and
# rollback".
#
#   CADENCE_CLAB  the clab to run instead of the one in bin/ (a machine the
#                 package has no clab for); of the version in VERSION or newer
set -eu

dir="$(cd "$(dirname "$0")" && pwd)"
cd "$dir"
command=upgrade

case "$(uname -s)" in
Linux) os=linux ;;
Darwin) os=darwin ;;
*) os="$(uname -s | tr '[:upper:]' '[:lower:]')" ;;
esac
case "$(uname -m)" in
x86_64 | amd64) arch=amd64 ;;
aarch64 | arm64) arch=arm64 ;;
*) arch="$(uname -m)" ;;
esac
clab="${CADENCE_CLAB:-$dir/bin/clab-$os-$arch}"
if [ -n "${CADENCE_CLAB:-}" ]; then
  what="CADENCE_CLAB=$clab"
elif [ -f "$clab" ]; then
  what="bin/clab-$os-$arch"
else
  what=""
fi
if [ -z "$what" ] || ! err="$("$clab" server --help 2>&1 >/dev/null)"; then
  version="$(tr -d '[:space:]' <VERSION 2>/dev/null || true)"
  if [ -z "$what" ]; then
    printf '✗ this package has no clab for %s/%s: it carries bin/clab-<os>-<arch> for linux and darwin, amd64 and arm64.\n' "$os" "$arch" >&2
  else
    printf '✗ %s does not run on this machine (%s/%s): %s\n' "$what" "$os" "$arch" "${err:-no output}" >&2
  fi
  cat >&2 <<EOF
  Nothing was done. Install clab ${version:-of this version} for this machine from the tap and run it on this directory:
    curl -fsSL https://raw.githubusercontent.com/cadence-lab-tech/homebrew-tap/main/install.sh | CLAB_VERSION=${version:-vX.Y.Z} sh
    clab server $command --dir $dir [the same arguments]
  or let this script run it: CADENCE_CLAB=/path/to/clab $0 [the same arguments]
  (docs/admin.md, "clab in the package").
EOF
  exit 1
fi
CADENCE_WRAPPER=1
export CADENCE_WRAPPER
exec "$clab" server "$command" --dir "$dir" "$@"
