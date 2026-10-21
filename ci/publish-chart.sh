#!/usr/bin/env bash
#
# Publishes the Helm chart of VERSION as an OCI artifact and signs it: the
# job "tag" of .github/workflows/release.yml runs it after the GitHub
# Release of the package (docs/admin.md, "Kubernetes (Helm)").
#
#   ci/publish-chart.sh             package, push, sign (cosign keyless, the
#                                   identity of this workflow on main)
#   ci/publish-chart.sh --no-sign   package and push only (a check against
#                                   a local registry)
#
#   CHART_REGISTRY  where the chart goes, default ghcr.io/cadence-lab-tech/charts:
#                   oci://$CHART_REGISTRY/cadence:X.Y.Z
#   CHART_PLAIN_HTTP=1  a registry without TLS (localhost:5050)
#
# The chart is charts/cadence of this checkout, its version that of VERSION
# (X.Y.Z of vX.Y.Z; Chart.yaml must say so). A version already in the
# registry is never pushed again: the run reports "already published" and
# only signs it when its signature is missing - the chart already
# published, not the one packaged here.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=lib.sh
. ./lib.sh
# shellcheck source=ci/pins.sh
. ./ci/pins.sh

sign=true
case "${1:-}" in
"") ;;
--no-sign) sign=false ;;
*) die "usage: ci/publish-chart.sh [--no-sign]" ;;
esac

version="$(tr -d '[:space:]' <VERSION)"
valid_version "$version" || die "VERSION holds '$version', expected vX.Y.Z"
[ "$(chart_version_of)" = "${version#v} $version" ] ||
  die "$CHART_FILE has version and appVersion $(chart_version_of), VERSION is $version"
registry="${CHART_REGISTRY:-ghcr.io/cadence-lab-tech/charts}"
ref="$registry/cadence"
plain=()
[ "${CHART_PLAIN_HTTP:-}" != 1 ] || plain=(--plain-http)
identity="$PIN_SOURCE/self-hosted/.github/workflows/release.yml@refs/heads/main"

out="$(mktemp -d)"
trap 'rm -rf "$out"' EXIT

# digest_of OUTPUT: the digest helm printed for a push or a pull.
digest_of() { awk '$1 == "Digest:" { print $2; exit }' <<<"$1"; }

if pulled="$(helm pull "oci://$ref" --version "${version#v}" --destination "$out" ${plain[@]+"${plain[@]}"} 2>&1)"; then
  digest="$(digest_of "$pulled")"
  ok "chart ${version#v} already published: oci://$ref@$digest"
else
  helm package charts/cadence --destination "$out" >/dev/null
  pkg="$out/cadence-${version#v}.tgz"
  [ -f "$pkg" ] || die "helm package wrote no $pkg"
  pushed="$(helm push "$pkg" "oci://$registry" ${plain[@]+"${plain[@]}"} 2>&1)" || {
    printf '%s\n' "$pushed" >&2
    die "helm push of the chart ${version#v} failed"
  }
  digest="$(digest_of "$pushed")"
  ok "chart ${version#v} published: oci://$ref@$digest"
fi
[[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || die "no digest of the chart ${version#v} in the answer of helm"

if [ "$sign" = false ]; then
  info "not signed (--no-sign)"
  exit 0
fi
if cosign verify --certificate-identity "$identity" --certificate-oidc-issuer "$PIN_ISSUER" "$ref@$digest" >/dev/null 2>&1; then
  ok "chart ${version#v} is already signed by $identity"
else
  cosign sign --yes "$ref@$digest"
  ok "chart ${version#v} signed: $ref@$digest"
fi
