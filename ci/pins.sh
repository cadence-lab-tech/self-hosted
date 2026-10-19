# shellcheck shell=bash
# shellcheck disable=SC2034 # the constants are read by the scripts that source it
#
# The digests the package pins its images to (docker-compose.yml). Sourced by
# ci/release-pr.sh, which writes them for a released version, by
# ci/check-config.sh and by the check workflow, which compare them with the
# registry. Not part of the package.
#
# In docker-compose.yml the digest is the default value of a variable next
# to the tag:
#
#   image: ${CADENCE_REGISTRY:-ghcr.io/cadence-lab-tech}/sdlc-pipeline-backend:${CADENCE_VERSION:?...}${CADENCE_BACKEND_DIGEST-@sha256:<64 hex>}
#
# Unset, the variable gives the pinned digest - every installation and every
# script, old or new, pulls these bytes. Set to an empty value, it drops the
# pin: images of a branch under the tag of VERSION in a local registry
# (CADENCE_REGISTRY=localhost:5050), docs/admin.md has the rule.

# The images of a release and the variable that pins each.
PIN_IMAGES="backend frontend"
pin_var() {
  case "$1" in
  backend) printf 'CADENCE_BACKEND_DIGEST' ;;
  frontend) printf 'CADENCE_FRONTEND_DIGEST' ;;
  *) return 1 ;;
  esac
}
pin_repo() { printf 'sdlc-pipeline-%s' "$1"; }

# The registry and the workflow that publish and sign the images of a
# release (release.yml of the backend and of the frontend on the tag).
PIN_REGISTRY=ghcr.io/cadence-lab-tech
PIN_SOURCE=https://github.com/cadence-lab-tech
PIN_ISSUER=https://token.actions.githubusercontent.com
# pin_identity IMAGE VERSION: the certificate identity of the signature of
# the image of VERSION.
pin_identity() { printf '%s/%s/.github/workflows/release.yml@refs/tags/%s' "$PIN_SOURCE" "$(pin_repo "$1")" "$2"; }

# pin_of IMAGE [FILE]: the digest FILE (docker-compose.yml) pins IMAGE to,
# sha256:<64 hex>; nothing (and status 1) when there is no pin.
pin_of() {
  local var
  var="$(pin_var "$1")" || return 1
  sed -n "s/.*\${$var-@\(sha256:[0-9a-f]\{64\}\)}.*/\1/p" "${2:-docker-compose.yml}" | head -n 1 | grep .
}

# set_pin IMAGE DIGEST [FILE]: writes DIGEST as the pin of IMAGE in FILE.
set_pin() {
  local var file="${3:-docker-compose.yml}"
  var="$(pin_var "$1")" || return 1
  [[ "$2" =~ ^sha256:[0-9a-f]{64}$ ]] || return 1
  pin_of "$1" "$file" >/dev/null || return 1
  sed -i.bak "s/\${$var-@sha256:[0-9a-f]\{64\}}/\${$var-@$2}/" "$file" && rm -f "$file.bak"
  [ "$(pin_of "$1" "$file")" = "$2" ]
}

# registry_digest REF: the digest of the manifest (the index of a
# multi-platform image) REF names in its registry, as docker buildx
# imagetools inspect prints it; status 1 with the answer of the registry on
# stderr when there is none.
registry_digest() {
  local out digest
  if ! out="$(docker buildx imagetools inspect "$1" 2>&1)"; then
    printf '%s\n' "$out" | tail -n 3 >&2
    return 1
  fi
  digest="$(awk '$1 == "Digest:" { print $2; exit }' <<<"$out")"
  [[ "$digest" =~ ^sha256:[0-9a-f]{64}$ ]] || {
    printf 'no digest in the answer for %s\n' "$1" >&2
    return 1
  }
  printf '%s\n' "$digest"
}
