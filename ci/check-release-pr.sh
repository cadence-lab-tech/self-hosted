#!/usr/bin/env bash
#
# Checks of ci/release-pr.sh without the network: docker (the registry),
# cosign and gh are stubs, git is real - a copy of this checkout on main with
# a bare repository as origin. CI runs it in the lint job.
#
#   ci/check-release-pr.sh
#
# Scenarios: both images signed - the branch release/vX.Y.Z moves VERSION and
# pins both digests in docker-compose.yml, the pull request names them; an
# image without the signature of its release.yml, a tag moved after the
# release event, an image that is not published - a failed run, no branch, no
# pull request; main already on the version, an open pull request - nothing
# to do, nothing verified.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=lib.sh
. ./lib.sh
# shellcheck source=ci/pins.sh
. ./ci/pins.sh

failures=0
pass() { printf '  ✓ %s\n' "$*"; }
fail() {
  printf '  ✗ %s\n' "$*" >&2
  failures=$((failures + 1))
}
contains() { grep -qF -- "$2" <<<"$1"; }
lacks() { ! grep -qF -- "$2" <<<"$1"; }

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
version=v99.1.0
backend_digest="sha256:$(printf 'b%.0s' $(seq 64))"
frontend_digest="sha256:$(printf 'f%.0s' $(seq 64))"
moved_digest="sha256:$(printf 'e%.0s' $(seq 64))"

# --- stubs --------------------------------------------------------------------------
bin="$work/bin"
mkdir -p "$bin"
# docker buildx imagetools inspect REF: the digest of REF from
# FAKE_<repo with _>, "missing" - not found.
cat >"$bin/docker" <<'SH'
#!/usr/bin/env bash
echo "docker $*" >>"$FAKE_LOG"
ref="${4:?}"
repo="${ref##*/}"
repo="${repo%%:*}"
var="FAKE_${repo//-/_}"
digest="${!var:-missing}"
if [ "$digest" = missing ]; then
  echo "ERROR: $ref: not found" >&2
  exit 1
fi
printf 'Name:      %s\nMediaType: application/vnd.oci.image.index.v1+json\nDigest:    %s\n' "$ref" "$digest"
SH
# cosign verify: fails for the repository in FAKE_UNSIGNED.
cat >"$bin/cosign" <<'SH'
#!/usr/bin/env bash
printf 'cosign' >>"$FAKE_LOG"; printf ' [%s]' "$@" >>"$FAKE_LOG"; echo >>"$FAKE_LOG"
if [ -n "${FAKE_UNSIGNED:-}" ] && [[ "${!#}" == *"/$FAKE_UNSIGNED@"* ]]; then
  echo "Error: no matching signatures: none of the expected identities matched what was in the certificate" >&2
  exit 1
fi
echo '[{"critical":{}}]'
SH
# gh pr list: FAKE_OPEN_PR; gh pr create: logged with its arguments.
cat >"$bin/gh" <<'SH'
#!/usr/bin/env bash
printf 'gh' >>"$FAKE_LOG"; printf ' [%s]' "$@" >>"$FAKE_LOG"; echo >>"$FAKE_LOG"
case "$1 $2" in
"pr list") printf '%s\n' "${FAKE_OPEN_PR:-}" ;;
"pr create") echo "https://github.com/cadence-lab-tech/self-hosted/pull/999" ;;
esac
SH
chmod +x "$bin/docker" "$bin/cosign" "$bin/gh"

# --- the repository: this checkout on main, origin a bare repository -----------
git_q() { git -c user.name=check -c user.email=check@localhost -c init.defaultBranch=main "$@" >/dev/null 2>&1; }
fresh_repo() {
  rm -rf "$work/repo" "$work/origin.git"
  git_q init --bare "$work/origin.git"
  mkdir "$work/repo"
  tar -cf - --exclude=./.git . | tar -xf - -C "$work/repo"
  git_q -C "$work/repo" init
  git_q -C "$work/repo" add -A
  git_q -C "$work/repo" commit -m main
  git_q -C "$work/repo" remote add origin "$work/origin.git"
  git_q -C "$work/repo" push origin main
}

# run NAME WANT [NAME=VALUE...]: ci/release-pr.sh of the copy for $version
# with the stubs; output in $work/out, calls in $work/log.
run() {
  local name="$1" want="$2" code
  shift 2
  : >"$work/log"
  set +e
  (cd "$work/repo" && env -u BACKEND_IMAGE -u FRONTEND_IMAGE PATH="$bin:$PATH" FAKE_LOG="$work/log" \
    VERSION="$version" GH_TOKEN=x \
    FAKE_sdlc_pipeline_backend="$backend_digest" FAKE_sdlc_pipeline_frontend="$frontend_digest" \
    "$@" ci/release-pr.sh) >"$work/out" 2>&1
  code=$?
  set -e
  if [ "$code" = "$want" ]; then
    pass "$name: exit $code"
  else
    fail "$name: exit $code, expected $want"
    sed 's/^/      /' "$work/out" >&2
  fi
}
remote_branch() { git -C "$work/origin.git" rev-parse --verify --quiet "refs/heads/release/$version" >/dev/null; }

# shellcheck disable=SC2034 # read as ${!id} below
identity_backend="$(pin_identity backend "$version")"
identity_frontend="$(pin_identity frontend "$version")"

