#!/usr/bin/env bash
#
# End-to-end check of the package on the images of VERSION: builds the
# release package of this checkout (ci/package.sh), installs it the way the
# documentation says - the one-line installer piped into sh (or clab server
# install, see CADENCE_DRIVER), from a local copy of the releases, with git
# out of reach - in proxy mode into a scratch directory, exercises the stack the way an administrator and an agent would,
# backs it up, restores it, and tears it down. CI runs it on every pull
# request; it runs the same way on any Linux machine with Docker.
#
#   ci/check-stack.sh
#
#   CHECK_HTTP_PORT       host port of the stack, default 8080; with the
#                         scripts driver a second installation takes the
#                         next port
#   COMPOSE_PROJECT_NAME  name of the installation (its compose project),
#                         default cadence-check, never cadence; the second
#                         one is NAME-2
#   CLAB_BIN              clab to use; default: install the CLI of VERSION
#                         from the public tap (the path docs/admin.md describes)
#   CHECK_KEEP=1          leave the stack (and its directory) after the check
#   CADENCE_DRIVER        scripts (default) - install with get-cadence.sh,
#                         back up and restore with backup.sh and restore.sh;
#                         clab - install with clab server install (clab
#                         v0.8.0+; an older clab falls back to get-cadence.sh
#                         with a note), back up and restore with clab server
#                         backup and restore of CLAB_BIN (v0.7.0+), plus the
#                         checks of clab server status. The same scenarios
#                         in both prove parity.
#
# The installation name (CLAB-164): install.sh keeps it in .env, so after the
# install every command runs without COMPOSE_PROJECT_NAME, as from cron or a
# new terminal; a second installation under the same name is refused; a
# COMPOSE_PROJECT_NAME of another installation makes backup, restore and
# upgrade refuse; with the scripts driver a second installation runs next to
# the first one and each sees only itself.
#
# Images: docker-compose.yml pins the images of VERSION by digest (ci/pins.sh)
# and the check compares the containers with it. Images of a branch, built
# under the tag of VERSION into a local registry, have other digests: drop
# the pin with empty variables, and the stack pulls them by tag:
#
#   CADENCE_REGISTRY=localhost:5050 CADENCE_BACKEND_DIGEST= CADENCE_FRONTEND_DIGEST= \
#     COMPOSE_PROJECT_NAME=check-<name> CHECK_HTTP_PORT=<port> ci/check-stack.sh
#
# The metrics of api and worker are checked on images of VERSION v0.10.0 or
# later, and on images of a branch (a pin variable set) whatever VERSION is.
#
# The stacks are torn down with their volumes at the end: give them a
# COMPOSE_PROJECT_NAME and a CHECK_HTTP_PORT (and the port after it) of their
# own, never those of a running instance.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=lib.sh
. ./lib.sh

port="${CHECK_HTTP_PORT:-8080}"
driver="${CADENCE_DRIVER:-scripts}"
case "$driver" in
scripts | clab) ;;
*) die "CADENCE_DRIVER is '$driver', expected scripts or clab" ;;
esac
base="http://127.0.0.1:$port"
version="$(tr -d '[:space:]' <VERSION)"
failures=0
export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-cadence-check}"
name="$COMPOSE_PROJECT_NAME"
second_name="$name-2"
second_port=$((port + 1))
# The stacks are torn down with their volumes: never the default name of a
# real installation.
[ "$name" != cadence ] || die "COMPOSE_PROJECT_NAME=cadence is the name of a real installation; the check tears its stacks down - give it a name of its own"
valid_name "$name" || die "COMPOSE_PROJECT_NAME '$name' is not a valid installation name"
repo="$(pwd)"
work="$(mktemp -d)"

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

# fresh DIR CMD...: CMD in DIR as from a new terminal or cron - without
# COMPOSE_PROJECT_NAME and the rest of what this check and load_env exported;
# CADENCE_VERSION only for a direct docker compose.
fresh() {
  local d="$1"
  shift
  (cd "$d" && env -i PATH="$PATH" HOME="$HOME" ${DOCKER_HOST:+DOCKER_HOST="$DOCKER_HOST"} \
    ${DOCKER_CONTEXT:+DOCKER_CONTEXT="$DOCKER_CONTEXT"} CADENCE_VERSION="$version" "$@")
}

