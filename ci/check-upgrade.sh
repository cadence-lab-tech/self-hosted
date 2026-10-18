#!/usr/bin/env bash
#
# Upgrade check between two versions of the package:
#
#   ci/check-upgrade.sh v0.5.3 v0.6.0
#
# FROM is installed the way an administrator has it: from the package of its
# release with the one-line installer, or - for versions released before
# packages existed (v0.5.x) - as a git clone of its tag, which is then moved
# on the way its first upgrade moves it: the files of this checkout with
# VERSION = FROM, committed, as if a tag with the new scripts were checked
# out. TO is the package of this checkout built by ci/package.sh with VERSION
# = TO and served from a local copy of the releases (CADENCE_RELEASES_URL), so
# the images of TO must be published, or be in CADENCE_REGISTRY.
#
# On FROM it creates a team, a project, a project document and a task with
# an artifact (on a minimal cycle imported as a bundle), and checks:
#
#   - a failed image pull puts the package files back; the stack stays on FROM
#   - a package file edited here stops the upgrade before the backup
#   - a version that does not become ready prints rollback commands without
#     git, and they, run as printed, bring back FROM and its data
#   - the upgrade itself: backup taken, the instance reports TO, the data and
#     the artifact content are there, .env, secrets/, compose.override.yml
#     and a file of the administrator are unchanged, a file the package no
#     longer has is removed, git is not called (.git moved away for a clone)
#   - the output of the upgrade reminds to update clab to TO (brew upgrade
#     clab, CLAB_VERSION=TO, clab version) - checked when the upgrade.sh that
#     runs it has the reminder: always for a clone (it runs the scripts of
#     this checkout), for a package once FROM is a release with it; "nothing
#     to do", the refusals and the failed upgrades do not remind
#   - ./upgrade.sh with no version on the latest release: nothing to do
#   - going down is refused, and restore.sh of a FROM backup refuses, each
#     with a hint that needs no git
#   - for a clone, as it really is - without backups/package-FROM-*, since
#     its first upgrade ran the old script with git: both refusals point at
#     the source archive of the tag without git, and at git checkout of the
#     tag with .git back, which, run as printed, brings back the files of FROM
#
# The stack is torn down with its volumes at the end.
#
#   CHECK_HTTP_PORT       host port of the stack, default 8080
#   COMPOSE_PROJECT_NAME  compose project of the stack, default cadence-check
#   CLAB_BIN              clab to use; default: the CLI of FROM from the public tap
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=lib.sh
. ./lib.sh

# Globals: the EXIT trap runs after main() has returned.
work=""
dir=""

# shellcheck disable=SC2317,SC2329 # invoked by the EXIT trap
cleanup() {
  if [ -n "$dir" ] && [ -f "$dir/.env" ]; then
    info "tearing the stack down"
    (cd "$dir" && CADENCE_VERSION="$(tr -d '[:space:]' <VERSION)" docker compose down -v --remove-orphans >/dev/null 2>&1) || true
  fi
  [ -z "$work" ] || rm -rf "$work" 2>/dev/null || true
}
trap cleanup EXIT

