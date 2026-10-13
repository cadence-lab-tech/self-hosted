#!/usr/bin/env bash
#
# Upgrades the whole stack to a new version: backup, package files of the new
# version (VERSION, compose, Caddyfile, scripts), new images, start, wait for
# readiness.
#
#   ./upgrade.sh            # fast-forward to the latest main (git pull --ff-only)
#   ./upgrade.sh v0.6.0     # switch the package files to the tag v0.6.0
#
# Skipping versions is fine: migrations of every version in between are
# built into the new image. Going down is refused - migrations only go
# forward; to return to an older version restore its backup (restore.sh).
#
# If the new version does not become ready, the script exits with an error
# and prints the exact commands that return to the previous version and its
# backup.
#
#   CADENCE_READY_TIMEOUT  seconds to wait for readiness, default 300
#   CADENCE_GIT_REMOTE     remote to fetch from, default origin
#   CADENCE_GIT_BRANCH     branch for an upgrade without a version, default main
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=lib.sh
. ./lib.sh

# Everything runs from main(): git replaces this very file during the
# upgrade, and bash must not read the rest of it from the new version.
main() {
  local target_version="" remote="${CADENCE_GIT_REMOTE:-origin}" branch="${CADENCE_GIT_BRANCH:-main}"
  local timeout="${CADENCE_READY_TIMEOUT:-300}"
  while [ $# -gt 0 ]; do
    case "$1" in
    -h | --help) sed -n '3,20p' "$0" | sed 's/^# \{0,1\}//'; return 0 ;;
    -*) die "unknown option: $1" ;;
    *) [ -z "$target_version" ] || die "one version at a time"; target_version="$1"; shift ;;
    esac
  done
  if [ -n "$target_version" ]; then
    valid_version "$target_version" || die "'$target_version' is not a version: expected vX.Y.Z"
  fi

  require_docker
  command -v git >/dev/null 2>&1 || die "git is required: the package files are upgraded with git"
  git rev-parse --git-dir >/dev/null 2>&1 ||
    die "$(pwd) is not a git clone of the self-hosted repository; upgrade.sh switches files with git"
  load_env
  check_mode

  # Local edits of tracked files would be lost or block the switch. .env,
  # backups/ and secrets/ are not tracked and are not affected.
  if ! git diff --quiet HEAD --; then
    git status --short
    die "tracked files are modified (above). Commit, stash or revert them before upgrading; keep your settings in .env"
  fi

  local old_version="$CADENCE_VERSION" old_ref
  old_ref="$(git rev-parse HEAD)"

  # --- 1. what to upgrade to, before touching anything -------------------------
  info "fetching $remote"
  git fetch --quiet --tags "$remote"
  local target_ref new_version
  if [ -n "$target_version" ]; then
    target_ref="$(git rev-parse --verify --quiet "refs/tags/$target_version^{commit}")" ||
      die "there is no tag $target_version in $remote. Available: $(git tag -l 'v*' --sort=-v:refname | head -n 5 | tr '\n' ' ')"
  else
    target_ref="$(git rev-parse --verify --quiet "refs/remotes/$remote/$branch^{commit}")" ||
      die "there is no branch $remote/$branch"
    if ! git merge-base --is-ancestor HEAD "$target_ref"; then
      die "$remote/$branch is not ahead of the current files (pinned to a tag or diverged): upgrade to a version instead, ./upgrade.sh vX.Y.Z"
    fi
  fi
  new_version="$(git show "$target_ref:VERSION" | tr -d '[:space:]')"
  valid_version "$new_version" || die "VERSION at $target_ref holds '$new_version', expected vX.Y.Z"
  if version_lt "$new_version" "$old_version"; then
    die "$new_version is older than the running $old_version: downgrades are not supported (migrations only go forward).
  To return to $new_version restore one of its backups: git checkout $new_version && ./restore.sh backups/cadence-$new_version-<date>.sql.gz"
  fi
  if [ "$target_ref" = "$old_ref" ]; then
    ok "already on $old_version ($(git rev-parse --short HEAD)); nothing to do"
    return 0
  fi

  # --- 2. backup ---------------------------------------------------------------------
  running postgres || die "the stack is not running; start it before upgrading so that a backup can be taken:
  export CADENCE_VERSION=\$(cat VERSION) && docker compose up -d"
  info "backup of $old_version"
  ./backup.sh
  # backup.sh names files by version and time, so the newest one is ours.
  local backup
  backup="$(find "${BACKUP_DIR:-backups}" -maxdepth 1 -name "cadence-$old_version-*.sql.gz" -print | sort | tail -n 1)"
  [ -n "$backup" ] || die "backup.sh reported success but no cadence-$old_version-*.sql.gz is in ${BACKUP_DIR:-backups}"

  # --- 3. package files of the new version -----------------------------------------
  info "switching the package files to $new_version"
  if [ -n "$target_version" ]; then
    git -c advice.detachedHead=false checkout --quiet "$target_ref"
  else
    if [ "$(git symbolic-ref --quiet --short HEAD || true)" != "$branch" ]; then
      git checkout --quiet "$branch"
    fi
    git pull --quiet --ff-only "$remote" "$branch"
  fi
  load_version
  [ "$CADENCE_VERSION" = "$new_version" ] || die "VERSION is $CADENCE_VERSION after the switch, expected $new_version"

  # --- 4. images and start ---------------------------------------------------------
  local rollback
  rollback="  git -c advice.detachedHead=false checkout $old_ref   # package files of $old_version
  ./restore.sh --yes $backup   # data as of the backup, starts $old_version"

  info "pulling images of $new_version"
  if ! docker compose pull --quiet; then
    # Nothing has changed yet but the files: put them back.
    git -c advice.detachedHead=false checkout --quiet "$old_ref"
    die "could not pull the images of $new_version (see above); the package files are back on $old_version ($(git rev-parse --short HEAD)) and the running stack is untouched."
  fi
  info "starting $new_version"
  if ! docker compose up -d --remove-orphans; then
    die "docker compose up failed for $new_version. To return to $old_version:
$rollback"
  fi
  # The Caddyfile is a bind mount: `up -d` does not notice its changes.
  docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true

  info "waiting for readiness (up to ${timeout}s)"
  if ! wait_ready "$timeout"; then
    docker compose ps
    docker compose logs --tail 40 api worker || true
    die "$new_version did not become ready in ${timeout}s (logs above). The database may already be migrated.
  To return to $old_version and its backup:
$rollback"
  fi
  if [ "$old_version" = "$new_version" ]; then
    ok "package files updated, still on $new_version ($(git rev-parse --short HEAD))"
  else
    ok "upgraded $old_version -> $new_version"
  fi
}

main "$@"
exit $?
