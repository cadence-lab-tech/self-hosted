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
# bucket; a file of 1 MiB uploaded through the Ingress (multipart, spooled to
# the emptyDir of /tmp of the read-only API) and downloaded with its sha256
# and name (CLAB-300); the long poll of events through the Ingress; the
# metrics inside the cluster only; Pod Security; no value of a
# secret in the values of the release or the manifests; a key missing in the
# Secret; a refused upgrade keeps the pods; an upgrade with a changed value
# keeps the data; the manifests of the bucket without keys (Pod Identity and
# IRSA, CLAB-394) admitted under restricted by a dry run; the HTTPRoute of the
# chart (httpRoute.enabled, CLAB-456) validated by the API server against the
# CRDs of Gateway API, installed only after the chart is: with the route off
# the chart needs none. CI runs it in the job "helm" of check.yml.
#
# Two live routes, in the same cluster (CLAB-457):
#   - the Ingress, through ingress-nginx controller-v1.15.1: the default of
#     the chart and the example of docs/admin.md for the installations that
#     run on it. ingress-nginx is retired, so the pin stays where it is;
#     the scenario stays while it comes up (the manifest and the images are
#     there, kind runs it) and a human has not moved the example to another
#     controller - to be looked at again by 2027-03-31 at the latest;
#   - the HTTPRoute, through Envoy Gateway CHECK_ENVOY_GATEWAY_VERSION, the
#     way "Envoy Gateway" of docs/admin.md has it: its manifest over the CRDs
#     of the dry run, then the GatewayClass and the Gateway of the block
#     "# cadence-gateway.yaml" and the overlay "# cadence-values-httproute.yaml",
#     both read from docs/admin.md, not kept here. The release serves both
#     routes at once (the move of the guide), the probes, the UI, sign-in,
#     MCP, the long poll of events held longer than the default timeout of a
#     route of Envoy (15 s: what reaches Envoy is the timeouts of the
#     overlay) and a file of 1 MiB through the Gateway; then the overlay as
#     it is drops the Ingress, and the data is there through the Gateway;
#     last, the route without the timeouts: Envoy cuts the long poll after
#     15 s with a 504, the default docs/admin.md names.
#     What kind needs and the guide does not have, and nothing else:
#       * the listener "https" is plain HTTP on port 80 with no tls and the
#         hostname localhost, and the route takes hostnames [localhost]:
#         TLS is not checked, as with the Ingress;
#       * the Gateway takes an EnvoyProxy of its own (infrastructure
#         parametersRef): the Service of Envoy is a NodePort on 30080 (in
#         the static band of the range, see gateway_node_port), mapped by
#         kind to 127.0.0.1:CHECK_GATEWAY_PORT - no port-forward;
#       * ingress.enabled=true for the step with both routes, and
#         config.shared.SDLC_LOG_LEVEL=debug of the upgrade before, so the
#         pods are not replaced.
#     No policy of Envoy Gateway is applied: the guide says none is needed,
#     and the timeouts of the overlay are not touched. A Gateway or a route
#     not ready by its deadline prints the status of the GatewayClass, the
#     Gateway, the HTTPRoute and the policies, the events and the logs of
#     the controller and of Envoy, and ends the check naming the object.
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
#   CHECK_GATEWAY_PORT
#                     host port of the Gateway (127.0.0.1), default
#                     CHECK_HTTP_PORT + 1; the same port as the Ingress or
#                     the bucket is refused before the cluster is made
#   CADENCE_REGISTRY  registry of the images (image.registry), default
#                     ghcr.io/cadence-lab-tech
#   CADENCE_BACKEND_DIGEST, CADENCE_FRONTEND_DIGEST
#                     unset - the pins of values.yaml; empty - no pin, the
#                     images by tag (images of a branch)
#   CHECK_IMAGE_TAG   tag of the images (image.tag), default VERSION
#   CLAB_BIN          clab to use; default: the CLI of VERSION from the tap
#   CHECK_ATTACHMENTS=1
#                     run the scenario of a file through the Ingress on images
#                     of a branch built under the tag of VERSION before
#                     v0.18.0 (the published images of those have no
#                     attachments, and the scenario is skipped for them)
#   CHECK_GATEWAY_API_VERSION
#                     release of the CRDs of Gateway API (Standard channel)
#                     the HTTPRoute of the chart is validated against, default
#                     v1.2.1 - the smallest one docs/admin.md names
#   CHECK_ENVOY_GATEWAY_VERSION
#                     release of Envoy Gateway the HTTPRoute is served by,
#                     default v1.10.0 - the one docs/admin.md names (its
#                     install.yaml brings Gateway API v1.6.1, and its
#                     Kubernetes are v1.34 to v1.37: the node of kind v0.30.0
#                     of check.yml is v1.34)
#   CHECK_KEEP=1      leave the cluster and the stand-ins after the check
#
# Images in a local registry (localhost:*) are not reachable from the nodes
# of kind: the check pulls them on this machine for the platform of the node
# and loads that platform into the cluster - kind load docker-image, and
# when it fails (a multi-platform image in the containerd image store of
# Docker Desktop: "content digest ... not found") the archive of that
# platform alone, docker save --platform (Docker 28 or newer) and kind load
# image-archive. Images of a branch, as for ci/check-stack.sh, built for
# both platforms with the attestations of buildx:
#
#   CADENCE_REGISTRY=localhost:5050 CADENCE_BACKEND_DIGEST= CADENCE_FRONTEND_DIGEST= \
#     CHECK_CLUSTER=check-<name> CHECK_HTTP_PORT=<port> ci/check-helm.sh
#
# If the images still do not load, the fallback is images of one platform
# without attestations: docker buildx build --platform linux/<arch>
# --provenance=false --sbom=false ... --push.
#
# Needs Docker, kind, helm, kubectl, jq, curl and openssl. The images must
# read *_FILE (v0.13.0 or newer) and the frontend image must run as uid 65532
# on :8080 (v0.14.0 or newer, CLAB-236) with no capability to add (v0.16.0
# or newer, CLAB-248: before it the Caddy binary carries a file capability
# and fails to exec under drop ALL): check.yml skips the job for an older
# VERSION.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=ci/lib.sh
. ./ci/lib.sh
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
gateway_port="${CHECK_GATEWAY_PORT:-$((port + 1))}"
version="$(tr -d '[:space:]' <VERSION)"
gateway_api="${CHECK_GATEWAY_API_VERSION:-v1.2.1}"
envoy_gateway="${CHECK_ENVOY_GATEWAY_VERSION:-v1.10.0}"
tag="${CHECK_IMAGE_TAG:-$version}"
registry="${CADENCE_REGISTRY:-ghcr.io/cadence-lab-tech}"
ns=cadence
release=cadence
host=localhost
base="http://$host:$port"
gw_base="http://$host:$gateway_port"
# The NodePort of Envoy, fixed by the EnvoyProxy of the check: in the static
# band of the range (30000-30085 of the default one), which the API server
# gives a Service that asks for no port only when the rest of the range is
# taken - the NodePorts of ingress-nginx do not take it.
gateway_node_port=30080
for p in "CHECK_HTTP_PORT=$port" "CHECK_GATEWAY_PORT=$gateway_port" "CHECK_S3_PORT=$s3_port"; do
  case "${p#*=}" in '' | *[!0-9]*) die "$p: a port is a number" ;; esac
