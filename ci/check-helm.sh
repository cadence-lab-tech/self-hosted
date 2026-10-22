#!/usr/bin/env bash
#
# End-to-end check of the Helm chart (charts/cadence) in a kind cluster, the
# way docs/admin.md ("Kubernetes (Helm)") installs it: ingress-nginx with the
# annotations of the guide, the stand-in of an external PostgreSQL
# (ci/external-db.sh: pgvector 18, TLS with a CA of its own, a role that is
# no superuser) and the stand-in bucket (ci/s3.sh), both containers in the
# Docker network of kind under names of the cluster (<cluster>-extdb,
# <cluster>-s3stand); the secrets are Secrets of the namespace, made
# with kubectl before the installation. The namespace enforces Pod Security
# "restricted" for every pod, ui included (CLAB-236).
#
# Scenarios: the precheck of the database refuses a database without vector
# (helm install fails, no Deployment); the install with three replicas of the
# API on an empty database (one set of migrations, the worker after the
# API); the probes, the UI and the version through the Ingress; sign-in with
# the token of the Secret, a team, a project, the starter bundle; MCP through
# the Ingress, unbuffered; an artifact larger than the inline limit in the
# bucket; the metrics inside the cluster only; Pod Security; no value of a
# secret in the values of the release or the manifests; a key missing in the
# Secret; a refused upgrade keeps the pods; an upgrade with a changed value
# keeps the data. CI runs it in the job "helm" of check.yml.
#
#   ci/check-helm.sh
#
#   CHECK_CLUSTER     name of the kind cluster, default cadence-check-helm;
#                     an existing cluster of that name is refused, the check
#                     deletes its own at the end. The stand-ins are named
#                     after it, containers and network aliases: checks with
#                     their own CHECK_CLUSTER and CHECK_HTTP_PORT run at the
#                     same time on one machine
#   CHECK_HTTP_PORT   host port of the Ingress (127.0.0.1), default 8090
#   CHECK_S3_PORT     host port of the stand-in bucket, default
#                     CHECK_HTTP_PORT + 4
#   CADENCE_REGISTRY  registry of the images (image.registry), default
#                     ghcr.io/cadence-lab-tech
#   CADENCE_BACKEND_DIGEST, CADENCE_FRONTEND_DIGEST
#                     unset - the pins of values.yaml; empty - no pin, the
#                     images by tag (images of a branch)
#   CHECK_IMAGE_TAG   tag of the images (image.tag), default VERSION
#   CLAB_BIN          clab to use; default: the CLI of VERSION from the tap
#   CHECK_KEEP=1      leave the cluster and the stand-ins after the check
#
# Images in a local registry (localhost:*) are not reachable from the nodes
# of kind: the check pulls them on this machine and loads them into the
# cluster (kind load docker-image). Images of a branch, as for
# ci/check-stack.sh:
#
#   CADENCE_REGISTRY=localhost:5050 CADENCE_BACKEND_DIGEST= CADENCE_FRONTEND_DIGEST= \
#     CHECK_CLUSTER=check-<name> CHECK_HTTP_PORT=<port> ci/check-helm.sh
#
# Needs Docker, kind, helm, kubectl, jq, curl and openssl. The images must
# read *_FILE (v0.13.0 or newer) and the frontend image must run as uid 65532
# on :8080 (v0.14.0 or newer, CLAB-236): check.yml skips the job for an
# older VERSION.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=lib.sh
. ./lib.sh
# shellcheck source=ci/external-db.sh
. ./ci/external-db.sh
# shellcheck source=ci/s3.sh
. ./ci/s3.sh

for tool in kind helm kubectl jq curl openssl docker; do
  command -v "$tool" >/dev/null || die "$tool is not installed"
done