main() {
  local from="${1:-}" to="${2:-}"
  if ! valid_version "$from" || ! valid_version "$to"; then
    die "usage: ci/check-upgrade.sh vFROM vTO"
  fi
  version_lt "$from" "$to" || die "$from must be older than $to"

  local repo port base failures=0 clab admin_token
  repo="$(pwd)"
  port="${CHECK_HTTP_PORT:-8080}"
  base="http://127.0.0.1:$port"
  export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-cadence-check}"
  work="$(mktemp -d)"
  dir="$work/cadence"

  pass() { printf '  ✓ %s\n' "$*"; }
  fail() {
    printf '  ✗ %s\n' "$*" >&2
    failures=$((failures + 1))
  }
  # files_state prints the sha256 of every file of the installation but the
  # backups and git: what "untouched" means here.
  files_state() {
    (cd "$dir" && find . -type f ! -path './backups/*' ! -path './.git/*' ! -path './.git.off/*' ! -path './.upgrade.*' |
      LC_ALL=C sort | while IFS= read -r f; do printf '%s  %s\n' "$(sha256_of "$f")" "$f"; done)
  }
  instance_version() {
    curl -sf "$base/v1/instance" | jq -r .version 2>/dev/null || true
  }

  # --- releases: TO is the package of this checkout ------------------------------
  local releases="$work/releases"
  info "package of this checkout as $to"
  ci/package.sh --version "$to" "$releases/download/$to" >/dev/null
  mkdir -p "$releases/latest"
  cp -R "$releases/download/$to" "$releases/latest/download"

  # --- FROM -------------------------------------------------------------------------
  admin_token="sdlc_$(openssl rand -hex 24)"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::add-mask::$admin_token"; fi
  local clone=false
  if curl -fsIL -o /dev/null "$CADENCE_RELEASES_DEFAULT/download/$from/$(package_name "$from")"; then
    info "installing $from from the package of its release"
    (cd "$work" && SDLC_ADMIN_TOKEN="$admin_token" sh "$repo/get-cadence.sh" --version "$from" \
      --mode proxy --http-addr "127.0.0.1:$port" --yes </dev/null)
  else
    clone=true
    info "installing $from from a git clone of its tag ($from has no release package)"
    git fetch --quiet --tags origin 2>/dev/null || true
    git clone --quiet --branch "$from" "file://$(git rev-parse --path-format=absolute --git-common-dir)" "$dir" 2>/dev/null
    (cd "$dir" && SDLC_ADMIN_TOKEN="$admin_token" ./install.sh --mode proxy --http-addr "127.0.0.1:$port" --yes </dev/null)
  fi
  [ -f "$dir/.env" ] || die "$from is not installed"
  cd "$dir"
  export CADENCE_RELEASES_URL="file://$releases"

  clab="${CLAB_BIN:-}"
  if [ -z "$clab" ]; then
    curl -fsSL https://raw.githubusercontent.com/cadence-lab-tech/homebrew-tap/main/install.sh |
      CLAB_VERSION="$from" CLAB_INSTALL_DIR="$work/bin" sh
    clab="$work/bin/clab"
  fi
  export CLAB_CONFIG_DIR="$work/clab"
  printf '%s\n' "$admin_token" | "$clab" auth login --host "$base" --with-token >/dev/null

  info "data on $from"
  printf 'Written on %s before the upgrade.\n' "$from" >"$work/doc.md"
  "$clab" --host "$base" team create upgrade --name "Upgrade check" >/dev/null
  "$clab" --host "$base" project create UPG --name "Upgrade check" --team upgrade >/dev/null
  SDLC_PROJECT=UPG "$clab" --host "$base" doc put --kind guideline --title "Upgrade check" --file "$work/doc.md" >/dev/null

  # A new project has no cycle: a minimal one (one role, one working status)
  # comes as a bundle, then a task is taken on it and an artifact submitted.
  cat >"$work/bundle.json" <<'JSON'
{
  "version": 2,
  "roles": [{
    "key": "upgrade",
    "name": "Upgrade check",
    "instructions": "Write a note.",
    "output_contract": [{"kind": "upgrade.note", "title": "Note", "format": "markdown", "required": true}]
  }],
  "workflows": [{
    "name": "Upgrade check",
    "statuses": [
      {"key": "work", "name": "Work", "category": "active", "is_initial": true, "role": "upgrade"},
      {"key": "done", "name": "Done", "category": "done", "is_terminal": true}
    ],
    "transitions": [{"key": "finish", "name": "Finish", "from": "work", "to": "done", "kind": "advance"}]
  }]
}
JSON
  local workflow_id task_key artifact_id
  workflow_id="$(SDLC_PROJECT=UPG "$clab" --host "$base" import --file "$work/bundle.json" --json | jq -r '.workflows[0].id')"
  SDLC_PROJECT=UPG "$clab" --host "$base" workflow activate "$workflow_id" >/dev/null
  task_key="$(SDLC_PROJECT=UPG "$clab" --host "$base" create --title "Upgrade check task" --json | jq -r '.key')"
  SDLC_PROJECT=UPG "$clab" --host "$base" claim "$task_key" >/dev/null
  printf 'Artifact written on %s before the upgrade.\n' "$from" >"$work/note.md"
  artifact_id="$(SDLC_PROJECT=UPG "$clab" --host "$base" submit "$task_key" --kind upgrade.note \
    --title "Upgrade check note" --file "$work/note.md" --json | jq -r '.artifact.id // .id')"
  case "$task_key/$artifact_id" in
  /* | */ | null/* | */null) die "could not create the task and its artifact on $from" ;;
  esac
  info "task $task_key with artifact $artifact_id on $from"

  # A clone takes the files of this checkout as its first upgrade would bring
  # them: committed, so the tree is clean, and without package.sha256, which
  # a git checkout does not have.
  if [ "$clone" = true ]; then
    info "the clone takes the scripts of this checkout (VERSION $from), as its first upgrade would"
    (cd "$repo" && ci/package.sh --version "$from" "$work/from-package" >/dev/null)
    tar -xpzf "$work/from-package/$(package_name "$from")" -C "$dir"
    mv "$dir/$PACKAGE_MANIFEST" "$work/from.manifest"
    git add -A .
    git -c user.name=check -c user.email=check@localhost commit --quiet -m "scripts of the package" || true
  fi

  # upgrade.sh runs to the end as the script of FROM (upgrade.sh, "move_tree"):
  # the reminder shows only if that one has it.
  local reminder="Update clab to $to on the machines of people and agents"
  local reminds=false
  # shellcheck disable=SC2016 # the text of the script, not an expansion
  if grep -qF 'Update clab to $target_version' upgrade.sh; then reminds=true; fi
  # no_reminder WHAT OUTPUT: a run that did not upgrade must not remind.
  no_reminder() {
    if grep -qF "Update clab" <<<"$2"; then
      fail "$1 reminds to update clab: $2"
    else
      pass "$1 does not remind to update clab"
    fi
  }

  # --- a failed image pull -------------------------------------------------------------
  info "./upgrade.sh $to with images that cannot be pulled"
  local before out
  before="$(files_state)"
  if out="$(CADENCE_REGISTRY=127.0.0.1:9 ./upgrade.sh "$to" 2>&1)"; then
    fail "upgrade.sh $to succeeded with an unreachable registry"
  else
    pass "upgrade.sh $to fails when the images cannot be pulled"
  fi
  [ "$reminds" = false ] || no_reminder "the failed pull" "$out"
  if [ "$(files_state)" = "$before" ]; then
    pass "the package files are back as they were (VERSION $(tr -d '[:space:]' <VERSION))"
  else
    fail "the package files changed after the failed pull: $(diff <(echo "$before") <(files_state) | head -n 10 | tr '\n' ';')"
  fi
  if [ "$(instance_version)" = "$from" ]; then
    pass "the stack still runs $from"
  else
    fail "the stack does not report $from after the failed pull"
  fi

  # --- an edited package file ------------------------------------------------------------
  info "./upgrade.sh $to over an edited docker-compose.yml"
  local backups_before
  cp docker-compose.yml "$work/compose.orig"
  printf '# a local edit\n' >>docker-compose.yml
  backups_before="$(find backups -maxdepth 1 -name 'cadence-*.sql.gz' | wc -l | tr -d ' ')"
  if out="$(./upgrade.sh "$to" 2>&1)"; then
    fail "upgrade.sh ran over an edited docker-compose.yml"
  elif grep -qF "docker-compose.yml" <<<"$out" && grep -qF "Nothing has changed" <<<"$out"; then
    pass "upgrade.sh refuses with the list of edited files (docker-compose.yml) and --force as the way out"
  else
    fail "upgrade.sh refused without naming docker-compose.yml: $out"
  fi
  [ "$reminds" = false ] || no_reminder "the refusal over an edited file" "$out"
  if [ "$(find backups -maxdepth 1 -name 'cadence-*.sql.gz' | wc -l | tr -d ' ')" = "$backups_before" ] &&
    [ "$(tr -d '[:space:]' <VERSION)" = "$from" ]; then
    pass "the refusal comes before the backup and changes nothing"
  else
    fail "the refusal over an edited file took a backup or changed VERSION"
  fi
  cp "$work/compose.orig" docker-compose.yml

  # --- from here on without git ------------------------------------------------------------
  mkdir -p "$work/nogit"
  printf '#!/bin/sh\necho "git $*" >>"%s/git-calls"\nexit 1\n' "$work" >"$work/nogit/git"
  chmod 755 "$work/nogit/git"
  local path_nogit="$work/nogit:$PATH"
  if [ "$clone" = true ]; then
    mv .git .git.off
    # The manifest an unpacked package has: the reference for edited files.
    cp "$work/from.manifest" "$PACKAGE_MANIFEST"
  fi
  # A file the next package no longer has, as if FROM had shipped it.
  printf 'shipped by %s only\n' "$from" >obsolete.txt
  printf '%s  %s\n' "$(sha256_of obsolete.txt)" obsolete.txt >>"$PACKAGE_MANIFEST"
  # Files of the administrator.
  printf 'notes of the administrator\n' >notes.txt
  [ -f compose.override.yml ] || printf 'services: {}\n' >compose.override.yml
  printf 'not a key\n' >secrets/check.pem
  local kept kept_before
  kept=".env compose.override.yml notes.txt secrets/check.pem"
  # shellcheck disable=SC2086 # a list of names
  kept_before="$(for f in $kept; do printf '%s %s\n' "$(sha256_of "$f")" "$f"; done)"

  # The edited file again, now found by package.sha256 rather than git.
  info "./upgrade.sh $to over an edited docker-compose.yml, without git"
  printf '# a local edit\n' >>docker-compose.yml
  if out="$(PATH="$path_nogit" ./upgrade.sh "$to" 2>&1)"; then
    fail "upgrade.sh ran over an edited docker-compose.yml without git"
  elif grep -qF "docker-compose.yml" <<<"$out" && grep -qF -- "--force" <<<"$out"; then
    pass "package.sha256 finds the edit: refused with the file and --force"
  else
    fail "upgrade.sh without git refused without naming docker-compose.yml: $out"
  fi
  cp "$work/compose.orig" docker-compose.yml

  # --- not ready: the printed rollback -----------------------------------------------------
  # compose up waits for the API to be healthy before it starts the worker,
  # so only a zero timeout makes "not ready" certain.
  info "./upgrade.sh $to that does not become ready in time"
  if out="$(PATH="$path_nogit" CADENCE_READY_TIMEOUT=0 ./upgrade.sh "$to" 2>&1)"; then
    fail "upgrade.sh did not report the readiness timeout"
  else
    pass "upgrade.sh fails when $to is not ready in time"
  fi
  [ "$reminds" = false ] || no_reminder "the upgrade that did not become ready" "$out"
  local rollback
  rollback="$(grep -E '^  (tar -xpzf |\./restore\.sh --yes )' <<<"$out" || true)"
  if [ "$(grep -c . <<<"$rollback")" = 2 ] && ! grep -qw git <<<"$rollback"; then
    pass "it prints the rollback: package files and the backup, no git"
  else
    fail "the rollback is not two commands without git: $rollback"
  fi
  info "running the rollback as printed"
  PATH="$path_nogit" bash -euc "$rollback" >/dev/null
  if [ "$(tr -d '[:space:]' <VERSION)" = "$from" ] && [ "$(instance_version)" = "$from" ]; then
    pass "after the rollback VERSION and /v1/instance are $from"
  else
    fail "after the rollback the installation is not on $from"
  fi
  if "$clab" --host "$base" project list --json | grep -qF '"UPG"'; then
    pass "after the rollback the project created on $from is there"
  else
    fail "after the rollback the project created on $from is gone"
  fi

  # --- the upgrade ------------------------------------------------------------------------
  # With an edited package file and --force: replaced, the edited copy kept.
  info "./upgrade.sh --force $to over an edited docker-compose.yml"
  printf '# a local edit\n' >>docker-compose.yml
  PATH="$path_nogit" ./upgrade.sh --force "$to" | tee "$work/upgrade.out"
  out="$(cat "$work/upgrade.out")"
  if [ "$reminds" = false ]; then
    info "upgrade.sh of $from has no reminder to update clab; not checked"
  elif grep -qF "$reminder" <<<"$out" && grep -qF "brew upgrade clab" <<<"$out" &&
    grep -qF "CLAB_VERSION=$to sh" <<<"$out" && grep -qF "clab version" <<<"$out" &&
    [ "$(grep -n "$reminder" <<<"$out" | cut -d: -f1)" -gt "$(grep -n "upgraded $from -> $to" <<<"$out" | cut -d: -f1)" ]; then
    pass "after 'upgraded $from -> $to' it reminds to update clab: brew upgrade clab, CLAB_VERSION=$to, clab version"
  else
    fail "the upgrade does not remind to update clab to $to after 'upgraded': $out"
  fi

  if [ -n "$(find backups -maxdepth 1 -name "cadence-$from-*.sql.gz")" ]; then
    pass "a backup of $from was taken before the upgrade"
  else
    fail "no backups/cadence-$from-*.sql.gz after the upgrade"
  fi
  if [ -n "$(find backups -maxdepth 1 -name "package-$from-*.tar.gz")" ]; then
    pass "the package files of $from are kept in backups/package-$from-*.tar.gz"
  else
    fail "no backups/package-$from-*.tar.gz after the upgrade"
  fi
  local saved_package
  saved_package="$(find backups -maxdepth 1 -name "package-$from-*.tar.gz" | sort | tail -n 1)"
  if [ -n "$saved_package" ] && tar -xzOf "$saved_package" docker-compose.yml | grep -qF '# a local edit' &&
    ! grep -qF '# a local edit' docker-compose.yml; then
    pass "--force replaced the edited docker-compose.yml and kept the edited copy in $saved_package"
  else
    fail "--force: the edited docker-compose.yml is not replaced or its copy is not kept"
  fi
  if [ "$(tr -d '[:space:]' <VERSION)" = "$to" ] && [ "$(instance_version)" = "$to" ]; then
    pass "VERSION and /v1/instance report $to"
  else
    fail "the installation does not report $to"
  fi
  if [ "$(awk '$2 == "VERSION" {print $1}' "$PACKAGE_MANIFEST")" = "$(sha256_of VERSION)" ]; then
    pass "$PACKAGE_MANIFEST is the one of $to"
  else
    fail "$PACKAGE_MANIFEST is not the one of $to"
  fi
  # shellcheck disable=SC2086 # a list of names
  if [ "$(for f in $kept; do printf '%s %s\n' "$(sha256_of "$f")" "$f"; done)" = "$kept_before" ]; then
    pass "$kept are unchanged"
  else
    fail "some of $kept changed"
  fi
  if [ ! -e obsolete.txt ]; then
    pass "a file the package of $to no longer has is removed"
  else
    fail "obsolete.txt, no longer in the package, is still there"
  fi
  if [ "$clone" = true ]; then
    if [ -d .git.off ]; then pass "the moved-away .git is untouched"; else fail ".git.off is gone"; fi
  fi
  if "$clab" --host "$base" project list --json | grep -qF '"UPG"'; then
    pass "the project created on $from is there"
  else
    fail "the project created on $from is gone"
  fi
  if SDLC_PROJECT=UPG "$clab" --host "$base" doc list --json | grep -qF "Upgrade check"; then
    pass "the document created on $from is there"
  else
    fail "the document created on $from is gone"
  fi
  # Into a variable first: grep -q would stop reading and fail the pipe.
  local state
  state="$("$clab" --host "$base" show "$task_key" --json || true)"
  if jq -e --arg key "$task_key" '.task.key == $key and .task.title == "Upgrade check task"' <<<"$state" >/dev/null; then
    pass "the task $task_key created on $from is there"
  else
    fail "the task $task_key created on $from is gone"
  fi
  if curl -sf -H "Authorization: Bearer $admin_token" "$base/v1/tasks/$task_key/artifacts" |
    jq -e --arg id "$artifact_id" '.artifacts[] | select(.id == $id and .kind == "upgrade.note")' >/dev/null; then
    pass "the artifact of $task_key is listed"
  else
    fail "the artifact of $task_key is not listed"
  fi
  if curl -sf -H "Authorization: Bearer $admin_token" "$base/v1/artifacts/$artifact_id/content" |
    cmp -s - "$work/note.md"; then
    pass "the content of the artifact is unchanged"
  else
    fail "the content of the artifact differs or is gone"
  fi

  # --- after the upgrade ----------------------------------------------------------------------
  info "./upgrade.sh on the latest release"
  if out="$(PATH="$path_nogit" ./upgrade.sh 2>&1)" && grep -qF "nothing to do" <<<"$out"; then
    pass "./upgrade.sh with no version on $to (the latest): nothing to do"
  else
    fail "./upgrade.sh with no version: $out"
  fi
  no_reminder "'nothing to do'" "$out"

  info "./upgrade.sh $from must refuse"
  if out="$(PATH="$path_nogit" ./upgrade.sh "$from" 2>&1)"; then
    fail "upgrade.sh $from after $to did not refuse the downgrade"
  elif grep -qF "tar -xpzf backups/package-$from-" <<<"$out" && ! grep -qw git <<<"$out"; then
    pass "upgrade.sh refuses to go down to $from, the hint puts its package files back without git"
  else
    fail "the downgrade refusal: $out"
  fi
  no_reminder "the downgrade refusal" "$out"

  info "restore.sh of a $from backup must refuse on $to"
  local old_backup
  old_backup="$(find backups -maxdepth 1 -name "cadence-$from-*.sql.gz" | sort | tail -n 1)"
  if out="$(PATH="$path_nogit" ./restore.sh --yes "$old_backup" 2>&1)"; then
    fail "restore.sh restored a $from backup on $to"
  elif grep -qF "tar -xpzf backups/package-$from-" <<<"$out" && ! grep -q 'git checkout' <<<"$out"; then
    pass "restore.sh refuses, the hint puts the package files of $from back without git"
  else
    fail "the restore refusal: $out"
  fi
  if [ "$(instance_version)" = "$to" ]; then pass "the stack still runs $to"; else fail "the stack does not report $to"; fi

  # --- a clone without the package copy of FROM ---------------------------------------------
  # A real clone came to the package with the old upgrade.sh and git checkout:
  # no backups/package-FROM-* is there, and FROM has no release package.
  local archive checkout
  archive="curl -fsSL https://github.com/cadence-lab-tech/self-hosted/archive/refs/tags/$from.tar.gz | tar -xpzf - --strip-components=1"
  checkout="git -c advice.detachedHead=false checkout --force $from"
  if [ "$clone" = true ]; then
    mkdir "$work/kept"
    mv backups/package-"$from"-*.tar.gz "$work/kept/"
    info "./upgrade.sh $from and restore.sh without backups/package-$from-* and without git"
    if out="$(PATH="$path_nogit" ./upgrade.sh "$from" 2>&1)"; then
      fail "upgrade.sh $from after $to did not refuse the downgrade"
    elif grep -qF -- "$archive && ./restore.sh" <<<"$out" && ! grep -qF "releases/download/$from" <<<"$out"; then
      pass "upgrade.sh refuses to go down to $from, the hint takes the source archive of the tag"
    else
      fail "the downgrade refusal without a package copy and git: $out"
    fi
    if out="$(PATH="$path_nogit" ./restore.sh --yes "$old_backup" 2>&1)"; then
      fail "restore.sh restored a $from backup on $to"
    elif grep -qF -- "$archive && ./restore.sh $old_backup" <<<"$out" && ! grep -qF "releases/download/$from" <<<"$out"; then
      pass "restore.sh refuses, the hint takes the source archive of the tag"
    else
      fail "the restore refusal without a package copy and git: $out"
    fi
  fi

  if [ -s "$work/git-calls" ]; then
    fail "git was called: $(tr '\n' ';' <"$work/git-calls")"
  else
    pass "git was never called after .git was moved away"
  fi

  if [ "$clone" = true ]; then
    info "./upgrade.sh $from and restore.sh without backups/package-$from-*, with .git and git back"
    mv .git.off .git
    if out="$(./upgrade.sh "$from" 2>&1)"; then
      fail "upgrade.sh $from after $to did not refuse the downgrade"
    elif grep -qF -- "    $checkout && ./restore.sh" <<<"$out"; then
      pass "upgrade.sh refuses to go down to $from, the hint checks out its tag with git"
    else
      fail "the downgrade refusal in a git clone without a package copy: $out"
    fi
    if out="$(./restore.sh --yes "$old_backup" 2>&1)"; then
      fail "restore.sh restored a $from backup on $to"
    elif grep -qF -- "    $checkout && ./restore.sh $old_backup" <<<"$out"; then
      pass "restore.sh refuses, the hint checks out the tag $from with git"
    else
      fail "the restore refusal in a git clone without a package copy: $out"
    fi
    if bash -euc "$checkout" >/dev/null 2>&1 && [ "$(tr -d '[:space:]' <VERSION)" = "$from" ]; then
      pass "the checkout, run as printed, brings back the files of $from"
    else
      fail "after the printed checkout VERSION is $(tr -d '[:space:]' <VERSION), expected $from"
    fi
  fi

  if [ "$failures" -gt 0 ]; then
    docker compose ps || true
    die "$failures check(s) failed"
  fi
  ok "upgrade $from -> $to passed"
}

main "$@"
exit $?
