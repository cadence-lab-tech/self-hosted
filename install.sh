#!/usr/bin/env bash
#
# First installation of Cadence Lab on this machine: checks the environment,
# writes .env with generated secrets, starts the stack of the version in
# VERSION and prints the administrator token.
#
#   ./install.sh                                  # asks questions
#   ./install.sh --mode tls --domain cadence.example.com --email ops@example.com
#   ./install.sh --mode proxy --http-addr 127.0.0.1:8080 --yes
#   ./install.sh --name cadence-stage --mode proxy --http-addr 127.0.0.1:8081
#
# Without a terminal, or with --yes, it asks nothing: every answer comes from
# flags or from the environment (CADENCE_MODE, SDLC_DOMAIN, ACME_EMAIL,
# CADENCE_HTTP_ADDR, SDLC_BOOTSTRAP_TEAM, SDLC_BOOTSTRAP_TEAM_NAME). An
# administrator token may be supplied as SDLC_ADMIN_TOKEN (at least 16
# characters); otherwise one is generated.
#
# --name NAME (or COMPOSE_PROJECT_NAME) names this installation on the
# machine, default cadence: the Docker Compose project of its containers,
# volumes and network, kept in .env. A second installation on the same
# machine needs a name of its own. It is not a project inside Cadence Lab:
# one installation holds any number of teams and projects.
#
# It runs once. With an existing .env it stops and changes nothing:
# regenerating the secrets would lock the database volume out with a new
# password.
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=lib.sh
. ./lib.sh

usage() {
  sed -n '3,26p' "$0" | sed 's/^# \{0,1\}//'
  exit "${1:-0}"
}

mode="${CADENCE_MODE:-}"
domain="${SDLC_DOMAIN:-}"
email="${ACME_EMAIL:-}"
http_addr="${CADENCE_HTTP_ADDR:-}"
team="${SDLC_BOOTSTRAP_TEAM:-}"
team_name="${SDLC_BOOTSTRAP_TEAM_NAME:-}"
admin_token="${SDLC_ADMIN_TOKEN:-}"
name=""
assume_yes=false
timeout="${CADENCE_READY_TIMEOUT:-300}"

while [ $# -gt 0 ]; do
  case "$1" in
  --mode) mode="${2:?--mode needs tls or proxy}"; shift 2 ;;
  --domain) domain="${2:?--domain needs a host name}"; shift 2 ;;
  --email) email="${2:?--email needs an address}"; shift 2 ;;
  --http-addr) http_addr="${2:?--http-addr needs [ip:]port}"; shift 2 ;;
  --team) team="${2:?--team needs a key}"; shift 2 ;;
  --team-name) team_name="${2:?--team-name needs a name}"; shift 2 ;;
  --name) name="${2:?--name needs a name of the installation}"; shift 2 ;;
  -y | --yes | --non-interactive) assume_yes=true; shift ;;
  -h | --help) usage 0 ;;
  *) warn "unknown argument: $1"; usage 2 >&2 ;;
  esac
done

interactive=false
if [ "$assume_yes" = false ] && [ -t 0 ]; then
  interactive=true
fi

# ask VAR "question" "default": in interactive mode read an answer, keeping
# the current value (or the default) on an empty line.
ask() {
  local var="$1" question="$2" current="${!1:-$3}" answer
  if [ "$interactive" = true ]; then
    read -r -p "$question [${current}]: " answer
    printf -v "$var" '%s' "${answer:-$current}"
  else
    printf -v "$var" '%s' "$current"
  fi
}

# --- 1. nothing to overwrite ---------------------------------------------------
if [ -e .env ]; then
  die ".env already exists: this instance is installed, and install.sh never regenerates secrets
  (a new POSTGRES_PASSWORD would no longer open the existing database volume).
  - start the configured stack:  export CADENCE_VERSION=\$(cat VERSION) && docker compose up -d
  - upgrade:                     ./upgrade.sh
  - start over, DELETING ALL DATA: docker compose down -v && rm .env && ./install.sh"
fi

# --- 2. environment ---------------------------------------------------------------
# The installation name: --name, else COMPOSE_PROJECT_NAME, else the default.
# Both given and different is a mistake in one of them, not a choice.
env_name="${COMPOSE_PROJECT_NAME:-}"
if [ -n "$name" ] && [ -n "$env_name" ] && [ "$name" != "$env_name" ]; then
  die "--name is '$name', but COMPOSE_PROJECT_NAME in the environment is '$env_name': give one of them, or the same name in both"
fi
name="${name:-${env_name:-$CADENCE_DEFAULT_NAME}}"
valid_name "$name" || die "'$name' is not a valid installation name (--name): $(name_rule)"