done
[ "$gateway_port" != "$port" ] ||
  die "CHECK_GATEWAY_PORT ($gateway_port) is CHECK_HTTP_PORT, the port of the Ingress: give the Gateway a port of its own"
[ "$gateway_port" != "$s3_port" ] ||
  die "CHECK_GATEWAY_PORT ($gateway_port) is CHECK_S3_PORT, the port of the bucket: give the Gateway a port of its own"
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
# step WHAT CMD...: CMD must succeed; its output is shown when it does not.
step() {
  local what="$1" out
  shift
  if out="$("$@" 2>&1)"; then pass "$what"; else fail "$what"; printf '%s\n' "$out" | sed 's/^/      /' >&2; fi
}
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
info "kind cluster $cluster, the Ingress on 127.0.0.1:$port, the Gateway on 127.0.0.1:$gateway_port"
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
      - containerPort: $gateway_node_port
        hostPort: $gateway_port
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
platform_of() { docker image inspect -f '{{.Os}}/{{.Architecture}}' "$1" 2>/dev/null; }
# load_image REF: the image REF of the local registry into the node, the
# platform of the node only. kind load docker-image imports every platform
# docker save hands it; a multi-platform image pulled into the containerd
# image store has the blobs of one platform, so the import fails and the
# archive of that platform goes instead. Nothing of the first try is shown
# when the second one loads the image.
load_image() {
  local ref="$1" archive="$work/image.tar" out
  local hint="build images of one platform without attestations: docker buildx build --platform $node_platform --provenance=false --sbom=false ... --push"
  # Not here, or here for another platform only: pulled for the node. Docker
  # pulls an image of one platform whatever --platform asks: it is checked.
  if [ "$(platform_of "$ref")" != "$node_platform" ]; then
    out="$(docker pull -q --platform "$node_platform" "$ref" 2>&1)" ||
      die "$ref: cannot pull it for $node_platform, the platform of the kind node ($(tail -n1 <<<"$out")); $hint"
    [ "$(platform_of "$ref")" = "$node_platform" ] ||
      die "$ref: no image for $node_platform, the platform of the kind node, only $(platform_of "$ref"); $hint"
  fi
  out="$(kind load docker-image --name "$cluster" "$ref" 2>&1)" && return 0
  if out="$out"$'\n'"$({ docker save --platform "$node_platform" -o "$archive" "$ref" &&
    kind load image-archive --name "$cluster" "$archive"; } 2>&1)"; then
    rm -f "$archive"
    return 0
  fi
  rm -f "$archive"
  printf '%s\n' "$out" | sed 's/^/      /' >&2
  die "$ref: kind does not load it for $node_platform, not even as docker save --platform (Docker 28 or newer); $hint"
}
case "$registry" in
localhost:* | 127.0.0.1:*)
  node_platform="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.operatingSystem}/{.items[0].status.nodeInfo.architecture}')"
  info "images of $registry: pulled here and loaded into kind for $node_platform"
  for ref in "$backend_image" "$frontend_image"; do
    load_image "$ref"
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
    nginx.ingress.kubernetes.io/proxy-body-size: 129m
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
check "no pod adds a capability" \
  [ "$(for c in api worker ui; do spec_of "$c" | jq -r --arg c "$c" '[.containers[], (.initContainers // [])[]] | map("\($c):\(.securityContext.capabilities.add // [] | join(","))") | join(" ")'; done | tr '\n' ' ')" = \
    "api: worker: worker: ui: " ]
# shellcheck disable=SC2016 # the program of awk
ui_uid="$(k exec "deploy/$release-ui" -- awk '/^Uid:/ { print $2 }' /proc/1/status 2>/dev/null || true)"
check "the Caddy of ui runs as uid 65532 ($ui_uid)" [ "$ui_uid" = 65532 ]
# The bucket without keys (CLAB-394): kind has neither Pod Identity nor IRSA,
# so these modes are not installed - the API server admits their manifests
# under restricted (a dry run of another release in the same namespace, on a
# host of its own: the controller refuses a second Ingress of the same host
# and path): the role in the annotation, and the token of the role mounted
# by the chart.
role=arn:aws:iam::111122223333:role/cadence-check
for mode in annotation podIdentity irsa; do
  extra=()
  [ "$mode" = annotation ] || extra=(--set "serviceAccount.projectedToken.$mode=true")
  dry="$(helm template nokeys "$chart" -n "$ns" -f "$work/values.yaml" --set ingress.host=nokeys.invalid \
    --set secrets.keys.SDLC_BLOB_S3_ACCESS_KEY_ID= \
    --set secrets.keys.SDLC_BLOB_S3_SECRET_ACCESS_KEY= --set-string "serviceAccount.annotations.eks\.amazonaws\.com/role-arn=$role" \
    ${extra[@]+"${extra[@]}"} | kubectl apply -n "$ns" --dry-run=server -f - 2>&1 >/dev/null || echo "exit $?")"
  check "no keys of the bucket ($mode): admitted under restricted, no warning ($(printf '%s' "${dry:-none}" | tr '\n' ' '))" \
    [ -z "$dry" ]
done

# --- HTTPRoute against Gateway API (CLAB-456) --------------------------------------------
info "HTTPRoute (Gateway API $gateway_api)"
# The install above ran with no CRD of Gateway API in the cluster: the chart
# with httpRoute off needs none. Now they go in (Standard channel, the
# smallest version the guide names), and the API server validates the
# HTTPRoute of the chart against their schema. The route is served later,
# through Envoy Gateway: see "Gateway API, live".
check "the release installed with no CRD of Gateway API in the cluster" \
  [ -z "$(kubectl get crd -o name | grep -F 'gateway.networking.k8s.io' || true)" ]
check "...and has no HTTPRoute among its manifests" lacks "$(helm get manifest "$release" -n "$ns")" "gateway.networking.k8s.io"
check "the CRDs of Gateway API $gateway_api (Standard channel) install" \
  kubectl apply --server-side -f "https://github.com/kubernetes-sigs/gateway-api/releases/download/$gateway_api/standard-install.yaml"
check "...and HTTPRoute is established" kubectl wait --for=condition=Established crd/httproutes.gateway.networking.k8s.io --timeout=60s
cat >"$work/httproute-values.yaml" <<EOT
ingress: {enabled: false}
httpRoute:
  enabled: true
  parentRefs:
    - {name: gateway, namespace: infra, sectionName: https}
  hostnames: [cadence.example.com]
  annotations: {check: httproute}
  labels: {team: check}
  timeouts: {request: 3600s, backendRequest: 3600s}
EOT
route_manifest() { helm template route "$chart" -n "$ns" -f "$work/values.yaml" -f "$work/httproute-values.yaml" "$@" --show-only templates/httproute.yaml; }
# stdout is dropped: what stays is the stderr of kubectl, errors and warnings.
route_dry="$(route_manifest | kubectl apply -n "$ns" --dry-run=server -f - 2>&1 >/dev/null || echo "exit $?")"
check "the HTTPRoute with parentRefs, hostnames and timeouts passes the schema, no error and no warning (${route_dry:-none})" [ -z "$route_dry" ]
route_created="$(route_manifest | kubectl apply -n "$ns" --dry-run=server -f - -o name 2>&1 || true)"
check "...the API server names it httproute.gateway.networking.k8s.io/route-cadence" contains "$route_created" "httproute.gateway.networking.k8s.io/route-cadence"
# The schema is applied: a backendRequest longer than request is refused.
bad_dry="$(route_manifest --set httpRoute.timeouts.request=1s --set httpRoute.timeouts.backendRequest=2s |
  kubectl apply -n "$ns" --dry-run=server -f - 2>&1 || true)"
