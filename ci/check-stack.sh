#!/usr/bin/env bash
#
# End-to-end check of the package on the images of VERSION: installs the
# stack in proxy mode, exercises it the way an administrator and an agent
# would, backs it up, restores it, and tears it down. CI runs it on every pull
# request; it runs the same way on any Linux machine with Docker.
#
#   ci/check-stack.sh
#
#   CHECK_HTTP_PORT  host port of the stack, default 8080
#   CLAB_BIN         clab to use; default: install the CLI of VERSION from the
#                    public tap (the path docs/admin.md describes)
#   CHECK_KEEP=1     leave the stack running after the check
#
# The stack is torn down with its volumes at the end: run it in a scratch
# clone or set COMPOSE_PROJECT_NAME, never next to a production instance.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=lib.sh
. ./lib.sh

[ ! -e .env ] || die "ci/check-stack.sh installs a fresh stack and deletes it afterwards: refusing to run next to an existing .env"

port="${CHECK_HTTP_PORT:-8080}"
base="http://127.0.0.1:$port"
version="$(tr -d '[:space:]' <VERSION)"
failures=0

pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  failures=$((failures + 1))
}
check() {
  local what="$1"
  shift
  if "$@" >/dev/null; then pass "$what"; else fail "$what"; fi
}
http_code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
# contains TEXT PATTERN / lacks TEXT PATTERN: a fixed string in a response.
contains() { grep -qF -- "$2" <<<"$1"; }
lacks() { ! grep -qF -- "$2" <<<"$1"; }
html() { curl -sf "$base/" | grep -qi '<html'; }
client_error() { [ "$1" -ge 400 ] && [ "$1" -lt 500 ]; }

cleanup() {
  if [ "${CHECK_KEEP:-}" != 1 ] && [ -f .env ]; then
    info "tearing the stack down"
    export CADENCE_VERSION="$version"
    docker compose down -v --remove-orphans >/dev/null 2>&1 || true
    rm -f .env
    rm -rf backups/cadence-* "${clab_dir:-}"
  fi
}
trap cleanup EXIT

# A token known in advance, so CI can mask it before anything prints it.
admin_token="sdlc_$(openssl rand -hex 24)"
if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::add-mask::$admin_token"; fi
auth=(-H "Authorization: Bearer $admin_token")

# --- install ---------------------------------------------------------------------
info "install.sh --mode proxy on 127.0.0.1:$port"
SDLC_ADMIN_TOKEN="$admin_token" ./install.sh --mode proxy --http-addr "127.0.0.1:$port" --yes </dev/null

check ".env has mode 600" [ "$(stat -c %a .env 2>/dev/null || stat -f %Lp .env)" = 600 ]
secrets_distinct() {
  local pg admin hook
  pg="$(grep '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)"
  admin="$(grep '^SDLC_ADMIN_TOKEN=' .env | cut -d= -f2-)"
  hook="$(grep '^SDLC_GITHUB_WEBHOOK_SECRET=' .env | cut -d= -f2-)"
  [ -n "$pg" ] && [ -n "$admin" ] && [ -n "$hook" ] && [ "$pg" != "$admin" ] && [ "$pg" != "$hook" ] && [ "$admin" != "$hook" ]
}
check "secrets in .env are set and distinct" secrets_distinct

before="$(sha256sum .env 2>/dev/null || shasum -a 256 .env)"
if ./install.sh --mode proxy --http-addr "127.0.0.1:$port" --yes </dev/null >/dev/null 2>&1; then
  fail "a second install.sh must refuse to run"
else
  pass "a second install.sh refuses to run"
fi
check "a second install.sh leaves .env untouched" [ "$before" = "$(sha256sum .env 2>/dev/null || shasum -a 256 .env)" ]

load_env

# --- proxy mode and routing ----------------------------------------------------------
info "proxy mode"
check "/readyz answers 200" [ "$(http_code "$base/readyz")" = 200 ]
check "/healthz answers 200" [ "$(http_code "$base/healthz")" = 200 ]
check "/ serves the UI" html
webhook_code="$(http_code -X POST -H 'X-GitHub-Event: ping' -d '{}' "$base/webhooks/github")"
check "/webhooks/github reaches the API and rejects an unsigned delivery ($webhook_code)" client_error "$webhook_code"
check "caddy does not try ACME in proxy mode" lacks "$(docker compose logs caddy 2>&1 | tr '[:upper:]' '[:lower:]')" acme

info "tls mode configuration"
tls_json="$(docker compose run --rm --no-deps -T -e CADENCE_MODE=tls -e SDLC_DOMAIN=cadence.example.com \
  -e ACME_EMAIL=ops@example.com caddy caddy adapt --config /etc/caddy/Caddyfile 2>/dev/null)"
check "tls mode listens on :443" contains "$tls_json" '":443"'
check "tls mode serves the domain" contains "$tls_json" '"cadence.example.com"'
check "tls mode issues the certificate with ACME" contains "$tls_json" '"module":"acme"'
check "MCP is proxied without buffering" contains "$tls_json" '"flush_interval":-1'

# --- instance ------------------------------------------------------------------------------
info "instance"
instance="$(curl -sf "$base/v1/instance")"
check "/v1/instance reports version $version" contains "$instance" "\"version\":\"$version\""
check "/v1/instance reports tenancy single" contains "$instance" '"tenancy":"single"'
check "/v1/instance reports project_creation teams" contains "$instance" '"project_creation":"teams"'
me="$(curl -sf "${auth[@]}" "$base/v1/auth/me" || true)"
check "the administrator token signs in (is_admin)" contains "$me" '"is_admin":true'

