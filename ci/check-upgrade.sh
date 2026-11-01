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
# the images of TO must be published, or be in CADENCE_REGISTRY, and clab of
# TO in the tap (the package carries it in bin/, decision 0057) - or in
# CHECK_TO_CLAB.
#
# The scripts of the package are wrappers of the clab in it (decision 0057).
# FROM of a release up to LAST_BASH_RELEASE (ci/lib.sh) has the bash
# scripts: its own bash upgrade.sh brings the wrappers and bin/clab-* (new
# files of the package, 755), and the rollback it prints brings the bash
# scripts back. CHECK_FROM=checkout installs FROM as the package of this
# checkout with VERSION = FROM and clab of FROM from the tap: an upgrade
# between two versions on the wrappers, whose rollback brings back the clab
# of FROM too. Before a release after VERSION exists, TO is made up - its
# images in a local registry, the backend built with --build-arg VERSION=TO,
# and clab of TO built from the backend with -X main.version=TO
# (ci/package.sh, --clab) - for example, with VERSION v0.13.0:
#
#   CHECK_FROM=checkout CHECK_TO_CLAB=/tmp/clab-v99 CADENCE_REGISTRY=localhost:5050/<name> \
#     CADENCE_BACKEND_DIGEST= CADENCE_FRONTEND_DIGEST= CADENCE_VERIFY=off \
#     ci/check-upgrade.sh v0.13.0 v99.0.0
#
# with localhost:5050/<name>/sdlc-pipeline-{backend,frontend} of both versions.
# After the upgrade the wrappers of TO work (./backup.sh,
# ./backup.sh verify), and no run prints "older than the target": the clab
# of the package is replaced with the package.
#
# docker-compose.yml pins the images of the VERSION of this checkout by
# digest (ci/pins.sh). TO = that VERSION upgrades to exactly those bytes, and
# the check compares the image of api with the pin. For another TO the pins
# name other images: the check drops them (empty CADENCE_BACKEND_DIGEST and
# CADENCE_FRONTEND_DIGEST) and the upgrade goes by the tag TO. Images of a
# branch in a local registry are pulled by tag too - the same rule as in
# ci/check-stack.sh:
#
#   CADENCE_VERIFY=off CADENCE_REGISTRY=localhost:5050 CADENCE_BACKEND_DIGEST= CADENCE_FRONTEND_DIGEST= \
#     ci/check-upgrade.sh vFROM vTO
#
# CADENCE_VERIFY=off there: images of a branch are no images of a release,
# their signatures are not ours to check (with auto they are "not pinned,
# not verified", require refuses them). The installer of FROM v0.15.0 and
# later keeps that CADENCE_REGISTRY in .env, and .env wins over the
# environment: the failed image pull puts its unreachable registry into .env
# itself and brings .env back afterwards - leave the line in .env as it is.
#
# Signatures (CADENCE_VERIFY, docs/admin.md "Verifying a release"): the package of TO is
# this checkout, not signed; it gets a stand-in bundle (ci/package.sh
# --bundle), and with a real cosign 3.x in PATH a wrapper accepts its
# verify-blob and hands the images to the real cosign (ci/verify-stubs.sh).
# When the upgrade verifies at all - clab server with CADENCE_VERIFY in its
# help, or an upgrade.sh of FROM that has it (the first upgrade to a release
# with the verification runs the old script, which has none) - a stub cosign
# with a bad signature of checksums.txt of TO, and of its backend image when
# TO is pinned, makes the upgrade refuse with nothing changed: FROM keeps
# running.
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
#   - the roles carry their documents over the upgrade (TO is v0.21.0 or
#     newer, the release that has them, CLAB-350): the claim of a role taken
#     on FROM and taken again after the upgrade hands the instructions with
#     the same sha256, byte for byte, to the clab of FROM; the clab of TO sees them as the one document main.md, and lays
#     it out by claim --instructions-dir as the same bytes; a role of two
#     documents reads as one string, with the markers, to the clab of FROM
#   - the starter bundle of FROM, imported into a project before the upgrade,
#     is left unchanged by the starter bundle of TO (import and clab server
#     starter: roles and cycles unchanged), and a role edited by hand stops
#     clab server starter; the clab of TO against the server of FROM: a bundle
#     of format 3 is refused and applies nothing, a bundle of format 2 and
#     export go through, export --dir does not
#   - ./upgrade.sh with no version on the latest release: nothing to do
#   - going down is refused, and restore.sh of a FROM backup refuses, each
#     with a hint that needs no git
#   - the move of the bundled database from PostgreSQL 17 to 18
#     (postgres/major-upgrade.sh), when FROM runs 17 and TO 18: a move cut
#     off after the new cluster is in place but before its mark (a directory
#     where the mark is written) fails the upgrade with postgres not started and
#     no mark, and the rollback as printed brings back FROM on 17; the
#     upgrade that is not ready has moved the data (TO on 18, the volume
#     pgdata kept) and its rollback brings back FROM on 17; a task written
#     on FROM after that rollback is on TO after the upgrade, the counts of
#     tasks, artifacts and embeddings are those of FROM, PostgreSQL 18 on
#     Debian 13, no collation version mismatch in the databases or the
#     logs; a second docker compose up -d on TO moves nothing, and a task
#     written on TO stays
#   - an installation from before v0.7.1 has no name in .env; started with
#     COMPOSE_PROJECT_NAME, as this check starts it, it is refused by the
#     scripts (after the upgrade) and by clab server with the one step that
#     fixes it - the line in .env - and runs without the variable after it
#   - for a clone, as it really is - without backups/package-FROM-*, since
#     its first upgrade ran the old script with git: both refusals point at
#     the source archive of the tag without git, and at git checkout of the
#     tag with .git back, which, run as printed, brings back the files of FROM
#
# The stack is torn down with its volumes at the end.
#
#   CHECK_HTTP_PORT       host port of the stack, default 8080
#   COMPOSE_PROJECT_NAME  compose project of the stack, default cadence-check
#   CLAB_BIN              clab of the people for the data of the check, and of
#                         CADENCE_DRIVER=clab; default: the CLI of FROM from the
#                         public tap
#   CHECK_FROM            release (default) - FROM from the package of its
#                         release; checkout - FROM as the package of this
#                         checkout with clab of FROM from the tap: FROM is
#                         v0.13.0 or later, a clab that knows the wrappers
#                         (CADENCE_WRAPPER). The pins of docker-compose.yml
#                         name the images of VERSION: give CADENCE_*_DIGEST=
#                         when FROM is another version
#   CHECK_TO_CLAB         a directory with clab-<os>-<arch> of the four
#                         platforms for the package of TO (ci/package.sh
#                         --clab), when the tap has no clab of TO
#   CADENCE_DRIVER        scripts (default) - upgrade and restore with
#                         upgrade.sh and restore.sh of the installation, the
#                         wrappers of clab server once FROM has them; clab -
#                         with clab server upgrade and restore of CLAB_BIN, an
#                         external clab (outside bin/): it proves that a clab
#                         of the people manages an installation of the
#                         package by --dir as the wrappers do, with its own
#                         hints (clab server ...). clab server manages
#                         installations from v0.6.0 on, so FROM is v0.6.0 or
#                         later.
set -euo pipefail

