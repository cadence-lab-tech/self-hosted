#!/usr/bin/env bash
#
# Static checks of the package that need no published images: the compose
# configuration in both modes, the Caddyfile in both modes, the defaults of
# .env.example, the file layout and the release package that ci/package.sh
# builds. CI runs it on every pull request next to the shell linter; it needs
# Docker and jq.
#
#   ci/check-config.sh
#
#   CLAB_BIN  clab whose "clab server ... --help" the documented clab server
#             flags are checked against; default: the CLI of VERSION from the
#             public tap, once VERSION has clab server (v0.7.0). Without
#             CLAB_BIN a documented command that the clab of VERSION does not
#             have yet (documented ahead of the release that brings it) is
#             skipped with a note; with CLAB_BIN it fails. An unknown flag of
#             an existing command fails either way.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=lib.sh
. ./lib.sh
# shellcheck source=ci/pins.sh
. ./ci/pins.sh

failures=0
pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  failures=$((failures + 1))
}
check() {
  local what="$1"
  shift
  if "$@" >/dev/null 2>&1; then pass "$what"; else fail "$what"; fi
}
contains() { grep -qF -- "$2" <<<"$1"; }
lacks() { ! grep -qF -- "$2" <<<"$1"; }

version="$(tr -d '[:space:]' <VERSION)"

info "layout"
for f in docker-compose.yml compose.tls.yml compose.proxy.yml .env.example Caddyfile README.md docs/admin.md LICENSE SECURITY.md VERSION; do
  check "$f exists" [ -f "$f" ]
done
for f in install.sh upgrade.sh backup.sh restore.sh get-cadence.sh ci/package.sh; do
  check "$f is executable" [ -x "$f" ]
done
check "VERSION is vX.Y.Z" valid_version "$version"
check "LICENSE is FSL-1.1-ALv2" grep -q '^FSL-1.1-ALv2$' LICENSE
for p in .env backups/ secrets/ compose.override.yml; do
  check ".gitignore has $p" grep -qxF "$p" .gitignore
done
check "get-cadence.sh is a POSIX sh script" [ "$(head -n 1 get-cadence.sh)" = "#!/bin/sh" ]

info "release package"
# What ci/package.sh builds for a release: the files an installation needs
# and nothing of the repository around them. The required list is kept here,
# apart from the list in ci/package.sh, so that a file dropped from the
# package turns this check red.
required_files="VERSION docker-compose.yml compose.tls.yml compose.proxy.yml Caddyfile .env.example
  install.sh upgrade.sh backup.sh restore.sh lib.sh bundles/starter.json docs/admin.md README.md LICENSE SECURITY.md
  package.sha256"
dist="$(mktemp -d)"
trap 'rm -rf "$dist"' EXIT
package="$(package_name "$version")"
check "ci/package.sh builds the assets" ci/package.sh "$dist/out"
check "the assets are $package, checksums.txt and get-cadence.sh" \
  [ "$(find "$dist/out" -type f -exec basename {} \; 2>/dev/null | sort | tr '\n' ' ')" = "$(printf '%s\n' "$package" checksums.txt get-cadence.sh | sort | tr '\n' ' ')" ]
verify_checksums() {
  local sum file
  while read -r sum file; do
    [ "$(sha256_of "$dist/out/$file")" = "$sum" ] || return 1
  done <"$dist/out/checksums.txt"
  [ "$(grep -c . "$dist/out/checksums.txt")" = 2 ]
}
check "checksums.txt matches both assets" verify_checksums
listing="$(tar -tzf "$dist/out/$package" 2>/dev/null | sed 's:^\./::' || true)"
for f in $required_files; do
  check "the package has $f" grep -qxF -- "$f" <<<"$listing"
