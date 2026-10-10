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
#   VERSION   the released version, vX.Y.Z
#   GH_TOKEN  token that pushes the branch and opens the pull request; not
#             GITHUB_TOKEN, whose pull requests start no workflows
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=lib.sh
. ./lib.sh

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

git config user.name "github-actions[bot]"
git config user.email "41898282+github-actions[bot]@users.noreply.github.com"
git switch --quiet -C "$branch"
printf '%s\n' "$version" >VERSION
git commit --quiet -m "VERSION → $version" -- VERSION
# The branch belongs to this workflow: a leftover from a closed pull request
# is replaced.
git push --quiet --force origin "$branch"

body="Released images:

- \`${BACKEND_IMAGE:-ghcr.io/cadence-lab-tech/sdlc-pipeline-backend:$version}\`
- \`${FRONTEND_IMAGE:-ghcr.io/cadence-lab-tech/sdlc-pipeline-frontend:$version}\`

The \`check\` workflow brings the stack up on these images. Merge when it is
green; the tag \`$version\` is then set on main automatically, and
\`./upgrade.sh $version\` upgrades an installation."
gh pr create --base main --head "$branch" --title "Release $version" --body "$body"
