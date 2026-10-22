#!/usr/bin/env bash
#
# Static checks of the package that need no published images: the compose
# configuration in both modes, the Caddyfile in both modes, the defaults of
# .env.example, the file layout, the release package that ci/package.sh
# builds - with the clab of every platform from the tap - and its wrappers,
# and the Helm chart (rendered, in parity with compose). CI runs it on every
# pull request next to the shell linter; it needs Docker and jq (helm of
# PATH, or its image), and the network for the clab of the tap (kept in
# .cache/clab).
#
#   ci/check-config.sh
#
# The wrappers (decision 0057): install.sh, upgrade.sh, backup.sh and
# restore.sh are POSIX sh, a few dozen lines without lib.sh and without
# docker, ending in exec of the clab of the package; their --help is the
# help of clab server <command>, an unknown flag exits with 2, a platform
# the package has no clab for - and a clab that does not run - with 1 and
# the commands that install clab of VERSION from the tap and run it on the
# directory, nothing changed. The flags of the scripts in the documentation
# are checked against clab server <command> --help of the clab of the
# package for this machine. ci/package.sh refuses an archive of the tap
# whose sum does not match its checksums.txt and a release of the tap
# without the archives, and builds without the tap from --clab DIR.
#
#   CLAB_BIN  clab whose "clab server ... --help" the documented clab server
#             commands are checked against; default: the clab of the package
#             for this machine (bin/clab-<os>-<arch>). Without CLAB_BIN a
#             documented command that the clab of VERSION does not have yet
#             (documented ahead of the release that brings it) is skipped
#             with a note; with CLAB_BIN it fails. So is a flag of the list
#             ahead_flags (documented ahead of the release in its line),
#             for the scripts and the one-line installer too, whose flags
#             CLAB_BIN then also checks. Any other unknown flag of an
#             existing command fails either way. The same clab checks the
#             line docs/admin.md quotes for clab without a host.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=ci/lib.sh
. ./ci/lib.sh
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
for f in docker-compose.yml compose.tls.yml compose.proxy.yml compose.external-db.yml compose.secrets.yml .env.example Caddyfile README.md docs/admin.md LICENSE SECURITY.md VERSION; do
  check "$f exists" [ -f "$f" ]
done
for f in install.sh upgrade.sh backup.sh restore.sh get-cadence.sh ci/package.sh ci/check-verify.sh; do
  check "$f is executable" [ -x "$f" ]
done
check "VERSION is vX.Y.Z" valid_version "$version"
check "LICENSE is FSL-1.1-ALv2" grep -q '^FSL-1.1-ALv2$' LICENSE
for p in .env backups/ secrets/ compose.override.yml; do
  check ".gitignore has $p" grep -qxF "$p" .gitignore
done
check "get-cadence.sh is a POSIX sh script" [ "$(head -n 1 get-cadence.sh)" = "#!/bin/sh" ]
check ".gitignore has .cache/ (the clab of the tap, ci/package.sh)" grep -qxF .cache/ .gitignore
check "lib.sh is no file of the installation any more, the checks have ci/lib.sh" [ ! -e lib.sh ]

info "wrappers"
# install.sh, upgrade.sh, backup.sh and restore.sh: exec of clab server
# <command> of the clab of the package, nothing else (decision 0057).
# shellcheck disable=SC2016 # the text of the scripts
wrapper_exec='exec "$clab" server "$command" --dir "$dir" "$@"'
for f in install.sh upgrade.sh backup.sh restore.sh; do
  check "$f is a POSIX sh script" [ "$(head -n 1 "$f")" = "#!/bin/sh" ]
  check "$f has a few dozen lines ($(grep -c . "$f"))" [ "$(grep -c . "$f")" -le 80 ]
  check "$f runs clab server ${f%.sh}" grep -qxF "command=${f%.sh}" "$f"
  check "$f ends in exec of the clab of the package with --dir and its arguments" [ "$(tail -n 1 "$f")" = "$wrapper_exec" ]
  check "$f sources no lib.sh" lacks "$(grep -v '^#' "$f")" "lib.sh"
  check "$f calls no docker" lacks "$(grep -v '^#' "$f")" "docker"
  check "$f sets CADENCE_WRAPPER=1 for the hints of clab server" grep -qxF "CADENCE_WRAPPER=1" "$f"
done
# Apart from the first lines and the command, the wrappers are one text.
wrapper_body() { sed -n '/^set -eu$/,$p' "$1" | grep -vx "command=${1%.sh}"; }
for f in upgrade.sh backup.sh restore.sh; do
  check "$f is install.sh but for the command" [ "$(wrapper_body "$f")" = "$(wrapper_body install.sh)" ]
done

info "release package"
# What ci/package.sh builds for a release: the files an installation needs
# and nothing of the repository around them. The required list is kept here,
# apart from the list in ci/package.sh, so that a file dropped from the
# package turns this check red.
required_files="VERSION docker-compose.yml compose.tls.yml compose.proxy.yml compose.external-db.yml compose.secrets.yml Caddyfile .env.example
  install.sh upgrade.sh backup.sh restore.sh bundles/starter.json docs/admin.md README.md LICENSE SECURITY.md
  bin/clab-linux-amd64 bin/clab-linux-arm64 bin/clab-darwin-amd64 bin/clab-darwin-arm64
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
for p in ci/ .github/ .git .gitignore .env backups/ secrets/ compose.override.yml docker-compose.override.yml get-cadence.sh lib.sh .cache/; do
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
check "the package has no clab-runner" [ -z "$(grep -F clab-runner <<<"$listing" || true)" ]
check "the package has no ._ metadata files of macOS" [ -z "$(grep -E '(^|/)\._' <<<"$listing" || true)" ]
check "the package has no top directory" [ -z "$(grep -E '^[^/]+/$' <<<"$listing" || true)" ]
mkdir -p "$dist/unpacked"
(umask 077 && tar -xpzf "$dist/out/$package" -C "$dist/unpacked")
check "VERSION in the package is $version" [ "$(tr -d '[:space:]' <"$dist/unpacked/VERSION")" = "$version" ]
mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
for f in install.sh upgrade.sh backup.sh restore.sh; do
  check "$f unpacks executable (755)" [ "$(mode_of "$dist/unpacked/$f")" = 755 ]
done
for p in $CLAB_PLATFORMS; do
  check "bin/clab-$p unpacks executable (755)" [ "$(mode_of "$dist/unpacked/bin/clab-$p")" = 755 ]
done
check "the other files unpack as 644 under umask 077" \
  [ "$(mode_of "$dist/unpacked/docker-compose.yml") $(mode_of "$dist/unpacked/README.md")" = "644 644" ]
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

# The clab of the package for this machine: what the wrappers run here.
case "$(uname -s)/$(uname -m)" in
Linux/x86_64 | Linux/amd64) platform=linux-amd64 ;;
Linux/aarch64 | Linux/arm64) platform=linux-arm64 ;;
Darwin/x86_64) platform=darwin-amd64 ;;
Darwin/arm64) platform=darwin-arm64 ;;
*) die "no clab in the package for $(uname -s)/$(uname -m): the checks of the wrappers need one" ;;
esac
pkg_clab="$dist/unpacked/bin/clab-$platform"
clab_cache="${CADENCE_CLAB_CACHE:-$PWD/.cache/clab}/$version"
mkdir -p "$dist/clab-config"
# clab_of CMD ARGS...: CMD with no clab configuration of this machine.
clab_of() { env -u SDLC_API_URL -u SDLC_TOKEN -u SDLC_PROJECT CLAB_CONFIG_DIR="$dist/clab-config" "$@"; }
check "bin/clab-$platform version: clab $version" [ "$(clab_of "$pkg_clab" version 2>/dev/null | head -n 1)" = "clab $version" ]
# clab_in_archive OS-ARCH: the sha256 of clab in the archive of the tap.
clab_in_archive() {
  local a
  a="$(clab_archive "$version" "$1")"
  tar -xzOf "$clab_cache/$a" "${a%.tar.gz}/clab" >"$dist/clab-of-archive"
  sha256_of "$dist/clab-of-archive"
}
for p in $CLAB_PLATFORMS; do
  check "bin/clab-$p is clab of the archive $(clab_archive "$version" "$p") of the tap" \
    [ "$(sha256_of "$dist/unpacked/bin/clab-$p")" = "$(clab_in_archive "$p")" ]
done

# The clab of the tap is checked before anything is packed; --clab DIR
# builds without the tap. A tap of the archives of $version in a scratch
# directory, an empty cache each time.
info "clab of the tap (ci/package.sh)"
tap="$dist/tap/download/$version"
mkdir -p "$tap"
cp "$clab_cache/checksums.txt" "$tap/"
for p in $CLAB_PLATFORMS; do cp "$clab_cache/$(clab_archive "$version" "$p")" "$tap/"; done
# package_from_tap NAME: ci/package.sh from the scratch tap into $dist/NAME;
# prints its output, the exit status is its.
package_from_tap() {
  CADENCE_TAP_RELEASES_URL="file://$dist/tap" CADENCE_CLAB_CACHE="$dist/cache-$1" ci/package.sh "$dist/$1" 2>&1
}
check "ci/package.sh builds from a tap with the archives of $version" package_from_tap from-tap
first="$(clab_archive "$version" linux-amd64)"
printf 'x' >>"$tap/$first"
if out="$(package_from_tap tampered)"; then
  fail "ci/package.sh with an archive whose sum does not match must fail"