check "an HTTPRoute with backendRequest longer than request is refused by the schema" contains "$bad_dry" "backendRequest"
bad_dry="$(route_manifest --set httpRoute.timeouts.request=an-hour | kubectl apply -n "$ns" --dry-run=server -f - 2>&1 || true)"
check "an HTTPRoute with a timeout that is no duration is refused by the schema" contains "$bad_dry" "timeouts"

# --- Envoy Gateway (CLAB-457) ---------------------------------------------------------------
# Installed here, over the CRDs of the dry run, and waited for at the end:
# the controller and Envoy start while the checks of the Ingress run.
gw_ns=envoy-gateway-system
info "Envoy Gateway $envoy_gateway over the CRDs of Gateway API $gateway_api"
if ! out="$(kubectl apply --server-side -f "https://github.com/envoyproxy/gateway/releases/download/$envoy_gateway/install.yaml" 2>&1 >/dev/null)"; then
  printf '%s\n' "$out" | tail -n 20 | sed 's/^/      /' >&2
  die "the manifest of Envoy Gateway $envoy_gateway does not apply (kubectl apply --server-side)"
fi
pass "the manifest of Envoy Gateway $envoy_gateway applies over the CRDs of $gateway_api (kubectl apply --server-side)"
crd_version() { kubectl get crd "$1" -o jsonpath='{.metadata.annotations.gateway\.networking\.k8s\.io/bundle-version} {.metadata.annotations.gateway\.networking\.k8s\.io/channel}'; }
info "...the CRD of HTTPRoute is now $(crd_version httproutes.gateway.networking.k8s.io)"