cleanup() {
  [ "${CHECK_KEEP:-}" != 1 ] || { info "kept: $work/cadence${second_up:+ and $work/second}"; return; }
  # By the names this check gave, never by what a .env says.
  local d n
  for d in cadence:"$name" second:"$second_name"; do
    n="${d#*:}"
    d="$work/${d%%:*}"
    if [ -f "$d/.env" ]; then
      info "tearing $n down"
      fresh "$d" docker compose -p "$n" down -v --remove-orphans >/dev/null 2>&1 || true
    fi
  done
  # Files of the containers (backups of the blobs volume) may belong to
  # another uid; the stack is gone, so what is left is ours to remove.
  rm -rf "$work" "${clab_dir:-}" 2>/dev/null || true
}
trap cleanup EXIT

# A token known in advance, so CI can mask it before anything prints it.
admin_token="sdlc_$(openssl rand -hex 24)"
if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::add-mask::$admin_token"; fi
auth=(-H "Authorization: Bearer $admin_token")

# --- install ---------------------------------------------------------------------
# The releases as the installer sees them: download/<version>/ and
# latest/download/ (lib.sh, "releases").
info "release package of this checkout"
ci/package.sh "$work/releases/download/$version"
mkdir -p "$work/releases/latest"
cp -R "$work/releases/download/$version" "$work/releases/latest/download"
# git must not be needed: a git that fails and leaves a trace stands first
# in PATH.
mkdir -p "$work/nogit"
printf '#!/bin/sh\necho "git $*" >>"%s/git-calls"\nexit 1\n' "$work" >"$work/nogit/git"
chmod 755 "$work/nogit/git"

# The CLI comes first: with the clab driver it is the installer.
clab="${CLAB_BIN:-}"
clab_dir="$(mktemp -d)"
if [ -z "$clab" ]; then
  curl -fsSL https://raw.githubusercontent.com/cadence-lab-tech/homebrew-tap/main/install.sh |
    CLAB_VERSION="$version" CLAB_INSTALL_DIR="$clab_dir/bin" sh
  clab="$clab_dir/bin/clab"
fi
export CLAB_CONFIG_DIR="$clab_dir/config"
# install_with: how this run installs - clab server install, or the one-line
# installer when the driver is scripts or the clab has no install (before
# v0.8.0).
install_with=scripts
if [ "$driver" = clab ]; then
  if "$clab" server --help 2>/dev/null | grep -qE '^  install '; then
    install_with=clab
  else
    info "clab $("$clab" version 2>/dev/null | head -n 1) has no clab server install (v0.8.0+): installing with get-cadence.sh"
  fi
fi
# clab_install DIR ARGS...: clab server install from the local releases, as
# from a new terminal in $work, with git out of reach.
clab_install() {
  local d="$1"
  shift
  (cd "$work" && PATH="$work/nogit:$PATH" CADENCE_RELEASES_URL="file://$work/releases" \
    "$clab" server install --dir "$d" "$@" </dev/null)
}

if [ "$install_with" = clab ]; then
  info "clab server install --mode proxy --http-addr 127.0.0.1:$port --yes"
  install_out="$(SDLC_ADMIN_TOKEN="$admin_token" clab_install "$work/cadence" --mode proxy --http-addr "127.0.0.1:$port" --yes 2>&1)" ||
    { printf '%s\n' "$install_out" >&2; die "clab server install failed"; }
  printf '%s\n' "$install_out"
  check "clab server install says the stack is up" contains "$install_out" "Cadence Lab $version is up"
  check "clab server install does not print a supplied token" lacks "$install_out" "$admin_token"
  check "...and says it was supplied" contains "$install_out" "the one supplied in SDLC_ADMIN_TOKEN"
  check "clab server install prints the cron line of clab server backup --dir" \
    contains "$install_out" "server backup --dir $work/cadence >> $work/cadence/backups/backup.log 2>&1"
else
  info "get-cadence.sh | sh -s -- --mode proxy --http-addr 127.0.0.1:$port --yes"
  (cd "$work" && PATH="$work/nogit:$PATH" CADENCE_RELEASES_URL="file://$work/releases" SDLC_ADMIN_TOKEN="$admin_token" \
    sh -s -- --mode proxy --http-addr "127.0.0.1:$port" --yes <"$repo/get-cadence.sh")