else
  check "an archive whose sum does not match checksums.txt of the tap: refused, naming it" contains "$out" "the sum of $first does not match checksums.txt"
fi
check "...and no package is written" [ ! -e "$dist/tampered/$package" ]
mv "$tap/$first" "$dist/$first.moved"
if out="$(package_from_tap missing)"; then
  fail "ci/package.sh with an archive missing from the tap must fail"
else
  check "an archive missing from the release of the tap: refused, naming it" contains "$out" "has no $first"
fi
check "...and no package is written" [ ! -e "$dist/missing/$package" ]
if out="$(CADENCE_TAP_RELEASES_URL="file://$dist/no-tap" CADENCE_CLAB_CACHE="$dist/cache-none" ci/package.sh "$dist/none" 2>&1)"; then
  fail "ci/package.sh without a release of the tap must fail"
else
  check "no release of clab $version in the tap: refused, the archives are not published" contains "$out" "the archives of clab $version are not published"
fi
check "...and no package is written" [ ! -e "$dist/none/$package" ]
mkdir -p "$dist/local-clab"
for p in $CLAB_PLATFORMS; do printf '#!/bin/sh\necho local clab %s\n' "$p" >"$dist/local-clab/clab-$p"; done
check "ci/package.sh --clab DIR builds with no tap at all" \
  env CADENCE_TAP_RELEASES_URL="file://$dist/no-tap" CADENCE_CLAB_CACHE="$dist/cache-local" ci/package.sh --clab "$dist/local-clab" "$dist/local"
mkdir -p "$dist/local/unpacked"
tar -xpzf "$dist/local/$package" -C "$dist/local/unpacked" 2>/dev/null || true
check "...with the clab of DIR as bin/clab-<os>-<arch>, 755" \
  [ "$("$dist/local/unpacked/bin/clab-linux-arm64" 2>/dev/null) $(mode_of "$dist/local/unpacked/bin/clab-linux-arm64" 2>/dev/null)" = "local clab linux-arm64 755" ]
mv "$dist/local-clab/clab-darwin-amd64" "$dist/clab-darwin-amd64.moved"
if out="$(ci/package.sh --clab "$dist/local-clab" "$dist/local-short" 2>&1)"; then
  fail "ci/package.sh --clab DIR without a platform must fail"
else
  check "ci/package.sh --clab DIR without clab-darwin-amd64: refused, naming it" contains "$out" "has no clab-darwin-amd64"
fi

info "wrappers in the package"
# wrapper_state DIR: the files of DIR with their sums - what "nothing was
# done" means.
wrapper_state() { (cd "$1" && find . -type f | LC_ALL=C sort | while IFS= read -r f; do printf '%s  %s\n' "$(sha256_of "$f")" "$f"; done); }
w="$dist/unpacked"
before="$(wrapper_state "$w")"
for f in install.sh upgrade.sh backup.sh restore.sh; do
  code=0
  out="$(clab_of "$w/$f" --help 2>&1)" || code=$?
  check "$f --help exits with 0 and is the help of clab server ${f%.sh}" [ "$code/$(head -n 1 <<<"$out" | cut -d' ' -f1-3)" = "0/clab server ${f%.sh}" ]
  code=0
  out="$(clab_of "$w/$f" --no-such-flag </dev/null 2>&1)" || code=$?
  check "$f --no-such-flag exits with 2: unknown option" [ "$code" = 2 ]
  check "...and says so" contains "$out" "unknown option: --no-such-flag"
done
# A platform the package has no clab for: a stand-in uname.
mkdir -p "$dist/uname"
# shellcheck disable=SC2016 # the text of the stand-in
printf '#!/bin/sh\ncase "$1" in -s) echo FreeBSD ;; -m) echo riscv64 ;; esac\n' >"$dist/uname/uname"
chmod 755 "$dist/uname/uname"
for f in install.sh backup.sh; do
  code=0
  out="$(PATH="$dist/uname:$PATH" "$w/$f" --yes </dev/null 2>&1)" || code=$?
  check "$f on freebsd/riscv64 exits with 1" [ "$code" = 1 ]
  check "...names the platform" contains "$out" "no clab for freebsd/riscv64"
  check "...prints the installation of clab $version from the tap" contains "$out" "| CLAB_VERSION=$version sh"
  check "...and clab server ${f%.sh} --dir with the directory" contains "$out" "clab server ${f%.sh} --dir $w"
done
code=0
out="$(CADENCE_CLAB=/etc/hosts "$w/backup.sh" 2>&1)" || code=$?
check "a clab that does not run (CADENCE_CLAB=/etc/hosts): exit 1" [ "$code" = 1 ]
check "...naming it" contains "$out" "CADENCE_CLAB=/etc/hosts does not run"
check "the refusals changed no file of the directory" [ "$(wrapper_state "$w")" = "$before" ]
cp "$pkg_clab" "$dist/clab-elsewhere"
check "CADENCE_CLAB runs another clab: backup.sh --help with a clab outside bin/" \
  [ "$(CADENCE_CLAB="$dist/clab-elsewhere" "$w/backup.sh" --help 2>/dev/null | head -n 1 | cut -d' ' -f1-3)" = "clab server backup" ]

info "rollback hint (docs)"
# What upgrade.sh and restore.sh print when they refuse another version, for
# a version before the release packages: the source archive of its tag, or
# git in a clone (clab server, packageFilesHint). docs/admin.md shows them
# as they are printed.
archive_of() { printf 'curl -fsSL https://github.com/cadence-lab-tech/self-hosted/archive/refs/tags/%s.tar.gz | tar -xpzf - --strip-components=1' "$1"; }
checkout_of() { printf 'git -c advice.detachedHead=false checkout --force %s' "$1"; }
for cmd in "$(archive_of v0.5.3)" "$(checkout_of v0.5.3)" "git fetch --tags origin && $(checkout_of v0.5.3)"; do
  check "docs/admin.md shows: $cmd" grep -qF -- "$cmd" docs/admin.md
done

info "documented flags"
# The scripts pass their arguments to clab server <command> of the clab of
# the package (decision 0057): the flags they take are those its help lists.
# With CLAB_BIN its help is the reference instead: the clab of the branch
# that brings a flag.
# flags_of COMMAND: the flags of clab server COMMAND --help.
flags_of() {
  { printf '%s\n' -h --help; clab_of "${CLAB_BIN:-$pkg_clab}" server "$1" --help 2>/dev/null; } |
    grep -oE -- '(^|[ ,[])-{1,2}[a-z][a-z-]*' | grep -oE -- '-{1,2}[a-z][a-z-]*' | sort -u
}
# Flags documented ahead of the release that brings them, "FLAG SINCE": while
# VERSION is older than SINCE and there is no CLAB_BIN, such a flag that the
# clab of the package does not take is skipped with a note, as a command
# documented ahead is; with CLAB_BIN, or once VERSION catches up, it is
# checked. A flag outside this list that no help lists fails.
ahead_flags='--with-starter v0.14.0
--project v0.14.0
--project-name v0.14.0'
# ahead FLAG: documented ahead of its release, not checked yet.
ahead() {
  local since
  [ -z "${CLAB_BIN:-}" ] || return 1
  since="$(awk -v f="$1" '$1 == f { print $2 }' <<<"$ahead_flags")"
  [ -n "$since" ] && version_lt "$version" "$since"
}
install_flags="$(flags_of install)"
if [ -n "$install_flags" ]; then
  pass "install.sh takes $(tr '\n' ' ' <<<"$install_flags")"
else
  fail "install.sh: no flags in the help of clab server install"
fi
# Every ./<script> command of the documentation, on a line of a code block or
# inline up to the closing backtick (or a comment, a redirection), uses only
# the flags of its command.
for script in install upgrade backup restore; do
  script_flags="$(flags_of "$script")"
  documented=0
  for f in README.md docs/admin.md; do
    while IFS=: read -r line command; do
      for flag in $(grep -oE -- ' -{1,2}[a-z][a-z-]*' <<<"$command" | tr -d ' ' || true); do
        documented=$((documented + 1))
        if grep -qxF -- "$flag" <<<"$script_flags"; then
          pass "$f:$line: $script.sh takes $flag"
        elif ahead "$flag"; then
          info "skipped $f:$line: $script.sh of clab $version has no $flag yet; CLAB_BIN=<clab with it> checks it"
        else
          fail "$f:$line: $script.sh (clab server $script) has no flag $flag"
        fi
      done
    done < <(grep -noE -- "\./$script\.sh[^\`#>|]*" "$f" || true)
  done
  check "the documentation shows $script.sh ($documented flags)" grep -qF "./$script.sh" docs/admin.md
done

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
      elif ahead "$flag"; then
        info "skipped $f:$line: install.sh of clab $version has no $flag yet; CLAB_BIN=<clab with it> checks it"
      else
        fail "$f:$line: neither get-cadence.sh nor install.sh has the flag $flag"
      fi
    done
  done < <(grep -noE -- 'get-cadence\.sh \| sh -s --[^`]*' "$f" | sed 's/get-cadence\.sh | //' || true)
done
check "the documentation shows the one-line installer with flags" [ "$documented" -gt 0 ]

