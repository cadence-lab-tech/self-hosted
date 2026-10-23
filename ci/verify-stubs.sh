# shellcheck shell=bash
#
# Stand-ins for the checks of the signatures (lib.sh, "signatures"): sourced
# by ci/check-get-cadence.sh, ci/check-verify.sh, ci/check-stack.sh,
# ci/check-upgrade.sh, ci/check-publish-chart.sh and ci/check-airgap.sh. Not
# part of the package.
#
#   stub_cosign DIR LOG         DIR/cosign: a cosign 3.x that writes its
#                               command line to LOG and verifies everything,
#                               except what FAKE_COSIGN_BAD names; sign
#                               signs anything
#   stub_cosign_local DIR LOG   DIR/cosign: accepts verify-blob of a package
#                               built by ci/package.sh --bundle (unsigned:
#                               it is this checkout) and hands everything
#                               else to the real cosign; only when a real
#                               cosign 3.x is in PATH (status 1 otherwise)
#   stub_cosign_package FILE REAL SUM LOG [TUF]
#                               FILE: a POSIX sh cosign for the machines of
#                               ci/check-airgap.sh (alpine): accepts
#                               verify-blob of a file whose SHA-256 is SUM -
#                               checksums.txt of the package of this checkout,
#                               built in the same run - and hands everything
#                               else to REAL, the real cosign, by exec
#   stub_curl DIR              DIR/curl: ghcr.io answers or not
#                               (FAKE_GHCR=down), everything else goes to
#                               the real curl
#   stub_compose_images FILE    FILE: what `docker compose [-f F]... config
#                               --images` prints, from the image: lines of
#                               the compose files with the variables of the
#                               environment - for the docker stubs
#   path_without_cosign         PATH without the directories that have a
#                               cosign: "cosign is not installed" on a
#                               machine that has one
#
# The stub cosign reads, when it runs:
#
#   FAKE_COSIGN_VERSION  what `cosign version` reports, default v3.1.3
#   FAKE_COSIGN_BAD      package - verify-blob fails (another identity);
#                        a repository (sdlc-pipeline-backend, cadence of the
#                        chart) - verify of its image fails
#   FAKE_WATCH           a path; each call logs whether it exists then
#                        ([exists] or [absent]) - "before unpacking"

stub_cosign() {
  local dir="$1" log="$2"
  mkdir -p "$dir"
  cat >"$dir/cosign" <<SH
#!/bin/sh
{
  printf 'cosign'
  for a in "\$@"; do printf ' [%s]' "\$a"; done
  if [ -n "\${FAKE_WATCH:-}" ]; then
    if [ -e "\$FAKE_WATCH" ]; then printf ' [exists]'; else printf ' [absent]'; fi
  fi
  echo
} >>"$log"
case "\$1" in
version)
  printf '  ______   ______        _______. __    _______ .__   __.\n\nGitVersion:    %s\nGitCommit:     0000000\n' "\${FAKE_COSIGN_VERSION:-v3.1.3}"
  ;;
verify-blob)
  if [ "\${FAKE_COSIGN_BAD:-}" = package ]; then
    echo "Error: none of the expected identities matched what was in the certificate, got subjects [https://github.com/someone/else/.github/workflows/release.yml@refs/heads/main]" >&2
    exit 1
  fi
  echo "Verified OK" >&2
  ;;
verify)
  for last in "\$@"; do :; done
  case "\$last" in
  *"/\${FAKE_COSIGN_BAD:-none}@"*)
    echo "Error: no matching signatures: none of the expected identities matched what was in the certificate" >&2
    exit 1
    ;;
  esac
  echo '[{"critical":{}}]'
  ;;
sign)
  echo "tlog entry created (cosign stub)" >&2
  ;;
*) echo "cosign stub: \$*" >&2; exit 1 ;;
esac
SH
  chmod 755 "$dir/cosign"
}

stub_cosign_local() {
  local dir="$1" log="$2" real v
  real="$(command -v cosign 2>/dev/null || true)"
  [ -n "$real" ] || return 1
  v="$("$real" version 2>&1 | sed -n 's/^GitVersion:[[:space:]]*v\{0,1\}\([0-9]*\)\..*/\1/p' | head -n 1 || true)"
  [ -n "$v" ] && [ "$v" -ge 3 ] || return 1
  mkdir -p "$dir"
  cat >"$dir/cosign" <<SH
#!/bin/sh
{ printf 'cosign'; for a in "\$@"; do printf ' [%s]' "\$a"; done; echo; } >>"$log"
# The package of this checkout is not signed: its stand-in bundle passes.
if [ "\$1" = verify-blob ]; then
  echo "Verified OK (the package of this checkout, ci/verify-stubs.sh)" >&2
  exit 0
fi
exec "$real" "\$@"
SH
  chmod 755 "$dir/cosign"
}

