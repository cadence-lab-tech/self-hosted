#!/usr/bin/env bash
#
# The secret scan of the lint job: gitleaks over the history of the commit
# under check - HEAD of the checkout - and not over every ref of the clone.
# A checkout with fetch-depth: 0 holds every branch of origin, and gitleaks
# git with no --log-opts scans them all (git log --all): a finding in an
# unmerged branch of somebody else failed lint on main and on every pull
# request, though none of them had it in its history. With --log-opts=HEAD
# the scan is the history of main on a push, the history of the merge ref
# (the base and the commits of the pull request) on a pull request, the
# history of the branch on a manual run - all of it, not just the commits of
# the pull request. .gitleaksignore of the checkout applies to it.
#
# Before the scan, a self-check on a scratch repository proves the scan does
# what it says, with the same call: a finding in another ref of the clone is
# out of it; a finding in the history of HEAD - in a commit of HEAD or behind
# the second parent of a merge commit, the way refs/pull/N/merge is built -
# fails it; the same finding over --all is caught, so the planted string is
# a finding at all. The planted token is put together when the check runs:
# no file of the repository holds it, and the scan of HEAD does not find it
# in this script. The scratch repository is removed whatever the outcome.
#
#   ci/check-secrets.sh
#
# Needs Docker and git. A git worktree works as well as a clone.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=ci/lib.sh
. ./ci/lib.sh

# The image is pinned: a newer gitleaks comes with a change of this line, and
# the self-check runs on it before it scans anything.
GITLEAKS_IMAGE=zricethezav/gitleaks:v8.30.1
# The exit code of gitleaks for findings - apart from its own errors (1) and
# those of docker (125-127), so that the self-check tells them apart.
LEAKS=99

# gitleaks_history DIR LOG_OPTS: gitleaks over the history LOG_OPTS selects
# (git log options) in the git repository at DIR, a clone or a git worktree.
# The repository and its git directory are mounted read-only at their own
# paths: the .git file of a worktree names its git directory by the absolute
# path. Exit code: 0 - no findings, LEAKS - findings, anything else - an
# error.
gitleaks_history() {
  local dir common
  dir="$(cd "$1" && pwd -P)"
  common="$(cd "$dir" && cd "$(git rev-parse --git-common-dir)" && pwd -P)"
  local mounts=(-v "$dir:$dir:ro")
  case "$common/" in
  "$dir"/*) ;;
  *) mounts+=(-v "$common:$common:ro") ;;
  esac
  docker run --rm "${mounts[@]}" "$GITLEAKS_IMAGE" \
    git "$dir" --log-opts="$2" --redact --no-banner --exit-code "$LEAKS"
}

command -v docker >/dev/null 2>&1 || die "no docker in PATH: the scan runs gitleaks in Docker"
docker info >/dev/null 2>&1 || die "Docker is not running: the scan runs gitleaks in Docker"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT

# --- self-check ----------------------------------------------------------------
repo="$work/repo"
out="$work/gitleaks.log"

# g runs git in the scratch repository, away from the configuration of the
# machine: no signing, no hooks, a fixed author.
g() {
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 \
    git -C "$repo" -c user.name=check -c user.email=check@example.invalid -c commit.gpgsign=false "$@"
}

# planted prints a GitHub personal access token of random digits: a finding
# of the default rules of gitleaks. The prefix is split so that no line of
# this file is one.
planted() {
  printf 'GITHUB_TOKEN=%s%s\n' 'gh' "p_$(od -An -tx1 -N18 /dev/urandom | tr -d ' \n')"
}

# expect WANT LOG_OPTS PROPERTY: the scan of LOG_OPTS in the scratch
# repository ends with WANT (clean or leaks); otherwise PROPERTY does not
# hold and the check fails with the output of gitleaks.
expect() {
  local want="$1" range="$2" property="$3" code=0 wanted
  gitleaks_history "$repo" "$range" >"$out" 2>&1 || code=$?
  case "$want" in
  clean) wanted=0 ;;
  leaks) wanted="$LEAKS" ;;
  esac
  if [ "$code" != "$wanted" ]; then
    cat "$out" >&2
    die "self-check: $property - gitleaks --log-opts=$range exited with $code, expected $wanted ($want)"
  fi
  ok "self-check: $property"
}

info "self-check of the scan with $GITLEAKS_IMAGE on a scratch repository"
mkdir -p "$repo"
g init -q -b main
printf 'nothing to see\n' >"$repo/README"
g add README
g commit -q -m "clean history"

# A finding in a branch of somebody else, kept as a ref of origin the way a
# clone with fetch-depth: 0 keeps it, and in no history of main.
g checkout -q -b side
planted >"$repo/config.env"
g add config.env
g commit -q -m "a token in another branch"
g update-ref refs/remotes/origin/clab/CLAB-0-planted side
g checkout -q main
g branch -q -D side

expect clean HEAD "a finding in another ref of the clone is out of the scan"
expect leaks --all "the planted token is a finding (the same scan over --all)"

# The merge ref of a pull request: a merge commit of the base and the head,
# checked out detached. The finding is behind its second parent.
g checkout -q --detach main
g merge -q --no-ff -m "merge of the pull request" refs/remotes/origin/clab/CLAB-0-planted
expect leaks HEAD "a finding behind the second parent of a merge commit fails the scan"

# A finding in a commit of HEAD itself.
g checkout -q main
planted >"$repo/settings.env"
g add settings.env
g commit -q -m "a token in the history of main"
expect leaks HEAD "a finding in a commit of HEAD fails the scan"

# --- the scan --------------------------------------------------------------------
info "gitleaks over the history of HEAD ($(git rev-parse --short HEAD))"
gitleaks_history . HEAD || {
  code=$?
  [ "$code" = "$LEAKS" ] && die "secrets in the history of HEAD: see the findings above (a false positive - its fingerprint in .gitleaksignore)"
  die "gitleaks failed with $code"
}
ok "no secrets in the history of HEAD"
