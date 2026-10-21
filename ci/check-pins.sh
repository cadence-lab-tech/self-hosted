#!/usr/bin/env bash
#
# The digests docker-compose.yml pins are the images of VERSION in the
# registry: for each image, the digest of the tag VERSION today equals the
# pin, and the values of the Helm chart pin the same digest (its Chart.yaml
# is of VERSION). A tag moved after the release (or a pin written by hand) turns the
# check red with both digests - the package would install other bytes than
# its version names. The check workflow runs it on every pull request and
# push to main; it needs Docker with buildx and the registry.
#
#   ci/check-pins.sh
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=lib.sh
. ./lib.sh
# shellcheck source=ci/pins.sh
. ./ci/pins.sh

version="$(tr -d '[:space:]' <VERSION)"
failures=0
for image in $PIN_IMAGES; do
  ref="$PIN_REGISTRY/$(pin_repo "$image"):$version"
  if ! pin="$(pin_of "$image")"; then
    # shellcheck disable=SC2016 # the variable is shown as it is written
    printf '::error file=docker-compose.yml::%s is not pinned: expected ${%s-@sha256:<digest of %s>}\n' "$image" "$(pin_var "$image")" "$ref"
    failures=$((failures + 1))
    continue
  fi
  if ! published="$(registry_digest "$ref")"; then
    printf '::error::%s is not published: the pin %s of docker-compose.yml cannot be checked\n' "$ref" "$pin"
    failures=$((failures + 1))
    continue
  fi
  if [ "$published" != "$pin" ]; then
    printf '::error file=docker-compose.yml::the tag was moved: %s is %s in the registry, docker-compose.yml pins %s\n' "$ref" "$published" "$pin"
    failures=$((failures + 1))
    continue
  fi
  ok "$ref is $pin, the pin of docker-compose.yml"
  # The Helm chart pins the same bytes.
  chart_pin="$(chart_pin_of "$image" || true)"
  if [ "$chart_pin" != "$pin" ]; then
    printf '::error file=%s::%s: the chart pins %s, docker-compose.yml and the registry %s\n' "$CHART_VALUES" "$image" "${chart_pin:-nothing}" "$pin"
    failures=$((failures + 1))
    continue
  fi
  ok "$CHART_VALUES pins $image to the same $pin"
done
if [ "$(chart_version_of)" != "${version#v} $version" ]; then
  printf '::error file=%s::version and appVersion are %s, VERSION is %s\n' "$CHART_FILE" "$(chart_version_of)" "$version"
  failures=$((failures + 1))
fi
[ "$failures" -eq 0 ] || die "$failures image(s) of $version do not match their pin"
