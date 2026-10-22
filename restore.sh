#!/bin/sh
#
# Restores the database (and the blobs volume, when the backup has it) from
# a backup of backup.sh, then starts the stack and waits for it. EVERYTHING
# written after the backup is lost. The backup must be of the version in
# VERSION; for another one it prints how to put its package files in place.
#
#   ./restore.sh backups/cadence-v0.14.0-20261008-030000.sql.gz
#   ./restore.sh --yes backups/cadence-v0.14.0-20261008-030000.sql.gz   # no prompt
#
# A wrapper: it runs clab server restore of the clab in bin/
# of this package - bin/clab-<os>-<arch> of this machine - on this directory,
# with the arguments as given; a relative FILE is in this directory. The
# flags and the exit codes (0 done, 1 refused or failed, 2 a wrong argument)
# are those of clab server restore: ./restore.sh --help lists them;
# docs/admin.md, "Restore".
#
#   CADENCE_CLAB  the clab to run instead of the one in bin/ (a machine the
#                 package has no clab for); of the version in VERSION or newer
set -eu

dir="$(cd "$(dirname "$0")" && pwd)"
cd "$dir"
command=restore

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