info "checking the environment"
require_docker
load_version
# Another installation under the same name would share its containers and
# volumes: the new database password would not open its volume, and this
# installation would break that one.
taken="$(name_in_use "$name")" || die "could not ask Docker which installation names are taken (docker ps, docker volume ls)"
if [ -n "$taken" ]; then
  case "$taken" in
  volumes) where="Docker keeps volumes of the compose project '$name' (an installation removed without its data)" ;;
  containers) where="Docker has containers of the compose project '$name'" ;;
  *) where="the installation in $taken uses it" ;;
  esac
  die "the installation name '$name' is taken on this machine: $where.
  Every installation on one machine needs a name of its own; pick another one with --name:
    ./install.sh --name ${name}-2 ...   (or get-cadence.sh ... --name ${name}-2)
  The name is the Docker Compose project of the installation, not a project inside Cadence Lab. Nothing was changed."
fi
# The images are built for linux/amd64 and linux/arm64 (uname -m says
# aarch64 on Linux and arm64 on macOS); anything else has no image to pull.
case "$(uname -m)" in
x86_64 | amd64 | aarch64 | arm64) ;;
*) warn "this machine is $(uname -m); the images are built for linux/amd64 and linux/arm64 only, so pulling them here will most likely fail" ;;
esac

gen_hex() {
  if command -v openssl >/dev/null 2>&1; then
    openssl rand -hex "$1"
  elif [ -r /dev/urandom ]; then
    od -An -tx1 -N"$1" /dev/urandom | tr -d ' \n'
  else
    die "need openssl or /dev/urandom to generate secrets"
  fi
}
# Fail before any question, not after the answers.
[ -n "$(gen_hex 4)" ] || die "could not generate a random secret (openssl or /dev/urandom)"

# port_busy PORT [ADDR]: something already listens on the port.
port_busy() {
  local port="$1" addr="${2:-}"
  if command -v ss >/dev/null 2>&1; then
    ss -Hltn "sport = :$port" 2>/dev/null | grep -q . && return 0
    return 1
  fi
  # No ss (e.g. macOS for a test run): try to connect.
  (exec 3<>"/dev/tcp/${addr:-127.0.0.1}/$port") 2>/dev/null
}

# --- 3. answers --------------------------------------------------------------------
ask mode "Mode: tls (HTTPS on your domain) or proxy (HTTP behind your reverse proxy)" tls
case "$mode" in
tls)
  ask domain "Domain name that points at this machine" ""
  [ -n "$domain" ] || die "tls mode needs a domain: --domain cadence.example.com (or SDLC_DOMAIN), or use --mode proxy"
  ask email "E-mail for Let's Encrypt notices" "admin@${domain}"
  for port in 80 443; do
    if port_busy "$port"; then
      die "port $port is already in use on this machine; tls mode needs ports 80 and 443 (or use --mode proxy behind the existing web server)"
    fi
  done
  # The certificate is only issued if the domain resolves to this machine.
  resolved=""
  if command -v getent >/dev/null 2>&1; then
    resolved="$(getent ahosts "$domain" 2>/dev/null | awk '{print $1}' | sort -u | tr '\n' ' ' || true)"
  fi
  if [ -z "$resolved" ]; then
    warn "$domain does not resolve. Create a DNS record pointing at this machine before the first start,"
    warn "or install in proxy mode behind your reverse proxy: ./install.sh --mode proxy"
  else
    local_ips="$(hostname -I 2>/dev/null || true)"
    match=false
    for ip in $resolved; do
      case " $local_ips " in *" $ip "*) match=true ;; esac
    done
    if [ "$match" = false ]; then
      warn "$domain resolves to ${resolved% } which is not an address of this machine (${local_ips:-unknown})."
      warn "Fine behind NAT with ports 80/443 forwarded here; otherwise Let's Encrypt will fail - consider --mode proxy."
    fi
  fi
  compose_file="docker-compose.yml:compose.tls.yml:compose.override.yml"
  ;;
proxy)
  ask http_addr "Address Caddy listens on for your proxy ([ip:]port)" "127.0.0.1:8080"
  port="${http_addr##*:}"
  host="${http_addr%:*}"
  [ "$host" = "$http_addr" ] && host=""
  [[ "$port" =~ ^[0-9]+$ ]] || die "--http-addr '$http_addr' is not [ip:]port"
  case "$host" in "" | 0.0.0.0) host=127.0.0.1 ;; esac
  if port_busy "$port" "$host"; then
    die "port $port is already in use on this machine; pick another with --http-addr 127.0.0.1:<port>"
  fi
  compose_file="docker-compose.yml:compose.proxy.yml:compose.override.yml"
  ;;
