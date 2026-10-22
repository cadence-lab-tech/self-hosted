#!/usr/bin/env bash
#
# Checks of the publication of the Helm chart (ci/publish-chart.sh) that
# need neither Docker nor the network: helm and cosign are stand-ins that
# write every call to a log, so "not pushed" is a call that is missing. CI
# runs it in the lint job.
#
#   ci/check-publish-chart.sh
#
# The stand-in helm answers helm pull the way helm 3.19 answers for the
# registry (FAKE_HELM_PULL; the texts are those of helm against ghcr.io):
#
#   published   the version is there: Pulled, Digest
#   absent      404: "<ref>:<version>: not found" - no such tag, and no such
#               package yet to a client that is signed in to GHCR (the first
#               release of the chart)
#   anonymous   403 DENIED of the token of GHCR: a client that is not signed
#               in, also for a package that does not exist
#   network, unauthorized (401), denied (403 of a package that exists),
#   unavailable (503), other-version (a 404 of another reference), garbage
#
# Only "absent" may package and push; "published" reports the digest of the
# registry and pushes nothing; every other answer stops the run with the
# output of helm, the version and the oci:// reference, before helm package.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=lib.sh
. ./lib.sh
# shellcheck source=ci/verify-stubs.sh
. ./ci/verify-stubs.sh

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
chart_version="${version#v}"
ref=ghcr.io/cadence-lab-tech/charts/cadence
published_digest="sha256:$(printf 'a%.0s' $(seq 64))"
pushed_digest="sha256:$(printf 'b%.0s' $(seq 64))"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
stubs="$work/bin"
log="$work/calls.log"
mkdir -p "$stubs"
stub_cosign "$stubs" "$log"
cat >"$stubs/helm" <<SH
#!/bin/sh
{ printf 'helm'; for a in "\$@"; do printf ' [%s]' "\$a"; done; echo; } >>"$log"
cmd="\$1"
shift
ref=""
version=""
dest=""
while [ \$# -gt 0 ]; do
  case "\$1" in
  --version) version="\$2"; shift ;;
  --destination) dest="\$2"; shift ;;
  oci://*) ref="\${1#oci://}" ;;
  esac
  shift
done
host="\${ref%%/*}"
path="\${ref#*/}"
fetch='Error: failed to perform "FetchReference" on source:'
case "\$cmd" in
pull)
  case "\${FAKE_HELM_PULL:-absent}" in
  published) printf 'Pulled: %s:%s\nDigest: %s\n' "\$ref" "\$version" "$published_digest" ;;
  absent) echo "\$fetch \$ref:\$version: not found" >&2; exit 1 ;;
  anonymous) echo "\$fetch GET \"https://\$host/v2/\$path/manifests/\$version\": GET \"https://\$host/token?scope=repository%3A\$path%3Apull&service=\$host\": response status code 403: denied: requested access to the resource is denied" >&2; exit 1 ;;
  network) echo "\$fetch Get \"https://\$host/v2/\$path/manifests/\$version\": dial tcp: lookup \$host: i/o timeout" >&2; exit 1 ;;
  unauthorized) echo "\$fetch GET \"https://\$host/v2/\$path/manifests/\$version\": response status code 401: unauthorized: authentication required" >&2; exit 1 ;;
  denied) echo "\$fetch GET \"https://\$host/v2/\$path/manifests/\$version\": response status code 403: denied: permission_denied: read_package" >&2; exit 1 ;;
  unavailable) echo "\$fetch GET \"https://\$host/v2/\$path/manifests/\$version\": response status code 503: Service Unavailable" >&2; exit 1 ;;
  other-version) echo "\$fetch \$ref:0.0.1: not found" >&2; exit 1 ;;
  garbage) echo "panic: something else" >&2; exit 2 ;;
  esac
  ;;
package)
  : >"\$dest/cadence-$chart_version.tgz"
  echo "Successfully packaged chart and saved it to: \$dest/cadence-$chart_version.tgz"
  ;;
push)
  if [ "\${FAKE_HELM_PUSH:-ok}" = fail ]; then
    echo "Error: failed to do request: Put \"https://\$host/v2/\$path/manifests/$chart_version\": unexpected EOF" >&2
    exit 1
  fi
  printf 'Pushed: %s/cadence:%s\nDigest: %s\n' "\$ref" "$chart_version" "$pushed_digest"
  ;;
*) echo "helm stub: \$cmd" >&2; exit 1 ;;
esac
SH
chmod 755 "$stubs/helm"