info "both images signed"
fresh_repo
run "signed" 0 BACKEND_IMAGE="$PIN_REGISTRY/sdlc-pipeline-backend:$version@$backend_digest" \
  FRONTEND_IMAGE="$PIN_REGISTRY/sdlc-pipeline-frontend:$version@$frontend_digest"
log="$(cat "$work/log")"
for image in backend frontend; do
  d="${image}_digest"
  id="identity_$image"
  if contains "$log" "cosign [verify] [--certificate-identity] [${!id}] [--certificate-oidc-issuer] [$PIN_ISSUER] [$PIN_REGISTRY/sdlc-pipeline-$image@${!d}]"; then
    pass "the signature of $image is verified by its digest and the identity of its release.yml on the tag"
  else
    fail "cosign verify of $image with the identity ${!id} and the digest ${!d} not called: $log"
  fi
done
if remote_branch; then
  pass "branch release/$version pushed"
  git -C "$work/origin.git" show "release/$version:docker-compose.yml" >"$work/compose.yml"
  check_pin() {
    if [ "$(pin_of "$1" "$work/compose.yml")" = "$2" ]; then pass "$3"; else fail "$3: $(pin_of "$1" "$work/compose.yml" || true)"; fi
  }
  check_pin backend "$backend_digest" "the branch pins backend to $backend_digest"
  check_pin frontend "$frontend_digest" "the branch pins frontend to $frontend_digest"
  if [ "$(git -C "$work/origin.git" show "release/$version:VERSION")" = "$version" ]; then pass "the branch has VERSION $version"; else fail "VERSION on the branch is not $version"; fi
  changed="$(git -C "$work/origin.git" diff --name-only main "release/$version" | tr '\n' ' ')"
  if [ "$changed" = "VERSION docker-compose.yml " ]; then pass "the commit changes VERSION and docker-compose.yml only"; else fail "the commit changes: $changed"; fi
  # Nothing else in the compose file moved: only the two digests.
  if [ "$(git -C "$work/origin.git" diff main "release/$version" -- docker-compose.yml | grep -c '^[-+] ')" = 4 ]; then
    pass "docker-compose.yml: only the two image lines change"
  else
    fail "docker-compose.yml: more than the two image lines change"
  fi
else
  fail "branch release/$version not pushed"
fi
if contains "$log" "gh [pr] [create]" && contains "$log" "$PIN_REGISTRY/sdlc-pipeline-backend:$version@$backend_digest" &&
  contains "$log" "$PIN_REGISTRY/sdlc-pipeline-frontend:$version@$frontend_digest"; then
  pass "the pull request names both images with their digests"
else
  fail "the pull request does not name both images with their digests: $log"
fi
# check_out WHAT TEXT: the output of the last run has TEXT.
check_out() { if grep -qF -- "$2" "$work/out"; then pass "$1"; else fail "$1: $(cat "$work/out")"; fi; }
check_out "the log names the signer" "signed by $identity_frontend"

info "a run by hand: no images in the event"
fresh_repo
run "by hand" 0
if remote_branch; then pass "branch release/$version pushed with the digests of the registry"; else fail "no branch"; fi

info "the frontend image is not signed by its release.yml"
fresh_repo
run "unsigned" 1 FAKE_UNSIGNED=sdlc-pipeline-frontend
log="$(cat "$work/log")"
check_out "the run names the image and the identity" "the signature of $PIN_REGISTRY/sdlc-pipeline-frontend@$frontend_digest ($PIN_REGISTRY/sdlc-pipeline-frontend:$version) did not verify for $identity_frontend"
check_out "...with the answer of cosign" "no matching signatures"
if remote_branch; then fail "a branch was pushed for an unsigned image"; else pass "no branch"; fi
if lacks "$log" "gh [pr] [create]"; then pass "no pull request"; else fail "a pull request was opened"; fi

info "the tag was moved after the release event"
fresh_repo
run "moved" 1 BACKEND_IMAGE="$PIN_REGISTRY/sdlc-pipeline-backend:$version@$moved_digest"
check_out "the run names both digests" "is $backend_digest in the registry, but the release event names $moved_digest"
if remote_branch; then fail "a branch was pushed for a moved tag"; else pass "no branch"; fi
if lacks "$(cat "$work/log")" "cosign"; then pass "nothing verified for a moved tag"; else fail "cosign called for a moved tag"; fi

info "an image of the version is not published"
fresh_repo
run "missing" 1 FAKE_sdlc_pipeline_backend=missing
check_out "the run names the image" "$PIN_REGISTRY/sdlc-pipeline-backend:$version is not published"
if remote_branch; then fail "a branch was pushed without the image"; else pass "no branch"; fi

info "nothing to do"
fresh_repo
current="$(tr -d '[:space:]' <VERSION)"
version="$current"
run "main on the version" 0
check_out "main is already on $current" "main is already on $current"
if lacks "$(cat "$work/log")" "cosign"; then pass "nothing verified"; else fail "cosign called"; fi
version=v99.1.0
run "open pull request" 0 FAKE_OPEN_PR=42
check_out "the open pull request is named" "pull request #42 for $version is already open"
if lacks "$(cat "$work/log")" "cosign"; then pass "nothing verified"; else fail "cosign called"; fi

[ "$failures" -eq 0 ] || die "$failures check(s) failed"
ok "release pull request checks passed"