cluster="${CHECK_CLUSTER:-cadence-check-helm}"
port="${CHECK_HTTP_PORT:-8090}"
s3_port="${CHECK_S3_PORT:-$((port + 4))}"
version="$(tr -d '[:space:]' <VERSION)"
tag="${CHECK_IMAGE_TAG:-$version}"
registry="${CADENCE_REGISTRY:-ghcr.io/cadence-lab-tech}"
ns=cadence
release=cadence
host=localhost
base="http://$host:$port"
chart=charts/cadence
failures=0
work="$(mktemp -d)"
export KUBECONFIG="$work/kubeconfig"

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
http_code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
k() { kubectl -n "$ns" "$@"; }

kind get clusters 2>/dev/null | grep -qxF "$cluster" &&
  die "a kind cluster '$cluster' exists: the check deletes the cluster it runs in - give it CHECK_CLUSTER of its own"

cleanup() {
  local code=$?
  if [ "${CHECK_KEEP:-}" = 1 ]; then
    info "kept: kind cluster $cluster (KUBECONFIG=$KUBECONFIG), $EXT_DB_NAME, $S3_NAME"
    exit "$code"
  fi
  kind delete cluster --name "$cluster" >/dev/null 2>&1 || true
  ext_db_down
  s3_down
  rm -rf "$work"
  exit "$code"
}
trap cleanup EXIT

# --- the cluster -----------------------------------------------------------------------
info "kind cluster $cluster, the Ingress on 127.0.0.1:$port"
cat >"$work/kind.yaml" <<EOF
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
  - role: control-plane
    labels:
      ingress-ready: "true"
    extraPortMappings:
      - containerPort: 80
        hostPort: $port
        listenAddress: 127.0.0.1
EOF
kind create cluster --name "$cluster" --config "$work/kind.yaml" --kubeconfig "$KUBECONFIG" --wait 120s
# The controller of the guide; the version is pinned like every image here.
kubectl apply -f https://raw.githubusercontent.com/kubernetes/ingress-nginx/controller-v1.15.1/deploy/static/provider/kind/deploy.yaml >/dev/null
kubectl -n ingress-nginx wait --for=condition=Available deploy/ingress-nginx-controller --timeout=180s >/dev/null
# The admission webhook of the controller answers a little after it is
# Available (its certificate comes from Jobs that delete themselves): until
# then every Ingress is refused.
probe_ingress() {
  kubectl apply --dry-run=server -f - >/dev/null 2>&1 <<EOF
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: probe
  namespace: default
spec:
  ingressClassName: nginx
  defaultBackend:
    service:
      name: probe
      port:
        number: 80
EOF
}
for i in $(seq 1 60); do
  probe_ingress && break
  [ "$i" -lt 60 ] || die "the admission webhook of ingress-nginx does not answer"
  sleep 2
done

# --- the stand-ins, in the network of kind ---------------------------------------------
# The network kind is one for every cluster of the machine: the names the
# pods reach the stand-ins by are those of this cluster, so two checks with
# their own CHECK_CLUSTER run side by side, each on its own database and
# bucket (the certificate of the database is for that name).
info "external PostgreSQL ($cluster-extdb) and the bucket ($cluster-s3stand) in the network kind"
EXT_DB_NETWORK=kind EXT_DB_ALIAS="$cluster-extdb" ext_db_up "$cluster-db" 5432 "$work/db"
S3_ALIAS="$cluster-s3stand"
s3_up "$cluster-s3" "$s3_port" kind

# --- images ------------------------------------------------------------------------------
backend_digest="${CADENCE_BACKEND_DIGEST-$(sed -n 's/^ *digest: "\(sha256:[0-9a-f]\{64\}\)" # CADENCE_BACKEND_DIGEST$/\1/p' "$chart/values.yaml")}"
frontend_digest="${CADENCE_FRONTEND_DIGEST-$(sed -n 's/^ *digest: "\(sha256:[0-9a-f]\{64\}\)" # CADENCE_FRONTEND_DIGEST$/\1/p' "$chart/values.yaml")}"
image_of() { printf '%s/%s:%s%s' "$registry" "$1" "$tag" "${2:+@$2}"; }
backend_image="$(image_of sdlc-pipeline-backend "$backend_digest")"
frontend_image="$(image_of sdlc-pipeline-frontend "$frontend_digest")"
case "$registry" in
localhost:* | 127.0.0.1:*)
  info "images of $registry: pulled here and loaded into kind"
  for ref in "$backend_image" "$frontend_image"; do
    docker image inspect "$ref" >/dev/null 2>&1 || docker pull -q "$ref" >/dev/null
    kind load docker-image --name "$cluster" "$ref" >/dev/null
  done
  ;;