done
# no_entry PATH: the package has neither the file PATH nor anything under it.
no_entry() {
  local p="${1%/}" e
  while IFS= read -r e; do
    case "$e" in "$p" | "$p"/*) return 1 ;; esac
  done <<<"$listing"
}
for p in ci/ .github/ .git .gitignore .env backups/ secrets/ compose.override.yml docker-compose.override.yml get-cadence.sh; do
  check "the package has no $p" no_entry "$p"
done
# only_known: every entry is a required file or lies under bundles/ or docs/ -
# a file added to the list of ci/package.sh goes into the list above too.
only_known() {
  local e known
  known="$(tr -s ' ' '\n' <<<"$required_files")"
  while IFS= read -r e; do
    case "$e" in bundles/* | docs/*) continue ;; esac
    grep -qxF -- "$e" <<<"$known" || return 1
  done <<<"$listing"
}
check "the package has nothing but the required files, bundles/ and docs/" only_known
check "the package has no ._ metadata files of macOS" [ -z "$(grep -E '(^|/)\._' <<<"$listing" || true)" ]
check "the package has no top directory" [ -z "$(grep -E '^[^/]+/$' <<<"$listing" || true)" ]
mkdir -p "$dist/unpacked"
(umask 077 && tar -xpzf "$dist/out/$package" -C "$dist/unpacked")
check "VERSION in the package is $version" [ "$(tr -d '[:space:]' <"$dist/unpacked/VERSION")" = "$version" ]
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
for f in install.sh upgrade.sh backup.sh restore.sh; do
  check "$f unpacks executable (755)" [ "$(mode_of "$dist/unpacked/$f")" = 755 ]
done
check "lib.sh and the other files unpack as 644 under umask 077" \
  [ "$(mode_of "$dist/unpacked/lib.sh") $(mode_of "$dist/unpacked/docker-compose.yml")" = "644 644" ]
verify_manifest() {
  local sum file listed
  listed="$(awk '{print $2}' "$dist/unpacked/package.sha256" | sort)"
  # Every file of the package but the manifest itself, with its sum.
  [ "$listed" = "$(grep -vxF package.sha256 <<<"$listing" | sort)" ] || return 1
  while read -r sum file; do
    [ "$(sha256_of "$dist/unpacked/$file")" = "$sum" ] || return 1
  done <"$dist/unpacked/package.sha256"
}
check "package.sha256 lists every file of the package with its sha256" verify_manifest
check "ci/package.sh --version sets VERSION in the package" ci/package.sh --version v99.0.0 "$dist/other"
check "...and names the package by it" [ -f "$dist/other/$(package_name v99.0.0)" ]

info "rollback hint"
# package_files_hint is what upgrade.sh and restore.sh print when they refuse
# another version. Its branches, run in scratch directories: a kept package
# copy, the release package (since v0.6.0), and for older versions git in a
# clone or else the source archive of the tag.
#
# hint_in DIR VERSION [NAME=VALUE...] prints the hint for VERSION in DIR with
# the given environment.
hint_in() {
  local in="$1" v="$2"
  shift 2
  (
    cd "$in" && unset BACKUP_DIR CADENCE_RELEASES_URL CADENCE_GIT_REMOTE
    # shellcheck disable=SC2163 # NAME=VALUE pairs, not names
    [ $# -eq 0 ] || export "$@"
    package_files_hint "$v"
  )
}
hint_dir() {
  local d
  d="$(mktemp -d "$dist/hint.XXXXXX")"
  mkdir "$d/backups"
  printf '%s\n' "$d"
}
releases="$CADENCE_RELEASES_DEFAULT"
archive_of() { printf 'curl -fsSL https://github.com/cadence-lab-tech/self-hosted/archive/refs/tags/%s.tar.gz | tar -xpzf - --strip-components=1' "$1"; }
checkout_of() { printf 'git -c advice.detachedHead=false checkout --force %s' "$1"; }
git_q() { git -c user.name=check -c user.email=check@localhost -c init.defaultBranch=main "$@" >/dev/null 2>&1; }

d="$(hint_dir)"
touch "$d/backups/package-v0.6.0-20261001-000000.tar.gz" "$d/backups/package-v0.6.0-20261008-030000.tar.gz" \
  "$d/backups/package-v0.5.3-20261008-030000.tar.gz"
check "[kept copy] v0.6.0: tar of the latest copy in backups/" \
  [ "$(hint_in "$d" v0.6.0)" = "tar -xpzf backups/package-v0.6.0-20261008-030000.tar.gz" ]
out="$(hint_in "$d" v0.5.3)"
check "[kept copy] v0.5.3: tar of the copy, before any other way" [ "$out" = "tar -xpzf backups/package-v0.5.3-20261008-030000.tar.gz" ]
check "[kept copy] v0.5.3: no releases/download" lacks "$out" "releases/download"

d="$(hint_dir)"
check "[release] v0.6.0 without a copy: the package of its release" \
  [ "$(hint_in "$d" v0.6.0)" = "curl -fsSLO $releases/download/v0.6.0/cadence-self-hosted-v0.6.0.tar.gz && tar -xpzf cadence-self-hosted-v0.6.0.tar.gz && rm cadence-self-hosted-v0.6.0.tar.gz" ]
check "[release] ...from the mirror when CADENCE_RELEASES_URL is set" \
  contains "$(hint_in "$d" v0.6.0 CADENCE_RELEASES_URL=file:///srv/mirror/)" "curl -fsSLO file:///srv/mirror/download/v0.6.0/"
git_q -C "$d" init && git_q -C "$d" commit --allow-empty -m init && git_q -C "$d" tag v0.6.0
check "[release] v0.6.0 in a git clone: still the package, not git" \
  contains "$(hint_in "$d" v0.6.0)" "curl -fsSLO $releases/download/v0.6.0/"

d="$(hint_dir)"
git_q -C "$d" init && git_q -C "$d" commit --allow-empty -m init && git_q -C "$d" tag v0.5.3
check "[git clone, tag here] v0.5.3: git checkout of the tag" [ "$(hint_in "$d" v0.5.3)" = "$(checkout_of v0.5.3)" ]

d="$(hint_dir)"
git_q -C "$d" init && git_q -C "$d" commit --allow-empty -m init
check "[git clone, no tag] v0.5.3: fetch the tags from origin, then checkout" \
  [ "$(hint_in "$d" v0.5.3)" = "git fetch --tags origin && $(checkout_of v0.5.3)" ]
check "[git clone, no tag] ...from CADENCE_GIT_REMOTE when set" \
  [ "$(hint_in "$d" v0.5.3 CADENCE_GIT_REMOTE=upstream)" = "git fetch --tags upstream && $(checkout_of v0.5.3)" ]

d="$(hint_dir)"
out="$(hint_in "$d" v0.5.3)"
check "[no git clone] v0.5.3: the source archive of the tag" [ "$out" = "$(archive_of v0.5.3)" ]
check "[no git clone] v0.5.3: no releases/download" lacks "$out" "releases/download/v0.5.3"
check "[no git clone] ...from GitHub even when CADENCE_RELEASES_URL is set" \
  [ "$(hint_in "$d" v0.5.3 CADENCE_RELEASES_URL=file:///srv/mirror)" = "$(archive_of v0.5.3)" ]
# .git without git on PATH: only the tools the function needs besides git.
nogit="$dist/nogit-bin"
mkdir -p "$nogit"
for tool in find sort tail head; do ln -sf "$(command -v "$tool")" "$nogit/$tool"; done
git_q -C "$d" init && git_q -C "$d" commit --allow-empty -m init && git_q -C "$d" tag v0.5.3
check "[.git, no git on PATH] v0.5.3: the source archive of the tag" \
  [ "$(hint_in "$d" v0.5.3 PATH="$nogit")" = "$(archive_of v0.5.3)" ]
# docs/admin.md shows these commands as the function prints them.
for cmd in "$(archive_of v0.5.3)" "$(checkout_of v0.5.3)" "git fetch --tags origin && $(checkout_of v0.5.3)"; do
  check "docs/admin.md shows: $cmd" grep -qF -- "$cmd" docs/admin.md
done

info "documented flags"
# The flags install.sh takes are the labels of the case in its argument loop
# ("--mode) ...", "-y | --yes | --non-interactive) ..."), not its usage
# comment: that comment is documentation too and drifts the same way.
install_flags="$(sed -n '/^while \[ \$# -gt 0 \]; do$/,/^done$/p' install.sh |
  sed -n 's/^ *\(-[^)]*\)).*/\1/p' | grep -oE -- '-{1,2}[a-z][a-z-]*' | sort -u || true)"
if [ -n "$install_flags" ]; then
  pass "install.sh takes $(tr '\n' ' ' <<<"$install_flags")"
else
  fail "install.sh: no flags found in its argument loop"
fi
# Every ./install.sh command of the documentation, on a line of a code block
# or inline up to the closing backtick, uses only those flags.
documented=0
for f in README.md docs/admin.md; do
  while IFS=: read -r line command; do
    for flag in $(grep -oE -- ' -{1,2}[a-z][a-z-]*' <<<"$command" | tr -d ' ' || true); do
      documented=$((documented + 1))
      if grep -qxF -- "$flag" <<<"$install_flags"; then
        pass "$f:$line: install.sh takes $flag"
      else
        fail "$f:$line: install.sh has no flag $flag"
      fi
    done
  done < <(grep -noE -- '\./install\.sh[^`]*' "$f" || true)
done
check "the documentation shows install.sh with flags" [ "$documented" -gt 0 ]

# The one-line installer: every flag after "sh -s --" in the documentation is
# a flag of get-cadence.sh itself or one it hands to install.sh.
# shellcheck disable=SC2016 # $n is the text of the loop, not a variable here
get_flags="$(sed -n '/^  while \[ "\$n" -gt 0 \]; do$/,/^  done$/p' get-cadence.sh |
  sed -n 's/^ *\(-[^)]*\)).*/\1/p' | grep -oE -- '-{1,2}[a-z][a-z-]*' | sort -u || true)"