# --- through the Ingress --------------------------------------------------------------------
# The checks of a route are functions of its name and its address: the
# Ingress and the Gateway (at the end) go through the same ones.
# route_checks VIA BASE: the probes, the version, the UI and no metrics.
route_checks() {
  local via="$1" b="$2" readyz instance
  check "/healthz through $via is 200" [ "$(http_code "$b/healthz")" = 200 ]
  readyz="$(curl -s "$b/readyz")"
  check "/readyz through $via reports database ok" contains "$(tr -d ' ' <<<"$readyz")" '"database":"ok"'
  instance="$(curl -sf "$b/v1/instance")"
  check "/v1/instance through $via reports version $tag" contains "$instance" "\"version\":\"$tag\""
  check "/v1/instance through $via reports tenancy single" contains "$instance" '"tenancy":"single"'
  check "/ through $via is the UI" grep -qi '<html' <<<"$(curl -sf "$b/")"
  check "/metrics through $via has no metrics" lacks "$(curl -s "$b/metrics")" "cadence_"
}
info "the Ingress"
route_checks "the Ingress" "$base"

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
check "clab import of the starter bundle" "$clab" --host "$base" import --project CHECK --file "$(starter_for_server "$version" "$work/starter-format1.json")"
for id in $("$clab" --host "$base" workflow list --project CHECK --json |
  jq -r '(if type == "array" then . else (.workflows // .items) end)[] | select(.state == "draft") | .id'); do
  check "clab workflow activate $id" "$clab" --host "$base" workflow activate "$id" --project CHECK
done

# --- MCP through the Ingress ---------------------------------------------------------------
info "MCP"
auth=(-H "Authorization: Bearer $admin_token")
# mcp_checks VIA BASE: initialize answered as a stream.
mcp_checks() {
  local via="$1" b="$2" mcp mcp_headers="$work/mcp-headers"
  mcp="$(curl -s -D "$mcp_headers" "${auth[@]}" -H 'Content-Type: application/json' -H 'Accept: application/json, text/event-stream' \
    -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"check-helm","version":"1"}}}' \
    "$b/mcp/projects/CHECK")"
  check "initialize through $via is 200" grep -qE '^HTTP/[0-9.]+ 200' "$mcp_headers"
  check "...with the result of the server" contains "$mcp" '"protocolVersion"'
  check "...as a stream (text/event-stream)" grep -qi '^content-type: text/event-stream' "$mcp_headers"
}
mcp_checks "the Ingress" "$base"
# The annotations of the guide reach the controller: every location of the
# host keeps a stream open for an hour (the default cuts it after 60s),
# does not buffer it, and takes an artifact up to the limit of the service.
nginx_conf="$(kubectl -n ingress-nginx exec deploy/ingress-nginx-controller -- cat /etc/nginx/nginx.conf)"
server_conf="$(awk -v s="## start server $host" -v e="## end server $host" '$0 ~ s { on = 1 } on; $0 ~ e { exit }' <<<"$nginx_conf")"
check "the controller has the server $host" [ -n "$server_conf" ]
check "...each location keeps a stream for 3600s (proxy_read_timeout)" \
  [ "$(grep -E 'proxy_read_timeout' <<<"$server_conf" | awk '{print $2}' | sort -u)" = "3600s;" ]