esac

# --- the namespace, the secrets, the values ------------------------------------------------
info "namespace $ns (Pod Security: enforce, warn and audit restricted) and its secrets"
kubectl create namespace "$ns" >/dev/null
kubectl label namespace "$ns" pod-security.kubernetes.io/enforce=restricted \
  pod-security.kubernetes.io/warn=restricted pod-security.kubernetes.io/audit=restricted >/dev/null
admin_token="sdlc_$(openssl rand -hex 24)"
sec="$work/secrets"
mkdir -p "$sec"
(
  umask 077
  printf '%s\n' "$admin_token" >"$sec/admin-token"
  # A key written with echo ends with a newline: the service cuts it.
  printf '%s\n' "$EXT_DB_PASSWORD" >"$sec/db-password"
  printf '%s' "$S3_ACCESS_KEY" >"$sec/s3-access-key-id"
  printf '%s' "$S3_SECRET" >"$sec/s3-secret-access-key"
)
cp "$work/db/ca.pem" "$sec/db-ca.pem"
# From files: no value of a secret on a command line of this machine.
kubectl -n "$ns" create secret generic cadence --from-file="$sec/admin-token" --from-file="$sec/db-password" \
  --from-file="$sec/s3-access-key-id" --from-file="$sec/s3-secret-access-key" --from-file="$sec/db-ca.pem" >/dev/null
secret_values=("$admin_token" "$EXT_DB_PASSWORD" "$EXT_DB_PASSWORD_URL" "$S3_SECRET")

db_url() { printf 'postgres://cadence@%s:%s/%s?sslmode=verify-full&sslrootcert=/secrets/cadence/db-ca.pem' "$EXT_DB_HOST" "$EXT_DB_PORT" "$1"; }
# The values of the guide (docs/admin.md, "Kubernetes (Helm)"), with the
# stand-ins and the images of this run.
cat >"$work/values.yaml" <<EOF
image:
  registry: $registry
  tag: $tag
  backend:
    digest: "$backend_digest"
  frontend:
    digest: "$frontend_digest"
ingress:
  className: nginx
  host: $host
  annotations:
    nginx.ingress.kubernetes.io/proxy-buffering: "off"
    nginx.ingress.kubernetes.io/proxy-request-buffering: "off"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-body-size: 64m
database:
  url: "$(db_url cadence)"
blobs:
  s3:
    bucket: $S3_BUCKET
    endpoint: $S3_ENDPOINT
    region: us-east-1
    prefix: helm/
secrets:
  name: cadence
  keys:
    SDLC_DATABASE_PASSWORD: db-password
    SDLC_ADMIN_TOKEN: admin-token
    SDLC_BLOB_S3_ACCESS_KEY_ID: s3-access-key-id
    SDLC_BLOB_S3_SECRET_ACCESS_KEY: s3-secret-access-key
  files: [db-ca.pem]
# A small inline limit: the artifact of the check goes to the bucket.
extraEnv:
  - name: SDLC_BLOB_INLINE_MAX_BYTES
    value: "4096"
EOF

# --- the precheck refuses a database ---------------------------------------------------------
info "helm install on a database without vector: the precheck refuses it"
set +e
out="$(helm install "$release" "$chart" -n "$ns" -f "$work/values.yaml" --set database.url="$(db_url cadence_noext)" \
  --wait --timeout 3m 2>&1)"
code=$?
set -e
check "helm install fails (exit $code)" [ "$code" != 0 ]
check "...in the pre-install hook" contains "$out" "pre-install"
check "no Deployment api is created" [ -z "$(k get deploy "$release-api" --ignore-not-found -o name)" ]
job_log="$(k logs "job/$release-dbcheck" 2>&1 || true)"
check "the log of the Job names the extension vector" contains "$job_log" "vector"
for s in "${secret_values[@]}"; do
  check "the log of the Job has no value of a secret" lacks "$job_log" "$s"