*) die "mode must be tls or proxy, not '$mode'" ;;
esac
ask team "Key of the first team (empty: create teams later with clab)" ""
if [ -n "$team" ] && [ -z "$team_name" ]; then
  ask team_name "Display name of team $team" "$team"
fi

if [ -n "$admin_token" ]; then
  [ "${#admin_token}" -ge 16 ] || die "SDLC_ADMIN_TOKEN must be at least 16 characters"
  token_generated=false
else
  admin_token="sdlc_$(gen_hex 24)"
  token_generated=true
fi

# --- 4. .env ---------------------------------------------------------------------------
info "writing .env"
# set_kv writes KEY=VALUE over the template line; values go through ENVIRON,
# so awk needs no escaping. compose reads .env and the scripts source it as
# shell, so a value with spaces or shell characters is single-quoted, which
# both read the same way.
set_kv() {
  case "$2" in
  *"'"* | *$'\n'*) die "the value of $1 must not contain a single quote or a line break" ;;
  esac
  KEY="$1" VALUE="$2" awk '
    BEGIN {
      k = ENVIRON["KEY"]; v = ENVIRON["VALUE"]; done = 0
      if (v ~ /[^A-Za-z0-9_.,:\/@+=-]/) v = "\047" v "\047"
    }
    index($0, k "=") == 1 { print k "=" v; done = 1; next }
    { print }
    END { if (!done) print k "=" v }
  ' .env.tmp >.env.tmp.next && mv .env.tmp.next .env.tmp
}
trap 'rm -f .env.tmp .env.tmp.next' EXIT
cp .env.example .env.tmp
chmod 600 .env.tmp
set_kv COMPOSE_PROJECT_NAME "$name"
set_kv CADENCE_MODE "$mode"
set_kv COMPOSE_FILE "$compose_file"
if [ "$mode" = tls ]; then
  set_kv SDLC_DOMAIN "$domain"
  set_kv ACME_EMAIL "$email"
else
  set_kv SDLC_DOMAIN ""
  set_kv ACME_EMAIL ""
  set_kv CADENCE_HTTP_ADDR "$http_addr"
fi
set_kv POSTGRES_PASSWORD "$(gen_hex 24)"
set_kv SDLC_ADMIN_TOKEN "$admin_token"
set_kv SDLC_GITHUB_WEBHOOK_SECRET "$(gen_hex 24)"
set_kv SDLC_BOOTSTRAP_TEAM "$team"
set_kv SDLC_BOOTSTRAP_TEAM_NAME "$team_name"
mv .env.tmp .env
trap - EXIT
# Local compose changes live in compose.override.yml, which COMPOSE_FILE
# lists from the start: compose reads it with no edit of .env, and upgrade.sh
# never touches it.
if [ ! -e compose.override.yml ]; then
  cat >compose.override.yml <<'YAML'
# Local changes of the compose configuration (docs/admin.md, "Local compose
# changes"). COMPOSE_FILE in .env lists this file; upgrade.sh never touches it.
#
# services:
#   api:
#     extra_hosts: ["host.docker.internal:host-gateway"]
services: {}
YAML
  chmod 644 compose.override.yml
fi
mkdir -p backups secrets
# The service runs as uid 65532 and must traverse secrets/ to read the GitHub
# App key; listing it is not needed.
chmod 700 backups
chmod 711 secrets
ok ".env written (mode 600)"

# --- 5. start ------------------------------------------------------------------------------
load_env
check_mode
info "pulling images of $CADENCE_VERSION"
if ! docker compose pull --quiet; then
  die "could not pull the images of $CADENCE_VERSION: check that ghcr.io is reachable from this host.
  Then start the stack: export CADENCE_VERSION=\$(cat VERSION) && docker compose up -d"
fi
info "starting the stack"
docker compose up -d --remove-orphans
info "waiting for the service to become ready (up to ${timeout}s)"
if ! wait_ready "$timeout"; then
  docker compose ps
  docker compose logs --tail 40 api caddy || true
  die "the stack did not become ready in ${timeout}s; the logs are above. .env is kept: fix the cause and run
  export CADENCE_VERSION=\$(cat VERSION) && docker compose up -d"
fi

ok "Cadence Lab $CADENCE_VERSION is up"
say ""
say "  Address:              $(public_url)"
if [ "$token_generated" = true ]; then
  say "  Administrator token:  $SDLC_ADMIN_TOKEN"
  say "                        (shown once; it is also in .env - keep both private)"
else
  say "  Administrator token:  the one supplied in SDLC_ADMIN_TOKEN"
fi
say ""
say "Next: sign in with the token and follow docs/admin.md (teams, GitHub App, OIDC, CLI)."
say "Set up nightly backups: 0 3 * * * $(pwd)/backup.sh >> $(pwd)/backups/backup.log 2>&1"