check "...and does not buffer it (proxy_buffering off)" [ "$(grep -E 'proxy_buffering' <<<"$server_conf" | awk '{print $2}' | sort -u)" = "off;" ]
check "...and takes 129m (client_max_body_size): a file of the limit of the service in multipart" contains "$server_conf" 'client_max_body_size                    129m;'

# --- an artifact in the bucket -----------------------------------------------------------------
info "artifact content in the bucket"
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
# artifact_content [BASE]: the content of the brief as the API serves it.
artifact_content() { curl -sf "${auth[@]}" "${1:-$base}/v1/artifacts/$artifact_id/content"; }
after="$(s3_keys helm/ | grep -c . || true)"
check "the brief is an object under helm/ in the bucket ($before -> $after)" [ "$after" -gt "$before" ]
artifact_content >"$work/brief.out" 2>&1 || true
check "the API serves the same content from the bucket" grep -qF "line 400 of the brief" "$work/brief.out"
# The source of the keys in the log of the start (CLAB-394, images of
# v0.24.0 and later, or of a branch with CADENCE_BACKEND_DIGEST=): the keys
# of the Secret, no key in the line.
if [ -z "$backend_digest" ] || ! version_lt "$version" v0.24.0; then
  for d in api worker; do
    start_log="$(k logs "deploy/$release-$d" 2>&1 | grep -F '"credentials"' || true)"
    check "$d: the log names the source of the keys of the bucket, static" contains "$start_log" '"credentials":"static"'
    check "$d: ...without the secret key" lacks "$start_log" "$S3_SECRET"
  done
else
  info "VERSION is $version: the source of the keys in the log comes with v0.24.0, skipped"
fi

# --- a file through the Ingress (CLAB-300) -----------------------------------------------------
# The root filesystem of the API is read-only, and a file above the inline
# limit (4096 bytes here) is spooled to /tmp before it goes to the bucket:
# this upload fails (500) on a chart without the emptyDir of /tmp. It is a
# multipart body through the Ingress, which takes 129m, and comes back with
# the same sha256 and its name in Content-Disposition.
# Attachments are in the images of v0.18.0 (CLAB-296): the published images of
# an older VERSION have no such route, so the scenario is skipped for them;
# CHECK_ATTACHMENTS=1 runs it on images of a branch built under the tag of an
# older VERSION.
# file_checks VIA BASE: a file of 1 MiB up and down through the route.
file_checks() {
  local via="$1" b="$2" file_name="helm-model.bin" file_sha file_code file_id before after
  head -c 1048576 /dev/urandom >"$work/model.bin"
  file_sha="$(sha256_of "$work/model.bin")"
  before="$(s3_keys helm/ | grep -c . || true)"
  file_code="$(curl -s -o "$work/file.json" -w '%{http_code}' "${auth[@]}" -F "title=Helm model" \
    -F "file=@$work/model.bin;filename=$file_name;type=application/octet-stream" "$b/v1/tasks/CHECK-1/attachments")"
  check "a file of 1 MiB through $via: 201 (got $file_code)" [ "$file_code" = 201 ]
  file_id="$(jq -r '.id // empty' "$work/file.json" 2>/dev/null || true)"
  if [ -n "$file_id" ]; then pass "the answer names the artifact $file_id"; else
    fail "the answer names the artifact"
    sed 's/^/      /' "$work/file.json" >&2 || true
  fi
  after="$(s3_keys helm/ | grep -c . || true)"
  check "the file is an object under helm/ in the bucket ($before -> $after)" [ "$after" -gt "$before" ]
  file_code="$(curl -s -o "$work/model.out" -D "$work/model.hdr" -w '%{http_code}' "${auth[@]}" "$b/v1/artifacts/${file_id:-none}/content")"
  check "the file downloads through $via: 200 (got $file_code)" [ "$file_code" = 200 ]
  check "...with the sha256 it was uploaded with" [ "$(sha256_of "$work/model.out")" = "$file_sha" ]
  check "...and its name in Content-Disposition" grep -qi "^content-disposition:.*filename=\"$file_name\"" "$work/model.hdr"
}
attachments=
if [ "${CHECK_ATTACHMENTS:-}" = 1 ] || ! version_lt "$version" v0.18.0; then attachments=1; fi
if [ -n "$attachments" ]; then
  info "a file through the Ingress"
  file_checks "the Ingress" "$base"
else
  info "VERSION is $version: attachments come with v0.18.0, the scenario is skipped (CHECK_ATTACHMENTS=1 runs it on images of a branch)"
fi