fi
check "the stack is installed from the package into $work/cadence" [ -f "$work/cadence/.env" ]
check "the installation is not a git clone" [ ! -e "$work/cadence/.git" ]
check "git was never called" [ ! -s "$work/git-calls" ]
check "VERSION of the installation is $version" [ "$(tr -d '[:space:]' <"$work/cadence/VERSION")" = "$version" ]
cd "$work/cadence"

check ".env has mode 600" [ "$(stat -c %a .env 2>/dev/null || stat -f %Lp .env)" = 600 ]
secrets_distinct() {
  local pg admin hook
  pg="$(grep '^POSTGRES_PASSWORD=' .env | cut -d= -f2-)"
  admin="$(grep '^SDLC_ADMIN_TOKEN=' .env | cut -d= -f2-)"
  hook="$(grep '^SDLC_GITHUB_WEBHOOK_SECRET=' .env | cut -d= -f2-)"
  [ -n "$pg" ] && [ -n "$admin" ] && [ -n "$hook" ] && [ "$pg" != "$admin" ] && [ "$pg" != "$hook" ] && [ "$admin" != "$hook" ]
}
check "secrets in .env are set and distinct" secrets_distinct
check "the installation has backups/ (700) and secrets/ (711)" \
  [ "$(stat -c %a backups secrets 2>/dev/null || stat -f %Lp backups secrets)" = "700"$'\n'"711" ]
check "compose.override.yml is there" [ -f compose.override.yml ]

before="$(sha256sum .env 2>/dev/null || shasum -a 256 .env)"
if [ "$install_with" = clab ]; then
  if out="$(clab_install "$work/cadence" --mode proxy --http-addr "127.0.0.1:$port" --yes 2>&1)"; then
    fail "a second clab server install must refuse to run"
  else
    check "a second clab server install refuses to run, pointing at clab server upgrade --dir" \
      contains "$out" "clab server upgrade --dir $work/cadence"
  fi
  check "a second clab server install leaves .env untouched" [ "$before" = "$(sha256sum .env 2>/dev/null || shasum -a 256 .env)" ]
fi
if ./install.sh --mode proxy --http-addr "127.0.0.1:$port" --yes </dev/null >/dev/null 2>&1; then
  fail "a second install.sh must refuse to run"
else
  pass "a second install.sh refuses to run"
fi
check "a second install.sh leaves .env untouched" [ "$before" = "$(sha256sum .env 2>/dev/null || shasum -a 256 .env)" ]

load_env

# --- installation name -------------------------------------------------------------
info "installation name"
check ".env keeps the installation name: COMPOSE_PROJECT_NAME=$name" grep -qxF "COMPOSE_PROJECT_NAME=$name" .env
# From here on nothing carries the name but .env, as in cron or a new
# terminal: before v0.7.1 this export alone kept the commands on this stack.
unset COMPOSE_PROJECT_NAME
# projects_in DIR: the compose projects docker compose sees from DIR.
projects_in() { fresh "$1" docker compose ps -a --format '{{.Project}}' | sort -u | tr '\n' ' '; }
check "docker compose here without the variable sees only $name" [ "$(projects_in "$work/cadence")" = "$name " ]
# started DIR: the containers of DIR with their start times.
started() {
  fresh "$1" docker compose ps -a -q | xargs docker inspect -f '{{.Name}} {{.State.StartedAt}}' | sort
}
started_before="$(started "$work/cadence")"
if [ "$install_with" = clab ]; then
  info "clab server install --dir same-name with COMPOSE_PROJECT_NAME=$name: the name is taken"
  out="$(COMPOSE_PROJECT_NAME="$name" clab_install "$work/same-name" --mode proxy --http-addr "127.0.0.1:$second_port" --yes 2>&1)" && taken_ok=1 || taken_ok=0
else
  info "get-cadence.sh --dir same-name with COMPOSE_PROJECT_NAME=$name: the name is taken"
  out="$(cd "$work" && PATH="$work/nogit:$PATH" CADENCE_RELEASES_URL="file://$work/releases" COMPOSE_PROJECT_NAME="$name" \
    sh -s -- --dir same-name --mode proxy --http-addr "127.0.0.1:$second_port" --yes <"$repo/get-cadence.sh" 2>&1)" && taken_ok=1 || taken_ok=0