done
helm uninstall "$release" -n "$ns" --wait >/dev/null 2>&1 || true
k delete job "$release-dbcheck" --ignore-not-found >/dev/null

# --- the installation: three replicas of the API on an empty database -------------------------
info "helm install --wait: api x3, worker, ui"
if ! out="$(helm install "$release" "$chart" -n "$ns" -f "$work/values.yaml" --set api.replicas=3 --wait --timeout 6m 2>&1)"; then
  printf '%s\n' "$out" >&2
  k get pods -o wide >&2 || true
  k describe pods >&2 || true
  die "helm install failed"
fi
pass "helm install --wait succeeded"
check "NOTES name the address" contains "$out" "Address: http://$host"
ready() { k get pods -l "app.kubernetes.io/component=$1" -o json | jq -r '[.items[] | select(.status.conditions[]? | .type == "Ready" and .status == "True")] | length'; }
check "three api pods are Ready" [ "$(ready api)" = 3 ]
check "the worker pod is Ready" [ "$(ready worker)" = 1 ]
check "the ui pod is Ready" [ "$(ready ui)" = 1 ]
check "no pod restarted" [ "$(k get pods -o json | jq '[.items[].status.containerStatuses[]?.restartCount] | add')" = 0 ]

# One set of migrations for three replicas under the advisory lock: every
# migration is applied once, by one of them, and none fails.
api_logs="$(k logs -l app.kubernetes.io/component=api --tail=-1 --prefix 2>&1)"
applied_logged="$(grep -c 'миграция применена' <<<"$api_logs" || true)"
applied_db="$(ext_db_query cadence 'SELECT count(*) FROM schema_migrations')"
check "the migrations are applied once: $applied_logged in the logs, $applied_db in schema_migrations" \
  [ "$applied_logged" -gt 0 -a "$applied_logged" = "$applied_db" ]
check "no api log has an error" lacks "$(grep -i '"level":"ERROR"' <<<"$api_logs" || true)" "ERROR"

# The worker waits for the API: its init container ends after the first api
# pod is Ready, and the worker finds the tables.
first_ready="$(k get pods -l app.kubernetes.io/component=api -o json |
  jq -r '[.items[].status.conditions[] | select(.type == "Ready") | .lastTransitionTime] | sort | .[0]')"
init_done="$(k get pods -l app.kubernetes.io/component=worker -o json |
  jq -r '.items[0].status.initContainerStatuses[0].state.terminated.finishedAt')"
check "the worker waited for the API ($init_done >= $first_ready)" [ ! "$init_done" \< "$first_ready" ]
worker_log="$(k logs deploy/"$release-worker" 2>&1)"
check "the worker log has no missing table" lacks "$worker_log" "does not exist"

# --- Pod Security ---------------------------------------------------------------------------
info "Pod Security"
# The namespace enforces restricted since the install, so every pod above
# was admitted under it; the dry run asks the API server once more about the
# running pods: no warning means none of them violates restricted.
check "the namespace enforces restricted" \
  [ "$(kubectl get namespace "$ns" -o jsonpath='{.metadata.labels.pod-security\.kubernetes\.io/enforce}')" = restricted ]