if [ -n "$get_flags" ]; then
  pass "get-cadence.sh takes $(tr '\n' ' ' <<<"$get_flags")"
else
  fail "get-cadence.sh: no flags found in its argument loop"
fi
documented=0
for f in README.md docs/admin.md; do
  while IFS=: read -r line command; do
    for flag in $(grep -oE -- ' -{1,2}[a-z][a-z-]*' <<<"${command#sh -s --}" | tr -d ' ' || true); do
      documented=$((documented + 1))
      if grep -qxF -- "$flag" <<<"$get_flags"$'\n'"$install_flags"; then
        pass "$f:$line: the one-line installer takes $flag"
      else
        fail "$f:$line: neither get-cadence.sh nor install.sh has the flag $flag"
      fi
    done
  done < <(grep -noE -- 'get-cadence\.sh \| sh -s --[^`]*' "$f" | sed 's/get-cadence\.sh | //' || true)
done
check "the documentation shows the one-line installer with flags" [ "$documented" -gt 0 ]

# clab server: every "clab server <command> ..." of the documentation uses
# only flags that "clab server <command> --help" lists. The clab is CLAB_BIN,
# else the CLI of VERSION from the public tap once VERSION is a release that
# has clab server (v0.7.0); before that the check is skipped. A command the
# tap's clab of VERSION does not list yet is documented ahead of its release
# (CLAB-160): skipped with a note until VERSION catches up, checked with
# CLAB_BIN of the branch that brings it.
info "documented clab server flags"
clab_server="${CLAB_BIN:-}"
if [ -z "$clab_server" ] && ! version_lt "$version" v0.7.0; then
  clab_dir="$dist/clab-tap"
  if curl -fsSL https://raw.githubusercontent.com/cadence-lab-tech/homebrew-tap/main/install.sh |
    CLAB_VERSION="$version" CLAB_INSTALL_DIR="$clab_dir" sh >/dev/null 2>&1; then
    clab_server="$clab_dir/clab"
  else
    fail "could not install clab $version from the tap to check the documented clab server flags"
  fi