fi
if [ "$taken_ok" = 1 ]; then
  fail "a second installation under the name $name must be refused"
else
  check "a second installation under the name $name is refused, naming it and --name" \
    contains "$out" "the installation name '$name' is taken on this machine: the installation in $work/cadence uses it"
  check "...and the refusal suggests --name" contains "$out" "--name $name-2"
fi
check "the refused installation wrote no .env" [ ! -e "$work/same-name/.env" ]
if [ "$install_with" = clab ]; then
  # A free name on the port of the first installation: the port is busy.
  if out="$(clab_install "$work/busy-port" --name "$second_name" --mode proxy --http-addr "127.0.0.1:$port" --yes 2>&1)"; then
    fail "clab server install on the port of the first installation must be refused"
  else
    check "clab server install on the port of the first installation is refused: port $port is in use" \
      contains "$out" "port $port is already in use"
  fi
  check "the refused installation on a busy port wrote no .env" [ ! -e "$work/busy-port/.env" ]
fi
check "the first installation was not touched (same containers, same start times)" [ "$(started "$work/cadence")" = "$started_before" ]

# --- local compose changes -------------------------------------------------------
info "compose.override.yml"
check "COMPOSE_FILE lists compose.override.yml" contains "$COMPOSE_FILE" ":compose.override.yml"
check "check_mode accepts COMPOSE_FILE with the override" bash -c '. ./lib.sh && load_env && check_mode'
cp compose.override.yml "$work/override.orig"
cat >>compose.override.yml <<'YAML'
  api:
    extra_hosts: ["host.docker.internal:host-gateway"]
YAML
sed -i.bak 's/^services: {}$/services:/' compose.override.yml && rm -f compose.override.yml.bak
check "docker compose picks the override up with no edit of .env (extra_hosts of api)" \
  contains "$(docker compose config --format json | jq -c '.services.api.extra_hosts')" "host.docker.internal"
cp "$work/override.orig" compose.override.yml

# --- platform ------------------------------------------------------------------------
# The images are built for linux/amd64 and linux/arm64 and compose pins no
# platform: the containers must run natively, not under emulation.
info "platform"
case "$(docker info --format '{{.Architecture}}')" in
x86_64 | amd64) host_platform=linux/amd64 ;;
aarch64 | arm64) host_platform=linux/arm64 ;;
*) host_platform="linux/$(docker info --format '{{.Architecture}}')" ;;
esac
for service in api ui; do
  check "$service runs natively ($host_platform)" \
    [ "$(docker image inspect --format '{{.Os}}/{{.Architecture}}' "$(docker compose images -q "$service")")" = "$host_platform" ]
done

# --- images --------------------------------------------------------------------------
# The containers run what compose names: the tag of VERSION with the digest
# the package pins, or the tag alone with the pin dropped (images of a branch).
info "images"
compose_json="$(docker compose config --format json)"
for service in api worker ui; do
  want="$(jq -r ".services.$service.image" <<<"$compose_json")"
  check "$service runs $want" [ "$(docker inspect --format '{{.Config.Image}}' "$(docker compose ps -q "$service")")" = "$want" ]
done
for image in backend frontend; do
  var="CADENCE_$(tr '[:lower:]' '[:upper:]' <<<"$image")_DIGEST"
  if [ -z "${!var+set}" ]; then
    check "$image is pinned by digest ($version@sha256:...)" contains "$compose_json" "/sdlc-pipeline-$image:$version@sha256:"
  else
    info "$var is set (${!var:-empty}): $image as the variable says"
  fi
done

# --- proxy mode and routing ----------------------------------------------------------
info "proxy mode"
check "/readyz answers 200" [ "$(http_code "$base/readyz")" = 200 ]
check "/healthz answers 200" [ "$(http_code "$base/healthz")" = 200 ]
check "/ serves the UI" html
webhook_code="$(http_code -X POST -H 'X-GitHub-Event: ping' -d '{}' "$base/webhooks/github")"
check "/webhooks/github reaches the API and rejects an unsigned delivery ($webhook_code)" client_error "$webhook_code"
check "caddy does not try ACME in proxy mode" lacks "$(docker compose logs caddy 2>&1 | tr '[:upper:]' '[:lower:]')" acme

