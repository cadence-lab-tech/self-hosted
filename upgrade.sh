#!/usr/bin/env bash
#
# Upgrades the whole stack to a new version: backup, package files of the new
# version (VERSION, compose, Caddyfile, scripts, docs), new images, start,
# wait for readiness. git is not needed: the package comes from the release.
#
#   ./upgrade.sh                  # the latest release
#   ./upgrade.sh v0.6.0           # a specific release
#   ./upgrade.sh --force v0.6.0   # also replace package files edited here
#
# The package of the release is downloaded with its checksums.txt and
# verified before anything changes. Package files edited here stop the
# upgrade with their list: keep settings in .env and compose changes in
# compose.override.yml. With --force they are replaced; the edited copies stay
# in backups/package-<old version>-<date>.tar.gz. .env, compose.override.yml,
# backups/, secrets/ and other files of the directory are never touched.
#
# With BACKUP_S3_BUCKET set the backup is also copied to the bucket
# (./backup.sh --help); a failed copy is only a warning here - the rollback
# uses the local backup.
#
# Skipping versions is fine: migrations of every version in between are
# built into the new image. Going down is refused - migrations only go
# forward; to return to an older version restore its backup (restore.sh).
#
# If the new version does not become ready, the script exits with an error
# and prints the exact commands that return to the previous version and its
# backup. After a successful upgrade it reminds to update clab, the CLI of
# people and agents, to the new version: the server does not update it.
#
#   CADENCE_READY_TIMEOUT  seconds to wait for readiness, default 300
#   CADENCE_RELEASES_URL   a mirror of the releases (see lib.sh, "releases")
set -euo pipefail

cd "$(dirname "$0")"
# shellcheck source=lib.sh
. ./lib.sh

# The scratch directory of the run; global for the EXIT trap.
UPGRADE_WORK=""
trap 'rm -rf "${UPGRADE_WORK:-}"' EXIT

# manifest_paths FILE prints the paths of a package manifest.
manifest_paths() {
  awk '{ sub(/^[0-9a-f]+  /, ""); print }' "$1"
}

# manifest_of_this_version FILE: the manifest describes the files of the
# version in VERSION. A manifest left over from another version (a rollback
# with tar puts the old files back but leaves a newer manifest) is no
# reference.
manifest_of_this_version() {
  [ -f "$1" ] && [ -f VERSION ] &&
    [ "$(awk '$2 == "VERSION" {print $1}' "$1")" = "$(sha256_of VERSION)" ]
}

# edited_files MANIFEST prints the package files that exist here with other
# content than the manifest says.
edited_files() {
  local sum path
  while read -r sum path; do
    [ -n "$path" ] || continue
    if [ -f "$path" ] && [ "$(sha256_of "$path")" != "$sum" ]; then
      printf '%s\n' "$path"
    fi
  done <"$1"
}

# move_tree SRC moves every file under SRC to the same path here. A rename
# gives the file a new inode: bash keeps reading this very script from the old
# one while upgrade.sh is replaced.
move_tree() {
  local src="$1" f
  while IFS= read -r f; do
    f="${f#./}"
    mkdir -p "$(dirname "$f")"
    mv -f "$src/$f" "$f"
  done < <(cd "$src" && find . -type f)
}