fi
if [ -z "$clab_server" ]; then
  info "skipped: clab $version has no clab server; CLAB_BIN=<clab with clab server> checks it"
else
  documented=0
  server_help="$("$clab_server" server --help 2>/dev/null || true)"
  for f in README.md docs/admin.md; do
    while IFS=: read -r line command; do
      sub="$(awk '{print $3}' <<<"$command")"
      if ! sub_help="$("$clab_server" server "$sub" --help 2>/dev/null)"; then
        if [ -z "${CLAB_BIN:-}" ] && ! grep -qE "^  $sub " <<<"$server_help"; then
          info "skipped $f:$line: clab $version has no 'clab server $sub'; CLAB_BIN=<clab with it> checks it"
        else
          fail "$f:$line: clab server has no command '$sub'"
        fi
        continue
      fi
      sub_flags="$(grep -oE -- '(^|[ ,])-{1,2}[a-z][a-z-]*' <<<"$sub_help" | grep -oE -- '-{1,2}[a-z][a-z-]*' | sort -u)"
      for flag in $(grep -oE -- ' -{1,2}[a-z][a-z-]*' <<<"$command" | tr -d ' ' || true); do
        documented=$((documented + 1))
        if grep -qxF -- "$flag" <<<"$sub_flags"; then
          pass "$f:$line: clab server $sub takes $flag"
        else
          fail "$f:$line: clab server $sub has no flag $flag"
        fi
      done
    done < <(grep -noE -- 'clab server [a-z]+[^`#]*' "$f" || true)
  done
  check "the documentation shows clab server with flags" [ "$documented" -gt 0 ]
fi

