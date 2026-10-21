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
# The signature of the package (CADENCE_VERIFY, lib.sh "signatures"): a stub
# cosign (ci/verify-stubs.sh) is called with the bundle of the release before
# anything is unpacked; a bad signature, require without cosign, an unsigned
# version with require and a release without the bundle are refused before
# the directory exists; auto without cosign warns once and installs; off
# calls no cosign. The scenarios without these words run with no cosign in
# PATH, even on a machine that has one.
#
#   ci/check-get-cadence.sh
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=lib.sh
. ./lib.sh
# shellcheck source=ci/verify-stubs.sh
. ./ci/verify-stubs.sh

failures=0
pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  failures=$((failures + 1))
}
contains() { grep -qF -- "$2" <<<"$1"; }
lacks() { ! grep -qF -- "$2" <<<"$1"; }

shell="sh"
if command -v dash >/dev/null 2>&1; then shell=dash; fi

version="$(tr -d '[:space:]' <VERSION)"
older=v0.0.1
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# Releases: an older one and the current one, which is the latest.
releases="$work/releases"
ci/package.sh --version "$older" "$releases/download/$older" >/dev/null
ci/package.sh --bundle "$releases/download/$version" >/dev/null
mkdir -p "$releases/latest"
cp -R "$releases/download/$version" "$releases/latest/download"
# A release whose package does not match its checksums.txt.
broken=v0.0.2
ci/package.sh --version "$broken" "$releases/download/$broken" >/dev/null
printf 'x' >>"$releases/download/$broken/$(package_name "$broken")"
# A signed version whose release has lost its signature (a mirror without
# the bundle).
nobundle=v99.1.0
ci/package.sh --version "$nobundle" "$releases/download/$nobundle" >/dev/null

stubs="$work/bin"
mkdir -p "$stubs"
cat >"$stubs/docker" <<'SH'
#!/bin/sh
# docker for the check: the daemon answers, pulling images fails. The compose
# project STUB_TAKEN has a container of an installation in /srv/other;
# every other installation name is free.
case "$*" in
"compose version" | info*) exit 0 ;;
"ps -a -q --filter label=com.docker.compose.project=${STUB_TAKEN:-}") echo c0ffee; exit 0 ;;
"ps -a -q --filter "* | "volume ls -q --filter "*) exit 0 ;;
"inspect -f "*" c0ffee") echo /srv/other; exit 0 ;;
*" config --images") exec "$(dirname "$0")/compose-images" "$@" ;;
*) echo "docker stub: $*" >&2; exit 1 ;;
esac
SH
stub_compose_images "$stubs/compose-images"
stub_curl "$stubs"
cosign_dir="$work/cosign"
stub_cosign "$cosign_dir" "$work/cosign.log"
# No cosign of this machine: the scenarios choose.
nocosign_path="$(path_without_cosign)"

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
  (cd "$dir" && PATH="$stubs:${COSIGN_PATH:+$COSIGN_PATH:}$nocosign_path" CADENCE_RELEASES_URL="file://$releases" \
    "$shell" -s -- "$@" <"$OLDPWD/get-cadence.sh" 2>&1)
}
# The installation name comes from --name or COMPOSE_PROJECT_NAME; the
# checks set the variable themselves, the caller's does not leak in.
unset COMPOSE_PROJECT_NAME CADENCE_VERIFY CADENCE_VERIFY_NOTED COSIGN_PATH

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
if grep -qxF 'COMPOSE_PROJECT_NAME=cadence' "$env_file" 2>/dev/null; then
  pass "without --name the installation name in .env is cadence"
else
  fail "without --name .env has no COMPOSE_PROJECT_NAME=cadence"
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
mkdir -p "$work/env"
if ! out="$(cd "$work/env" && PATH="$stubs:$nocosign_path" CADENCE_RELEASES_URL="file://$releases" \
  CADENCE_INSTALL_VERSION="$older" CADENCE_INSTALL_DIR=viaenv "$shell" -s -- --mode proxy --http-addr 127.0.0.1:1 --yes \
  <"$OLDPWD/get-cadence.sh" 2>&1)"; then
  : # install.sh stops at the image pull; what matters is what was unpacked
fi
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

info "installation name"
# name_written DIR NAME: install.sh of DIR/cadence wrote COMPOSE_PROJECT_NAME=NAME.
name_written() { grep -qxF "COMPOSE_PROJECT_NAME=$2" "$1/cadence/.env" 2>/dev/null; }
out="$(get "$work/named" --name cadence-stage --mode proxy --http-addr 127.0.0.1:1 --yes || true)"
if name_written "$work/named" cadence-stage; then
  pass "--name cadence-stage reaches install.sh and lands in .env"