backup_flags="$(flags_of backup)"
check "backup.sh takes --no-upload and --ignore-version" [ "$(grep -cxE -- '--no-upload|--ignore-version' <<<"$backup_flags")" = 2 ]
check "the documentation shows ./backup.sh verify" grep -qF "./backup.sh verify" docs/admin.md
check "the documentation shows ./backup.sh fetch" grep -qF "./backup.sh fetch" docs/admin.md

# clab server: every "clab server <command> ..." of the documentation uses
# only flags that "clab server <command> --help" lists. The clab is CLAB_BIN,
# else the clab of the package for this machine - clab of VERSION from the
# tap. A command it does not list yet is documented ahead of its release:
# skipped with a note until VERSION catches up, checked with CLAB_BIN of the
# branch that brings it.
info "documented clab server flags"
clab_server="${CLAB_BIN:-$pkg_clab}"
if [ -z "$clab_server" ]; then
  fail "no clab to check the documented clab server flags"
else
  documented=0
  server_help="$(clab_of "$clab_server" server --help 2>/dev/null || true)"
  for f in README.md docs/admin.md; do
    while IFS=: read -r line command; do
      sub="$(awk '{print $3}' <<<"$command")"
      # Two levels: clab server images list|save|load has a help of each.
      words=("$sub")
      second="$(awk '{print $4}' <<<"$command")"
      if [ "$sub" = images ] && [[ "$second" =~ ^(list|save|load)$ ]]; then
        words+=("$second")
      fi
      if ! sub_help="$(clab_of "$clab_server" server "${words[@]}" --help 2>/dev/null)"; then
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
          pass "$f:$line: clab server ${words[*]} takes $flag"
        elif ahead "$flag"; then
          info "skipped $f:$line: clab server ${words[*]} of clab $version has no $flag yet; CLAB_BIN=<clab with it> checks it"
        else
          fail "$f:$line: clab server ${words[*]} has no flag $flag"
        fi
      done
    done < <(grep -noE -- 'clab server [a-z]+[^`#]*' "$f" || true)
  done
  check "the documentation shows clab server with flags" [ "$documented" -gt 0 ]
fi

# clab without a host: docs/admin.md quotes the line clab prints when no host
# is configured (clab v0.10.1, CLAB-147). The clab is CLAB_BIN, else the
# clab of the package.
info "documented clab without a host"
clab_nohost="${CLAB_BIN:-$pkg_clab}"
if [ -n "$clab_nohost" ]; then
  nohost_config="$(mktemp -d "$dist/clab-config.XXXXXX")"
  nohost_code=0
  nohost="$(cd "$dist" && CLAB_CONFIG_DIR="$nohost_config" env -u SDLC_API_URL -u SDLC_TOKEN "$clab_nohost" tasks 2>&1 >/dev/null)" ||
    nohost_code=$?
  nohost="${nohost%%$'\n'*}"
  check "clab with no host exits with code 1" [ "$nohost_code" = 1 ]
  check "clab with no host prints a line" [ -n "$nohost" ]
  check "docs/admin.md quotes what clab prints with no host: $nohost" grep -qF -- "$nohost" docs/admin.md
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

info "verifying a release (CADENCE_VERIFY)"
# clab server verifies (the wrappers run it); get-cadence.sh repeats the
# rules in POSIX sh for the package, with the constants of ci/lib.sh, which
# the checks verify with.
for mode in auto require off; do
  check "docs/admin.md describes CADENCE_VERIFY=$mode" contains "$admin" "\`$mode\`"
done
check "docs/admin.md has the automatic verification with its table" contains "$admin" "### Automatic verification"
check "docs/admin.md no longer says the installer does not check the signatures" lacks "$admin" "does not check the"
check ".env.example documents CADENCE_VERIFY, commented out" grep -qxF "# CADENCE_VERIFY=auto" .env.example
check ".env.example does not set CADENCE_VERIFY" lacks "$(grep -v '^#' .env.example)" "CADENCE_VERIFY="
for f in get-cadence.sh install.sh upgrade.sh README.md; do
  check "$f names CADENCE_VERIFY" grep -qF CADENCE_VERIFY "$f"
