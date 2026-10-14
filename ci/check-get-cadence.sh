#!/usr/bin/env bash
#
# Checks of the one-line installer that need neither Docker nor published
# images: get-cadence.sh runs the way the documentation shows it - piped
# into sh (dash where there is one, the sh of Debian and Ubuntu) - against
# releases built by ci/package.sh in a scratch directory. A stub stands in
# for docker: install.sh of the package gets as far as writing .env and stops
# at pulling the images. Another stub stands in for git and records any call:
# the installer must not need it. CI runs it next to ci/check-config.sh.
#
#   ci/check-get-cadence.sh
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=lib.sh
. ./lib.sh

failures=0
pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  failures=$((failures + 1))
}
contains() { grep -qF -- "$2" <<<"$1"; }

shell="sh"
if command -v dash >/dev/null 2>&1; then shell=dash; fi

version="$(tr -d '[:space:]' <VERSION)"
older=v0.0.1
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Releases: an older one and the current one, which is the latest.
releases="$work/releases"
ci/package.sh --version "$older" "$releases/download/$older" >/dev/null
ci/package.sh "$releases/download/$version" >/dev/null
mkdir -p "$releases/latest"
cp -R "$releases/download/$version" "$releases/latest/download"
# A release whose package does not match its checksums.txt.
broken=v0.0.2
ci/package.sh --version "$broken" "$releases/download/$broken" >/dev/null
printf 'x' >>"$releases/download/$broken/$(package_name "$broken")"

stubs="$work/bin"
mkdir -p "$stubs"
cat >"$stubs/docker" <<'SH'
#!/bin/sh
# docker for the check: the daemon answers, pulling images fails.
case "$*" in
"compose version" | info*) exit 0 ;;
*) echo "docker stub: $*" >&2; exit 1 ;;
esac
SH
cat >"$stubs/git" <<SH
#!/bin/sh
echo "git \$*" >>"$work/git-calls"
exit 1
SH
chmod 755 "$stubs/docker" "$stubs/git"

# get DIR ARGS...: the one-line installer, piped into the shell, from DIR.
# Prints its output; the exit status is the installer's.
get() {
  local dir="$1"
  shift
  mkdir -p "$dir"
  (cd "$dir" && PATH="$stubs:$PATH" CADENCE_RELEASES_URL="file://$releases" \
    "$shell" -s -- "$@" <"$OLDPWD/get-cadence.sh" 2>&1)
}

info "get-cadence.sh under $shell"

out="$(get "$work/latest" --mode proxy --http-addr 127.0.0.1:1 --yes || true)"
if [ "$(tr -d '[:space:]' <"$work/latest/cadence/VERSION" 2>/dev/null)" = "$version" ]; then
  pass "without --version it installs the latest release ($version) into ./cadence"
else
  fail "without --version it did not unpack $version into ./cadence: $out"
fi
if contains "$out" "could not pull the images of $version"; then
  pass "it runs install.sh of the package with the flags (install.sh reached the image pull)"
else
  fail "install.sh of the package did not run up to the image pull: $out"
fi
env_file="$work/latest/cadence/.env"
if grep -qxF 'CADENCE_MODE=proxy' "$env_file" 2>/dev/null &&
  grep -qxF 'CADENCE_HTTP_ADDR=127.0.0.1:1' "$env_file" &&
  grep -qxF 'COMPOSE_FILE=docker-compose.yml:compose.proxy.yml:compose.override.yml' "$env_file"; then
  pass "install.sh wrote .env from the flags, COMPOSE_FILE with compose.override.yml"
else
  fail "install.sh did not write the expected .env"
fi
if [ -f "$work/latest/cadence/compose.override.yml" ]; then
  pass "install.sh created compose.override.yml"
else
  fail "install.sh did not create compose.override.yml"
fi
mode="$(stat -c %a "$work/latest/cadence/install.sh" 2>/dev/null || stat -f %Lp "$work/latest/cadence/install.sh")"
if [ "$mode" = 755 ]; then pass "the unpacked install.sh is executable"; else fail "the unpacked install.sh is $mode"; fi

out="$(get "$work/flag" --version "$older" --dir there --mode proxy --http-addr 127.0.0.1:1 --yes || true)"
if [ "$(tr -d '[:space:]' <"$work/flag/there/VERSION" 2>/dev/null)" = "$older" ]; then
  pass "--version $older --dir there installs $older into ./there"