# --- metrics -------------------------------------------------------------------------
# Prometheus metrics (since v0.10.0): each process listens on :9090 inside the
# network, nothing is published, Caddy does not serve them. Read from the
# caddy container - its busybox has wget. The images of VERSION before
# v0.10.0 have no listener; images of a branch (a pin variable set) are
# checked whatever VERSION says, since that is how a branch with metrics is
# checked before its release.
info "metrics"
if version_lt "$version" v0.10.0 && [ -z "${CADENCE_BACKEND_DIGEST+set}" ]; then
  info "skipped: the images of $version have no metrics (v0.10.0+); images of a branch are checked with CADENCE_BACKEND_DIGEST="
else
  scrape() { docker compose exec -T caddy wget -qO- "http://$1:9090/metrics" 2>/dev/null; }
  # build_info SERVICE: its cadence_build_info line, labels in name order.
  build_info() { scrape "$1" | grep '^cadence_build_info{' || true; }
  # The worker starts once the API is healthy: give its listener a moment.
  for _ in $(seq 30); do
    [ -z "$(build_info worker)" ] || break
    sleep 1
  done
  for service in api worker; do
    line="$(build_info "$service")"
    check "$service serves /metrics on :9090 with cadence_build_info of $version" \
      contains "$line" "component=\"$service\""
    check "...version=\"$version\"" contains "$line" "version=\"$version\""
  done
  api_metrics="$(scrape api)"
  worker_metrics="$(scrape worker)"
  check "api counts requests by route template (/readyz)" contains "$api_metrics" 'route="/readyz"'
  check "api reports the database pool" contains "$api_metrics" "cadence_db_pool_max_connections "
  check "worker reports the index queue" contains "$worker_metrics" 'cadence_index_queue_runs{state="queued"}'
  check "worker reports leases" contains "$worker_metrics" 'cadence_leases{state="live"}'
  check "worker has passed lease_sweep" contains "$worker_metrics" 'cadence_worker_job_last_success_timestamp_seconds{job="lease_sweep"}'
  check "api has go_* and process_* metrics" contains "$api_metrics" "process_cpu_seconds_total "
  check "/metrics through caddy serves no metrics" lacks "$(curl -s "$base/metrics")" cadence_build_info
  # The table of docs/admin.md is the list: every cadence_* metric the
  # processes expose is in it, and everything in it is exposed.
  exposed="$(printf '%s\n%s\n' "$api_metrics" "$worker_metrics" | sed -n 's/^# TYPE \(cadence_[a-z_]*\) .*/\1/p' | sort -u)"
  # shellcheck disable=SC2016 # backticks of the markdown table, not a command
  documented="$(sed -n '/^## Monitoring/,/^## /p' "$repo/docs/admin.md" | sed -n 's/^| `\(cadence_[a-z_]*\)`.*/\1/p' | sort -u)"
  check "every exposed cadence_* metric is in the table of docs/admin.md" \
    [ -z "$(comm -23 <(printf '%s\n' "$exposed") <(printf '%s\n' "$documented"))" ]
  check "every metric in the table of docs/admin.md is exposed" \
    [ -z "$(comm -13 <(printf '%s\n' "$exposed") <(printf '%s\n' "$documented"))" ]
  [ -n "$exposed" ] || fail "no cadence_* metrics exposed"
fi

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
# A second import changes nothing. Cycles report unchanged since v0.5.2
# (CLAB-108); v0.5.1 and older create a new draft of each cycle every time.
again="$("$clab" --host "$base" import --project CHECK --file bundles/starter.json --json)"
check "a second import leaves the roles unchanged" [ "$(jq -r '[.roles[].outcome] | unique | join(",")' <<<"$again")" = unchanged ]
cycles_again=unchanged
if version_lt "$version" v0.5.2; then cycles_again=draft_created; fi
check "a second import leaves the cycles $cycles_again" [ "$(jq -r '[.workflows[].outcome] | unique | join(",")' <<<"$again")" = "$cycles_again" ]

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
# Order of tasks (CLAB-107): a task blocked by an open one does not start.
check "clab create a second task" "$clab" --host "$base" create --project CHECK --title "Second task"
check "clab relate CHECK-1 blocks CHECK-3" env SDLC_PROJECT=CHECK "$clab" --host "$base" relate CHECK-1 --to CHECK-3 --rel blocks
blocked="$(env SDLC_PROJECT=CHECK "$clab" --host "$base" transition CHECK-3 --to start 2>&1 || true)"
check "the start of a blocked task is held by dependencies_closed" contains "$blocked" 'dependencies_closed'