done
# same_constant NAME_IN_GET NAME_IN_LIB: get-cadence.sh and ci/lib.sh agree.
same_constant() {
  [ "$(sed -n "s/^$1=//p" get-cadence.sh)" = "$(bash -c ". ./ci/lib.sh && printf '%s' \"\$$2\"")" ]
}
check "get-cadence.sh and ci/lib.sh: the same first signed version" same_constant FIRST_SIGNED VERIFY_FIRST_SIGNED
check "...the same issuer" same_constant ISSUER VERIFY_ISSUER
check "...the same identity of the package" same_constant PACKAGE_IDENTITY VERIFY_PACKAGE_IDENTITY
check "...the same bundle" same_constant BUNDLE VERIFY_BUNDLE
check "ci/lib.sh: the identity of the package is the one docs/admin.md names" contains "$admin" "$VERIFY_PACKAGE_IDENTITY"
check "ci/lib.sh: the identity of an image is the one ci/pins.sh pins with" \
  [ "$(verify_identity sdlc-pipeline-backend v1.2.3)" = "$(pin_identity backend v1.2.3)" ]

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
  SDLC_SEED= SDLC_EMBEDDINGS_MODEL= POSTGRES_PASSWORD= SDLC_ADMIN_TOKEN= CADENCE_DB=bundled SDLC_DATABASE_URL=; do
  check ".env.example sets $kv" grep -qxF "$kv" .env.example
done
# Audit log retention (CLAB-210): set in .env.example, defaulted in compose
# for an .env written before the variable existed.
check ".env.example sets SDLC_AUDIT_RETENTION_DAYS=180" grep -qxF "SDLC_AUDIT_RETENTION_DAYS=180" .env.example
check ".env.example sets no image version" lacks "$(grep -v '^#' <<<"$env_example")" "CADENCE_VERSION="
# An uncommented empty line would turn the metrics listeners off on every new
# installation: the default lives in docker-compose.yml.
check ".env.example documents SDLC_METRICS_ADDR, commented out" grep -qxF "# SDLC_METRICS_ADDR=:9090" .env.example
check ".env.example does not set SDLC_METRICS_ADDR" lacks "$(grep -v '^#' <<<"$env_example")" "SDLC_METRICS_ADDR="

# Off-machine backups (CLAB-132): every variable is in .env.example with an
# empty value - a new installation behaves as before - and is described in
# docs/admin.md.
for v in BACKUP_S3_BUCKET BACKUP_S3_ENDPOINT BACKUP_S3_REGION BACKUP_S3_PREFIX BACKUP_S3_ACCESS_KEY_ID \
  BACKUP_S3_SECRET_ACCESS_KEY BACKUP_S3_PATH_STYLE BACKUP_S3_KEEP; do
  check ".env.example sets $v=" grep -qxF "$v=" .env.example
done
# The keys in files (CLAB-200) are commented examples: an empty value is no
# value, and the file form is a choice.
backup_s3_of_example() { grep -oE '^(# )?BACKUP_S3_[A-Z_]+=' .env.example | sed 's/^# //; s/=$//' | sort -u; }
while read -r v; do
  check "docs/admin.md describes $v" grep -qF "$v" docs/admin.md
done < <(backup_s3_of_example)

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
# ui and caddy run the frontend image from one anchor (x-image-frontend), so
# one set_pin moves both and they never run different builds.
set_pin_frontend_roundtrip() {
  local f d rc=0
  f="$(mktemp)"
  d="sha256:$(printf '2%.0s' $(seq 64))"
  cp docker-compose.yml "$f"
  { set_pin frontend "$d" "$f" && [ "$(pin_of frontend "$f")" = "$d" ] && [ "$(pin_of backend "$f")" = "$backend_pin" ] &&
    [ "$(env -u CADENCE_REGISTRY -u CADENCE_FRONTEND_DIGEST POSTGRES_PASSWORD=x CADENCE_VERSION="$version" docker compose -f "$f" config --format json |
      jq -r '[.services.ui.image, .services.caddy.image] | unique | join(" ")')" = \
      "ghcr.io/cadence-lab-tech/sdlc-pipeline-frontend:$version@$d" ]; } || rc=1
  rm -f "$f"
  return "$rc"
}
check "set_pin rewrites the frontend pin of ui and caddy together and keeps the backend one" set_pin_frontend_roundtrip
images() { env -u CADENCE_REGISTRY -u CADENCE_BACKEND_DIGEST -u CADENCE_FRONTEND_DIGEST "$@" POSTGRES_PASSWORD=x CADENCE_VERSION="$version" docker compose config --images | sort -u | tr '\n' ' '; }
check "no variable: api, worker, ui and caddy by tag and digest" \
  [ "$(images)" = "$(printf '%s\n' pgvector/pgvector:pg17 \
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
  # The entry point runs our Caddy (the frontend image), not caddy:2-alpine.
  check "[$mode] caddy runs the frontend image of ui" \
    [ "$(jq -r '.services.caddy.image' <<<"$config")" = "ghcr.io/cadence-lab-tech/sdlc-pipeline-frontend:$version@$frontend_pin" ]
  check "[$mode] no service runs caddy:2-alpine" lacks "$(jq -r '.services[].image' <<<"$config")" "caddy:2-alpine"
  # The frontend image runs as uid 65532 (CLAB-236); caddy stays root: its
  # volumes hold the certificates of existing installations, owned by root.
  # ui runs as the user of its image.
  check "[$mode] caddy runs as root (user 0:0), ui as the user of its image" \
    [ "$(jq -r '"\(.services.caddy.user) \(.services.ui.user)"' <<<"$config")" = "0:0 null" ]
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
retention() { env -u SDLC_AUDIT_RETENTION_DAYS "$@" POSTGRES_PASSWORD=x CADENCE_VERSION="$version" docker compose config --format json | jq -r '.services.worker.environment.SDLC_AUDIT_RETENTION_DAYS'; }
check "the worker gets SDLC_AUDIT_RETENTION_DAYS=180 without the line in .env" [ "$(retention)" = "180" ]
check "SDLC_AUDIT_RETENTION_DAYS of .env reaches the worker" [ "$(retention SDLC_AUDIT_RETENTION_DAYS=30)" = "30" ]

# Traces of the API over OTLP/HTTP (since v0.12.0): the standard OTEL_* go to
# the API only - the worker is not traced - and are empty by default, so an
# installation exports nothing until .env sets an endpoint. .env.example
# has each of them only commented out, docs/admin.md describes each. The
# headers are a secret (CLAB-235): their file form goes with them.
info "traces (OTEL_*)"
otel_vars="OTEL_EXPORTER_OTLP_ENDPOINT OTEL_EXPORTER_OTLP_HEADERS OTEL_EXPORTER_OTLP_HEADERS_FILE OTEL_RESOURCE_ATTRIBUTES OTEL_SERVICE_NAME OTEL_TRACES_EXPORTER OTEL_TRACES_SAMPLER OTEL_TRACES_SAMPLER_ARG"
otel_config() {
  local unset=()
  for v in $otel_vars; do unset+=(-u "$v"); done
  env -u CADENCE_REGISTRY -u CADENCE_BACKEND_DIGEST -u CADENCE_FRONTEND_DIGEST "${unset[@]}" "$@" \
    POSTGRES_PASSWORD=x CADENCE_VERSION="$version" docker compose config --format json
}
for mode in tls proxy; do
  otel="$(otel_config COMPOSE_FILE="docker-compose.yml:compose.$mode.yml")"
  check "[$mode] api gets exactly: $otel_vars" \
    [ "$(jq -r '[.services.api.environment | keys[] | select(startswith("OTEL_"))] | sort | join(" ")' <<<"$otel")" = "$otel_vars" ]
  check "[$mode] every OTEL_* of api is empty without .env" \
    [ "$(jq -r '[.services.api.environment | to_entries[] | select((.key | startswith("OTEL_")) and .value != "")] | length' <<<"$otel")" = 0 ]
  check "[$mode] worker gets no OTEL_*" \
    [ "$(jq -r '[.services | to_entries[] | select(.key != "api") | (.value.environment // {}) | keys[] | select(startswith("OTEL_"))] | length' <<<"$otel")" = 0 ]
done
otel_set="$(otel_config OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318 OTEL_SERVICE_NAME=acme-cadence |
  jq -r '.services.api.environment | "\(.OTEL_EXPORTER_OTLP_ENDPOINT) \(.OTEL_SERVICE_NAME)"')"
check "OTEL_* of .env reach the api" [ "$otel_set" = "http://otel-collector:4318 acme-cadence" ]
for v in $otel_vars; do
  check ".env.example documents $v, commented out" grep -qE "^# $v=" .env.example
  check ".env.example does not set $v" lacks "$(grep -v '^#' <<<"$env_example")" "$v="
  check "docs/admin.md describes $v" grep -qF "\`$v\`" docs/admin.md
done
check "docs/admin.md says OTLP over gRPC is not supported" contains "$admin" "Only OTLP over HTTP with protobuf is supported"

# The example alert rules of docs/admin.md ("Monitoring") are what an
# administrator copies into Prometheus: they must load.
info "alert rules (docs)"
rules="$(awk '/^# cadence-alerts.yml$/ { on = 1 } on && /^```$/ { exit } on' docs/admin.md)"
check "docs/admin.md has the example rules (# cadence-alerts.yml)" [ -n "$rules" ]
# The rules go in on stdin: a bind mount of a scratch directory is not
# readable for the user of the image on every CI runner.
if promtool_out="$(docker run --rm -i --entrypoint promtool prom/prometheus:v3.5.0 \
  check rules /dev/stdin <<<"$rules" 2>&1)"; then
  pass "promtool check rules accepts them"
else
  fail "promtool check rules accepts them"
  printf '%s\n' "$promtool_out" >&2
fi

info "external database (compose.external-db.yml)"
# CADENCE_DB=external: COMPOSE_FILE adds compose.external-db.yml after the
# file of the mode. The postgres container and its volume are gone, the API
# and the worker take SDLC_DATABASE_URL of .env, the backup client is a
# service of the profile tools.
ext_url='postgres://cadence:p%40ss@db.example.com:5432/cadence?sslmode=verify-full&sslrootcert=/secrets/db-ca.pem'
ext_config() {
  env -u CADENCE_REGISTRY -u CADENCE_BACKEND_DIGEST -u CADENCE_FRONTEND_DIGEST POSTGRES_PASSWORD= CADENCE_VERSION="$version" \
    COMPOSE_FILE="docker-compose.yml:compose.proxy.yml:$EXTERNAL_DB_FILE" "$@" docker compose config --format json
}
ext="$(ext_config SDLC_DATABASE_URL="$ext_url")"
check "[external] compose takes the overlay" [ -n "$ext" ]
check "[external] no postgres service" [ "$(jq -r '.services | has("postgres")' <<<"$ext")" = false ]
check "[external] no pgdata volume" [ "$(jq -r '.volumes // {} | has("pgdata")' <<<"$ext")" = false ]
check "[external] api and worker take SDLC_DATABASE_URL of .env" \
  [ "$(jq -r '[.services.api.environment.SDLC_DATABASE_URL, .services.worker.environment.SDLC_DATABASE_URL] | unique | join(" ")' <<<"$ext")" = "$ext_url" ]
check "[external] api does not wait for postgres (depends_on.required: false)" \
  [ "$(jq -r '.services.api.depends_on.postgres.required' <<<"$ext")" = false ]
check "[external] only caddy publishes ports" \
  [ "$(jq -r '[.services | to_entries[] | select(.value.ports != null) | .key] | join(" ")' <<<"$ext")" = caddy ]
tools="$(ext_config SDLC_DATABASE_URL="$ext_url" COMPOSE_PROFILES=tools)"
check "[external] the backup client is pgvector/pgvector:pg18 with /secrets" \
  [ "$(jq -r '.services["db-client"] | "\(.image) \(.volumes[0].target)"' <<<"$tools")" = "pgvector/pgvector:pg18 /secrets" ]
# The URL may come as a file (CLAB-200): compose then passes an empty URL and
# the path, the service reads the file; with neither it refuses to start,
# and clab server before it.
from_file="$(ext_config SDLC_DATABASE_URL= SDLC_DATABASE_URL_FILE=/secrets/db-url)"
check "[external] without SDLC_DATABASE_URL compose passes SDLC_DATABASE_URL_FILE to api and worker" \
  [ "$(jq -r '[.services.api.environment, .services.worker.environment] | map("\(.SDLC_DATABASE_URL)|\(.SDLC_DATABASE_URL_FILE)") | unique | join(" ")' <<<"$from_file")" = "|/secrets/db-url" ]
bundled="$(POSTGRES_PASSWORD=x CADENCE_VERSION="$version" COMPOSE_FILE=docker-compose.yml:compose.proxy.yml docker compose config --format json)"
check "[bundled] the postgres service stays" [ "$(jq -r '.services | has("postgres")' <<<"$bundled")" = true ]
check "[bundled] SDLC_DATABASE_URL is the postgres container" \
  contains "$(jq -r .services.api.environment.SDLC_DATABASE_URL <<<"$bundled")" "@postgres:5432/"
check "[bundled] no backup client service" [ "$(jq -r '.services | has("db-client")' <<<"$bundled")" = false ]
pool="$(POSTGRES_PASSWORD=x CADENCE_VERSION="$version" COMPOSE_FILE=docker-compose.yml:compose.proxy.yml SDLC_DB_MAX_CONNS=7 SDLC_DB_CONNECT_TIMEOUT=45s docker compose config --format json)"
check "SDLC_DB_MAX_CONNS and SDLC_DB_CONNECT_TIMEOUT of .env reach api and worker" \
  [ "$(jq -r '[.services.api.environment, .services.worker.environment] | map("\(.SDLC_DB_MAX_CONNS)/\(.SDLC_DB_CONNECT_TIMEOUT)") | unique | join(" ")' <<<"$pool")" = "7/45s" ]
check "...and default to 10 and 30s" \
  [ "$(jq -r '"\(.services.api.environment.SDLC_DB_MAX_CONNS)/\(.services.api.environment.SDLC_DB_CONNECT_TIMEOUT)"' <<<"$bundled")" = "10/30s" ]

info "secrets in files (compose.secrets.yml)"
# CLAB-200: every secret X of the table in docs/admin.md ("Secrets in
# files") that compose passes to a service also passes X_FILE there, empty
# by default; compose.secrets.yml turns the password of the bundled database
# and the administrator token into Docker secrets, in both database modes.
secret_rows="$(awk '/^## Secrets in files$/ { on = 1; next } on && /^## / { exit } on && /^\| `/' docs/admin.md)"
check "docs/admin.md has the table of secrets (## Secrets in files)" [ -n "$secret_rows" ]
secrets_config="$(POSTGRES_PASSWORD=x CADENCE_VERSION="$version" COMPOSE_FILE=docker-compose.yml:compose.proxy.yml docker compose config --format json)"
services_with() { jq -r --arg k "$1" '[.services | to_entries[] | select(.value.environment // {} | has($k)) | .key] | sort | join(" ")' <<<"$secrets_config"; }
# shellcheck disable=SC2016 # the backticks of the markdown table
while read -r name; do
  case "$name" in *_FILE | *"<"* | POSTGRES_PASSWORD) continue ;; esac
  [ -n "$(services_with "$name")" ] || continue
  check "$name: docker-compose.yml passes ${name}_FILE: \${${name}_FILE:-}" grep -qF "${name}_FILE: \${${name}_FILE:-}" docker-compose.yml
  check "$name: ${name}_FILE reaches the same services ($(services_with "$name"))" [ "$(services_with "${name}_FILE")" = "$(services_with "$name")" ]
done < <(sed -E 's/^\| `([A-Z0-9_<>]+)`.*/\1/' <<<"$secret_rows")
while read -r v; do
  check ".env.example has the commented example # $v=" grep -qE "^# $v=" .env.example
  check "docs/admin.md lists $v" grep -qF "$v" <<<"$secret_rows"
done < <(grep -oE '^ +[A-Z0-9_]+_FILE: \$\{' docker-compose.yml | sed -E 's/^ +//; s/: .*//' | grep -vx SDLC_GITHUB_APP_KEY_FILE | sort -u)
check "the X_FILE lines are empty by default" \
  [ "$(jq -r '[.services[].environment // {} | to_entries[] | select(.key | endswith("_FILE")) | select(.key != "SDLC_GITHUB_APP_KEY_FILE") | .value] | unique | join(",")' <<<"$secrets_config")" = "" ]
secrets_cfg() {
  env -u CADENCE_REGISTRY -u CADENCE_BACKEND_DIGEST -u CADENCE_FRONTEND_DIGEST POSTGRES_PASSWORD= SDLC_ADMIN_TOKEN= CADENCE_VERSION="$version" "$@" docker compose config --format json
}
sec="$(secrets_cfg COMPOSE_FILE="docker-compose.yml:compose.proxy.yml:$SECRETS_FILE")"
check "[secrets] compose takes compose.secrets.yml" [ -n "$sec" ]
check "[secrets] postgres reads POSTGRES_PASSWORD_FILE of a Docker secret" \
  [ "$(jq -r '"\(.services.postgres.environment.POSTGRES_PASSWORD_FILE) \(.services.postgres.secrets[0].source) \(.secrets.postgres_password.file | sub(".*/"; ""))"' <<<"$sec")" = "/run/secrets/postgres_password postgres_password postgres_password" ]
check "[secrets] POSTGRES_PASSWORD stays empty for postgres" [ "$(jq -r '.services.postgres.environment.POSTGRES_PASSWORD' <<<"$sec")" = "" ]
check "[secrets] api and worker read the same password file (SDLC_DATABASE_PASSWORD_FILE)" \
  [ "$(jq -r '[.services.api.environment.SDLC_DATABASE_PASSWORD_FILE, .services.worker.environment.SDLC_DATABASE_PASSWORD_FILE] | unique | join(" ")' <<<"$sec")" = /secrets/postgres_password ]
check "[secrets] the URL of the bundled database has no password" \
  [ "$(jq -r .services.api.environment.SDLC_DATABASE_URL <<<"$sec")" = "postgres://sdlc:@postgres:5432/sdlc?sslmode=disable" ]
check "[secrets] api reads SDLC_ADMIN_TOKEN_FILE of a Docker secret" \
  [ "$(jq -r '"\(.services.api.environment.SDLC_ADMIN_TOKEN_FILE) \(.services.api.secrets[0].source) \(.services.api.environment.SDLC_ADMIN_TOKEN)"' <<<"$sec")" = "/run/secrets/admin_token admin_token " ]
check "[secrets] the worker has no secret of the administrator token" [ "$(jq -r '.services.worker.secrets // [] | length' <<<"$sec")" = 0 ]
check "[secrets] a value left in .env still reaches api (and stops it, naming both)" \
  [ "$(secrets_cfg SDLC_ADMIN_TOKEN=sdlc_left COMPOSE_FILE="docker-compose.yml:compose.proxy.yml:$SECRETS_FILE" | jq -r .services.api.environment.SDLC_ADMIN_TOKEN)" = sdlc_left ]
for mode in tls proxy; do
  check "[secrets] $mode: compose config is valid" \
    secrets_cfg SDLC_DOMAIN=x.example.com ACME_EMAIL=a@x.example.com COMPOSE_FILE="docker-compose.yml:compose.$mode.yml:$SECRETS_FILE"
done
sec_ext="$(secrets_cfg SDLC_DATABASE_URL= SDLC_DATABASE_URL_FILE=/secrets/db-url COMPOSE_FILE="docker-compose.yml:compose.proxy.yml:$SECRETS_FILE:$EXTERNAL_DB_FILE")"
check "[secrets+external] compose config is valid" [ -n "$sec_ext" ]
check "[secrets+external] no postgres service" [ "$(jq -r '.services | has("postgres")' <<<"$sec_ext")" = false ]
check "[secrets+external] api and worker read the URL file, not the password of the bundled database" \
  [ "$(jq -r '[.services.api.environment, .services.worker.environment] | map("\(.SDLC_DATABASE_URL)|\(.SDLC_DATABASE_URL_FILE)|\(.SDLC_DATABASE_PASSWORD_FILE)") | unique | join(" ")' <<<"$sec_ext")" = "|/secrets/db-url|" ]
check "[secrets+external] the administrator token stays a Docker secret" \
  [ "$(jq -r .services.api.environment.SDLC_ADMIN_TOKEN_FILE <<<"$sec_ext")" = /run/secrets/admin_token ]
check "[secrets+external] a password file of .env reaches api" \
  [ "$(secrets_cfg SDLC_DATABASE_URL="postgres://cadence@db/x" SDLC_DATABASE_PASSWORD_FILE=/secrets/db-password COMPOSE_FILE="docker-compose.yml:compose.proxy.yml:$SECRETS_FILE:$EXTERNAL_DB_FILE" |
    jq -r .services.api.environment.SDLC_DATABASE_PASSWORD_FILE)" = /secrets/db-password ]

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

# The Helm chart (charts/cadence, docs/admin.md "Kubernetes (Helm)"): the
# second way to install, kept in parity with docker-compose.yml. helm of PATH
# (the lint job installs a pinned one), else the image alpine/helm; YAML is
# read with the image mikefarah/yq. In the cluster: ci/check-helm.sh.
info "Helm chart (charts/cadence)"
helm_run() {
  if command -v helm >/dev/null; then
    helm "$@"
  else
    docker run --rm -v "$PWD:$PWD" -v "$dist:$dist" -w "$PWD" alpine/helm:3.19.0 "$@"
  fi
}
yaml_json() { docker run --rm -i mikefarah/yq:4.47.1 -o=json -I=0 '.'; }
chart=charts/cadence
for f in Chart.yaml values.yaml templates/_helpers.tpl templates/api.yaml templates/worker.yaml templates/ui.yaml \
  templates/ingress.yaml templates/dbcheck-job.yaml templates/NOTES.txt; do
  check "$chart/$f exists" [ -f "$chart/$f" ]
done
check "Chart.yaml: version ${version#v}, appVersion $version (VERSION)" [ "$(chart_version_of)" = "${version#v} $version" ]
values_json="$(yaml_json <"$CHART_VALUES")"
# The example of docs/admin.md is what an administrator starts from.
example="$(awk '/^# cadence-values.yaml$/ { on = 1 } on && /^```$/ { exit } on' docs/admin.md)"
check "docs/admin.md has the example values (# cadence-values.yaml)" [ -n "$example" ]
printf '%s\n' "$example" >"$dist/example-values.yaml"
if lint_out="$(helm_run lint "$chart" -f "$dist/example-values.yaml" 2>&1)"; then
  pass "helm lint with the example of docs/admin.md"
else
  fail "helm lint with the example of docs/admin.md"
  printf '%s\n' "$lint_out" >&2
fi
render_json() { helm_run template cadence "$chart" "$@" | yaml_json | jq -s -c '[.[] | select(. != null)]'; }
example_json="$(render_json -f "$dist/example-values.yaml" 2>/dev/null || true)"
check "helm template with the example of docs/admin.md" [ -n "$example_json" -a "$example_json" != "[]" ]

# The smallest values the chart takes: the URL of the database in a Secret,
# the bucket and its keys, the administrator token, the host.
cat >"$dist/min-values.yaml" <<'EOF'
ingress: {host: cadence.example.com}
blobs: {s3: {bucket: check-bucket}}
secrets:
  name: cadence
  keys:
    SDLC_DATABASE_URL: db-url
    SDLC_ADMIN_TOKEN: admin-token
    SDLC_BLOB_S3_ACCESS_KEY_ID: s3-key-id
    SDLC_BLOB_S3_SECRET_ACCESS_KEY: s3-secret-key
EOF
min_json="$(render_json -f "$dist/min-values.yaml")"

# Required values: the rendering stops and names the key.
refused() {
  local want="$1" out
  shift
  if out="$(helm_run template cadence "$chart" -f "$dist/min-values.yaml" "$@" 2>&1)"; then return 1; fi
  grep -qF -- "$want" <<<"$out" && ! grep -qF 'nil pointer' <<<"$out"
}
check "no host: refused, naming ingress.host" refused "ingress.host is required" --set ingress.host=
check "no database: refused, naming secrets.keys.SDLC_DATABASE_URL and database.url" refused \
  "secrets.keys.SDLC_DATABASE_URL (the key of the Secret with the URL), or database.url" --set secrets.keys.SDLC_DATABASE_URL=
check "database.url without the password key: refused, naming secrets.keys.SDLC_DATABASE_PASSWORD" refused \
  "database.url needs secrets.keys.SDLC_DATABASE_PASSWORD" --set secrets.keys.SDLC_DATABASE_URL= --set database.url=postgres://cadence@db/cadence
check "database.url with a password: refused" refused "database.url has a password" \
  --set secrets.keys.SDLC_DATABASE_URL= --set secrets.keys.SDLC_DATABASE_PASSWORD=p --set 'database.url=postgres://cadence:pw@db/cadence'
check "no bucket: refused, naming blobs.s3.bucket" refused "blobs.s3.bucket is required" --set blobs.s3.bucket=
for k in SDLC_BLOB_S3_ACCESS_KEY_ID SDLC_BLOB_S3_SECRET_ACCESS_KEY SDLC_ADMIN_TOKEN; do
  check "no secrets.keys.$k: refused, naming it" refused "secrets.keys.$k is required" --set "secrets.keys.$k="
done
check "an unknown key of secrets.keys: refused" refused "secrets.keys.SDLC_NO_SUCH: no such secret" --set secrets.keys.SDLC_NO_SUCH=x
check "a secret as a value of config: refused" refused "SDLC_GITHUB_TOKEN is a secret" --set config.shared.SDLC_GITHUB_TOKEN=x
check "the headers of traces as a value of config.api: refused" refused "OTEL_EXPORTER_OTLP_HEADERS is a secret" \
  --set config.api.OTEL_EXPORTER_OTLP_HEADERS=x
check "the per-signal headers of traces in extraEnv: refused" refused "extraEnv: OTEL_EXPORTER_OTLP_TRACES_HEADERS is a variable of the chart or a secret" \
  --set 'extraEnv[0].name=OTEL_EXPORTER_OTLP_TRACES_HEADERS' --set 'extraEnv[0].value=x'
check "a value fixed by the chart in config: refused" refused "SDLC_TENANCY is set by the chart" --set config.api.SDLC_TENANCY=shared

# A section left null in the values (`database:` with nothing under it, or
# --set database=null) drops its defaults: what it lacks is refused by the
# name of the key, never a nil pointer, and what it may lack renders.
printf 'database:\n' >"$dist/null-database.yaml"
no_db_url=(--set secrets.keys.SDLC_DATABASE_URL=)
check "database: null and no URL in secrets.keys: refused, naming both keys" refused \
  "secrets.keys.SDLC_DATABASE_URL (the key of the Secret with the URL), or database.url" --set database=null "${no_db_url[@]}"
check "...the same with database: empty in a values file" refused \
  "secrets.keys.SDLC_DATABASE_URL (the key of the Secret with the URL), or database.url" -f "$dist/null-database.yaml" "${no_db_url[@]}"
check "ingress: null: refused, naming ingress.host" refused "ingress.host is required" --set ingress=null
check "blobs: null: refused, naming blobs.s3.bucket" refused "blobs.s3.bucket is required" --set blobs=null
check "blobs.s3: null: refused, naming blobs.s3.bucket" refused "blobs.s3.bucket is required" --set blobs.s3=null
check "secrets: null: refused, naming secrets.keys.SDLC_DATABASE_URL" refused "the database is required: secrets.keys.SDLC_DATABASE_URL" --set secrets=null
check "secrets.keys: null: refused, naming secrets.keys.SDLC_DATABASE_URL" refused "the database is required: secrets.keys.SDLC_DATABASE_URL" --set secrets.keys=null
check "image: null: refused, naming image.registry" refused "image.registry is required" --set image=null
for side in backend frontend; do
  check "image.$side: null: refused, naming image.$side.repository" refused "image.$side.repository is required" --set "image.$side=null"
done
# api and worker: the URL by its file, SDLC_DATABASE_URL empty; the precheck the same.
db_from_secret() {
  local json
  json="$(render_json -f "$dist/min-values.yaml" "$@")" || return 1
  [ "$(jq -r '[.[] | select(.kind == "Deployment" or .kind == "Job") | .spec.template.spec.containers[0].env // [] | map({(.name): .value}) | add // {}
    | select(has("SDLC_DATABASE_URL")) | "\(.SDLC_DATABASE_URL)|\(.SDLC_DATABASE_URL_FILE)"] | unique | join(" ")' <<<"$json")" = "|/secrets/cadence/db-url" ]
}
check "database: null with the URL in secrets.keys.SDLC_DATABASE_URL renders: SDLC_DATABASE_URL_FILE, SDLC_DATABASE_URL empty" \
  db_from_secret --set database=null
check "...the same with database: empty in a values file" db_from_secret -f "$dist/null-database.yaml"
check "ingress.tls: null renders, the Ingress without TLS" \
  [ "$(render_json -f "$dist/min-values.yaml" --set ingress.tls=null | jq -r '.[] | select(.kind == "Ingress") | "\(.spec.rules[0].host) \(.spec.tls)"')" = "cadence.example.com null" ]

# What the chart installs: three Deployments, their Services, one Ingress,
# the hook of the precheck; no database, no Caddy, no volume claims.
kinds="$(jq -r '[.[] | "\(.kind)/\(.metadata.name)"] | sort | join(" ")' <<<"$min_json")"
check "the chart renders: $kinds" [ "$kinds" = "Deployment/cadence-api Deployment/cadence-ui Deployment/cadence-worker Ingress/cadence Job/cadence-dbcheck Service/cadence-api Service/cadence-ui Service/cadence-worker-metrics ServiceAccount/cadence" ]
images_of() { jq -r '[.[] | .spec.template.spec // empty | (.containers + (.initContainers // []))[] | .image] | unique | join(" ")' <<<"$1"; }
check "no image of postgres, pgvector or caddy" lacks "$(images_of "$min_json")" "postgres"
check "...nor of caddy" lacks "$(images_of "$min_json")" "caddy:"
routes="$(jq -r '.[] | select(.kind == "Ingress") | .spec.rules[0].http.paths[] | "\(.path) \(.pathType) \(.backend.service.name):\(.backend.service.port.name)"' <<<"$min_json" | tr '\n' ',')"
check "the Ingress routes as the Caddyfile: $routes" \
  [ "$routes" = "/v1 Prefix cadence-api:http,/mcp Prefix cadence-api:http,/webhooks Prefix cadence-api:http,/healthz Exact cadence-api:http,/readyz Exact cadence-api:http,/ Prefix cadence-ui:http," ]
check "the Ingress routes no metrics port" lacks "$(jq -c '.[] | select(.kind == "Ingress")' <<<"$min_json")" "metrics"
check "the Services are ClusterIP" [ "$(jq -r '[.[] | select(.kind == "Service") | .spec.type] | unique | join(" ")' <<<"$min_json")" = ClusterIP ]

# The images: the tag of VERSION and the pins of docker-compose.yml.
for image in $PIN_IMAGES; do
  check "values.yaml pins $image to the pin of docker-compose.yml" [ "$(chart_pin_of "$image" || true)" = "$(pin_of "$image" || true)" ]
done
check "api, worker, init container and hook: the backend image of VERSION by digest; ui: the frontend one" \
  [ "$(images_of "$min_json")" = "ghcr.io/cadence-lab-tech/sdlc-pipeline-backend:$version@$backend_pin ghcr.io/cadence-lab-tech/sdlc-pipeline-frontend:$version@$frontend_pin" ]
check "image.registry changes only the prefix" \
  [ "$(images_of "$(render_json -f "$dist/min-values.yaml" --set image.registry=mirror.example.com/cadence)")" = "mirror.example.com/cadence/sdlc-pipeline-backend:$version@$backend_pin mirror.example.com/cadence/sdlc-pipeline-frontend:$version@$frontend_pin" ]
check "empty digests drop the pin" \
  [ "$(images_of "$(render_json -f "$dist/min-values.yaml" --set image.backend.digest= --set image.frontend.digest=)")" = "ghcr.io/cadence-lab-tech/sdlc-pipeline-backend:$version ghcr.io/cadence-lab-tech/sdlc-pipeline-frontend:$version" ]
chart_pin_roundtrip() {
  local f d rc=0
  f="$(mktemp)"
  d="sha256:$(printf '1%.0s' $(seq 64))"
  cp "$CHART_VALUES" "$f"
  { set_chart_pin backend "$d" "$f" && [ "$(chart_pin_of backend "$f")" = "$d" ] && [ "$(chart_pin_of frontend "$f")" = "$frontend_pin" ]; } || rc=1
  rm -f "$f"
  return "$rc"
}
check "set_chart_pin rewrites the backend pin and keeps the frontend one" chart_pin_roundtrip
chart_version_roundtrip() {
  local f rc=0
  f="$(mktemp)"
  cp "$CHART_FILE" "$f"
  { set_chart_version v9.8.7 "$f" && [ "$(chart_version_of "$f")" = "9.8.7 v9.8.7" ]; } || rc=1
  rm -f "$f"
  return "$rc"
}
check "set_chart_version writes version and appVersion" chart_version_roundtrip

# Parity with docker-compose.yml: every variable compose gives api and worker
# is in the container of the chart with the same default, or an exception
# with its reason. A variable added to compose without the chart turns this
# red.
compose_env() {
  local unset=() v
  for v in $(env | grep -oE '^(SDLC|OTEL|POSTGRES)_[A-Z0-9_]*' || true); do unset+=(-u "$v"); done
  env ${unset[@]+"${unset[@]}"} -u CADENCE_REGISTRY POSTGRES_PASSWORD=x CADENCE_VERSION="$version" \
    COMPOSE_FILE=docker-compose.yml:compose.proxy.yml docker compose config --format json |
    jq -c --arg s "$1" '.services[$s].environment'
}
chart_env() { jq -c --arg d "cadence-$2" '.[] | select(.kind == "Deployment" and .metadata.name == $d) | .spec.template.spec.containers[0].env | map({(.name): .value}) | add' <<<"$1"; }
# shellcheck disable=SC2016 # the backticks of the markdown table
secret_values_of_table="$(sed -E 's/^\| `([A-Z0-9_<>]+)`.*/\1/' <<<"$secret_rows" | grep -vE '_FILE$|<' || true)"
for svc in api worker; do
  c_env="$(compose_env "$svc")"
  h_env="$(chart_env "$min_json" "$svc")"
  while IFS= read -r name; do
    [ -n "$name" ] || continue
    c_val="$(jq -r --arg k "$name" '.[$k]' <<<"$c_env")"
    h_has="$(jq -r --arg k "$name" 'has($k)' <<<"$h_env")"
    h_val="$(jq -r --arg k "$name" '.[$k] // ""' <<<"$h_env")"
    if [ "$name" = SDLC_DATABASE_URL ]; then
      # The URL without a password (database.url), as compose passes the URL
      # beside SDLC_DATABASE_PASSWORD_FILE; the URL with one comes as a file.
      if [ "$h_has" = true ]; then pass "[$svc] SDLC_DATABASE_URL: in the chart from database.url, the URL without a password"; else fail "[$svc] SDLC_DATABASE_URL is not in the chart"; fi
    elif grep -qxF -- "$name" <<<"$secret_values_of_table"; then
      if [ "$h_has" = false ]; then pass "[$svc] $name: a secret, only ${name}_FILE in the chart"; else fail "[$svc] $name: a secret has a value in the chart"; fi
    elif [[ "$name" == *_FILE ]]; then
      continue
    elif [ "$name" = SDLC_BLOB_DIR ]; then
      if [ "$h_has" = false ]; then pass "[$svc] SDLC_BLOB_DIR: not in the chart (the pods share no volume, S3 is required)"; else fail "[$svc] SDLC_BLOB_DIR is in the chart"; fi
    elif [ "$name" = SDLC_BLOB_S3_BUCKET ]; then
      # Empty in compose (the volume), required in the chart.
      if [ "$h_has" = true ]; then pass "[$svc] SDLC_BLOB_S3_BUCKET: in the chart from blobs.s3.bucket"; else fail "[$svc] SDLC_BLOB_S3_BUCKET is not in the chart"; fi
    elif [ "$h_has" = false ]; then
      fail "[$svc] $name of docker-compose.yml is not in the chart (charts/cadence/values.yaml config, or an exception of ci/check-config.sh)"
    elif [ "$h_val" = "$c_val" ]; then
      pass "[$svc] $name=$c_val as in docker-compose.yml"
    else
      fail "[$svc] $name is '$h_val' in the chart, '$c_val' in docker-compose.yml"
    fi
  done < <(jq -r 'keys[]' <<<"$c_env")
  # And nothing in the chart that compose does not know, but the path style
  # of the bucket (the default of the service in compose) and the files of
  # secrets.
  extra="$(jq -r --argjson c "$c_env" 'keys[] | select(. as $k | $c | has($k) | not) | select(endswith("_FILE") | not) | select(. != "SDLC_BLOB_S3_PATH_STYLE")' <<<"$h_env" | tr '\n' ' ')"
  check "[$svc] the chart has no variable docker-compose.yml lacks${extra:+: $extra}" [ -z "$extra" ]
done
# The values docker-compose.yml fixes, fixed in the chart too (one line per
# container and variable).
fixed_of() {
  jq -r --arg d "cadence-$1" --arg n "$2" '.[] | select(.kind == "Deployment" and .metadata.name == $d) |
    .spec.template.spec.containers[0].env[] | select(.name == $n) | .value' <<<"$min_json"
}
while read -r svc name want; do
  check "[$svc] $name is $want, as docker-compose.yml fixes it" [ "$(fixed_of "$svc" "$name")" = "$want" ]
done <<'EOF'
api SDLC_ENV production
api SDLC_STRICT_GATES true
api SDLC_MCP_ENABLED true
api SDLC_AUTO_MIGRATE true
api SDLC_TENANCY single
api SDLC_PROJECT_CREATION teams
api SDLC_METRICS_ADDR :9090
worker SDLC_ENV production
worker SDLC_AUTO_MIGRATE false
worker SDLC_METRICS_ADDR :9090
EOF

# Secrets: every X_FILE compose passes is the path of a key in the chart once
# its key is set, and no secret has a value anywhere in a manifest.
all_keys=(--set secrets.keys.SDLC_GITHUB_TOKEN=gh --set secrets.keys.SDLC_GITHUB_APP_KEY_FILE=app-key
  --set secrets.keys.SDLC_GITHUB_APP_CLIENT_SECRET=app-secret --set secrets.keys.SDLC_GITHUB_WEBHOOK_SECRET=other/hook
  --set secrets.keys.SDLC_EMBEDDINGS_API_KEY=emb --set secrets.keys.SDLC_VOYAGE_API_KEY=voyage
  --set secrets.keys.SDLC_BLOB_S3_SESSION_TOKEN=s3-session
  --set secrets.keys.OTEL_EXPORTER_OTLP_HEADERS=otlp-headers --set secrets.keys.OTEL_EXPORTER_OTLP_TRACES_HEADERS=otlp-traces-headers)
all_json="$(render_json -f "$dist/min-values.yaml" "${all_keys[@]}")"
pw_json="$(render_json -f "$dist/min-values.yaml" --set secrets.keys.SDLC_DATABASE_URL= \
  --set database.url=postgres://cadence@db/cadence --set secrets.keys.SDLC_DATABASE_PASSWORD=db-password)"
for svc in api worker; do
  c_files="$(compose_env "$svc" | jq -r 'keys[] | select(endswith("_FILE"))' | grep -vx SDLC_DATABASE_PASSWORD_FILE | sort | tr '\n' ' ')"
  h_files="$(chart_env "$all_json" "$svc" | jq -r 'keys[] | select(endswith("_FILE"))' |
    grep -vx -e SDLC_BLOB_S3_SESSION_TOKEN_FILE -e OTEL_EXPORTER_OTLP_TRACES_HEADERS_FILE | sort | tr '\n' ' ')"
  check "[$svc] with every key set the chart passes the X_FILE of docker-compose.yml: $h_files" [ "$c_files" = "$h_files" ]
  check "[$svc] ...plus SDLC_BLOB_S3_SESSION_TOKEN_FILE (compose.override.yml in compose)" \
    [ "$(chart_env "$all_json" "$svc" | jq -r .SDLC_BLOB_S3_SESSION_TOKEN_FILE)" = /secrets/cadence/s3-session ]
  check "[$svc] the URL without a password: SDLC_DATABASE_PASSWORD_FILE, no SDLC_DATABASE_URL_FILE" \
    [ "$(chart_env "$pw_json" "$svc" | jq -r '"\(.SDLC_DATABASE_PASSWORD_FILE) \(.SDLC_DATABASE_URL_FILE)"')" = "/secrets/cadence/db-password null" ]