# Everything runs from main(): the upgrade replaces this very file, and bash
# must not read the rest of it from the new version.
main() {
  local target_version="" force=false timeout="${CADENCE_READY_TIMEOUT:-300}"
  while [ $# -gt 0 ]; do
    case "$1" in
    --force) force=true; shift ;;
    -h | --help) sed -n '3,32p' "$0" | sed 's/^# \{0,1\}//'; return 0 ;;
    -*) die "unknown option: $1" ;;
    *) [ -z "$target_version" ] || die "one version at a time"; target_version="$1"; shift ;;
    esac
  done
  if [ -n "$target_version" ]; then
    valid_version "$target_version" || die "'$target_version' is not a version: expected vX.Y.Z"
  fi

  # .env first: a COMPOSE_PROJECT_NAME of another installation stops here,
  # before Docker is asked anything.
  load_env
  require_docker
  command -v curl >/dev/null 2>&1 || die "curl is required to download the package of the release"
  check_mode
  local old_version="$CADENCE_VERSION" backups="${BACKUP_DIR:-backups}"

  # A local override that compose does not read is a change that silently
  # does not apply; upgrade.sh never edits .env, so it only says so.
  local f
  for f in compose.override.yml docker-compose.override.yml; do
    if [ -f "$f" ]; then
      case ":${COMPOSE_FILE:-}:" in
      *":$f:"*) ;;
      *) warn "$f exists, but COMPOSE_FILE in .env does not list it, so compose ignores it. To apply it: COMPOSE_FILE=${COMPOSE_FILE:-}:$f" ;;
      esac
    fi
  done

  # --- 1. what to upgrade to, before touching anything -------------------------
  if [ -z "$target_version" ]; then
    info "looking up the latest release at $(releases_url)"
    target_version="$(latest_version)" || die "could not find the latest release at $(releases_url)"
  fi
  if version_lt "$target_version" "$old_version"; then
    die "$target_version is older than the running $old_version: downgrades are not supported (migrations only go forward).
  To return to $target_version, put its package files back and restore one of its backups:
    $(package_files_hint "$target_version") && ./restore.sh backups/cadence-$target_version-<date>.sql.gz"
  fi
  if [ "$target_version" = "$old_version" ]; then
    ok "already on $old_version; nothing to do"
    return 0
  fi

  # Same file system as the installation: the files are moved into place.
  UPGRADE_WORK="$(mktemp -d "$(pwd)/.upgrade.XXXXXX")"
  local work="$UPGRADE_WORK" name rc=0
  name="$(package_name "$target_version")"
  info "downloading $name"
  download_package "$target_version" "$work" || rc=$?
  case "$rc" in
  0) ;;
  2)
    local latest
    latest="$(latest_version || true)"
    die "there is no release $target_version with a package at $(releases_url)${latest:+ (the latest is $latest)}"
    ;;
  *) die "the checksum of $name does not match checksums.txt of $target_version: the download is broken or altered; nothing has changed" ;;
  esac
  mkdir "$work/new"
  tar -xpzf "$work/$name" -C "$work/new"
  [ -f "$work/new/$PACKAGE_MANIFEST" ] || die "$name has no $PACKAGE_MANIFEST: not a package of this repository"
  local new_version
  new_version="$(tr -d '[:space:]' <"$work/new/VERSION")"
  [ "$new_version" = "$target_version" ] || die "VERSION in $name holds '$new_version', expected $target_version"
  # The files of the new package, manifest included; kept apart because the
  # unpacked files are moved into place later.
  {
    manifest_paths "$work/new/$PACKAGE_MANIFEST"
    printf '%s\n' "$PACKAGE_MANIFEST"
  } >"$work/new.list"

  # --- 2. package files edited here --------------------------------------------
  # The reference is the manifest of the running version: the one unpacked
  # with it, or - for an installation from a git clone - the one of its
  # release, or else git itself.
  local reference="" edited=""
  if manifest_of_this_version "$PACKAGE_MANIFEST"; then
    reference="$PACKAGE_MANIFEST"
  else
    mkdir "$work/old"
    if download_package "$old_version" "$work/old" &&
      tar -xpzf "$work/old/$(package_name "$old_version")" -C "$work/old" "$PACKAGE_MANIFEST"; then
      reference="$work/old/$PACKAGE_MANIFEST"
    fi
  fi
  if [ -n "$reference" ]; then
    edited="$(edited_files "$reference")"
  elif git_clone; then
    # Only files the new package replaces matter.
    edited="$(git diff --name-only HEAD -- 2>/dev/null | grep -xF -f "$work/new.list" || true)"
  else
    warn "cannot tell whether package files were edited here: there is no $PACKAGE_MANIFEST of $old_version and no package of its release."
    warn "They are replaced; the current ones are kept in $backups/package-$old_version-<date>.tar.gz."
  fi
  if [ -n "$edited" ]; then
    if [ "$force" = true ]; then
      warn "replacing package files edited here (--force); the edited copies go to $backups/package-$old_version-<date>.tar.gz:"
      printf '    %s\n' "${edited//$'\n'/$'\n'    }" >&2
    else
      die "package files are edited here, and the upgrade would replace them:
    ${edited//$'\n'/$'\n'    }
  Keep settings in .env and compose changes in compose.override.yml (docs/admin.md, \"Local compose changes\"),
  and put these files back as they were - or run ./upgrade.sh --force $target_version to replace them
  and keep the edited copies in $backups/package-$old_version-<date>.tar.gz. Nothing has changed."
    fi
  fi

  # --- 3. backup ---------------------------------------------------------------------
  if external_db; then
    # The external database is checked by the images of the new version,
    # with the compose files of its package, before the backup: a database
    # the new version cannot use stops the upgrade while nothing has changed.
    info "checking the external database $(db_label) with the images of $target_version"
    [ -f "$work/new/$EXTERNAL_DB_FILE" ] ||
      die "the package of $target_version has no $EXTERNAL_DB_FILE: it cannot run on an external database. Nothing has changed."
    # compose.secrets.yml of COMPOSE_FILE too: without it the Docker secrets
    # of api would be missing; compose.external-db.yml goes after it.
    local check_files=(-f "$work/new/docker-compose.yml")
    case ":${COMPOSE_FILE:-}:" in
    *":$SECRETS_FILE:"*) [ ! -f "$work/new/$SECRETS_FILE" ] || check_files+=(-f "$work/new/$SECRETS_FILE") ;;
    esac
    CADENCE_VERSION="$target_version" docker compose --project-directory . \
      "${check_files[@]}" -f "$work/new/$EXTERNAL_DB_FILE" run --rm --no-deps -T api dbcheck ||
      die "the external database is not ready for $target_version (see above). Nothing has changed."
  else
    running postgres || die "the stack is not running; start it before upgrading so that a backup can be taken:
  export CADENCE_VERSION=\$(cat VERSION) && docker compose up -d"
  fi
  info "backup of $old_version"
  # The off-machine copy is no condition of the upgrade: its rollback uses
  # the local file.
  ./backup.sh --no-upload
  # backup.sh names files by version and time, so the newest one is ours.
  local backup
  backup="$(find "$backups" -maxdepth 1 -name "cadence-$old_version-*.sql.gz" -print | sort | tail -n 1)"
  [ -n "$backup" ] || die "backup.sh reported success but no cadence-$old_version-*.sql.gz is in $backups"
  if backup_s3_configured && ! backup_upload "$backup"; then
    warn "$(upload_failed "$backup")"
    warn "the upgrade goes on: its rollback uses the local backup"
  fi

  # The package files as they are now - of the old manifest and every file
  # the new package overwrites - for the rollback.
  local saved stamp
  stamp="${backup##*/cadence-"$old_version"-}"
  saved="$backups/package-$old_version-${stamp%.sql.gz}.tar.gz"
  {
    [ -z "$reference" ] || manifest_paths "$reference"
    cat "$work/new.list"
  } | sort -u | while IFS= read -r f; do [ ! -f "$f" ] || printf '%s\n' "$f"; done >"$work/saved.list"
  COPYFILE_DISABLE=1 tar -czf "$saved" -T "$work/saved.list"
  info "package files of $old_version saved to $saved"

  # --- 4. package files of the new version -----------------------------------------
  info "replacing the package files with $target_version"
  # Files of the old package that the new one no longer has.
  if [ -n "$reference" ]; then
    while IFS= read -r f; do
      rm -f "$f"
      info "removed $f (no longer in the package)"
    done < <(manifest_paths "$reference" | grep -vxF -f "$work/new.list" || true)
  fi
  move_tree "$work/new"
  load_version
  [ "$CADENCE_VERSION" = "$target_version" ] || die "VERSION is $CADENCE_VERSION after the switch, expected $target_version"

  # --- 5. images and start ---------------------------------------------------------
  local rollback
  rollback="  tar -xpzf $saved   # package files of $old_version
  ./restore.sh --yes $backup   # data as of the backup, starts $old_version"

  info "pulling images of $target_version"
  if ! docker compose pull --quiet; then
    # Nothing has changed yet but the files: put them back.
    mkdir "$work/back"
    tar -xpzf "$saved" -C "$work/back"
    # Files that came with the new package and were not here before go.
    while IFS= read -r f; do
      grep -qxF -- "$f" "$work/saved.list" || rm -f "$f"
    done <"$work/new.list"
    move_tree "$work/back"
    load_version
    die "could not pull the images of $target_version (see above); the package files are back on $CADENCE_VERSION and the running stack is untouched."
  fi
  info "starting $target_version"
  if ! docker compose up -d --remove-orphans; then
    die "docker compose up failed for $target_version. To return to $old_version:
$rollback"
  fi
  # The Caddyfile is a bind mount: `up -d` does not notice its changes.
  docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile >/dev/null 2>&1 || true

  info "waiting for readiness (up to ${timeout}s)"
  if ! wait_ready "$timeout"; then
    docker compose ps
    docker compose logs --tail 40 api worker || true
    die "$target_version did not become ready in ${timeout}s (logs above). The database may already be migrated.
  To return to $old_version and its backup:
$rollback"
  fi
  ok "upgraded $old_version -> $target_version"
  # clab of people and agents stays on the old version: say so here, where
  # the administrator is looking.
  say "  Update clab to $target_version on the machines of people and agents:"
  say "    brew upgrade clab   # installed with Homebrew"
  say "    curl -fsSL https://raw.githubusercontent.com/cadence-lab-tech/homebrew-tap/main/install.sh | CLAB_VERSION=$target_version sh"
  say "  and check with: clab version"
  if [ -e .git ]; then
    say "  This directory is a git clone; upgrades no longer use git, and .git can be removed (docs/admin.md, \"Moving a git installation to release packages\")."
  fi
}

main "$@"
exit $?
