#!/usr/bin/env bash
#
# Static checks of the package that need no published images: the compose
# configuration in both modes, the Caddyfile in both modes, the defaults of
# .env.example, the file layout and the release package that ci/package.sh
# builds. CI runs it on every pull request next to the shell linter; it needs
# Docker and jq.
#
#   ci/check-config.sh
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
check() {
  local what="$1"
  shift
  if "$@" >/dev/null 2>&1; then pass "$what"; else fail "$what"; fi
}
contains() { grep -qF -- "$2" <<<"$1"; }
lacks() { ! grep -qF -- "$2" <<<"$1"; }

version="$(tr -d '[:space:]' <VERSION)"

info "layout"
for f in docker-compose.yml compose.tls.yml compose.proxy.yml .env.example Caddyfile README.md docs/admin.md LICENSE VERSION; do
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
  install.sh upgrade.sh backup.sh restore.sh lib.sh bundles/starter.json docs/admin.md README.md LICENSE
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
for kv in SDLC_TENANCY=single SDLC_PROJECT_CREATION=teams SDLC_AUTH_MODE=token SDLC_EMBEDDINGS_PROVIDER=none \
  SDLC_SEED= SDLC_EMBEDDINGS_MODEL= POSTGRES_PASSWORD= SDLC_ADMIN_TOKEN=; do
  check ".env.example sets $kv" grep -qxF "$kv" .env.example
done
check ".env.example sets no image version" lacks "$(grep -v '^#' <<<"$env_example")" "CADENCE_VERSION="

info "compose"
check "compose refuses to run without CADENCE_VERSION" sh -c '! env -u CADENCE_VERSION docker compose config -q'
missing="$(env -u CADENCE_VERSION docker compose config 2>&1 || true)"
check "the error names CADENCE_VERSION" contains "$missing" CADENCE_VERSION

for mode in tls proxy; do
  config="$(POSTGRES_PASSWORD=x CADENCE_VERSION="$version" COMPOSE_FILE="docker-compose.yml:compose.$mode.yml" docker compose config --format json)"
  check "[$mode] backend image is :$version" contains "$config" "\"ghcr.io/cadence-lab-tech/sdlc-pipeline-backend:$version\""
  check "[$mode] frontend image is :$version" contains "$config" "\"ghcr.io/cadence-lab-tech/sdlc-pipeline-frontend:$version\""
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
done

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
done

[ "$failures" -eq 0 ] || die "$failures check(s) failed"
ok "configuration checks passed"