done
check "every X_FILE is a path under /secrets/<secret>/<key>, a key of another Secret too" \
  [ "$(chart_env "$all_json" api | jq -r '[to_entries[] | select(.key | endswith("_FILE")) | .value | test("^/secrets/[a-z0-9.-]+/[-._a-zA-Z0-9]+$")] | all')" = true ]
check "...other/hook is the key hook of the Secret other" [ "$(chart_env "$all_json" api | jq -r .SDLC_GITHUB_WEBHOOK_SECRET_FILE)" = /secrets/other/hook ]
check "the worker gets no sign-in or webhook secret" \
  [ "$(chart_env "$all_json" worker | jq -r '[keys[] | select(test("ADMIN_TOKEN|APP_CLIENT_SECRET|WEBHOOK_SECRET"))] | length')" = 0 ]
check "the headers of traces: api gets both files (the per-signal one by compose.override.yml in compose)" \
  [ "$(chart_env "$all_json" api | jq -r '"\(.OTEL_EXPORTER_OTLP_HEADERS_FILE) \(.OTEL_EXPORTER_OTLP_TRACES_HEADERS_FILE)"')" = "/secrets/cadence/otlp-headers /secrets/cadence/otlp-traces-headers" ]
check "...the worker none" \
  [ "$(chart_env "$all_json" worker | jq -r '[keys[] | select(startswith("OTEL_"))] | length')" = 0 ]