# --- clab server -------------------------------------------------------------------------------------
if [ "$driver" = clab ]; then
  info "clab server status"
  status="$("$clab" server status)"
  check "status names the installation directory" contains "$status" "$work/cadence"
  check "status reports the stack $version (VERSION)" contains "$status" "$version (VERSION)"
  clab_version="$("$clab" server status --json | jq -r '.clab // empty')"
  check "status reports the version of clab (${clab_version:-none})" grep -qE "^clab: +${clab_version:-none}\$" <<<"$status"
  check "status reports an installation from the package" contains "$status" "package"
  check "status reports the services" contains "$status" "api"
  check "status names the installation: $name (.env)" grep -qE "^Name: +$name \(\.env\)\$" <<<"$status"
  check "status --json reports .name $name from .env" \
    [ "$("$clab" server status --json | jq -r '"\(.name) \(.name_from)"')" = "$name .env" ]
  if out="$(COMPOSE_PROJECT_NAME=other "$clab" server status 2>&1)"; then
    check "status with COMPOSE_PROJECT_NAME=other warns, naming both" \
      contains "$out" "! COMPOSE_PROJECT_NAME is 'other' in the environment, but this installation is '$name'"
    check "...and still lists the services of $name" contains "$out" "api"
  else
    fail "status with COMPOSE_PROJECT_NAME=other must not fail: $out"
  fi
  mkdir -p "$work/cadence/docs/sub"
  check "status from a subdirectory finds the installation" \
    contains "$(cd "$work/cadence/docs/sub" && "$clab" server status)" "$work/cadence"
  check "status with CADENCE_DIR from / finds the installation" \
    contains "$(cd / && CADENCE_DIR="$work/cadence" "$clab" server status)" "$work/cadence"
  rmdir "$work/cadence/docs/sub"
  if out="$(cd "$work" && "$clab" server status 2>&1)"; then
    fail "status outside an installation must fail"
  else
    check "status outside an installation fails and points at --dir" contains "$out" "--dir"
  fi
fi

# backup_cmd / restore_cmd: the scripts, or clab server (CADENCE_DRIVER).
backup_cmd() {
  if [ "$driver" = clab ]; then "$clab" server backup; else ./backup.sh; fi
}
restore_cmd() {
  if [ "$driver" = clab ]; then "$clab" server restore "$@"; else ./restore.sh "$@"; fi
}

# --- backup and restore ----------------------------------------------------------------------------
info "backup ($driver)"
backup_cmd
dump="$(find backups -maxdepth 1 -name "cadence-$version-*.sql.gz" | sort | tail -n 1)"
check "backup writes cadence-$version-*.sql.gz" [ -n "$dump" ]
check "the dump is larger than 1 KB" [ "$(wc -c <"${dump:-/dev/null}" | tr -d ' ')" -gt 1024 ]
check "the blobs volume is archived next to it" [ -f "${dump%.sql.gz}.blobs.tar.gz" ]

"$clab" --host "$base" project create AFTER --name "Created after the backup" --team check >/dev/null
check "a project created after the backup exists" contains "$("$clab" --host "$base" project list --json)" '"AFTER"'

info "restore ($driver)"
if [ "$driver" = clab ]; then
  # stdin is /dev/null, as under cron: a character device, but not a terminal.
  if out="$("$clab" server restore "$dump" </dev/null 2>&1)"; then
    fail "clab server restore without a terminal and --yes must refuse"
  else
    check "clab server restore without a terminal and --yes refuses and asks for --yes" contains "$out" "run it in a terminal or pass --yes"
  fi
  check "the refusal leaves the project created after the backup" contains "$("$clab" --host "$base" project list --json)" '"AFTER"'
fi
restore_cmd --yes "$dump"
projects="$("$clab" --host "$base" project list --json)"
check "after restore the project from before the backup is there" contains "$projects" '"CHECK"'
check "after restore the project created after the backup is gone" lacks "$projects" '"AFTER"'
check "/readyz answers 200 after restore" [ "$(http_code "$base/readyz")" = 200 ]