# publish [VAR=value...] [-- ARGS]: ci/publish-chart.sh on the stand-ins with
# a fresh log; sets out (stdout and stderr), code and calls.
publish() {
  local vars=()
  while [ $# -gt 0 ] && [ "$1" != -- ]; do
    vars+=("$1")
    shift
  done
  [ $# -eq 0 ] || shift
  : >"$log"
  code=0
  out="$(env PATH="$stubs:$PATH" ${vars[@]+"${vars[@]}"} ci/publish-chart.sh "$@" 2>&1)" || code=$?
  calls="$(cat "$log")"
}

info "publish-chart.sh $chart_version on a stand-in helm and cosign"

publish FAKE_HELM_PULL=absent -- --no-sign
check "not found: exits 0" [ "$code" = 0 ]
check "...asks for the version first: helm pull oci://$ref --version $chart_version" \
  contains "$(head -n 1 <<<"$calls")" "helm [pull] [oci://$ref] [--version] [$chart_version]"
check "...packages the chart and pushes the package to oci://ghcr.io/cadence-lab-tech/charts" \
  [ -n "$(grep -E "^helm \[push\] \[[^]]*/cadence-$chart_version\.tgz\] \[oci://ghcr\.io/cadence-lab-tech/charts\]$" <<<"$calls")" ]
check "...'✓ chart $chart_version published' with the digest of the push" \
  contains "$out" "✓ chart $chart_version published: oci://$ref@$pushed_digest"
check "...--no-sign: no cosign" lacks "$calls" "cosign"
check "...packaged before the push" [ "$(grep -n 'helm \[package\]' "$log" | cut -d: -f1)" -lt "$(grep -n 'helm \[push\]' "$log" | cut -d: -f1)" ]

publish FAKE_HELM_PULL=absent FAKE_COSIGN_BAD=cadence
check "not found, signing: exits 0" [ "$code" = 0 ]
check "...signs the digest of the push" contains "$calls" "cosign [sign] [--yes] [$ref@$pushed_digest]"
check "...'✓ chart $chart_version signed'" contains "$out" "✓ chart $chart_version signed: $ref@$pushed_digest"

publish FAKE_HELM_PULL=absent FAKE_HELM_PUSH=fail -- --no-sign
check "not found, the push fails: refused" [ "$code" != 0 ]
check "...'helm push of the chart $chart_version failed' with the answer of helm" \
  contains "$out" "helm push of the chart $chart_version failed"
check "...and the answer of helm" contains "$out" "unexpected EOF"

publish FAKE_HELM_PULL=published -- --no-sign
check "published: exits 0" [ "$code" = 0 ]
check "...'✓ chart $chart_version already published' with the digest of the registry" \
  contains "$out" "✓ chart $chart_version already published: oci://$ref@$published_digest"
check "...pushes nothing" lacks "$calls" "helm [push]"
check "...packages nothing" lacks "$calls" "helm [package]"
check "...--no-sign: no cosign" lacks "$calls" "cosign"

publish FAKE_HELM_PULL=published
check "published and signed: exits 0, '✓ ... already signed'" \
  [ "$code" = 0 -a -n "$(grep -F "✓ chart $chart_version is already signed by" <<<"$out")" ]
check "...verifies the published digest, signs nothing" \
  [ -n "$(grep -F "cosign [verify]" <<<"$calls" | grep -F "[$ref@$published_digest]")" -a -z "$(grep -F "cosign [sign]" <<<"$calls")" ]

publish FAKE_HELM_PULL=published FAKE_COSIGN_BAD=cadence
check "published, not signed: signs the published digest, pushes nothing" \
  [ "$code" = 0 -a -n "$(grep -F "cosign [sign] [--yes] [$ref@$published_digest]" <<<"$calls")" -a -z "$(grep -F "helm [push]" <<<"$calls")" ]

for answer in anonymous network unauthorized denied unavailable other-version garbage; do
  publish FAKE_HELM_PULL="$answer"
  check "$answer: refused" [ "$code" != 0 ]
  check "...nothing packaged, nothing pushed, nothing signed" \
    [ -z "$(grep -E 'helm \[(package|push)\]|cosign' <<<"$calls")" ]
  check "...names the version and oci://$ref:$chart_version" \
    contains "$out" "the registry did not say whether the chart $chart_version is published (oci://$ref:$chart_version): not pushed"
done
publish FAKE_HELM_PULL=network
check "network: the answer of helm is shown" contains "$out" "dial tcp: lookup ghcr.io: i/o timeout"
publish FAKE_HELM_PULL=denied
check "denied: the answer of helm is shown" contains "$out" "response status code 403: denied: permission_denied"
publish FAKE_HELM_PULL=anonymous
check "anonymous: the answer of helm is shown" contains "$out" "requested access to the resource is denied"

publish FAKE_HELM_PULL=absent CHART_REGISTRY=localhost:5050/charts CHART_PLAIN_HTTP=1 -- --no-sign
check "CHART_REGISTRY and CHART_PLAIN_HTTP: pull and push there, with --plain-http" \
  [ "$code" = 0 -a -n "$(grep -F "helm [pull] [oci://localhost:5050/charts/cadence]" <<<"$calls" | grep -F "[--plain-http]")" -a -n "$(grep -F "helm [push]" <<<"$calls" | grep -F "[oci://localhost:5050/charts] [--plain-http]")" ]

[ "$failures" -eq 0 ] || die "$failures check(s) failed"
ok "chart publication checks passed"