info "verifying a release (docs)"
# The signature asset and the identities of the signers, as release.yml of
# this repository, of the backend and of the frontend sign (ci/pins.sh).
admin="$(cat docs/admin.md)"
check "docs/admin.md names the asset checksums.txt.sigstore.json" contains "$admin" "checksums.txt.sigstore.json"
check "docs/admin.md names the signer of the package" contains "$admin" "https://github.com/cadence-lab-tech/self-hosted/.github/workflows/release.yml@refs/heads/main"
for image in $PIN_IMAGES; do
  check "docs/admin.md names the signer of $image" contains "$admin" "$PIN_SOURCE/$(pin_repo "$image")/.github/workflows/release.yml@refs/tags/"
done
check "docs/admin.md names the issuer" contains "$admin" "$PIN_ISSUER"
check "docs/admin.md has the known scanner findings with GO-2026-5932" contains "$admin" "GO-2026-5932"
for f in README.md docs/admin.md; do
  check "$f no longer says signatures are planned" lacks "$(cat "$f")" "are planned"
done

info "bundles/starter.json"
bundle=bundles/starter.json
check "$bundle exists" [ -f "$bundle" ]
check "$bundle is JSON of bundle version 1" [ "$(jq -r .version "$bundle")" = 1 ]
check "$bundle has no repositories, documents or project of ours" [ "$(jq -r '[.repositories, .documents, .project] | map(select(. != null)) | length' "$bundle")" = 0 ]
check "$bundle has a cycle for task and one for epic" [ "$(jq -r '[.workflows[].task_types[]] | sort | join(" ")' "$bundle")" = "epic task" ]
check "every status role of $bundle is a role of the bundle" [ "$(jq -r '[.roles[].key] as $roles | [.workflows[].statuses[].role // empty] | map(select(. as $r | $roles | index($r) | not)) | length' "$bundle")" = 0 ]
check "every artifact kind a gate requires is produced by a role" [ "$(jq -r '
  ([.roles[].output_contract[].kind] + ["problem.report"]) as $kinds
  | [.workflows[].transitions[].gates[]? | select(.type == "artifacts_required") | .config.kinds[]]
  | map(select(. as $k | $kinds | index($k) | not)) | length' "$bundle")" = 0 ]
check "every role of $bundle stands on a status" [ "$(jq -r '[.workflows[].statuses[].role // empty] as $used | [.roles[].key] | map(select(. as $r | $used | index($r) | not)) | length' "$bundle")" = 0 ]

info ".env.example"
env_example="$(cat .env.example)"
for kv in COMPOSE_PROJECT_NAME=cadence SDLC_TENANCY=single SDLC_PROJECT_CREATION=teams SDLC_AUTH_MODE=token SDLC_EMBEDDINGS_PROVIDER=none \
  SDLC_SEED= SDLC_EMBEDDINGS_MODEL= POSTGRES_PASSWORD= SDLC_ADMIN_TOKEN=; do
  check ".env.example sets $kv" grep -qxF "$kv" .env.example
done
check ".env.example sets no image version" lacks "$(grep -v '^#' <<<"$env_example")" "CADENCE_VERSION="
# An uncommented empty line would turn the metrics listeners off on every new
# installation: the default lives in docker-compose.yml.
check ".env.example documents SDLC_METRICS_ADDR, commented out" grep -qxF "# SDLC_METRICS_ADDR=:9090" .env.example
check ".env.example does not set SDLC_METRICS_ADDR" lacks "$(grep -v '^#' <<<"$env_example")" "SDLC_METRICS_ADDR="

info "installation name"
# The name of an installation is COMPOSE_PROJECT_NAME of its .env, and
# compose takes it from there; without the line (installations before
# v0.7.1) it is "cadence" from docker-compose.yml. The caller's variable is
# kept out: it is what the scripts refuse, not what compose should see here.
name_dir="$dist/name"
mkdir -p "$name_dir"
cp docker-compose.yml compose.proxy.yml Caddyfile VERSION "$name_dir/"
compose_name() {
  (cd "$name_dir" && env -u COMPOSE_PROJECT_NAME CADENCE_VERSION="$version" docker compose config --format json | jq -r .name)
}
printf 'COMPOSE_PROJECT_NAME=x\nPOSTGRES_PASSWORD=x\nCOMPOSE_FILE=docker-compose.yml:compose.proxy.yml\n' >"$name_dir/.env"
check "compose takes the name from .env (COMPOSE_PROJECT_NAME=x)" [ "$(compose_name)" = x ]
printf 'POSTGRES_PASSWORD=x\nCOMPOSE_FILE=docker-compose.yml:compose.proxy.yml\n' >"$name_dir/.env"
check "without the line in .env the name is cadence" [ "$(compose_name)" = cadence ]

# load_env of the scripts: the name from .env or the default, exported for
# compose; a COMPOSE_PROJECT_NAME of the caller that names another
# installation is refused with both names and the way out.
#
# name_of LINE CALLER: runs load_env in $name_dir with .env holding LINE (or
# no name line when LINE is empty) and COMPOSE_PROJECT_NAME=CALLER ("-" -
# unset); prints the exported name or the refusal.
name_of() {
  local line="$1" caller="$2" lib
  lib="$(pwd)/lib.sh"
  { [ -z "$line" ] || printf '%s\n' "$line"; printf 'POSTGRES_PASSWORD=x\n'; } >"$name_dir/.env"
  local caller_env=(-u COMPOSE_PROJECT_NAME)
  [ "$caller" = - ] || caller_env=(COMPOSE_PROJECT_NAME="$caller")
  # shellcheck disable=SC2016 # expanded by the inner bash
  (cd "$name_dir" && env "${caller_env[@]}" bash -c '. "$1" && load_env && printf "%s\n" "$COMPOSE_PROJECT_NAME"' _ "$lib" 2>&1)
}
check "load_env: no line, no variable - cadence" [ "$(name_of "" -)" = cadence ]
check "load_env: COMPOSE_PROJECT_NAME=stage in .env - stage" [ "$(name_of COMPOSE_PROJECT_NAME=stage -)" = stage ]
check "load_env: the same name in the variable - stage" [ "$(name_of COMPOSE_PROJECT_NAME=stage stage)" = stage ]
check "load_env: an empty variable is no variable - stage" [ "$(name_of COMPOSE_PROJECT_NAME=stage "")" = stage ]
check "load_env: an empty line in .env is the default - cadence" [ "$(name_of COMPOSE_PROJECT_NAME= -)" = cadence ]
if out="$(name_of COMPOSE_PROJECT_NAME=stage other)"; then
  fail "load_env: another name in the variable must be refused: $out"
else
  check "load_env: another name in the variable is refused, naming both" contains "$out" "COMPOSE_PROJECT_NAME is 'other' in the environment, but the installation in $name_dir is 'stage'"
  check "...and pointing at unset COMPOSE_PROJECT_NAME" contains "$out" "unset COMPOSE_PROJECT_NAME"
fi
if out="$(name_of "" other)"; then
  fail "load_env: a variable on an installation without the line must be refused: $out"
else
  check "load_env: a variable on an installation without the line points at the line to add" \
    contains "$out" "echo COMPOSE_PROJECT_NAME=other >> $name_dir/.env"
fi
if out="$(name_of COMPOSE_PROJECT_NAME=Bad_Name -)"; then
  fail "load_env: an invalid name in .env must be refused: $out"
else
  check "load_env: an invalid name in .env is refused" contains "$out" "COMPOSE_PROJECT_NAME in .env is 'Bad_Name', which is not a valid installation name"
fi

info "compose"
check "compose refuses to run without CADENCE_VERSION" sh -c '! env -u CADENCE_VERSION docker compose config -q'
missing="$(env -u CADENCE_VERSION docker compose config 2>&1 || true)"
check "the error names CADENCE_VERSION" contains "$missing" CADENCE_VERSION

# The images are pinned to the digests of VERSION (ci/pins.sh): the digest is
# the default of a variable next to the tag, so compose pins with no new
# variable - an upgrade.sh of an older version included - and an empty
# variable drops the pin for images of a branch. Whether the digests are the
# images of VERSION in the registry is the check workflow (ci/check-pins.sh).
backend_pin="$(pin_of backend || true)"
frontend_pin="$(pin_of frontend || true)"
check "docker-compose.yml pins backend to a digest (\${CADENCE_BACKEND_DIGEST-@sha256:<64 hex>})" [ -n "$backend_pin" ]
check "docker-compose.yml pins frontend to a digest (\${CADENCE_FRONTEND_DIGEST-@sha256:<64 hex>})" [ -n "$frontend_pin" ]
check "the image lines carry the tag of VERSION before the pin" \
  [ "$(grep -cE '^ *image: \$\{CADENCE_REGISTRY:-ghcr.io/cadence-lab-tech\}/sdlc-pipeline-(backend|frontend):\$\{CADENCE_VERSION:\?[^}]*\}\$\{CADENCE_(BACKEND|FRONTEND)_DIGEST-@sha256:[0-9a-f]{64}\}$' docker-compose.yml)" = 2 ]
# Older Compose v2 (seen on v2.3 and v2.6) reads " - " in the message of
# CADENCE_VERSION as a default value when the pin variable follows it.
check "the message of CADENCE_VERSION has no ' - '" lacks "$(grep -E '^ *image: .*CADENCE_VERSION:\?' docker-compose.yml)" " - "
# set_pin (the release pull request) rewrites one pin and leaves the other.
set_pin_roundtrip() {
  local f d rc=0
  f="$(mktemp)"
  d="sha256:$(printf '1%.0s' $(seq 64))"
  cp docker-compose.yml "$f"
  { set_pin backend "$d" "$f" && [ "$(pin_of backend "$f")" = "$d" ] && [ "$(pin_of frontend "$f")" = "$frontend_pin" ]; } || rc=1
  rm -f "$f"
  return "$rc"
}
check "set_pin rewrites the backend pin and keeps the frontend one" set_pin_roundtrip
images() { env -u CADENCE_REGISTRY -u CADENCE_BACKEND_DIGEST -u CADENCE_FRONTEND_DIGEST "$@" POSTGRES_PASSWORD=x CADENCE_VERSION="$version" docker compose config --images | sort -u | tr '\n' ' '; }
check "no variable: api, worker and ui by tag and digest" \
  [ "$(images)" = "$(printf '%s\n' caddy:2-alpine pgvector/pgvector:pg17 \
    "ghcr.io/cadence-lab-tech/sdlc-pipeline-backend:$version@$backend_pin" \
    "ghcr.io/cadence-lab-tech/sdlc-pipeline-frontend:$version@$frontend_pin" | sort -u | tr '\n' ' ')" ]
check "a mirror (CADENCE_REGISTRY) keeps the digests" \
  contains "$(images CADENCE_REGISTRY=mirror.example.com/cadence)" "mirror.example.com/cadence/sdlc-pipeline-backend:$version@$backend_pin"
check "images of a branch: CADENCE_REGISTRY=localhost:5050 and empty pin variables - by tag" \
  [ "$(images CADENCE_REGISTRY=localhost:5050 CADENCE_BACKEND_DIGEST= CADENCE_FRONTEND_DIGEST= | tr ' ' '\n' | grep sdlc-pipeline | tr '\n' ' ')" = \
    "localhost:5050/sdlc-pipeline-backend:$version localhost:5050/sdlc-pipeline-frontend:$version " ]

for mode in tls proxy; do
  config="$(POSTGRES_PASSWORD=x CADENCE_VERSION="$version" COMPOSE_FILE="docker-compose.yml:compose.$mode.yml" docker compose config --format json)"
  check "[$mode] backend image is :$version@<pin>" contains "$config" "\"ghcr.io/cadence-lab-tech/sdlc-pipeline-backend:$version@$backend_pin\""
  check "[$mode] frontend image is :$version@<pin>" contains "$config" "\"ghcr.io/cadence-lab-tech/sdlc-pipeline-frontend:$version@$frontend_pin\""
  check "[$mode] no build: sections" lacks "$config" '"build"'
  # The images are multi-arch since v0.5.3: a platform pin would put arm64
  # machines back under emulation.
  check "[$mode] compose pins no platform" lacks "$config" '"platform"'
  published="$(jq -r '.services | to_entries[] | .key as $s | (.value.ports // [])[] | "\($s) \(.published)"' <<<"$config")"
  check "[$mode] only caddy publishes ports" lacks "$(grep -v '^caddy ' <<<"$published" || true)" " "
  case "$mode" in
  tls) check "[tls] caddy publishes 80 and 443" [ "$(sort <<<"$published" | tr '\n' ' ')" = "caddy 443 caddy 80 " ] ;;
  proxy) check "[proxy] caddy publishes only the proxy port" [ "$published" = "caddy 8080" ] ;;
  esac
  envs="$(jq -r '
    ["SDLC_EMBEDDINGS_PROVIDER", "SDLC_EMBEDDINGS_MODEL", "SDLC_EMBEDDINGS_URL", "SDLC_EMBEDDINGS_API_KEY",
     "SDLC_EMBEDDINGS_SEND_DIMENSIONS", "SDLC_VOYAGE_API_KEY", "SDLC_LEASE_TTL", "SDLC_HEARTBEAT_INTERVAL"] as $keys
    | .services.api.environment as $api | .services.worker.environment as $worker
    | [$keys[] | . as $k | select(($api | has($k)) and ($worker | has($k)) and $api[$k] == $worker[$k])] as $same
    | (if ($same | length) == ($keys | length) then "same" else "mismatch" end),
      "model=[\($api.SDLC_EMBEDDINGS_MODEL)]", "provider=\($api.SDLC_EMBEDDINGS_PROVIDER)"' <<<"$config")"
  check "[$mode] api and worker get the same embeddings and lease settings" contains "$envs" "same"
  check "[$mode] SDLC_EMBEDDINGS_MODEL is empty by default" contains "$envs" "model=[]"
  check "[$mode] SDLC_EMBEDDINGS_PROVIDER is none by default" contains "$envs" "provider=none"
  # Metrics (since v0.10.0): both processes listen on :9090 inside the
  # network; nothing is published (the ports check above) and Caddy does not
  # route /metrics (the Caddyfile checks below).
  check "[$mode] api and worker get SDLC_METRICS_ADDR=:9090" \
    [ "$(jq -r '[.services.api.environment.SDLC_METRICS_ADDR, .services.worker.environment.SDLC_METRICS_ADDR] | join(" ")' <<<"$config")" = ":9090 :9090" ]