# --- events by long poll through the Ingress (CLAB-457) -----------------------------------------
# clab wait and the agent plugin long-poll GET /v1/tasks/:key/events: with no
# event after the cursor the API holds the answer for wait seconds, and the
# route passes it as it is. Through the Gateway (at the end) the wait is
# longer than the default timeout of a route of Envoy. The images before
# v0.19.0 have no such route; images of a branch (a pin variable empty) are
# checked whatever VERSION says, as in ci/check-stack.sh.
long_poll_on=
if ! version_lt "$version" v0.19.0 || [ -z "$backend_digest" ]; then long_poll_on=1; fi
# long_poll VIA BASE WAIT MIN MAX: 200, an object with events and a cursor,
# held for MIN-MAX seconds.
long_poll() {
  local via="$1" b="$2" wait="$3" lo="$4" hi="$5" cursor code took
  cursor="$(curl -sf "${auth[@]}" "$b/v1/tasks/CHECK-1/events" | jq -r '.cursor // empty' 2>/dev/null || true)"
  check "the handshake of GET /v1/tasks/CHECK-1/events through $via names a cursor" [ -n "$cursor" ]
  read -r code took < <(curl -s -o "$work/events.json" -w '%{http_code} %{time_total}\n' "${auth[@]}" \
    --get --data-urlencode "after=$cursor" --data "wait=$wait" "$b/v1/tasks/CHECK-1/events" || echo "000 0")
  check "a long poll with wait=$wait through $via: 200 (got $code)" [ "$code" = 200 ]
  check "...an object with events and a cursor" [ "$(jq -r 'has("events") and (.cursor | type == "string")' "$work/events.json" 2>/dev/null)" = true ]
  check "...held for $lo-$hi s (took $took s)" awk -v t="$took" -v lo="$lo" -v hi="$hi" 'BEGIN { exit !(t >= lo && t <= hi) }'
}
if [ -n "$long_poll_on" ]; then
  info "events by long poll through the Ingress"
  long_poll "the Ingress" "$base" 3 2.9 5
else
  info "VERSION is $version: the events endpoint comes with v0.19.0, the long poll is skipped"
fi

# --- metrics inside the cluster ------------------------------------------------------------------
info "metrics inside the cluster"
# in_cluster URL: the body of URL fetched by a pod of the namespace. Not
# kubectl run -i: curl may end before kubectl attaches, and the logs it falls
# back to are now and then empty. The pod runs to its end, then its logs.
in_cluster() {
  local pod="curl-$RANDOM"
  k run "$pod" --image=curlimages/curl:8.16.0 --restart=Never \
    --overrides='{"spec":{"securityContext":{"runAsNonRoot":true,"runAsUser":100,"seccompProfile":{"type":"RuntimeDefault"}},"containers":[{"name":"c","image":"curlimages/curl:8.16.0","args":["-s","'"$1"'"],"securityContext":{"allowPrivilegeEscalation":false,"capabilities":{"drop":["ALL"]}}}]}}' >/dev/null 2>&1 || return 0
  for _ in $(seq 1 90); do
    case "$(k get pod "$pod" -o jsonpath='{.status.phase}' 2>/dev/null)" in Succeeded | Failed) break ;; esac
    sleep 2
  done
  k logs "$pod" 2>/dev/null || true
  k delete pod "$pod" --wait=false >/dev/null 2>&1 || true
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

# --- Gateway API, live: Envoy Gateway (CLAB-457) -------------------------------------------------
info "Gateway API through Envoy Gateway $envoy_gateway on 127.0.0.1:$gateway_port"
# gateway_diag WHAT: what stands behind a Gateway that is not ready - the
# status of the objects and the policies, the events and the logs of the
# controller and of Envoy - then the end of the check, naming WHAT.
gateway_diag() {
  {
    echo "--- GatewayClass envoy"
    kubectl get gatewayclass envoy -o json 2>&1 | jq '.status' 2>/dev/null || true
    echo "--- Gateway infra/gateway"
    kubectl -n infra get gateway gateway -o json 2>&1 | jq '.status' 2>/dev/null || true
    echo "--- HTTPRoute $ns/$release"
    k get httproute "$release" -o json 2>&1 | jq '.status' 2>/dev/null || true
    echo "--- policies of Envoy Gateway"
    kubectl get clienttrafficpolicies.gateway.envoyproxy.io,backendtrafficpolicies.gateway.envoyproxy.io -A -o json 2>&1 |
      jq '[.items[] | {kind, name: .metadata.name, namespace: .metadata.namespace, status}]' 2>/dev/null || true
    echo "--- pods and events of $gw_ns"
    kubectl -n "$gw_ns" get pods -o wide 2>&1 || true
    kubectl -n "$gw_ns" get events --sort-by=.lastTimestamp 2>&1 | tail -n 30 || true
    echo "--- the log of the controller"
    kubectl -n "$gw_ns" logs deploy/envoy-gateway --tail=40 2>&1 || true
    echo "--- the log of Envoy"
    kubectl -n "$gw_ns" logs -l gateway.envoyproxy.io/owning-gateway-name=gateway --all-containers --tail=40 2>&1 || true
  } | sed 's/^/      /' >&2
  die "$1"
}
# until_ready SECONDS WHAT CMD...: CMD again every 2 s until it succeeds; by
# the deadline the diagnostics of the Gateway and the end of the check.
until_ready() {
  local limit="$1" what="$2" deadline
  shift 2
  deadline=$((SECONDS + limit))
  until "$@" >/dev/null 2>&1; do
    [ "$SECONDS" -lt "$deadline" ] || gateway_diag "$what: not within ${limit}s"
    sleep 2
  done
  pass "$what"
}
# condition TYPE ARGS...: the condition TYPE of the object kubectl get ARGS
# names is True.
condition() {
  local t="$1"
  shift
  kubectl get "$@" -o json | jq -e --arg t "$t" '.status.conditions[]? | select(.type == $t and .status == "True")'
}
# route_condition TYPE: the condition TYPE of the HTTPRoute is True for the
# Gateway infra/gateway.
route_condition() {
  k get httproute "$release" -o json | jq -e --arg t "$1" \
    '.status.parents[]? | select(.parentRef.name == "gateway" and .parentRef.namespace == "infra") | .conditions[] | select(.type == $t and .status == "True")'
}
# doc_block MARKER: the block of docs/admin.md whose first line is MARKER,
# as ci/check-config.sh reads the examples; none ends the check naming it.
doc_block() {
  local block
  block="$(awk -v m="$1" '$0 == m { on = 1 } on && /^```$/ { exit } on' docs/admin.md)"
  [ -n "$block" ] || die "docs/admin.md has no block that starts with \"$1\": the check of the Gateway applies it"
  printf '%s\n' "$block"
}
doc_block "# cadence-gateway.yaml" >"$work/gateway-doc.yaml"
doc_block "# cadence-values-httproute.yaml" >"$work/httproute-doc.yaml"