else
  fail "--version $older --dir there: $out"
fi
out="$(mkdir -p "$work/env" && cd "$work/env" && PATH="$stubs:$PATH" CADENCE_RELEASES_URL="file://$releases" \
  CADENCE_INSTALL_VERSION="$older" CADENCE_INSTALL_DIR=viaenv "$shell" -s -- --mode proxy --http-addr 127.0.0.1:1 --yes \
  <"$OLDPWD/get-cadence.sh" 2>&1 || true)"
if [ "$(tr -d '[:space:]' <"$work/env/viaenv/VERSION" 2>/dev/null)" = "$older" ]; then
  pass "CADENCE_INSTALL_VERSION and CADENCE_INSTALL_DIR do the same"
else
  fail "CADENCE_INSTALL_VERSION/CADENCE_INSTALL_DIR: $out"
fi

# tls mode from --domain alone, with no terminal: no questions, the e-mail
# defaults to admin@<domain>. It needs ports 80 and 443 free.
if (exec 3<>/dev/tcp/127.0.0.1/80) 2>/dev/null || (exec 3<>/dev/tcp/127.0.0.1/443) 2>/dev/null; then
  warn "ports 80 or 443 are busy on this machine: the --domain check is skipped"
else
  out="$(get "$work/domain" --domain cadence.example.com || true)"
  env_file="$work/domain/cadence/.env"
  if grep -qxF 'CADENCE_MODE=tls' "$env_file" 2>/dev/null &&
    grep -qxF 'SDLC_DOMAIN=cadence.example.com' "$env_file" &&
    grep -qxF 'ACME_EMAIL=admin@cadence.example.com' "$env_file" &&
    grep -qxF 'COMPOSE_FILE=docker-compose.yml:compose.tls.yml:compose.override.yml' "$env_file"; then
    pass "--domain alone without a terminal writes .env for tls with ACME_EMAIL=admin@<domain>"
  else
    fail "--domain alone did not write the tls .env: $out"
  fi
fi

info "refusals"
out="$(get "$work/broken" --version "$broken" --yes)" && status=0 || status=$?
if [ "$status" != 0 ] && contains "$out" "checksum" && [ ! -e "$work/broken/cadence" ]; then
  pass "a package that does not match checksums.txt: refused, nothing unpacked"
else
  fail "a broken package: status $status, $out"
fi
out="$(get "$work/missing" --version v9.9.9 --yes)" && status=0 || status=$?
if [ "$status" != 0 ] && contains "$out" "there is no release v9.9.9" && [ ! -e "$work/missing/cadence" ]; then
  pass "a version without a release: refused with \"there is no release v9.9.9\""
else
  fail "a missing version: status $status, $out"
fi
out="$(get "$work/bad" --version 1.2 --yes)" && status=0 || status=$?
if [ "$status" != 0 ] && contains "$out" "is not a version"; then
  pass "a version that is not vX.Y.Z is refused"
else
  fail "a malformed version: status $status, $out"
fi
mkdir -p "$work/installed/cadence"
printf 'POSTGRES_PASSWORD=keep\n' >"$work/installed/cadence/.env"
before="$(sha256_of "$work/installed/cadence/.env")"
out="$(get "$work/installed" --yes)" && status=0 || status=$?
if [ "$status" != 0 ] && contains "$out" "./upgrade.sh" && [ "$before" = "$(sha256_of "$work/installed/cadence/.env")" ]; then
  pass "a directory with .env: refused with a hint to ./upgrade.sh, .env untouched"
else
  fail "an installed directory: status $status, $out"
fi
mkdir -p "$work/busy/cadence"
printf 'mine\n' >"$work/busy/cadence/notes.txt"
out="$(get "$work/busy" --yes)" && status=0 || status=$?
if [ "$status" != 0 ] && contains "$out" "is not empty" && [ ! -e "$work/busy/cadence/VERSION" ]; then
  pass "a directory that is not empty: refused, nothing unpacked"
else
  fail "a non-empty directory: status $status, $out"
fi

if [ -s "$work/git-calls" ]; then
  fail "git was called: $(tr '\n' ';' <"$work/git-calls")"
else
  pass "git was never called"
fi

[ "$failures" -eq 0 ] || die "$failures check(s) failed"
ok "one-line installer checks passed"