done
metrics_off="$(SDLC_METRICS_ADDR='' POSTGRES_PASSWORD=x CADENCE_VERSION="$version" docker compose config --format json |
  jq -r '[.services.api.environment.SDLC_METRICS_ADDR, .services.worker.environment.SDLC_METRICS_ADDR] | join(",")')"
check "an empty SDLC_METRICS_ADDR in .env turns the listeners off" [ "$metrics_off" = "," ]

# The example alert rules of docs/admin.md ("Monitoring") are what an
# administrator copies into Prometheus: they must load.
info "alert rules (docs)"
rules_dir="$dist/rules"
mkdir -p "$rules_dir"
awk '/^# cadence-alerts.yml$/ { on = 1 } on && /^```$/ { exit } on' docs/admin.md >"$rules_dir/cadence-alerts.yml"
check "docs/admin.md has the example rules (# cadence-alerts.yml)" [ -s "$rules_dir/cadence-alerts.yml" ]
check "promtool check rules accepts them" docker run --rm -v "$rules_dir:/rules:ro" --entrypoint promtool \
  prom/prometheus:v3.5.0 check rules /rules/cadence-alerts.yml

info "Caddyfile"
adapt() {
  docker run --rm "$@" -v "$PWD/Caddyfile:/etc/caddy/Caddyfile:ro" caddy:2-alpine \
    caddy adapt --config /etc/caddy/Caddyfile 2>/dev/null
}
check "Caddyfile is formatted" docker run --rm -v "$PWD/Caddyfile:/etc/caddy/Caddyfile:ro" caddy:2-alpine \
  caddy fmt --diff /etc/caddy/Caddyfile
tls="$(adapt -e CADENCE_MODE=tls -e SDLC_DOMAIN=cadence.example.com -e ACME_EMAIL=ops@example.com)"
check "[tls] listens on :443" contains "$tls" '":443"'
check "[tls] serves the domain" contains "$tls" '"cadence.example.com"'
check "[tls] issues the certificate with ACME and the e-mail" contains "$tls" '"email":"ops@example.com"'
proxy="$(adapt -e CADENCE_MODE=proxy -e SDLC_DOMAIN= -e ACME_EMAIL=)"
check "[proxy] listens on :80" contains "$proxy" '":80"'
check "[proxy] has no TLS automation" lacks "$proxy" '"acme"'
for cfg in "$tls" "$proxy"; do
  check "routes /v1 /mcp /webhooks /healthz /readyz to the API" contains "$cfg" '"/v1/*","/mcp/*","/webhooks/*","/healthz","/readyz"'
  check "MCP is proxied without buffering" contains "$cfg" '"flush_interval":-1'
  check "everything else goes to the UI" contains "$cfg" '"dial":"ui:80"'
  check "nothing is routed to the metrics port" lacks "$cfg" ':9090'
done

[ "$failures" -eq 0 ] || die "$failures check(s) failed"
ok "configuration checks passed"