until_ready 240 "the controller of Envoy Gateway is Available" \
  kubectl -n "$gw_ns" wait --for=condition=Available deploy/envoy-gateway --timeout=5s
# The overrides for kind of the header, and nothing else: the listener https
# as plain HTTP on 80 for localhost, the EnvoyProxy with the NodePort.
kubectl create namespace infra >/dev/null
cat >"$work/envoyproxy.yaml" <<EOF
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: EnvoyProxy
metadata:
  name: kind
  namespace: infra
spec:
  provider:
    type: Kubernetes
    kubernetes:
      envoyService:
        type: NodePort
        patch:
          type: StrategicMerge
          value:
            spec:
              ports:
                - port: 80
                  nodePort: $gateway_node_port
EOF
step "the EnvoyProxy of kind (a NodePort on $gateway_node_port) applies" kubectl apply -f "$work/envoyproxy.yaml"
if ! gateway_json="$(kubectl create --dry-run=client -o json -f "$work/gateway-doc.yaml" 2>&1)"; then
  printf '%s\n' "$gateway_json" | sed 's/^/      /' >&2
  die "the block \"# cadence-gateway.yaml\" of docs/admin.md is no manifest kubectl reads"
fi
# kubectl prints one object after another, or a List: jq takes them all.
jq -s --arg host "$host" '
  [.[] | if .kind == "List" then .items[] else . end]
  | map(if .kind == "Gateway" then
      .spec.listeners |= map(if .name == "https" then .protocol = "HTTP" | .port = 80 | .hostname = $host | del(.tls) else . end)
      | .spec.infrastructure.parametersRef = {group: "gateway.envoyproxy.io", kind: "EnvoyProxy", name: "kind"}
    else . end)
  | {apiVersion: "v1", kind: "List", items: .}' <<<"$gateway_json" >"$work/gateway.json"
check "the block of docs/admin.md is a GatewayClass and a Gateway with the listener https" \
  [ "$(jq -r '([.items[].kind] | join(",")) + " " + ([.items[] | select(.kind == "Gateway") | .spec.listeners[].name] | join(","))' "$work/gateway.json")" = "GatewayClass,Gateway https" ]
step "the GatewayClass and the Gateway of docs/admin.md apply" kubectl apply -f "$work/gateway.json"
until_ready 60 "GatewayClass envoy is Accepted" condition Accepted gatewayclass envoy
until_ready 240 "Gateway infra/gateway is Programmed" condition Programmed -n infra gateway gateway

# Both routes, as in the move of the guide: the overlay of docs/admin.md with
# the Ingress kept, and the hostnames of kind.
cat >"$work/httproute-kind.yaml" <<EOF
httpRoute:
  hostnames: [$host]
EOF
gw_values=(-f "$work/values.yaml" -f "$work/httproute-doc.yaml" -f "$work/httproute-kind.yaml" --set config.shared.SDLC_LOG_LEVEL=debug)
info "helm upgrade with the overlay of docs/admin.md and the Ingress kept: both routes"
if out="$(helm upgrade "$release" "$chart" -n "$ns" "${gw_values[@]}" --set ingress.enabled=true --wait --timeout 6m 2>&1)"; then
  pass "helm upgrade --wait succeeded"
else
  printf '%s\n' "$out" >&2
  fail "helm upgrade --wait succeeded"
fi
check "the release has the Ingress and the HTTPRoute $release" \
  [ "$(k get ingress,httproute -o name | sort | tr '\n' ' ')" = "httproute.gateway.networking.k8s.io/$release ingress.networking.k8s.io/$release " ]