# --- another installation name in the environment ------------------------------------
# backup, restore and upgrade of this installation with COMPOSE_PROJECT_NAME
# of another one refuse before they touch Docker: no dump, no restart.
info "COMPOSE_PROJECT_NAME=other ($driver)"
upgrade_cmd() {
  if [ "$driver" = clab ]; then "$clab" server upgrade "$@"; else ./upgrade.sh "$@"; fi
}
started_before="$(started "$work/cadence")"
dumps_before="$(find backups -maxdepth 1 -name 'cadence-*.sql.gz' | sort)"
for cmd in "backup_cmd" "restore_cmd --yes $dump" "upgrade_cmd $version"; do
  what="${cmd%%_cmd*}"
  # shellcheck disable=SC2086 # the command and its arguments
  if out="$(COMPOSE_PROJECT_NAME=other $cmd 2>&1)"; then
    fail "$what with COMPOSE_PROJECT_NAME=other must refuse"
  elif contains "$out" "COMPOSE_PROJECT_NAME is 'other' in the environment, but the installation in $work/cadence is '$name'" &&
    contains "$out" "unset COMPOSE_PROJECT_NAME"; then
    pass "$what with COMPOSE_PROJECT_NAME=other refuses, naming both and unset"
  else
    fail "$what with COMPOSE_PROJECT_NAME=other refused without both names: $out"
  fi
done
check "the refusals took no backup" [ "$(find backups -maxdepth 1 -name 'cadence-*.sql.gz' | sort)" = "$dumps_before" ]
check "the refusals restarted nothing" [ "$(started "$work/cadence")" = "$started_before" ]
COMPOSE_PROJECT_NAME="" backup_cmd >/dev/null
check "an empty COMPOSE_PROJECT_NAME is no variable: backup works" \
  [ "$(find backups -maxdepth 1 -name 'cadence-*.sql.gz' | wc -l)" -gt "$(grep -c . <<<"$dumps_before")" ]

# --- two installations on one machine ------------------------------------------------
if [ "$driver" = scripts ]; then
  info "a second installation: --name $second_name on port $second_port"
  (cd "$work" && PATH="$work/nogit:$PATH" CADENCE_RELEASES_URL="file://$work/releases" \
    sh -s -- --dir second --name "$second_name" --mode proxy --http-addr "127.0.0.1:$second_port" --yes <"$repo/get-cadence.sh" >/dev/null)
  second_up=1
  check "the second installation keeps its name: COMPOSE_PROJECT_NAME=$second_name" \
    grep -qxF "COMPOSE_PROJECT_NAME=$second_name" "$work/second/.env"
  check "the second installation answers on $second_port" [ "$(http_code "http://127.0.0.1:$second_port/readyz")" = 200 ]
  check "docker compose in the first installation sees only $name" [ "$(projects_in "$work/cadence")" = "$name " ]
  check "docker compose in the second installation sees only $second_name" [ "$(projects_in "$work/second")" = "$second_name " ]
  first_dumps="$(find backups -maxdepth 1 -name 'cadence-*.sql.gz' | wc -l | tr -d ' ')"
  fresh "$work/second" ./backup.sh >/dev/null
  check "./backup.sh of the second installation writes into its own backups/" \
    [ "$(find "$work/second/backups" -maxdepth 1 -name 'cadence-*.sql.gz' | wc -l | tr -d ' ')" = 1 ]
  check "...and nothing into the backups/ of the first" \
    [ "$(find backups -maxdepth 1 -name 'cadence-*.sql.gz' | wc -l | tr -d ' ')" = "$first_dumps" ]
  fresh "$work/cadence" ./backup.sh >/dev/null
  check "./backup.sh of the first installation writes into its own backups/" \
    [ "$(find backups -maxdepth 1 -name 'cadence-*.sql.gz' | wc -l | tr -d ' ')" = "$((first_dumps + 1))" ]
  check "...and nothing into the backups/ of the second" \
    [ "$(find "$work/second/backups" -maxdepth 1 -name 'cadence-*.sql.gz' | wc -l | tr -d ' ')" = 1 ]
  check "the first installation still answers on $port" [ "$(http_code "$base/readyz")" = 200 ]
fi

if [ "$failures" -gt 0 ]; then
  docker compose ps || true
  docker compose logs --tail 30 api caddy || true
  die "$failures check(s) failed"
fi
ok "all checks passed on $version ($driver, installed with $install_with)"
