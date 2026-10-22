#!/bin/sh
#
# Backup of the database and the blobs volume into backups/, rotation of old
# backups, the copy to an S3 bucket (BACKUP_S3_*); verify checks that a
# backup restores, fetch downloads one from the bucket.
#
#   ./backup.sh [--no-upload]
#   ./backup.sh verify [--ignore-version] [FILE]
#   ./backup.sh fetch [NAME]
#
# For cron:
#
#   0 3 * * * /path/to/cadence/backup.sh >> /path/to/cadence/backups/backup.log 2>&1
#   0 5 * * 0 /path/to/cadence/backup.sh verify >> /path/to/cadence/backups/backup.log 2>&1
#
# A wrapper: it runs clab server backup of the clab in bin/
# of this package - bin/clab-<os>-<arch> of this machine - on this directory,
# with the arguments as given. The flags, the variables (BACKUP_DIR,
# KEEP_DAYS, BACKUP_S3_*, ...) and the exit codes (0 done, 1 refused or
# failed, 2 a wrong argument) are those of clab server backup:
# ./backup.sh --help lists them; docs/admin.md, "Backups".
#
#   CADENCE_CLAB  the clab to run instead of the one in bin/ (a machine the
#                 package has no clab for); of the version in VERSION or newer
set -eu

dir="$(cd "$(dirname "$0")" && pwd)"
cd "$dir"
command=backup

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