psa="$(kubectl label --dry-run=server --overwrite namespace "$ns" pod-security.kubernetes.io/enforce=restricted 2>&1 >/dev/null || true)"
check "under restricted no pod is refused ($(printf '%s' "${psa:-no warnings}" | tr '\n' ' '))" lacks "$psa" "Warning"
spec_of() { k get pods -l "app.kubernetes.io/component=$1" -o json | jq -c '.items[0].spec'; }
for c in api worker ui; do
  spec="$(spec_of "$c")"
  check "$c: runAsNonRoot, uid 65532, read-only root, no escalation, drop ALL, RuntimeDefault" \
    [ "$(jq -r '[.securityContext.runAsNonRoot, .securityContext.runAsUser, .securityContext.seccompProfile.type,
      ([.containers[], (.initContainers // [])[]] | map(.securityContext | "\(.readOnlyRootFilesystem) \(.allowPrivilegeEscalation) \(.capabilities.drop | join(","))") | unique | join("|"))] | join(" ")' <<<"$spec")" = \
      "true 65532 RuntimeDefault true false ALL" ]
done
check "api and worker add no capability, ui only NET_BIND_SERVICE" \
  [ "$(for c in api worker ui; do spec_of "$c" | jq -r --arg c "$c" '[.containers[], (.initContainers // [])[]] | map("\($c):\(.securityContext.capabilities.add // [] | join(","))") | join(" ")'; done | tr '\n' ' ')" = \
    "api: worker: worker: ui:NET_BIND_SERVICE " ]
# shellcheck disable=SC2016 # the program of awk
ui_uid="$(k exec "deploy/$release-ui" -- awk '/^Uid:/ { print $2 }' /proc/1/status 2>/dev/null || true)"
check "the Caddy of ui runs as uid 65532 ($ui_uid)" [ "$ui_uid" = 65532 ]

# --- through the Ingress --------------------------------------------------------------------
info "the Ingress"
check "/healthz is 200" [ "$(http_code "$base/healthz")" = 200 ]
readyz="$(curl -s "$base/readyz")"
check "/readyz reports database ok" contains "$(tr -d ' ' <<<"$readyz")" '"database":"ok"'
instance="$(curl -sf "$base/v1/instance")"
check "/v1/instance reports version $tag" contains "$instance" "\"version\":\"$tag\""
check "/v1/instance reports tenancy single" contains "$instance" '"tenancy":"single"'
check "/ is the UI" grep -qi '<html' <<<"$(curl -sf "$base/")"
check "/metrics through the Ingress has no metrics" lacks "$(curl -s "$base/metrics")" "cadence_"

# --- sign-in, team, project, bundle ------------------------------------------------------------
info "clab with the token of the Secret"
clab="${CLAB_BIN:-}"
if [ -z "$clab" ]; then
  curl -fsSL https://raw.githubusercontent.com/cadence-lab-tech/homebrew-tap/main/install.sh |
    CLAB_VERSION="$version" CLAB_INSTALL_DIR="$work/bin" sh >/dev/null
  clab="$work/bin/clab"
fi
export CLAB_CONFIG_DIR="$work/clab"
k get secret cadence -o go-template='{{index .data "admin-token" | base64decode}}' | "$clab" auth login --host "$base" --with-token >/dev/null
check "clab whoami is admin" contains "$("$clab" --host "$base" whoami 2>&1)" "admin"
check "clab team create" "$clab" --host "$base" team create check --name "Helm check"
check "clab project create" "$clab" --host "$base" project create CHECK --name "Helm check" --team check
check "clab import of the starter bundle" "$clab" --host "$base" import --project CHECK --file bundles/starter.json
for id in $("$clab" --host "$base" workflow list --project CHECK --json |
  jq -r '(if type == "array" then . else (.workflows // .items) end)[] | select(.state == "draft") | .id'); do
  check "clab workflow activate $id" "$clab" --host "$base" workflow activate "$id" --project CHECK
done

# --- MCP through the Ingress ---------------------------------------------------------------
info "MCP"
auth=(-H "Authorization: Bearer $admin_token")
mcp_headers="$work/mcp-headers"
mcp="$(curl -s -D "$mcp_headers" "${auth[@]}" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"check-helm","version":"1"}}}' \
  "$base/mcp/projects/CHECK")"
check "initialize through the Ingress is 200" grep -qE '^HTTP/[0-9.]+ 200' "$mcp_headers"
check "...with the result of the server" contains "$mcp" '"protocolVersion"'
check "...as a stream (text/event-stream)" grep -qi '^content-type: text/event-stream' "$mcp_headers"
# The annotations of the guide reach the controller: every location of the
# host keeps a stream open for an hour (the default cuts it after 60s),
# does not buffer it, and takes an artifact up to the limit of the service.
nginx_conf="$(kubectl -n ingress-nginx exec deploy/ingress-nginx-controller -- cat /etc/nginx/nginx.conf)"
server_conf="$(awk -v s="## start server $host" -v e="## end server $host" '$0 ~ s { on = 1 } on; $0 ~ e { exit }' <<<"$nginx_conf")"
check "the controller has the server $host" [ -n "$server_conf" ]
check "...each location keeps a stream for 3600s (proxy_read_timeout)" \
  [ "$(grep -E 'proxy_read_timeout' <<<"$server_conf" | awk '{print $2}' | sort -u)" = "3600s;" ]
check "...and does not buffer it (proxy_buffering off)" [ "$(grep -E 'proxy_buffering' <<<"$server_conf" | awk '{print $2}' | sort -u)" = "off;" ]
check "...and takes 64m (client_max_body_size)" contains "$server_conf" 'client_max_body_size                    64m;'

# --- an artifact in the bucket -----------------------------------------------------------------
info "artifact content in the bucket"
# step WHAT CMD...: CMD must succeed; its output is shown when it does not.
step() {
  local what="$1" out
  shift
  if out="$("$@" 2>&1)"; then pass "$what"; else fail "$what"; printf '%s\n' "$out" | sed 's/^/      /' >&2; fi
}
step "clab create a task" "$clab" --host "$base" create --project CHECK --title "Helm task"
step "clab transition CHECK-1 --to start" env SDLC_PROJECT=CHECK "$clab" --host "$base" transition CHECK-1 --to start
agent_token="$("$clab" --host "$base" token create --project CHECK --name helm-agent --for agent:helm-bot --roles analyst --json | jq -r .token)"
if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::add-mask::$agent_token"; fi
agent() { env SDLC_API_URL="$base" SDLC_TOKEN="$agent_token" SDLC_PROJECT=CHECK CLAB_CONFIG_DIR="$work/agent" "$clab" "$@"; }
step "the agent claims CHECK-1 as analyst" agent claim CHECK-1
{
  echo "# Brief"
  for i in $(seq 1 400); do echo "line $i of the brief that goes to the bucket, not the database"; done
} >"$work/brief.md"
before="$(s3_keys helm/ | grep -c . || true)"
step "the agent submits a brief of $(wc -c <"$work/brief.md" | tr -d ' ') bytes" agent submit CHECK-1 --kind analysis.brief --title "Brief" --file "$work/brief.md"
artifact_id="$(curl -s "${auth[@]}" "$base/v1/tasks/CHECK-1/artifacts" |
  jq -r '[.. | objects | select(.kind? == "analysis.brief") | .id // empty] | .[0] // empty' || true)"
if [ -n "$artifact_id" ]; then pass "the task lists the artifact $artifact_id"; else fail "the task lists the artifact"; fi
# artifact_content: the content of the brief as the API serves it.
artifact_content() { curl -sf "${auth[@]}" "$base/v1/artifacts/$artifact_id/content"; }
after="$(s3_keys helm/ | grep -c . || true)"
check "the brief is an object under helm/ in the bucket ($before -> $after)" [ "$after" -gt "$before" ]
artifact_content >"$work/brief.out" 2>&1 || true
check "the API serves the same content from the bucket" grep -qF "line 400 of the brief" "$work/brief.out"

# --- metrics inside the cluster ------------------------------------------------------------------
info "metrics inside the cluster"
in_cluster() {
  k run "curl-$RANDOM" --image=curlimages/curl:8.16.0 --restart=Never --rm -i --quiet \
    --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":100,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"c","image":"curlimages/curl:8.16.0","args":["-s","'"$1"'"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' 2>/dev/null
}
check "the API serves cadence_* on :9090 inside the cluster" contains "$(in_cluster "http://$release-api:9090/metrics")" "cadence_"
check "the worker serves cadence_worker_* on :9090 inside the cluster" contains "$(in_cluster "http://$release-worker-metrics:9090/metrics")" "cadence_worker_"

# --- no value of a secret --------------------------------------------------------------------
info "no value of a secret in the release"
shown="$(helm get values "$release" -n "$ns" --all; helm get manifest "$release" -n "$ns"; k get deploy,pods -o yaml)"
for s in "${secret_values[@]}"; do
  check "helm get values, the manifests and the pods have no value of a secret" lacks "$shown" "$s"
done
check "the containers get the secrets as files" contains "$shown" "SDLC_ADMIN_TOKEN_FILE"

# --- a key missing in the Secret ----------------------------------------------------------------
info "a key missing in the Secret"
kubectl create namespace cadence-missing >/dev/null
kubectl -n cadence-missing create secret generic cadence --from-file="$sec/admin-token" --from-file="$sec/db-password" \
  --from-file="$sec/s3-access-key-id" --from-file="$sec/s3-secret-access-key" --from-file="$sec/db-ca.pem" >/dev/null
helm install missing "$chart" -n cadence-missing -f "$work/values.yaml" --set secrets.keys.SDLC_GITHUB_TOKEN=github-token >/dev/null 2>&1 || true
events=""
for _ in $(seq 1 30); do
  events="$(kubectl -n cadence-missing get events --field-selector reason=FailedMount -o jsonpath='{range .items[*]}{.message}{"\n"}{end}' 2>/dev/null || true)"
  contains "$events" "github-token" && break
  sleep 2
done
check "the pod does not start: the event names the key and the Secret" contains "$events" "github-token"
check "no api pod of that release is Ready" [ "$(kubectl -n cadence-missing get pods -l app.kubernetes.io/component=api -o json |
  jq '[.items[] | select(.status.conditions[]? | .type == "Ready" and .status == "True")] | length')" = 0 ]
helm uninstall missing -n cadence-missing >/dev/null 2>&1 || true
kubectl delete namespace cadence-missing --wait=false >/dev/null

# --- upgrades ------------------------------------------------------------------------------------
info "helm upgrade refused by the precheck keeps the pods"
pods_before="$(k get pods -l app.kubernetes.io/component=api -o jsonpath='{.items[*].metadata.uid}')"
set +e
out="$(helm upgrade "$release" "$chart" -n "$ns" -f "$work/values.yaml" --set api.replicas=3 \
  --set database.url="$(db_url cadence_noext)" --wait --timeout 3m 2>&1)"
code=$?
set -e
check "helm upgrade fails (exit $code)" [ "$code" != 0 ]
check "...in the pre-upgrade hook" contains "$out" "pre-upgrade"
check "the api pods are the same and Ready" [ "$(k get pods -l app.kubernetes.io/component=api -o jsonpath='{.items[*].metadata.uid}')" = "$pods_before" -a "$(ready api)" = 3 ]
check "the instance still answers" [ "$(http_code "$base/readyz")" = 200 ]

info "helm upgrade with a changed value keeps the data"
if out="$(helm upgrade "$release" "$chart" -n "$ns" -f "$work/values.yaml" --set config.shared.SDLC_LOG_LEVEL=debug --wait --timeout 6m 2>&1)"; then
  pass "helm upgrade --wait succeeded"
else
  printf '%s\n' "$out" >&2
  fail "helm upgrade --wait succeeded"
fi
check "the API runs with SDLC_LOG_LEVEL=debug" [ "$(k get deploy "$release-api" -o json |
  jq -r '.spec.template.spec.containers[0].env[] | select(.name == "SDLC_LOG_LEVEL") | .value')" = debug ]
check "one api pod after the upgrade (api.replicas back to 1)" [ "$(ready api)" = 1 ]
check "the same token signs in" contains "$("$clab" --host "$base" whoami 2>&1)" "admin"
check "the project CHECK is there" contains "$("$clab" --host "$base" project list --json)" '"CHECK"'
check "the artifact is there with its content" grep -qF "line 400 of the brief" <(artifact_content 2>/dev/null)

[ "$failures" -eq 0 ] || die "$failures check(s) failed"
ok "Helm chart checks passed"