check "...with the timeouts of docs/admin.md on every rule" \
  [ "$(k get httproute "$release" -o json | jq -r '[.spec.rules[].timeouts | "\(.request) \(.backendRequest)"] | unique | join(",")')" = "3600s 3600s" ]
until_ready 60 "HTTPRoute $release is Accepted by the Gateway" route_condition Accepted
until_ready 60 "HTTPRoute $release has ResolvedRefs" route_condition ResolvedRefs
# Programmed comes before Envoy has the route: the first 200 is the sign.
gateway_answers() { [ "$(http_code "$gw_base/readyz")" = 200 ]; }
until_ready 90 "the Gateway answers /readyz with 200" gateway_answers
route_checks "the Ingress" "$base"
route_checks "the Gateway" "$gw_base"
k get secret cadence -o go-template='{{index .data "admin-token" | base64decode}}' | "$clab" auth login --host "$gw_base" --with-token >/dev/null
check "clab auth login through the Gateway, whoami is admin" contains "$("$clab" --host "$gw_base" whoami 2>&1)" "admin"
mcp_checks "the Gateway" "$gw_base"
if [ -n "$long_poll_on" ]; then
  # Longer than 15 s, the timeout Envoy gives a route with no timeouts.
  long_poll "the Gateway" "$gw_base" 20 19.5 23
fi
if [ -n "$attachments" ]; then
  file_checks "the Gateway" "$gw_base"
fi

# The overlay as it is: ingress.enabled false, the route stays.
info "helm upgrade with the overlay of docs/admin.md as it is: the Ingress goes"
if out="$(helm upgrade "$release" "$chart" -n "$ns" "${gw_values[@]}" --wait --timeout 6m 2>&1)"; then
  pass "helm upgrade --wait succeeded"
else
  printf '%s\n' "$out" >&2
  fail "helm upgrade --wait succeeded"
fi
check "the release has no Ingress" [ -z "$(k get ingress -o name)" ]
check "...and the HTTPRoute $release" [ -n "$(k get httproute "$release" -o name --ignore-not-found)" ]
code="$(http_code "$base/v1/instance")"
check "the port of the Ingress does not reach the instance (/v1/instance: $code)" [ "$code" != 200 ]
check "/readyz through the Gateway is 200" [ "$(http_code "$gw_base/readyz")" = 200 ]
check "the same token signs in through the Gateway" contains "$("$clab" --host "$gw_base" whoami 2>&1)" "admin"
check "the project CHECK is there" contains "$("$clab" --host "$gw_base" project list --json)" '"CHECK"'
check "the artifact is there with its content" grep -qF "line 400 of the brief" <(artifact_content "$gw_base" 2>/dev/null)

# What the timeouts of the overlay are for: without them Envoy gives a
# request 15 s, as docs/admin.md says, and cuts the long poll with a 504.
if [ -n "$long_poll_on" ]; then
  info "the route without the timeouts of the overlay: Envoy cuts the long poll"
  route_generation() { k get httproute "$release" -o jsonpath='{.metadata.generation}'; }
  generation="$(route_generation)"
  if out="$(helm upgrade "$release" "$chart" -n "$ns" "${gw_values[@]}" --set httpRoute.timeouts=null --wait --timeout 3m 2>&1)"; then
    pass "helm upgrade with httpRoute.timeouts null succeeded"
  else
    printf '%s\n' "$out" >&2
    fail "helm upgrade with httpRoute.timeouts null succeeded"
  fi
  check "...and the HTTPRoute has no timeouts" [ "$(k get httproute "$release" -o json | jq -c '[.spec.rules[].timeouts // empty]')" = "[]" ]
  # The Gateway has taken the new route: Accepted for its generation.
  route_taken() {
    [ "$(route_generation)" != "$generation" ] &&
      k get httproute "$release" -o json | jq -e '.metadata.generation as $g | .status.parents[]?
        | select(.parentRef.name == "gateway") | .conditions[] | select(.type == "Accepted" and .status == "True" and .observedGeneration == $g)'
  }
  until_ready 60 "...Accepted by the Gateway for its generation" route_taken
  # Envoy gets the route a moment after the status: one more try if the
  # first long poll still had the old one.
  for _ in 1 2; do
    cursor="$(curl -sf "${auth[@]}" "$gw_base/v1/tasks/CHECK-1/events" | jq -r '.cursor // empty' 2>/dev/null || true)"
    read -r code took < <(curl -s -o /dev/null -w '%{http_code} %{time_total}\n' "${auth[@]}" \
      --get --data-urlencode "after=$cursor" --data wait=20 "$gw_base/v1/tasks/CHECK-1/events" || echo "000 0")
    if [ "$code" != 200 ]; then break; fi
  done
  check "a long poll with wait=20 through the Gateway is cut: 504 (got $code)" [ "$code" = 504 ]
  check "...after 15 s, the default of Envoy (took $took s)" awk -v t="$took" 'BEGIN { exit !(t >= 14.5 && t <= 17) }'
fi

[ "$failures" -eq 0 ] || die "$failures check(s) failed"
ok "Helm chart checks passed in ${SECONDS}s"
