#!/usr/bin/env bash
#
# Opens the pull request "VERSION -> vX.Y.Z" for a released version. Run by
# .github/workflows/release.yml on the cadence-release event; idempotent,
# because the event may arrive twice for one version:
#
#   - main already on the version, or newer      nothing to do
#   - an open pull request for the version        nothing to do
#   - otherwise                                   branch release/vX.Y.Z, PR
#
# The pull request moves VERSION and pins both images to the digests of
# their indexes (docker-compose.yml and the values of the Helm chart,
# ci/pins.sh), with the version of the chart - but only once both
# images of the version are signed by release.yml of their repository on the
# tag (cosign keyless, the identity is the workflow on refs/tags/vX.Y.Z).
# An image without such a signature, or whose tag points at another digest
# than the release event names, fails the run: no pull request.
#
# The package of the version carries clab of the same version (decision
# 0057), which ci/package.sh takes from the release vX.Y.Z of the tap: the
# archives clab_vX.Y.Z_<os>_<arch>.tar.gz of the four platforms and
# checksums.txt with its signature must be there before the pull request -
# release.yml of the backend publishes them in a job of its own, and the
# event of the images may come first. Not there yet: the run fails, naming
# what is missing and the command that runs it again; no pull request.
#
#   VERSION         the released version, vX.Y.Z
#   GH_TOKEN        token that pushes the branch and opens the pull request;
#                   not GITHUB_TOKEN, whose pull requests start no workflows
#   BACKEND_IMAGE   the images of the release event, ...:vX.Y.Z@sha256:...;
#   FRONTEND_IMAGE  optional (a run by hand has none), compared with the
#                   registry when given
#   CADENCE_TAP_RELEASES_URL  the releases of the tap (ci/lib.sh), for the
#                   checks
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=ci/lib.sh
. ./ci/lib.sh
# shellcheck source=ci/pins.sh
. ./ci/pins.sh

version="${VERSION:?VERSION is not set}"
valid_version "$version" || die "'$version' is not a version: expected vX.Y.Z"
[ -n "${GH_TOKEN:-}" ] || die "GH_TOKEN is not set"

current="$(tr -d '[:space:]' <VERSION)"
if [ "$current" = "$version" ]; then
  ok "main is already on $version"
  exit 0
fi
if version_lt "$version" "$current"; then
  ok "main is on $current, newer than $version: nothing to do"
  exit 0
fi

branch="release/$version"
open="$(gh pr list --head "$branch" --base main --state open --json number --jq '.[0].number // empty')"
if [ -n "$open" ]; then
  ok "pull request #$open for $version is already open"
  exit 0
fi

# clab of the version in the tap, before anything is verified or written.
tap="$(tap_releases_url)/download/$version"
missing=""
for asset in checksums.txt "$VERIFY_BUNDLE"; do
  curl -fsIL -o /dev/null "$tap/$asset" || missing="$missing $asset"
done
if [ -z "$missing" ]; then
  tmp="$(mktemp)"
  fetch "$tap/checksums.txt" "$tmp" || missing=" checksums.txt"
  for p in $CLAB_PLATFORMS; do
    asset="$(clab_archive "$version" "$p")"
    if ! grep -qE "^[0-9a-f]{64}  $asset\$" "$tmp" || ! curl -fsIL -o /dev/null "$tap/$asset"; then
      missing="$missing $asset"
    fi
  done
  rm -f "$tmp"
fi
if [ -n "$missing" ]; then
  die "the archives of clab $version are not published in the tap yet ($tap): no${missing}.
  The package of $version carries them; release.yml of the backend publishes them. No pull request.
  Run it again once they are there: gh workflow run release.yml --repo cadence-lab-tech/self-hosted -f version=$version"
fi
ok "clab $version is in the tap: $tap"

# The digest of each image of the version, checked against the event and
# the signature, before anything is written.
# digest_of IMAGE: the digest found for IMAGE below.
digest_of() {
  local v="digest_$1"
  printf '%s' "${!v}"
}
for image in $PIN_IMAGES; do
  repo="$(pin_repo "$image")"
  ref="$PIN_REGISTRY/$repo:$version"
  found="$(registry_digest "$ref")" || die "$ref is not published: no digest in the registry"
  printf -v "digest_$image" '%s' "$found"
  case "$image" in
  backend) event="${BACKEND_IMAGE:-}" ;;
  frontend) event="${FRONTEND_IMAGE:-}" ;;
  esac
  if [[ "$event" == *@sha256:* ]] && [ "${event##*@}" != "$found" ]; then
    die "$ref is $found in the registry, but the release event names ${event##*@}: the tag was moved after the release - no pull request"
  fi
  identity="$(pin_identity "$image" "$version")"
  if ! out="$(cosign verify --certificate-identity "$identity" --certificate-oidc-issuer "$PIN_ISSUER" \
    "$PIN_REGISTRY/$repo@$found" 2>&1 >/dev/null)"; then
    printf '%s\n' "$out" | tail -n 5 >&2
    die "the signature of $PIN_REGISTRY/$repo@$found ($ref) did not verify for $identity: no pull request"
  fi
  ok "$ref is $found, signed by $identity"
done

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git switch --quiet -C "$branch"
printf '%s\n' "$version" >VERSION
for image in $PIN_IMAGES; do
  set_pin "$image" "$(digest_of "$image")" || die "could not pin $image to $(digest_of "$image") in docker-compose.yml"
  set_chart_pin "$image" "$(digest_of "$image")" || die "could not pin $image to $(digest_of "$image") in $CHART_VALUES"
done
set_chart_version "$version" || die "could not set the version $version in $CHART_FILE"
git commit --quiet -m "VERSION → $version" -- VERSION docker-compose.yml "$CHART_VALUES" "$CHART_FILE"
# The branch belongs to this workflow: a leftover from a closed pull request
# is replaced.
git push --quiet --force origin "$branch"

body="Released images, signatures verified, pinned in \`docker-compose.yml\` and
\`$CHART_VALUES\` (chart $version):

- \`$PIN_REGISTRY/$(pin_repo backend):$version@$(digest_of backend)\`
- \`$PIN_REGISTRY/$(pin_repo frontend):$version@$(digest_of frontend)\`

The \`check\` workflow brings the stack up on these images. Merge when it is
green; the tag \`$version\` is then set on main automatically, and
\`./upgrade.sh $version\` upgrades an installation."
gh pr create --base main --head "$branch" --title "Release $version" --body "$body"