else
  fail "--name cadence-stage did not land in .env: $out"
fi
out="$(COMPOSE_PROJECT_NAME=cadence-env get "$work/env-name" --mode proxy --http-addr 127.0.0.1:1 --yes || true)"
if name_written "$work/env-name" cadence-env; then
  pass "COMPOSE_PROJECT_NAME=cadence-env without --name lands in .env"
else
  fail "COMPOSE_PROJECT_NAME without --name did not land in .env: $out"
fi
out="$(COMPOSE_PROJECT_NAME=cadence-env get "$work/env-same" --name cadence-env --mode proxy --http-addr 127.0.0.1:1 --yes || true)"
if name_written "$work/env-same" cadence-env; then
  pass "--name and COMPOSE_PROJECT_NAME with the same name are fine"
else
  fail "--name and COMPOSE_PROJECT_NAME with the same name: $out"
fi
# refused DIR TEXT ARGS...: the installer fails, says TEXT and writes no .env.
refused() {
  local dir="$1" text="$2" out status
  shift 2
  out="$(get "$dir" "$@")" && status=0 || status=$?
  if [ "$status" != 0 ] && contains "$out" "$text" && [ ! -e "$dir/cadence/.env" ]; then
    pass "$* is refused (\"$text\"), no .env"
  else
    fail "$*: status $status, no \"$text\" or .env written: $out"
  fi
}
refused "$work/bad-name" "'Bad_Name' is not a valid installation name" --name Bad_Name --mode proxy --http-addr 127.0.0.1:1 --yes
refused "$work/dash-name" "'-x' is not a valid installation name" --name -x --mode proxy --http-addr 127.0.0.1:1 --yes
export COMPOSE_PROJECT_NAME=cadence-env
refused "$work/two-names" "--name is 'cadence-stage', but COMPOSE_PROJECT_NAME in the environment is 'cadence-env'" \
  --name cadence-stage --mode proxy --http-addr 127.0.0.1:1 --yes
unset COMPOSE_PROJECT_NAME
export STUB_TAKEN=cadence
refused "$work/taken" "the installation name 'cadence' is taken on this machine: the installation in /srv/other uses it" \
  --mode proxy --http-addr 127.0.0.1:1 --yes
out="$(get "$work/taken-hint" --mode proxy --http-addr 127.0.0.1:1 --yes || true)"
if contains "$out" "--name cadence-2"; then
  pass "the refusal of a taken name suggests --name"
else
  fail "the refusal of a taken name does not suggest --name: $out"
fi
out="$(get "$work/not-taken" --name cadence-stage --mode proxy --http-addr 127.0.0.1:1 --yes || true)"
if name_written "$work/not-taken" cadence-stage; then
  pass "another name next to the taken one installs"
else
  fail "--name cadence-stage next to a taken cadence: $out"
fi
unset STUB_TAKEN

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

info "the signature of the package"
pkg_identity="$VERIFY_PACKAGE_IDENTITY"
# signed DIR ARGS...: get with the stub cosign in PATH; $out, $status and
# $cosign_log.
signed() {
  local d="$1"
  shift
  : >"$work/cosign.log"
  out="$(COSIGN_PATH="$cosign_dir" FAKE_WATCH="$d/cadence" get "$d" "$@")" && status=0 || status=$?
  cosign_log="$(cat "$work/cosign.log")"
}
nodir() { [ ! -e "$1/cadence" ]; }
proxy_args=(--mode proxy --http-addr 127.0.0.1:1 --yes)

signed "$work/sig-ok" "${proxy_args[@]}"
if contains "$cosign_log" "[verify-blob] [--bundle] [" && contains "$cosign_log" "/$VERIFY_BUNDLE] [--certificate-identity] [$pkg_identity] [--certificate-oidc-issuer] [$VERIFY_ISSUER] [" &&
  contains "$cosign_log" "/checksums.txt] [absent]"; then
  pass "cosign verify-blob --bundle $VERIFY_BUNDLE --certificate-identity $pkg_identity --certificate-oidc-issuer $VERIFY_ISSUER checksums.txt, before ./cadence exists"
else
  fail "cosign verify-blob with the bundle and the identity of self-hosted on main was not called before unpacking: $cosign_log"
fi
if contains "$out" "✓ the signature of checksums.txt of $version verified: signed by $pkg_identity" &&
  contains "$out" "could not pull the images of $version"; then
  pass "a verified package installs: install.sh reached the pull"
else
  fail "a verified package did not install: $out"
fi
if contains "$cosign_log" "[verify] [--certificate-identity] [$(verify_identity sdlc-pipeline-backend "$version")]"; then
  pass "install.sh of the package verified the images"
else
  fail "install.sh of the package did not verify the images: $cosign_log"
fi