check "SDLC_DATABASE_URL of database.url carries no password" \
  [ "$(jq -r '[.[] | .. | objects | select(.name? == "SDLC_DATABASE_URL") | .value] | unique | join(" ")' <<<"$pw_json")" = "postgres://cadence@db/cadence" ]
for name in $secret_values_of_table; do
  case "$name" in POSTGRES_PASSWORD | SDLC_DATABASE_URL) continue ;; esac
  check "no manifest has a value of $name" [ "$(jq -r --arg k "$name" '[.. | objects | select(.name? == $k and has("value"))] | length' <<<"$all_json")" = 0 ]
done
check "the keys are mounted read-only from the Secrets (projected, 0440, fsGroup 65532)" \
  [ "$(jq -r '.[] | select(.metadata.name == "cadence-api" and .kind == "Deployment") | .spec.template.spec | "\(.volumes[0].projected.defaultMode) \(.securityContext.fsGroup) \(.containers[0].volumeMounts[0].readOnly)"' <<<"$all_json")" = "288 65532 true" ]
check "the precheck gets only the database" \
  [ "$(jq -r '.[] | select(.kind == "Job") | [.spec.template.spec.containers[0].env[].name] | sort | join(" ")' <<<"$all_json")" = "SDLC_DATABASE_URL SDLC_DATABASE_URL_FILE" ]