# stub_cosign_package FILE REAL SUM LOG [TUF]: the package of this checkout
# is not signed and cannot be (the identity of the signature, release.yml of
# self-hosted on main, is built into clab), so its checksums.txt passes here -
# and only it: verify-blob of a file with another SHA-256 (a checksums.txt
# of a published release, an altered one), verify and verify-attestation of
# the images, initialize and version go to the real cosign untouched. As the
# real one, it refuses without --trusted-root when Sigstore TUF (TUF, default
# its timestamp.json) does not answer - a machine without network - so that
# clab and get-cadence.sh take trusted_root.json of the mirror or the archive
# as they would. Each call goes to LOG as "stub ..." or "real ..." with its
# arguments; the check reads it.
stub_cosign_package() {
  local file="$1" real="$2" sum="$3" log="$4" tuf="${5:-https://tuf-repo-cdn.sigstore.dev/timestamp.json}"
  cat >"$file" <<SH
#!/bin/sh
# The cosign of ci/check-airgap.sh on the package of this checkout
# (ci/verify-stubs.sh, stub_cosign_package): not a cosign of the product.
real='$real'
sum='$sum'
log='$log'
tuf='$tuf'
note() {
  { printf '%s' "\$1"; shift; for a in "\$@"; do printf ' [%s]' "\$a"; done; echo; } >>"\$log"
}
sha256() {
  if command -v sha256sum >/dev/null 2>&1; then sha256sum "\$1" | cut -d' ' -f1; else shasum -a 256 "\$1" | cut -d' ' -f1; fi
}
reachable() {
  if command -v curl >/dev/null 2>&1; then
    curl -fs -m 5 -o /dev/null "\$tuf"
  else
    wget -q -T 5 -O /dev/null "\$tuf"
  fi
}
if [ "\${1:-}" = verify-blob ]; then
  blob="" bundle="" root="" prev=""
  for a in "\$@"; do
    case "\$prev" in
    --bundle) bundle="\$a" ;;
    --trusted-root) root="\$a" ;;
    esac
    case "\$a" in
    --bundle=*) bundle="\${a#*=}" ;;
    --trusted-root=*) root="\${a#*=}" ;;
    esac
    prev="\$a"
    blob="\$a"
  done
  if [ -f "\$blob" ] && [ "\$(sha256 "\$blob")" = "\$sum" ]; then
    if [ ! -f "\$bundle" ]; then
      note refused "\$@"
      echo "Error: open \$bundle: no such file or directory" >&2
      exit 1
    fi
    if [ -n "\$root" ]; then
      if [ ! -s "\$root" ]; then
        note refused "\$@"
        echo "Error: reading trusted root \$root: no such file or empty" >&2
        exit 1
      fi
    elif ! reachable; then
      note refused "\$@"
      echo "Error: getting trusted root from TUF: \$tuf does not answer (no network)" >&2
      exit 1
    fi
    note stub "\$@"
    echo "Verified OK (the unsigned package of this checkout, sha256 \$sum: ci/verify-stubs.sh)" >&2
    exit 0
  fi
fi
note real "\$@"
exec "\$real" "\$@"
SH
  chmod 755 "$file"
}

stub_curl() {
  local dir="$1" real
  real="$(command -v curl)"
  mkdir -p "$dir"
  cat >"$dir/curl" <<SH
#!/bin/sh
for a in "\$@"; do
  case "\$a" in
  https://ghcr.io/*)
    [ "\${FAKE_GHCR:-up}" != down ] || exit 7
    exit 0
    ;;
  esac
done
exec "$real" "\$@"
SH
  chmod 755 "$dir/curl"
}

stub_compose_images() {
  cat >"$1" <<'SH'
#!/bin/sh
# The image: lines of the compose files after -f (default
# docker-compose.yml), with the variables interpolated as compose does for
# the forms the package uses: ${VAR:-default}, ${VAR-default}, ${VAR:?msg}.
files=""
prev=""
for a in "$@"; do
  [ "$prev" != -f ] || files="$files $a"
  prev="$a"
done
[ -n "$files" ] || files=docker-compose.yml
for f in $files; do
  sed -n 's/^ *image: *//p' "$f" | while IFS= read -r line; do
    eval "printf '%s\n' \"$line\""
  done
done
SH
  chmod 755 "$1"
}

path_without_cosign() {
  local d out="" IFS=:
  for d in $PATH; do
    [ -x "$d/cosign" ] || out="${out:+$out:}$d"
  done
  printf '%s\n' "$out"
}