for mode in auto require; do
  out="$(CADENCE_VERIFY="$mode" COSIGN_PATH="$cosign_dir" FAKE_COSIGN_BAD=package get "$work/sig-bad-$mode" --dir there "${proxy_args[@]}")" && status=0 || status=$?
  if [ "$status" != 0 ] && contains "$out" "the signature of checksums.txt of $version did not verify for $pkg_identity" &&
    contains "$out" "Nothing was installed." && [ ! -e "$work/sig-bad-$mode/there" ]; then
    pass "$mode: checksums.txt signed by another identity is refused, naming checksums.txt, $version and the identity; --dir there not created"
  else
    fail "$mode: a bad signature of the package: status $status, $out"
  fi
done

out="$(CADENCE_VERIFY=require get "$work/sig-none-require" "${proxy_args[@]}")" && status=0 || status=$?
if [ "$status" != 0 ] && contains "$out" "CADENCE_VERIFY=require, but cosign 3.x is not installed" && nodir "$work/sig-none-require"; then
  pass "require without cosign: refused before the directory"
else
  fail "require without cosign: status $status, $out"
fi
out="$(get "$work/sig-none-auto" "${proxy_args[@]}" || true)"
if [ "$(grep -c '^! .*cosign' <<<"$out")" = 1 ] && contains "$out" "! cosign 3.x is not installed: the signatures of the release are not verified (CADENCE_VERIFY=auto)" &&
  contains "$out" "could not pull the images of $version"; then
  pass "auto without cosign: one warning, for the installer and install.sh together, and the installation goes on"
else
  fail "auto without cosign: $out"
fi
: >"$work/cosign.log"
out="$(CADENCE_VERIFY=off COSIGN_PATH="$cosign_dir" get "$work/sig-off" "${proxy_args[@]}" || true)"
if [ ! -s "$work/cosign.log" ] && [ "$(grep -c '^▸ signature verification is off (CADENCE_VERIFY=off)$' <<<"$out")" = 1 ] &&
  lacks "$out" "! " && contains "$out" "could not pull the images of $version"; then
  pass "off: no cosign call, one line '▸ signature verification is off', no warning, installed"
else
  fail "off: $(cat "$work/cosign.log") $out"
fi
out="$(CADENCE_VERIFY=yes get "$work/sig-yes" "${proxy_args[@]}")" && status=0 || status=$?
if [ "$status" != 0 ] && contains "$out" "CADENCE_VERIFY is 'yes', expected auto, require or off" && nodir "$work/sig-yes"; then
  pass "CADENCE_VERIFY=yes is refused with auto, require and off"
else
  fail "CADENCE_VERIFY=yes: status $status, $out"
fi

signed "$work/sig-old" --version "$older" "${proxy_args[@]}" || true
if contains "$out" "! $older is not signed (signatures start with $VERIFY_FIRST_SIGNED)" && lacks "$cosign_log" "[verify" &&
  [ "$(tr -d '[:space:]' <"$work/sig-old/cadence/VERSION" 2>/dev/null)" = "$older" ]; then
  pass "auto, $older: '! $older is not signed', nothing verified, installed"
else
  fail "auto, $older: $out"
fi
out="$(CADENCE_VERIFY=require COSIGN_PATH="$cosign_dir" get "$work/sig-old-require" --version "$older" "${proxy_args[@]}")" && status=0 || status=$?
if [ "$status" != 0 ] && contains "$out" "$older is not signed (signatures start with $VERIFY_FIRST_SIGNED), and CADENCE_VERIFY=require refuses it" &&
  nodir "$work/sig-old-require"; then
  pass "require, $older: refused before the directory"
else
  fail "require, $older: status $status, $out"
fi

for mode in auto require; do
  out="$(CADENCE_VERIFY="$mode" COSIGN_PATH="$cosign_dir" get "$work/sig-nobundle-$mode" --version "$nobundle" "${proxy_args[@]}")" && status=0 || status=$?
  if [ "$status" != 0 ] && contains "$out" "the release $nobundle has no $VERIFY_BUNDLE at file://$releases" &&
    contains "$out" "Copy $VERIFY_BUNDLE of the release to the mirror, or set CADENCE_VERIFY=off. Nothing was installed." &&
    nodir "$work/sig-nobundle-$mode"; then
    pass "$mode with cosign: a release of $nobundle without $VERIFY_BUNDLE is refused before the directory"
  else
    fail "$mode, no bundle: status $status, $out"
  fi
done

if [ -s "$work/git-calls" ]; then
  fail "git was called: $(tr '\n' ';' <"$work/git-calls")"
else
  pass "git was never called"
fi

[ "$failures" -eq 0 ] || die "$failures check(s) failed"
ok "one-line installer checks passed"
