#!/bin/sh
#
# First installation of Cadence Lab on this machine: checks the environment,
# writes .env with generated secrets, starts the stack of the version in
# VERSION and prints the administrator token. It runs once: with .env here
# it stops and changes nothing.
#
#   ./install.sh                                  # asks questions
#   ./install.sh --mode tls --domain cadence.example.com --email ops@example.com
#   ./install.sh --mode proxy --http-addr 127.0.0.1:8080 --yes
#   ./install.sh --name cadence-stage --mode proxy --http-addr 127.0.0.1:8081
#   ./install.sh --external-db URL --external-db-ca FILE --yes
#   ./install.sh --mode proxy --team acme --with-starter --project ACME --yes
#
# A wrapper: it runs clab server install of the clab in bin/
# of this package - bin/clab-<os>-<arch> of this machine - on this directory,
# with the arguments as given. The flags, the variables (CADENCE_MODE,
# SDLC_DOMAIN, SDLC_ADMIN_TOKEN, CADENCE_VERIFY, ...) and the exit codes
# (0 done, 1 refused or failed, 2 a wrong argument) are those of clab server
# install: ./install.sh --help lists them; docs/admin.md, "Install".
#
#   CADENCE_CLAB  the clab to run instead of the one in bin/ (a machine the
#                 package has no clab for); of the version in VERSION or newer
set -eu

dir="$(cd "$(dirname "$0")" && pwd)"
cd "$dir"
command=install

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