# --- CLI ---------------------------------------------------------------------------------------
info "clab"
clab="${CLAB_BIN:-}"
clab_dir="$(mktemp -d)"
if [ -z "$clab" ]; then
  curl -fsSL https://raw.githubusercontent.com/cadence-lab-tech/homebrew-tap/main/install.sh |
    CLAB_VERSION="$version" CLAB_INSTALL_DIR="$clab_dir/bin" sh
  clab="$clab_dir/bin/clab"
fi
export CLAB_CONFIG_DIR="$clab_dir/config"
printf '%s\n' "$admin_token" | "$clab" auth login --host "$base" --with-token
check "clab version" "$clab" --host "$base" version
check "clab team create" "$clab" --host "$base" team create check --name "Package check"
check "clab project create --team" "$clab" --host "$base" project create CHECK --name "Package check" --team check

mcp="$(curl -s "${auth[@]}" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"tools/list"}' "$base/mcp/projects/CHECK")"
check "MCP tools/list on /mcp/projects/CHECK lists sdlc_claim_task" contains "$mcp" '"sdlc_claim_task"'

# --- first cycle and roles: the starter bundle (docs/admin.md, "First cycle and roles") ------
info "starter bundle"
if "$clab" --host "$base" token create --project CHECK --name before-bundle --for agent:check-bot --roles developer >/dev/null 2>&1; then
  fail "a token with --roles on a project without roles must be refused"
else
  pass "a token with --roles on a project without roles is refused"
fi
check "clab import --dry-run reports the bundle" "$clab" --host "$base" import --project CHECK --file bundles/starter.json --dry-run
check "clab import applies the bundle" "$clab" --host "$base" import --project CHECK --file bundles/starter.json
roles="$("$clab" --host "$base" role show analyst --project CHECK --json 2>/dev/null || true)"
check "the project has the analyst role" contains "$roles" '"analyst"'
drafts="$("$clab" --host "$base" workflow list --project CHECK --json |
  jq -r '(if type == "array" then . else (.workflows // .items) end)[] | select(.state == "draft") | .id')"
check "the bundle brings two draft cycles (tasks and epics)" [ "$(grep -c . <<<"$drafts")" = 2 ]
for id in $drafts; do
  check "clab workflow activate $id" "$clab" --host "$base" workflow activate "$id" --project CHECK
done
active="$("$clab" --host "$base" workflow list --project CHECK --json |
  jq -r '(if type == "array" then . else (.workflows // .items) end)[] | select(.state == "active") | .task_types[]' | sort | tr '\n' ' ')"
check "active cycles cover task and epic ($active)" [ "$active" = "epic task " ]
# Roles are idempotent; cycles come back as new drafts on every import (CLAB-108).
again="$("$clab" --host "$base" import --project CHECK --file bundles/starter.json --json)"
check "a second import leaves the roles unchanged" [ "$(jq -r '[.roles[].outcome] | unique | join(",")' <<<"$again")" = unchanged ]
check "a second import does not touch the active cycles" [ "$(jq -r '[.workflows[].outcome] | unique | join(",")' <<<"$again")" = draft_created ]

info "first task"
check "clab create a task" "$clab" --host "$base" create --project CHECK --title "First task"
check "clab create an epic" "$clab" --host "$base" create --project CHECK --title "First epic" --type epic
check "clab transition start" env SDLC_PROJECT=CHECK "$clab" --host "$base" transition CHECK-1 --to start
agent_token="$("$clab" --host "$base" token create --project CHECK --name check-agent --for agent:check-bot --roles analyst --json | jq -r .token)"
if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::add-mask::$agent_token"; fi
check "a token with --roles analyst is issued" [ "${agent_token#sdlc_}" != "$agent_token" ]
queue="$(env SDLC_API_URL="$base" SDLC_TOKEN="$agent_token" SDLC_PROJECT=CHECK "$clab" queue --json)"
check "the agent sees CHECK-1 in its queue" contains "$queue" '"CHECK-1"'
check "the agent claims CHECK-1 as analyst" env SDLC_API_URL="$base" SDLC_TOKEN="$agent_token" SDLC_PROJECT=CHECK "$clab" claim CHECK-1
gates="$(env SDLC_PROJECT=CHECK "$clab" --host "$base" gates CHECK-1 --json)"
check "analysis_done waits for the artifacts and a human approval" contains "$gates" 'human_approval'

# --- backup and restore ----------------------------------------------------------------------------
info "backup.sh"
./backup.sh
dump="$(find backups -maxdepth 1 -name "cadence-$version-*.sql.gz" | sort | tail -n 1)"
check "backup.sh writes cadence-$version-*.sql.gz" [ -n "$dump" ]
check "the dump is larger than 1 KB" [ "$(wc -c <"${dump:-/dev/null}" | tr -d ' ')" -gt 1024 ]
check "the blobs volume is archived next to it" [ -f "${dump%.sql.gz}.blobs.tar.gz" ]

"$clab" --host "$base" project create AFTER --name "Created after the backup" --team check >/dev/null
check "a project created after the backup exists" contains "$("$clab" --host "$base" project list --json)" '"AFTER"'

info "restore.sh"
./restore.sh --yes "$dump"
projects="$("$clab" --host "$base" project list --json)"
check "after restore the project from before the backup is there" contains "$projects" '"CHECK"'
check "after restore the project created after the backup is gone" lacks "$projects" '"AFTER"'
check "/readyz answers 200 after restore" [ "$(http_code "$base/readyz")" = 200 ]

if [ "$failures" -gt 0 ]; then
  docker compose ps || true
  docker compose logs --tail 30 api caddy || true
  die "$failures check(s) failed"
fi
ok "all checks passed on $version"