# values.yaml and the example hold references, never values: every entry of
# secrets.keys is empty or a key name, and no other field is a secret.
check "values.yaml: every entry of secrets.keys is empty" [ "$(jq -r '[.secrets.keys[]] | unique | join(",")' <<<"$values_json")" = "" ]
example_values_json="$(yaml_json <"$dist/example-values.yaml")"
check "the example: secrets.keys are key names" \
  [ "$(jq -r '[.secrets.keys // {} | .[] | test("^([a-z0-9.-]+/)?[-._a-zA-Z0-9]+$")] | all' <<<"$example_values_json")" = true ]
check "the example has no other field of a password, token or secret key" \
  [ -z "$(jq -r 'paths(scalars) | map(tostring) | join(".") | select(test("password|token|secret"; "i")) | select(startswith("secrets.") or . == "ingress.tls.secretName" | not)' <<<"$example_values_json")" ]

# Pod Security: every pod - restricted, ui included since CLAB-236 (the
# frontend image runs as uid 65532 from v0.14.0).
sc="$(jq -r '[.[] | select(.kind == "Deployment" or .kind == "Job") | .spec.template.spec as $p |
  ($p.containers + ($p.initContainers // []))[] | "\($p.securityContext.runAsNonRoot) \($p.securityContext.runAsUser) \(.securityContext.runAsNonRoot) \(.securityContext.runAsUser) \(.securityContext.readOnlyRootFilesystem) \(.securityContext.allowPrivilegeEscalation) \(.securityContext.capabilities.drop | join(",")) \(.securityContext.seccompProfile.type)"] | unique | join("|")' <<<"$min_json")"
check "api, worker, wait-for-api, dbcheck and ui: non-root 65532, read-only root, no escalation, drop ALL, RuntimeDefault" \
  [ "$sc" = "true 65532 true 65532 true false ALL RuntimeDefault" ]
check "every pod has seccomp RuntimeDefault and fsGroup 65532" \
  [ "$(jq -r '[.[] | select(.kind == "Deployment" or .kind == "Job") | .spec.template.spec.securityContext | "\(.seccompProfile.type) \(.fsGroup)"] | unique | join("|")' <<<"$min_json")" = "RuntimeDefault 65532" ]
# The one capability restricted lets a container add: NET_BIND_SERVICE, and
# only ui has it (the file capability of its Caddy binary needs it in the
# bounding set, or exec fails).
check "added capabilities: NET_BIND_SERVICE of ui and nothing else" \
  [ "$(jq -r '[.[] | select(.kind == "Deployment" or .kind == "Job") | .metadata.name as $n | .spec.template.spec as $p |
    ($p.containers + ($p.initContainers // []))[] | (.securityContext.capabilities.add // [])[] | "\($n):\(.)"] | join(",")' <<<"$min_json")" = "cadence-ui:NET_BIND_SERVICE" ]
ui_spec="$(jq -c '.[] | select(.kind == "Deployment" and .metadata.name == "cadence-ui") | .spec.template.spec' <<<"$min_json")"
check "ui: Caddy on :8080 only (CADENCE_UI_ADDRESS), the port http is 8080" \
  [ "$(jq -r '.containers[0] | "\([.env[] | select(.name == "CADENCE_UI_ADDRESS") | .value] | join(",")) \([.ports[] | "\(.name)=\(.containerPort)"] | join(","))"' <<<"$ui_spec")" = ":8080 http=8080" ]
check "ui: readiness and liveness on the port http" \
  [ "$(jq -r '.containers[0] | "\(.readinessProbe.httpGet.port) \(.livenessProbe.httpGet.port)"' <<<"$ui_spec")" = "http http" ]
check "ui: emptyDir on /data and /config" \
  [ "$(jq -r '. as $s | [.containers[0].volumeMounts[] | .name as $v | "\(.mountPath):\([$s.volumes[] | select(.name == $v) | has("emptyDir")] | first)"] | join(",")' <<<"$ui_spec")" = "/data:true,/config:true" ]
check "Service cadence-ui: port 80 to the port http" \
  [ "$(jq -r '.[] | select(.kind == "Service" and .metadata.name == "cadence-ui") | [.spec.ports[] | "\(.port)->\(.targetPort)"] | join(",")' <<<"$min_json")" = "80->http" ]
check "templates/ui.yaml no longer says the image runs as root" lacks "$(cat charts/cadence/templates/ui.yaml)" "runs as root"
check "every pod mounts no service account token" \
  [ "$(jq -r '[.[] | .spec.template.spec // empty | .automountServiceAccountToken] | unique | join(",")' <<<"$min_json")" = false ]
check "api and worker are Recreate" \
  [ "$(jq -r '[.[] | select(.kind == "Deployment" and (.metadata.name | test("api|worker"))) | .spec.strategy.type] | unique | join(",")' <<<"$min_json")" = Recreate ]
probes="$(jq -r '.[] | select(.metadata.name == "cadence-api" and .kind == "Deployment") | .spec.template.spec.containers[0] | "\(.startupProbe.httpGet.path) \(.readinessProbe.httpGet.path) \(.livenessProbe.httpGet.path)"' <<<"$min_json")"
check "api probes: startup and readiness /readyz, liveness /healthz" [ "$probes" = "/readyz /readyz /healthz" ]
check "the worker waits for the API: /api healthcheck on the Service" \
  [ "$(jq -r '.[] | select(.metadata.name == "cadence-worker" and .kind == "Deployment") | .spec.template.spec.initContainers[0] | "\(.command | join(" ")) \(.env[0].value)"' <<<"$min_json")" = "/api healthcheck cadence-api:8080" ]
check "the precheck is a pre-install,pre-upgrade hook with /api dbcheck --install" \
  [ "$(jq -r '.[] | select(.kind == "Job") | "\(.metadata.annotations["helm.sh/hook"]) \(.spec.template.spec.containers[0].args | join(" "))"' <<<"$min_json")" = "pre-install,pre-upgrade dbcheck --install --timeout 15s" ]
check "metrics.enabled=false: no listener, no metrics port" \
  [ "$(render_json -f "$dist/min-values.yaml" --set metrics.enabled=false | jq -r '[.. | objects | select(.name? == "SDLC_METRICS_ADDR") | .value] + [.. | objects | select(.name? == "metrics") | .name] | unique | join(",")')" = "" ]

# Every key of the values docs/admin.md names is a key of values.yaml.
k8s_doc="$(awk '/^## Kubernetes \(Helm\)$/ { on = 1; next } on && /^## / { exit } on' docs/admin.md)"
check "docs/admin.md has the section ## Kubernetes (Helm)" [ -n "$k8s_doc" ]
value_paths="$(jq -r 'paths | map(tostring) | join(".")' <<<"$values_json")"
documented=0
# shellcheck disable=SC2016 # the backticks of markdown
while read -r key; do
  documented=$((documented + 1))
  check "docs/admin.md names $key: a key of values.yaml" grep -qxF -- "$key" <<<"$value_paths"
done < <(grep -oE '`(image|imagePullSecrets|ingress|database|blobs|secrets|config|extraEnv|metrics|api|worker|ui|dbcheck|serviceAccount)(\.[A-Za-z0-9_]+)+`' <<<"$k8s_doc" | tr -d '`' | sort -u)
check "docs/admin.md names keys of values.yaml" [ "$documented" -gt 0 ]
# CLAB-236: the namespace enforces restricted, the UI included.
check "docs/admin.md labels the namespace enforce=restricted" contains "$k8s_doc" "kubectl label namespace cadence pod-security.kubernetes.io/enforce=restricted"
check "docs/admin.md no longer labels it enforce=baseline" lacks "$k8s_doc" "enforce=baseline"
check "docs/admin.md no longer says the UI needs baseline" lacks "$k8s_doc" "The UI needs"
check "docs/admin.md no longer says the chart is coming" lacks "$(cat docs/admin.md)" "coming in a later"
check "README.md names the Helm chart" grep -qF "charts/cadence" README.md

[ "$failures" -eq 0 ] || die "$failures check(s) failed"
ok "configuration checks passed"
