#!/usr/bin/env bash
#
# Upgrade check between two released versions of the package:
#
#   ci/check-upgrade.sh v0.5.0 v0.5.1
#
# Installs the stack at tag FROM (proxy mode), creates a team, a project and
# a project document, runs ./upgrade.sh TO, and checks that the backup was
# taken, the instance reports TO and the data is still there. Then checks that
# going back down is refused. Both tags must exist in the remote, with their
# images published. The stack is torn down with its volumes at the end.
#
#   CHECK_HTTP_PORT  host port of the stack, default 8080
#   CLAB_BIN         clab to use; default: the CLI of FROM from the public tap
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=lib.sh
. ./lib.sh

# Everything runs from main(): checking out FROM and upgrading to TO replace
# this file while it runs.
main() {
  local from="${1:-}" to="${2:-}"
  if ! valid_version "$from" || ! valid_version "$to"; then
    die "usage: ci/check-upgrade.sh vFROM vTO"
  fi
  version_lt "$from" "$to" || die "$from must be older than $to"
  [ ! -e .env ] || die "refusing to run next to an existing .env"
  git diff --quiet HEAD -- || die "tracked files are modified"

  # Globals: the EXIT trap runs after main() has returned.
  local port base failures=0 clab admin_token
  start_ref="$(git rev-parse HEAD)"
  port="${CHECK_HTTP_PORT:-8080}"
  base="http://127.0.0.1:$port"
  clab_dir="$(mktemp -d)"

  pass() { printf '  ✓ %s\n' "$*"; }
  fail() {
    printf '  ✗ %s\n' "$*" >&2
    failures=$((failures + 1))
  }
  # shellcheck disable=SC2317,SC2329 # invoked by the EXIT trap
  cleanup() {
    if [ -f .env ]; then
      info "tearing the stack down"
      CADENCE_VERSION="$(tr -d '[:space:]' <VERSION)" docker compose down -v --remove-orphans >/dev/null 2>&1 || true
      rm -f .env
    fi
    rm -rf backups/cadence-* "$clab_dir"
    git -c advice.detachedHead=false checkout --quiet "$start_ref" || true
  }
  trap cleanup EXIT

  git fetch --quiet --tags "${CADENCE_GIT_REMOTE:-origin}"
  info "installing $from"
  git -c advice.detachedHead=false checkout --quiet "refs/tags/$from"
  admin_token="sdlc_$(openssl rand -hex 24)"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::add-mask::$admin_token"; fi
  SDLC_ADMIN_TOKEN="$admin_token" ./install.sh --mode proxy --http-addr "127.0.0.1:$port" --yes </dev/null

  clab="${CLAB_BIN:-}"
  if [ -z "$clab" ]; then
    curl -fsSL https://raw.githubusercontent.com/cadence-lab-tech/homebrew-tap/main/install.sh |
      CLAB_VERSION="$from" CLAB_INSTALL_DIR="$clab_dir/bin" sh
    clab="$clab_dir/bin/clab"
  fi
  export CLAB_CONFIG_DIR="$clab_dir/config"
  printf '%s\n' "$admin_token" | "$clab" auth login --host "$base" --with-token >/dev/null

  info "data on $from"
  printf 'Written on %s before the upgrade.\n' "$from" >"$clab_dir/doc.md"
  "$clab" --host "$base" team create upgrade --name "Upgrade check" >/dev/null
  "$clab" --host "$base" project create UPG --name "Upgrade check" --team upgrade >/dev/null
  SDLC_PROJECT=UPG "$clab" --host "$base" doc put --kind guideline --title "Upgrade check" --file "$clab_dir/doc.md" >/dev/null

  info "./upgrade.sh $to"
  ./upgrade.sh "$to"

  if [ -n "$(find backups -maxdepth 1 -name "cadence-$from-*.sql.gz")" ]; then
    pass "a backup of $from was taken before the upgrade"
  else
    fail "no backups/cadence-$from-*.sql.gz after the upgrade"
  fi
  if curl -sf "$base/v1/instance" | grep -qF "\"version\":\"$to\""; then
    pass "/v1/instance reports $to"
  else
    fail "/v1/instance does not report $to"
  fi
  if "$clab" --host "$base" project list --json | grep -qF '"UPG"'; then
    pass "the project created on $from is there"
  else
    fail "the project created on $from is gone"
  fi
  if SDLC_PROJECT=UPG "$clab" --host "$base" doc list --json | grep -qF "Upgrade check"; then
    pass "the document created on $from is there"
  else
    fail "the document created on $from is gone"
  fi

  info "./upgrade.sh $from must refuse"
  if ./upgrade.sh "$from" >/dev/null 2>&1; then
    fail "upgrade.sh $from after $to did not refuse the downgrade"
  else
    pass "upgrade.sh refuses to go down to $from"
  fi

  if [ "$failures" -gt 0 ]; then
    docker compose ps || true
    die "$failures check(s) failed"
  fi
  ok "upgrade $from -> $to passed"
}

main "$@"
exit $?