cd "$(dirname "$0")/.."
# shellcheck source=ci/lib.sh
. ./ci/lib.sh

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
  local driver="${CADENCE_DRIVER:-scripts}"
  case "$driver" in
  scripts) ;;
  clab)
    [ -n "${CLAB_BIN:-}" ] || die "CADENCE_DRIVER=clab needs CLAB_BIN: a clab with clab server"
    version_lt "$from" "$FIRST_PACKAGE_VERSION" &&
      die "CADENCE_DRIVER=clab: clab server manages installations from $FIRST_PACKAGE_VERSION on, $from is older"
    ;;
  *) die "CADENCE_DRIVER is '$driver', expected scripts or clab" ;;
  esac

  local from_mode="${CHECK_FROM:-release}"
  case "$from_mode" in
  release | checkout) ;;
  *) die "CHECK_FROM is '$from_mode', expected release or checkout" ;;
  esac
  local repo port base failures=0 clab admin_token
  repo="$(pwd)"
  port="${CHECK_HTTP_PORT:-8080}"
  base="http://127.0.0.1:$port"
  export COMPOSE_PROJECT_NAME="${COMPOSE_PROJECT_NAME:-cadence-check}"
  [ "$COMPOSE_PROJECT_NAME" != cadence ] ||
    die "COMPOSE_PROJECT_NAME=cadence is the name of a real installation; the check tears its stack down - give it a name of its own"
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
  local releases="$work/releases" checkout_version
  checkout_version="$(tr -d '[:space:]' <VERSION)"
  if [ "$to" != "$checkout_version" ] && [ -z "${CADENCE_BACKEND_DIGEST+set}${CADENCE_FRONTEND_DIGEST+set}" ]; then
    info "docker-compose.yml pins the images of $checkout_version, not of $to: the upgrade goes by the tag $to"
    export CADENCE_BACKEND_DIGEST="" CADENCE_FRONTEND_DIGEST=""
  fi
  if [ "$from_mode" = checkout ]; then
    version_lt "$from" v0.13.0 &&
      die "CHECK_FROM=checkout: the wrappers need clab v0.13.0 or newer, which knows them (CADENCE_WRAPPER); $from is older"
    if [ "$from" != "$checkout_version" ] && [ -z "${CADENCE_BACKEND_DIGEST+set}${CADENCE_FRONTEND_DIGEST+set}" ]; then
      info "FROM is this checkout as $from: its pins name the images of $checkout_version, the images go by their tags"
      export CADENCE_BACKEND_DIGEST="" CADENCE_FRONTEND_DIGEST=""
    fi
  fi
  info "package of this checkout as $to"
  local to_clab=(--clab-version "$to")
  [ -z "${CHECK_TO_CLAB:-}" ] || to_clab=(--clab "$CHECK_TO_CLAB")
  ci/package.sh --bundle --version "$to" "${to_clab[@]}" "$releases/download/$to" >/dev/null
  mkdir -p "$releases/latest"
  cp -R "$releases/download/$to" "$releases/latest/download"

  # --- FROM -------------------------------------------------------------------------
  admin_token="sdlc_$(openssl rand -hex 24)"
  if [ -n "${GITHUB_ACTIONS:-}" ]; then echo "::add-mask::$admin_token"; fi
  local clone=false
  if [ "$from_mode" = checkout ]; then
    info "installing $from as the package of this checkout, with clab $from of the tap"
    ci/package.sh --bundle --version "$from" --clab-version "$from" "$releases/download/$from" >/dev/null
    (cd "$work" && CADENCE_RELEASES_URL="file://$releases" SDLC_ADMIN_TOKEN="$admin_token" sh "$repo/get-cadence.sh" --version "$from" \
      --mode proxy --http-addr "127.0.0.1:$port" --yes </dev/null)
  elif curl -fsIL -o /dev/null "$CADENCE_RELEASES_DEFAULT/download/$from/$(package_name "$from")"; then
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
  # The scripts of FROM: wrappers of the clab in its package, or bash.
  local from_wrappers=false
  if grep -qxF CADENCE_WRAPPER=1 upgrade.sh; then from_wrappers=true; fi
  info "$from has $([ "$from_wrappers" = true ] && echo "the wrappers of clab server" || echo "the bash scripts")"
  # FROM's files of the package with their sums, for the rollback.
  local from_manifest="$work/from-installed.manifest"
  cp "$PACKAGE_MANIFEST" "$from_manifest" 2>/dev/null || : >"$from_manifest"
  export CADENCE_RELEASES_URL="file://$releases"
  # shellcheck source=ci/verify-stubs.sh
  . "$repo/ci/verify-stubs.sh"
  if stub_cosign_local "$work/cosign-local" "$work/cosign.log"; then
    export PATH="$work/cosign-local:$PATH"
    info "a real cosign is in PATH: the images of $to are verified at ghcr.io"
  fi

  clab="${CLAB_BIN:-}"
  if [ -z "$clab" ]; then
    curl -fsSL https://raw.githubusercontent.com/cadence-lab-tech/homebrew-tap/main/install.sh |
      CLAB_VERSION="$from" CLAB_INSTALL_DIR="$work/bin" sh
    clab="$work/bin/clab"
  fi
  export CLAB_CONFIG_DIR="$work/clab"
  # upgrade_cmd / restore_cmd: the scripts of the installation, or clab
  # server (CADENCE_DRIVER). The printed rollback of clab server calls
  # "clab": it is on PATH as this clab.
  mkdir -p "$work/clab-bin"
  ln -sf "$clab" "$work/clab-bin/clab"
  upgrade_cmd() {
    if [ "$driver" = clab ]; then "$clab" server upgrade "$@"; else ./upgrade.sh "$@"; fi
  }
  restore_cmd() {
    if [ "$driver" = clab ]; then "$clab" server restore "$@"; else ./restore.sh "$@"; fi
  }
  # restore_hint: how the refusals name the restore after the package files.
  local up_name=./upgrade.sh restore_name=./restore.sh
  if [ "$driver" = clab ]; then up_name="clab server upgrade" restore_name="clab server restore"; fi
  printf '%s\n' "$admin_token" | "$clab" auth login --host "$base" --with-token >/dev/null

  # name_line_fix WHAT CMD...: an installation from before v0.7.1 has no name
  # in .env and this check runs it with COMPOSE_PROJECT_NAME. CMD must refuse
  # and print the line to add; the line is added as printed, and CMD then
  # runs without the variable.
  name_line_fix() {
    local what="$1" out fix
    shift
    if out="$("$@" 2>&1)"; then
      fail "$what on an installation without the name in .env, with COMPOSE_PROJECT_NAME=$COMPOSE_PROJECT_NAME, must refuse"
      return
    fi
    fix="$(grep -E "^    echo COMPOSE_PROJECT_NAME=$COMPOSE_PROJECT_NAME >> $dir/.env\$" <<<"$out" || true)"
    if [ -n "$fix" ] && grep -qF "the installation in $dir is 'cadence'" <<<"$out"; then
      pass "$what refuses: this installation is 'cadence' by .env, and the one step is the line in .env"
    else
      fail "$what refused without the line to add: $out"
      return
    fi
    bash -euc "$fix"
    if env -u COMPOSE_PROJECT_NAME "$@" >/dev/null 2>&1; then
      pass "after the line in .env, $what runs without COMPOSE_PROJECT_NAME"
    else
      fail "after the line in .env, $what without COMPOSE_PROJECT_NAME failed"
    fi
  }
  # clab server applies the rule to FROM already.
  if [ "$driver" = clab ] && ! grep -q '^COMPOSE_PROJECT_NAME=' .env; then
    info "clab server on $from without the name in .env"
    name_line_fix "clab server backup" "$clab" server backup
  fi

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
    "instructions": "Write a note.\n\n- Cyrillic: заметка, a tab:\t|, a quote \" and a backslash \\.\n- A trailing blank line follows.\n\n",
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
  local workflow_id task_key artifact_id instructions_sha
  workflow_id="$(SDLC_PROJECT=UPG "$clab" --host "$base" import --file "$work/bundle.json" --json | jq -r '.workflows[0].id')"
  SDLC_PROJECT=UPG "$clab" --host "$base" workflow activate "$workflow_id" >/dev/null
  task_key="$(SDLC_PROJECT=UPG "$clab" --host "$base" create --title "Upgrade check task" --json | jq -r '.key')"
  # What the claim hands the agent on FROM, byte for byte: after the upgrade the
  # claim of the same role must hand the same bytes (CLAB-350).
  SDLC_PROJECT=UPG "$clab" --host "$base" claim "$task_key" --json >"$work/claim-before.json"
  jq -j '.role.instructions // empty' "$work/claim-before.json" >"$work/instructions-before.md"
  [ -s "$work/instructions-before.md" ] || die "the claim of $task_key on $from carries no instructions of the role"
  instructions_sha="$(sha256_of "$work/instructions-before.md")"
  printf 'Artifact written on %s before the upgrade.\n' "$from" >"$work/note.md"
  artifact_id="$(SDLC_PROJECT=UPG "$clab" --host "$base" submit "$task_key" --kind upgrade.note \
    --title "Upgrade check note" --file "$work/note.md" --json | jq -r '.artifact.id // .id')"
  case "$task_key/$artifact_id" in
  /* | */ | null/* | */null) die "could not create the task and its artifact on $from" ;;
  esac
  info "task $task_key with artifact $artifact_id on $from"

  # The starter bundle of FROM, as an administrator who installed $from has it
  # (a project UPS with the starter roles and both cycles active): after the
  # upgrade the starter bundle of TO must find nothing to change in it. A
  # package of FROM that is this checkout (CHECK_FROM=checkout) has the bundle
  # in format 3, which a server of FROM refuses: format 1 copy.
  local starter_from="" starter_roles=""
  if [ -f bundles/starter.json ]; then
    starter_from="$(starter_for_server "$from" "$work/starter-from.json")"
    "$clab" --host "$base" project create UPS --name "Upgrade check, starter" --team upgrade >/dev/null
    SDLC_PROJECT=UPS "$clab" --host "$base" import --file "$starter_from" >/dev/null
    local draft
    for draft in $(SDLC_PROJECT=UPS "$clab" --host "$base" workflow list --json |
      jq -r '(if type == "array" then . else (.workflows // .items) end)[] | select(.state == "draft") | .id'); do
      SDLC_PROJECT=UPS "$clab" --host "$base" workflow activate "$draft" >/dev/null
    done
    starter_roles="$(jq -r '[.roles[].key] | sort | join(" ")' "$starter_from")"
    info "the starter bundle of $from imported into UPS: $starter_roles"
  else
    info "$from has no bundles/starter.json: the starter bundle is not checked"
  fi

  # The clab of TO, from its package, against the server of FROM (CLAB-350,
  # AC-S9): a bundle of format 3 is not for a server that takes up to 2 - it
  # answers that the bundle is newer than it supports and applies nothing -
  # and a directory of roles is not made by a server that has no documents;
  # a bundle of format 2 goes through.
  local platform to_clab_bin="" to_pkg="$work/to-package"
  case "$(uname -s)/$(uname -m)" in
  Linux/x86_64 | Linux/amd64) platform=linux-amd64 ;;
  Linux/aarch64 | Linux/arm64) platform=linux-arm64 ;;
  Darwin/x86_64) platform=darwin-amd64 ;;
  Darwin/arm64) platform=darwin-arm64 ;;
  *) platform=unknown ;;
  esac
  mkdir -p "$to_pkg"
  tar -xzf "$releases/download/$to/$(package_name "$to")" -C "$to_pkg"
  to_clab_bin="$(find "$to_pkg" -type f -name "clab-$platform" | head -n 1)"
  if [ -z "$to_clab_bin" ]; then
    info "the package of $to has no clab for $platform: the clab of $to against $from is not checked"
  elif ! version_lt "$from" "$STARTER_FORMAT3_FIRST"; then
    info "$from takes bundles of format 3: the clab of $to against it needs no refusals (ci/lib.sh, STARTER_FORMAT3_FIRST)"
  elif [ "$("$to_clab_bin" version 2>/dev/null | head -n 1)" != "clab $to" ]; then
    info "the clab of the package is not clab $to ($("$to_clab_bin" version 2>/dev/null | head -n 1)): not checked against $from"
  elif ! grep -qF -- "--dir" <<<"$("$to_clab_bin" import --help 2>&1)"; then
    info "the clab of $to has no import --dir: not checked against $from"
  else
    info "the clab of $to against the server of $from"
    local format3="$repo/bundles/starter.json" refusal code
    [ "$(jq -r .version "$format3")" = 3 ] || die "bundles/starter.json of this checkout is not in bundle format 3"
    # The refusal is in the report ("error"); the exit code of clab import is
    # not part of the check (it is 0 for a refusal of the server in v0.21.0).
    refusal="$(SDLC_PROJECT=UPG "$to_clab_bin" --host "$base" import --file "$format3" 2>&1)" && code=0 || code=$?
    if grep -qiE "новее|newer" <<<"$refusal" && grep -qF "3" <<<"$refusal"; then
      pass "import of a bundle of format 3 into the server of $from is refused as newer than it supports (exit $code)"
    else
      fail "import of a bundle of format 3 into the server of $from is not refused: exit $code, $refusal"
    fi
    if SDLC_PROJECT=UPG "$to_clab_bin" --host "$base" role show analyst >/dev/null 2>&1; then
      fail "the refused bundle of format 3 left the role analyst in UPG: nothing may be applied"
    else
      pass "...and applied nothing: UPG has no role analyst"
    fi
    if SDLC_PROJECT=UPG "$to_clab_bin" --host "$base" import --file "$work/bundle.json" --dry-run >/dev/null 2>&1; then
      pass "import of a bundle of format 2 into the server of $from goes through"
    else
      fail "import of a bundle of format 2 into the server of $from failed"
    fi
    if SDLC_PROJECT=UPG "$to_clab_bin" --host "$base" export --dir "$work/export-from" >/dev/null 2>&1; then
      fail "export --dir from the server of $from must be refused: it has no documents of roles"
    else
      pass "export --dir from the server of $from is refused"
    fi
    if SDLC_PROJECT=UPG "$to_clab_bin" --host "$base" export >"$work/export-from.json" 2>/dev/null &&
      [ "$(jq -r .version "$work/export-from.json")" = 2 ]; then
      pass "export of the server of $from works: a bundle of format 2, as before-upgrade.json of docs/admin.md"
    else
      fail "export of the server of $from failed or is not of format 2"
    fi
  fi

  # The bundled database (docs/admin.md, "PostgreSQL 18"): FROM on 17 and TO
  # on 18 make the upgrades below move the data.
  dc() { CADENCE_VERSION="$(tr -d '[:space:]' <VERSION)" docker compose "$@"; }
  pg_q() {
    # shellcheck disable=SC2016 # expanded by the shell of the container
    dc exec -T postgres sh -c 'psql -X -At -U "$POSTGRES_USER" -d "$POSTGRES_DB" -c "$1"' sh "$1"
  }
  pg_major() { pg_q 'SHOW server_version_num' 2>/dev/null | cut -c1-2; }
  key_counts() {
    pg_q "SELECT concat_ws(' ', (SELECT count(*) FROM tasks), (SELECT count(*) FROM artifacts), (SELECT count(*) FROM artifact_chunks),
      (SELECT count(*) FROM document_chunks), (SELECT count(*) FROM embedding_cache))"
  }
  in_volume() { docker run --rm -v "$1:/v" alpine:3 sh -c "$2"; }
  local moves=false new_volume="${COMPOSE_PROJECT_NAME}_postgres" old_volume="${COMPOSE_PROJECT_NAME}_pgdata"
  if grep -qx CADENCE_DB=external .env; then
    info "$from runs on an external database: no move of the bundled one"
  elif [ "$(pg_major)" = 17 ] && grep -qF pgvector/pgvector:pg18 "$repo/docker-compose.yml"; then
    moves=true
    info "$from runs PostgreSQL 17, $to runs 18: the upgrades move the data"
  else
    info "$from runs PostgreSQL $(pg_major): no move to check"
  fi

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
  if [ "$driver" = clab ] || [ "$from_wrappers" = true ] || grep -qF 'Update clab to $target_version' upgrade.sh; then reminds=true; fi
  # no_reminder WHAT OUTPUT: a run that did not upgrade must not remind.
  no_reminder() {
    if grep -qF "Update clab" <<<"$2"; then
      fail "$1 reminds to update clab: $2"
    else
      pass "$1 does not remind to update clab"
    fi
  }

  # --- a failed image pull -------------------------------------------------------------
  # The installer of FROM v0.15.0 and later writes CADENCE_REGISTRY of its
  # environment to .env, and .env wins over the environment (clab server, and
  # set -a; . ./.env of the bash scripts): the unreachable registry goes into
  # .env as well - in place of the line, or as a new one - and the copy of
  # .env comes back after the scenario, byte for byte.
  info "$up_name $to with images that cannot be pulled"
  local before out env_sum
  env_sum="$(sha256_of .env)"
  cp -p .env "$work/env.before-pull"
  if grep -q '^CADENCE_REGISTRY=' .env; then
    sed 's/^CADENCE_REGISTRY=.*/CADENCE_REGISTRY=127.0.0.1:9/' "$work/env.before-pull" >.env
  else
    { cat "$work/env.before-pull"; [ -z "$(tail -c 1 "$work/env.before-pull")" ] || echo; echo CADENCE_REGISTRY=127.0.0.1:9; } >.env
  fi
  before="$(files_state)"
  if out="$(CADENCE_REGISTRY=127.0.0.1:9 upgrade_cmd "$to" 2>&1)"; then
    fail "$up_name $to succeeded with an unreachable registry"
  else
    pass "$up_name $to fails when the images cannot be pulled"
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
  cp -p "$work/env.before-pull" .env
  if [ "$(sha256_of .env)" = "$env_sum" ]; then
    pass ".env as it was before the failed pull"
  else
    fail ".env is not as it was before the failed pull"
  fi

  # --- signatures of TO -------------------------------------------------------------------
  local verifies=false pinned=true
  if [ "$driver" = clab ]; then
    "$clab" server upgrade --help 2>/dev/null | grep -q CADENCE_VERIFY && verifies=true
  elif grep -q CADENCE_VERIFY upgrade.sh; then
    verifies=true
  fi
  [ -z "${CADENCE_BACKEND_DIGEST+set}${CADENCE_FRONTEND_DIGEST+set}" ] || pinned=false
  if [ "$verifies" = true ]; then
    stub_cosign "$work/cosign-bad" "$work/cosign-bad.log"
    local bad backups_before
    for bad in package sdlc-pipeline-backend; do
      if [ "$bad" != package ] && [ "$pinned" = false ]; then
        info "the images of $to are not pinned here: the bad signature of an image is not checked"
        continue
      fi
      info "$up_name $to with a bad signature ($bad)"
      before="$(files_state)"
      backups_before="$(find backups -maxdepth 1 \( -name '*.tar.gz' -o -name '*.sql.gz' \) | sort)"
      if out="$(PATH="$work/cosign-bad:$PATH" CADENCE_VERIFY=auto FAKE_COSIGN_BAD="$bad" upgrade_cmd "$to" 2>&1)"; then
        fail "$up_name $to went on with a bad signature ($bad)"
      elif grep -qF "did not verify for" <<<"$out" && grep -qF "Nothing has changed." <<<"$out"; then
        pass "$up_name $to refuses a bad signature ($bad): did not verify, nothing has changed"
      else
        fail "$up_name $to refused a bad signature ($bad) without saying so: $out"
      fi
      if [ "$(files_state)" = "$before" ] && [ "$(find backups -maxdepth 1 \( -name '*.tar.gz' -o -name '*.sql.gz' \) | sort)" = "$backups_before" ] &&
        [ -z "$(find . -maxdepth 1 -name '.upgrade.*')" ]; then
        pass "...VERSION, the files and .env as they were, no backup, no .upgrade.*"
      else
        fail "...the refused upgrade changed the files or took a backup"
      fi
      if [ "$(instance_version)" = "$from" ] && [ "$(curl -s -o /dev/null -w '%{http_code}' "$base/readyz")" = 200 ]; then
        pass "...the stack still runs $from and is ready"
      else
        fail "...the stack does not report $from or is not ready"
      fi
    done
  else
    info "$up_name of $from does not verify signatures: the refusals are not checked"
  fi

  # --- an edited package file ------------------------------------------------------------
  info "$up_name $to over an edited docker-compose.yml"
  local backups_before
  cp docker-compose.yml "$work/compose.orig"
  printf '# a local edit\n' >>docker-compose.yml
  backups_before="$(find backups -maxdepth 1 -name 'cadence-*.sql.gz' | wc -l | tr -d ' ')"
  if out="$(upgrade_cmd "$to" 2>&1)"; then
    fail "$up_name ran over an edited docker-compose.yml"
  elif grep -qF "docker-compose.yml" <<<"$out" && grep -qF "Nothing has changed" <<<"$out"; then
    pass "$up_name refuses with the list of edited files (docker-compose.yml) and --force as the way out"
  else
    fail "$up_name refused without naming docker-compose.yml: $out"
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
  mkdir -p "$work/nogit" "$work/noclab"
  printf '#!/bin/sh\necho "git $*" >>"%s/git-calls"\nexit 1\n' "$work" >"$work/nogit/git"
  printf '#!/bin/sh\necho "clab $*" >>"%s/clab-calls"\nexit 1\n' "$work" >"$work/noclab/clab"
  chmod 755 "$work/nogit/git" "$work/noclab/clab"
  # no_older WHAT OUTPUT: no "older than the target" - the clab of the
  # package is replaced with the package, and an older upgrade.sh has no such
  # warning.
  no_older() {
    if [ "$driver" = scripts ] && grep -qF "older than the target" <<<"$2"; then
      fail "$1 warns that clab is older than the target: $2"
    elif [ "$driver" = scripts ]; then
      pass "$1: no 'older than the target'"
    fi
  }
  # same_files_as MANIFEST PREFIX: every file of MANIFEST under PREFIX is
  # here with its sum (PREFIX empty: every file).
  same_files_as() {
    local sum f n=0
    while read -r sum f; do
      case "$f" in "$2"*) ;; *) continue ;; esac
      [ -f "$f" ] && [ "$(sha256_of "$f")" = "$sum" ] || return 1
      n=$((n + 1))
    done <"$1"
    [ "$n" -gt 0 ]
  }
  local path_nogit="$work/nogit:$work/clab-bin:$PATH"
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
  info "$up_name $to over an edited docker-compose.yml, without git"
  printf '# a local edit\n' >>docker-compose.yml
  if out="$(PATH="$path_nogit" upgrade_cmd "$to" 2>&1)"; then
    fail "$up_name ran over an edited docker-compose.yml without git"
  elif grep -qF "docker-compose.yml" <<<"$out" && grep -qF -- "--force" <<<"$out"; then
    pass "package.sha256 finds the edit: refused with the file and --force"
  else
    fail "$up_name without git refused without naming docker-compose.yml: $out"
  fi
  cp "$work/compose.orig" docker-compose.yml

  # --- a move cut off before its mark ------------------------------------------------------
  # The worst moment to stop: the new cluster is in place, the mark is not
  # written. A directory where the mark goes (postgres/major-upgrade.sh)
  # makes it fail there, in the volume postgres made ahead with the labels of
  # compose.
  if [ "$moves" = true ]; then
    info "$up_name $to with a move cut off before its mark"
    docker volume create --label "com.docker.compose.project=$COMPOSE_PROJECT_NAME" \
      --label com.docker.compose.volume=postgres "$new_volume" >/dev/null
    in_volume "$new_volume" 'mkdir -p /v/cadence-upgrade/done.part/state/x'
    if out="$(PATH="$path_nogit" upgrade_cmd "$to" 2>&1)"; then
      fail "$up_name $to went on after the move failed"
    elif grep -qF "docker compose up failed for $to" <<<"$out"; then
      pass "$up_name $to fails with the move: docker compose up failed"
    else
      fail "$up_name $to with a failed move: $out"
    fi
    if in_volume "$new_volume" 'test -s /v/18/docker/PG_VERSION && test ! -e /v/cadence-upgrade/done'; then
      pass "...the new cluster is in place but has no mark: the move is not done"
    else
      fail "...the new cluster is not in place, or it has a mark"
    fi
    if [ -z "$(dc ps -q --status running postgres)" ]; then
      pass "...postgres did not start on it"
    else
      fail "...postgres runs on a move that did not finish"
    fi
    if dc logs --no-log-prefix pg-upgrade-load 2>&1 | grep -qF "the move failed"; then
      pass "...pg-upgrade-load says the move failed"
    else
      fail "...pg-upgrade-load does not say the move failed"
    fi
    in_volume "$new_volume" 'rm -rf /v/cadence-upgrade/done.part'
    rollback="$(grep -E '^  (tar -xpzf |\./restore\.sh --yes |clab server restore --yes )' <<<"$out" || true)"
    if [ "$(grep -c . <<<"$rollback")" = 2 ]; then
      pass "...it prints the rollback"
    else
      fail "...the rollback is not two commands: $rollback"
    fi
    info "running the rollback as printed"
    if [ "$driver" = scripts ]; then
      PATH="$work/noclab:$path_nogit" bash -euc "$rollback" >/dev/null
    else
      PATH="$path_nogit" bash -euc "$rollback" >/dev/null
    fi
    if [ "$(instance_version)" = "$from" ] && [ "$(pg_major)" = 17 ] &&
      "$clab" --host "$base" project list --json | grep -qF '"UPG"'; then
      pass "after the rollback $from runs on PostgreSQL 17 with its data"
    else
      fail "after the rollback of the failed move $from is not back on PostgreSQL 17 with its data"
    fi
  fi

  # --- not ready: the printed rollback -----------------------------------------------------
  # compose up waits for the API to be healthy before it starts the worker,
  # so only a zero timeout makes "not ready" certain.
  info "$up_name $to that does not become ready in time"
  if out="$(PATH="$path_nogit" CADENCE_READY_TIMEOUT=0 upgrade_cmd "$to" 2>&1)"; then
    fail "$up_name did not report the readiness timeout"
  else
    pass "$up_name fails when $to is not ready in time"
  fi
  [ "$reminds" = false ] || no_reminder "the upgrade that did not become ready" "$out"
  local rollback
  rollback="$(grep -E '^  (tar -xpzf |\./restore\.sh --yes |clab server restore --yes )' <<<"$out" || true)"
  if [ "$(grep -c . <<<"$rollback")" = 2 ] && ! grep -qw git <<<"$rollback"; then
    pass "it prints the rollback: package files and the backup, no git"
  else
    fail "the rollback is not two commands without git: $rollback"
  fi
  if [ "$driver" = scripts ]; then
    if [ "$(grep -c '^  \./restore\.sh --yes ' <<<"$rollback")" = 1 ]; then
      pass "...the backup by ./restore.sh, no clab"
    else
      fail "the rollback does not restore by ./restore.sh: $rollback"
    fi
  fi
  no_older "the upgrade that did not become ready" "$out"
  if [ "$moves" = true ]; then
    if [ "$(pg_major)" = 18 ] && dc logs --no-log-prefix pg-upgrade-dump 2>&1 | grep -qF "moving the data of PostgreSQL 17" &&
      [ -n "$(docker volume ls -q --filter "name=^$old_volume\$")" ]; then
      pass "...the data was moved anew: $to runs PostgreSQL 18, the volume $old_volume is kept"
    else
      fail "...the upgrade that did not become ready has not moved the data to PostgreSQL 18, or $old_volume is gone"
    fi
  fi
  info "running the rollback as printed$([ "$driver" = scripts ] && echo ", without clab in PATH")"
  if [ "$driver" = scripts ]; then
    PATH="$work/noclab:$path_nogit" bash -euc "$rollback" >/dev/null
  else
    PATH="$path_nogit" bash -euc "$rollback" >/dev/null
  fi
  if [ "$(tr -d '[:space:]' <VERSION)" = "$from" ] && [ "$(instance_version)" = "$from" ]; then
    pass "after the rollback VERSION and /v1/instance are $from"
  else
    fail "after the rollback the installation is not on $from"
  fi
  if [ "$from_wrappers" = true ]; then
    if same_files_as "$from_manifest" bin/; then
      pass "after the rollback bin/clab-* are those of $from (package.sha256 of $from)"
    else
      fail "after the rollback bin/clab-* are not those of $from"
    fi
  else
    if [ "$(head -n 1 upgrade.sh)" = "#!/usr/bin/env bash" ] && [ -f lib.sh ] && same_files_as "$from_manifest" ""; then
      pass "after the rollback the bash scripts of $from and lib.sh are back, as package.sha256 of $from has them"
    else
      fail "after the rollback the scripts are not those of $from"
    fi
  fi
  if "$clab" --host "$base" project list --json | grep -qF '"UPG"'; then
    pass "after the rollback the project created on $from is there"
  else
    fail "after the rollback the project created on $from is gone"
  fi
  local after_rollback="" from_counts=""
  if [ "$moves" = true ]; then
    if [ "$(pg_major)" = 17 ]; then
      pass "after the rollback $from runs on PostgreSQL 17 (the volume $old_volume)"
    else
      fail "after the rollback $from does not run PostgreSQL 17: $(pg_major)"
    fi
    # Written on FROM after the rollback: the next upgrade must move it.
    after_rollback="$(SDLC_PROJECT=UPG "$clab" --host "$base" create --title "Written after the rollback" --json | jq -r '.key')"
    from_counts="$(key_counts)"
    info "task $after_rollback written on $from after the rollback; tasks, artifacts, chunks and embeddings: $from_counts"
  fi

  # --- the upgrade ------------------------------------------------------------------------
  # With an edited package file and --force: replaced, the edited copy kept.
  info "$up_name --force $to over an edited docker-compose.yml"
  printf '# a local edit\n' >>docker-compose.yml
  PATH="$path_nogit" upgrade_cmd --force "$to" | tee "$work/upgrade.out"
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
  # The containers run what compose names: by tag and pin when the package
  # pins (no variable - as an upgrade.sh of an older version runs it), by
  # tag when the pin is dropped.
  local want_image api_image
  want_image="$(CADENCE_VERSION="$to" docker compose config --format json | jq -r .services.api.image)"
  api_image="$(docker inspect --format '{{.Config.Image}}' "$(CADENCE_VERSION="$to" docker compose ps -q api)")"
  if [ "$api_image" = "$want_image" ]; then
    pass "api runs $api_image, the image of docker-compose.yml"
  else
    fail "api runs $api_image, docker-compose.yml names $want_image"
  fi
  if [ -z "${CADENCE_BACKEND_DIGEST+set}" ]; then
    if [[ "$api_image" == *":$to@sha256:"* ]]; then
      pass "api is pinned: $to by digest"
    else
      fail "api is not pinned by digest: $api_image"
    fi
  fi
  if [ "$(awk '$2 == "VERSION" {print $1}' "$PACKAGE_MANIFEST")" = "$(sha256_of VERSION)" ]; then
    pass "$PACKAGE_MANIFEST is the one of $to"
  else
    fail "$PACKAGE_MANIFEST is not the one of $to"
  fi
  no_older "the upgrade" "$out"
  # The wrappers of TO and the clab of every platform, 755, as package.sha256 says.
  local p bins_ok=true
  for p in $CLAB_PLATFORMS; do
    [ "$(stat -c %a "bin/clab-$p" 2>/dev/null || stat -f %Lp "bin/clab-$p" 2>/dev/null)" = 755 ] || bins_ok=false
  done
  if [ "$bins_ok" = true ] && same_files_as "$PACKAGE_MANIFEST" bin/; then
    pass "bin/clab-* of $to are there, 755, with the sums of $PACKAGE_MANIFEST"
  else
    fail "bin/clab-* of $to are missing, not 755 or not of $PACKAGE_MANIFEST"
  fi
  if grep -qxF CADENCE_WRAPPER=1 upgrade.sh && [ ! -e lib.sh ]; then
    pass "the scripts are the wrappers of $to; lib.sh, no longer in the package, is gone"
  else
    fail "the scripts of $to are not the wrappers, or lib.sh is still there"
  fi
  if [ "$driver" = scripts ]; then
    info "the wrappers of $to: ./backup.sh and ./backup.sh verify, without clab in PATH"
    local wrapped_dumps
    wrapped_dumps="$(find backups -maxdepth 1 -name "cadence-$to-*.sql.gz" | wc -l | tr -d ' ')"
    sleep 1
    if out="$(PATH="$work/noclab:$path_nogit" ./backup.sh 2>&1)" &&
      [ "$(find backups -maxdepth 1 -name "cadence-$to-*.sql.gz" | wc -l | tr -d ' ')" -gt "$wrapped_dumps" ]; then
      pass "./backup.sh of $to writes backups/cadence-$to-*.sql.gz"
    else
      fail "./backup.sh of $to: $out"
    fi
    if out="$(PATH="$work/noclab:$path_nogit" ./backup.sh verify 2>&1)" && grep -qF "the schema of the images of $to" <<<"$out"; then
      pass "./backup.sh verify of $to: the backup restores"
    else
      fail "./backup.sh verify of $to: $out"
    fi
  fi
  # shellcheck disable=SC2086 # a list of names
  if [ "$(for f in $kept; do printf '%s %s\n' "$(sha256_of "$f")" "$f"; done)" = "$kept_before" ]; then
    pass "$kept are unchanged"
  else
    fail "some of $kept changed"
  fi
  # The scripts of TO apply the rule; upgrade.sh did not write the line.
  if [ "$driver" = scripts ]; then
    if grep -q '^COMPOSE_PROJECT_NAME=' .env; then
      info "$from had the name in .env already; the upgrade kept it"
    else
      info "./backup.sh of $to on an installation without the name in .env"
      name_line_fix "./backup.sh" ./backup.sh
    fi
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
  # --- roles after the upgrade (CLAB-350): documents, byte for byte ------------------
  # The migration of TO carries the instructions of every version of a role
  # into the document main.md. What the agent is handed must not change by
  # a byte: the claim of the role on $from, taken before the upgrade, and the
  # claim of the same role now - with the clab of $from, as agents have it
  # until they update - are compared by sha256, and so is the text the clab
  # of $to lays out as a file.
  info "the roles after the upgrade: the instructions byte for byte"
  local claim_after="$work/claim-after.json"
  SDLC_PROJECT=UPG "$clab" --host "$base" claim "$task_key" --json >"$claim_after" 2>"$work/claim-after.err" || cat "$work/claim-after.err" >&2
  jq -j '.role.instructions // empty' "$claim_after" >"$work/instructions-after.md"
  if [ -s "$work/instructions-after.md" ] && [ "$(sha256_of "$work/instructions-after.md")" = "$instructions_sha" ]; then
    pass "the claim of the role upgrade hands the same instructions as on $from: sha256 $instructions_sha"
  else
    fail "the claim of the role upgrade differs from $from: sha256 $instructions_sha before, $(sha256_of "$work/instructions-after.md") after"
  fi
  local printed
  printed="$(SDLC_PROJECT=UPG "$clab" --host "$base" claim "$task_key" 2>&1 || true)"
  if grep -qF -- "- Cyrillic: заметка, a tab:"$'\t'"|, a quote \" and a backslash \\." <<<"$printed"; then
    pass "clab $from prints the instructions of the role as it did on $from"
  else
    fail "clab $from does not print the instructions of the role: $printed"
  fi
  if [ -z "$to_clab_bin" ]; then
    info "no clab of $to for $platform: the documents of the role are not checked"
  else
    local role_after
    role_after="$(SDLC_PROJECT=UPG "$to_clab_bin" --host "$base" role show upgrade --json 2>/dev/null || true)"
    if [ "$(jq -r '[.. | objects | select(.name? == "main.md" and .kind? == "instructions")] | length' <<<"$role_after")" -ge 1 ] &&
      [ "$(jq -r '[.. | objects | select(.name? == "main.md") | .sha256] | unique | join(" ")' <<<"$role_after")" = "$instructions_sha" ]; then
      pass "clab $to: the role upgrade has the document main.md of the kind instructions, sha256 $instructions_sha"
    else
      fail "clab $to: the role upgrade has no main.md of the kind instructions with sha256 $instructions_sha: $role_after"
    fi
    if [ "$(jq -r '[.versions[]?] | length' <<<"$role_after")" = 1 ]; then
      pass "...and it has the one version it had on $from"
    else
      fail "the role upgrade has more versions than on $from: $role_after"
    fi
    rm -rf "$work/role-docs"
    if SDLC_PROJECT=UPG "$to_clab_bin" --host "$base" claim "$task_key" --instructions-dir "$work/role-docs" >/dev/null 2>&1 &&
      [ "$(ls "$work/role-docs")" = main.md ] && cmp -s "$work/role-docs/main.md" "$work/instructions-before.md"; then
      pass "claim --instructions-dir of clab $to lays out main.md, the instructions of $from byte for byte"
    else
      fail "claim --instructions-dir of clab $to: main.md is not the instructions of $from, or the claim failed"
    fi
  fi

  # The starter bundle of $from, in UPS, against the bundle of $to (format 3),
  # and a role of two documents for the clab of $from.
  if [ -z "$to_clab_bin" ]; then
    info "no clab of $to for $platform: the starter bundle and the roles of two documents are not checked"
  else
    if [ -n "$starter_roles" ] && [ -f bundles/starter.json ]; then
      info "the starter bundle of $from in UPS, against the one of $to"
      local again starter_out starter_code
      again="$(SDLC_PROJECT=UPS "$to_clab_bin" --host "$base" import --file bundles/starter.json --json 2>&1 || true)"
      if [ "$(jq -r '[.roles[].outcome] | unique | join(",")' <<<"$again" 2>/dev/null)" = unchanged ] &&
        [ "$(jq -r '[.roles[].key] | sort | join(" ")' <<<"$again" 2>/dev/null)" = "$starter_roles" ]; then
        pass "the starter bundle of $to (format 3) leaves every role of $from unchanged: $starter_roles"
      else
        fail "the starter bundle of $to changes the roles of $from: $again"
      fi
      if [ "$(jq -r '[.workflows[].outcome] | unique | join(",")' <<<"$again" 2>/dev/null)" = unchanged ]; then
        pass "...and the cycles are unchanged"
      else
        fail "the starter bundle of $to changes the cycles of $from: $again"
      fi
      starter_out="$("$to_clab_bin" server starter --dir "$dir" --team upgrade --project UPS 2>&1)" && starter_code=0 || starter_code=$?
      if [ "$starter_code" = 0 ] && [ "$(grep -o 'unchanged, already active' <<<"$starter_out" | wc -l | tr -d ' ')" = 2 ]; then
        pass "clab server starter of $to after the upgrade changes nothing in UPS: both cycles unchanged, already active"
      else
        fail "clab server starter of $to after the upgrade: exit $starter_code, $starter_out"
      fi
      if grep -qF "$admin_token" <<<"$starter_out"; then fail "clab server starter prints the token"; fi
      # A role edited by hand is not overwritten: the command refuses and
      # leaves the roles as they are.
      printf 'A role edited by hand after the upgrade.\n' >"$work/edited-analyst.md"
      SDLC_PROJECT=UPS "$to_clab_bin" --host "$base" role put --key analyst --name Analyst --file "$work/edited-analyst.md" >/dev/null
      starter_out="$("$to_clab_bin" server starter --dir "$dir" --team upgrade --project UPS 2>&1)" && starter_code=0 || starter_code=$?
      if [ "$starter_code" != 0 ]; then
        pass "clab server starter refuses over a role edited by hand (exit $starter_code)"
      else
        fail "clab server starter must refuse over a role edited by hand: $starter_out"
      fi
      if [ "$(SDLC_PROJECT=UPS "$to_clab_bin" --host "$base" role show analyst --json 2>/dev/null |
        jq -r '[.. | objects | select(.name? == "main.md") | .sha256] | first // ""')" = "$(sha256_of "$work/edited-analyst.md")" ]; then
        pass "...and the role edited by hand is still the current one"
      else
        fail "the role edited by hand is not the current one after clab server starter"
      fi
    else
      info "the starter bundle is not checked: $from has none, or the bundle of $to is gone"
    fi

    # A role of two documents reads as one string to the clab of $from: the
    # documents joined, each after the marker <!-- document: name -->.
    info "a role of two documents for the clab of $from"
    mkdir -p "$work/role-two"
    cp "$work/instructions-before.md" "$work/role-two/main.md"
    printf -- '- A checklist item.\n' >"$work/role-two/checklist.md"
    cat >"$work/role-two/role.json" <<'JSON'
{
  "key": "upgrade",
  "name": "Upgrade check",
  "output_contract": [{"kind": "upgrade.note", "title": "Note", "format": "markdown", "required": true}],
  "documents": [{"name": "main.md", "kind": "instructions"}, {"name": "checklist.md", "kind": "checklist"}]
}
JSON
    if SDLC_PROJECT=UPG "$to_clab_bin" --host "$base" role put --dir "$work/role-two" >/dev/null 2>&1; then
      # A claim in progress keeps the version of the role it began with: a
      # second task begins with the new one.
      local task_two
      task_two="$(SDLC_PROJECT=UPG "$clab" --host "$base" create --title "Upgrade check task, two documents" --json | jq -r '.key')"
      printed="$(SDLC_PROJECT=UPG "$clab" --host "$base" claim "$task_two" --json 2>/dev/null | jq -r '.role.instructions // empty' || true)"
      if grep -qF '<!-- document: main.md -->' <<<"$printed" && grep -qF '<!-- document: checklist.md -->' <<<"$printed" &&
        grep -qF -- '- A checklist item.' <<<"$printed" && grep -qF "A trailing blank line follows." <<<"$printed"; then
        pass "clab $from reads a role of two documents as one string: the documents after the markers <!-- document: name -->"
      else
        fail "clab $from does not get the joined documents of a role of two: $printed"
      fi
    else
      fail "clab $to could not put a role of two documents (role put --dir)"
    fi
  fi

  if [ "$moves" = true ]; then
    info "the database after the move"
    if [ "$(pg_major)" = 18 ] && dc exec -T postgres cat /etc/debian_version | grep -q '^13\.'; then
      pass "postgres runs PostgreSQL 18 on Debian 13"
    else
      fail "postgres does not run PostgreSQL 18 on Debian 13"
    fi
    if [ "$(key_counts)" = "$from_counts" ]; then
      pass "tasks, artifacts, chunks and embeddings as on $from: $from_counts"
    else
      fail "the counts of tasks, artifacts, chunks and embeddings differ: $from $from_counts, $to $(key_counts)"
    fi
    if "$clab" --host "$base" show "$after_rollback" --json | jq -e '.task.title == "Written after the rollback"' >/dev/null; then
      pass "the task $after_rollback written on $from after the rollback is there"
    else
      fail "the task $after_rollback written on $from after the rollback is gone"
    fi
    if [ -z "$(pg_q 'SELECT datname FROM pg_database WHERE datallowconn AND datcollversion IS DISTINCT FROM pg_database_collation_actual_version(oid)')" ] &&
      ! dc logs postgres api worker 2>&1 | grep -qiF "collation version mismatch"; then
      pass "no collation version mismatch: in the databases and in the logs of postgres, api and worker"
    else
      fail "a collation version mismatch after the move"
    fi
    if [ -n "$(docker volume ls -q --filter "name=^$old_volume\$")" ]; then
      pass "the volume $old_volume of PostgreSQL 17 is kept"
    else
      fail "the volume $old_volume is gone after the move"
    fi
    # The move after the rollback replaced the cluster of the earlier one.
    if in_volume "$new_volume" 'ls -d /v/cadence-upgrade/replaced-* >/dev/null 2>&1'; then
      pass "the PostgreSQL 18 cluster of the earlier move is kept aside (cadence-upgrade/replaced-*)"
    else
      fail "the PostgreSQL 18 cluster of the earlier move is not kept aside"
    fi
    info "docker compose up -d again on $to"
    local on_to
    on_to="$(SDLC_PROJECT=UPG "$clab" --host "$base" create --title "Written on $to" --json | jq -r '.key')"
    dc up -d >/dev/null 2>&1
    if dc logs --no-log-prefix pg-upgrade-dump 2>&1 | tail -n 1 | grep -qF "nothing to do" &&
      dc logs --no-log-prefix pg-upgrade-load 2>&1 | tail -n 1 | grep -qF "nothing to do"; then
      pass "...moves nothing: pg-upgrade-dump and pg-upgrade-load say nothing to do"
    else
      fail "...the services of the move did not say nothing to do"
    fi
    if CADENCE_VERSION="$to" wait_ready 180 && "$clab" --host "$base" show "$on_to" --json | jq -e --arg t "Written on $to" '.task.title == $t' >/dev/null; then
      pass "...the task $on_to written on $to stays"
    else
      fail "...the task $on_to written on $to is gone"
    fi
  fi

  # --- after the upgrade ----------------------------------------------------------------------
  info "$up_name on the latest release"
  if out="$(PATH="$path_nogit" upgrade_cmd 2>&1)" && grep -qF "nothing to do" <<<"$out"; then
    pass "$up_name with no version on $to (the latest): nothing to do"
  else
    fail "$up_name with no version: $out"
  fi
  no_reminder "'nothing to do'" "$out"

  info "$up_name $from must refuse"
  if out="$(PATH="$path_nogit" upgrade_cmd "$from" 2>&1)"; then
    fail "$up_name $from after $to did not refuse the downgrade"
  elif grep -qF "tar -xpzf backups/package-$from-" <<<"$out" && grep -qF "&& $restore_name backups/cadence-$from-" <<<"$out" &&
    ! grep -qw git <<<"$out"; then
    pass "$up_name refuses to go down to $from, the hint puts its package files back without git"
  else
    fail "the downgrade refusal: $out"
  fi
  no_reminder "the downgrade refusal" "$out"

  info "$restore_name of a $from backup must refuse on $to"
  local old_backup
  old_backup="$(find backups -maxdepth 1 -name "cadence-$from-*.sql.gz" | sort | tail -n 1)"
  if out="$(PATH="$path_nogit" restore_cmd --yes "$old_backup" 2>&1)"; then
    fail "$restore_name restored a $from backup on $to"
  elif grep -qF "tar -xpzf backups/package-$from-" <<<"$out" && grep -qF "&& $restore_name $old_backup" <<<"$out" &&
    ! grep -q 'git checkout' <<<"$out"; then
    pass "$restore_name refuses, the hint puts the package files of $from back without git"
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
    if out="$(PATH="$path_nogit" upgrade_cmd "$from" 2>&1)"; then
      fail "upgrade.sh $from after $to did not refuse the downgrade"
    elif grep -qF -- "$archive && ./restore.sh" <<<"$out" && ! grep -qF "releases/download/$from" <<<"$out"; then
      pass "upgrade.sh refuses to go down to $from, the hint takes the source archive of the tag"
    else
      fail "the downgrade refusal without a package copy and git: $out"
    fi
    if out="$(PATH="$path_nogit" restore_cmd --yes "$old_backup" 2>&1)"; then
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
  if [ -s "$work/clab-calls" ]; then
    fail "a clab of PATH was called: $(tr '\n' ';' <"$work/clab-calls")"
  elif [ "$driver" = scripts ]; then
    pass "no clab of PATH was called by the scripts"
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
