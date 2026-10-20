# shellcheck shell=bash
# shellcheck disable=SC2034 # the S3_* variables are for ci/check-stack.sh
#
# A stand-in for the S3 bucket of a customer, for the off-machine backups of
# ci/check-stack.sh (CLAB-132). Not a command: sourced after lib.sh.
#
# The Versity S3 Gateway (an S3 server over a directory, Apache 2.0; MinIO
# no longer publishes images) in the network of the installation under the
# name s3stand, and on 127.0.0.1:PORT of the host for the checks. Its keys
# come from its environment, and curl of the checks reads them from a file:
# no command line of the machine carries the secret, so the check of ps
# stays meaningful.
#
#   s3_up NAME PORT NETWORK   start it, create the bucket S3_BUCKET
#   s3_keys PREFIX            the keys under PREFIX, one per line
#   s3_get KEY FILE / s3_put FILE KEY
#   s3_down

S3_IMAGE="${S3_IMAGE:-versity/versitygw:v1.0.16}"
S3_BUCKET=cadence-check-backups
S3_ALIAS=s3stand

s3_up() {
  local name="$1" port="$2" network="$3" i
  S3_NAME="$name"
  S3_PORT="$port"
  S3_ACCESS_KEY="check$(openssl rand -hex 4)"
  S3_SECRET="$(openssl rand -hex 20)"
  S3_ENDPOINT="http://$S3_ALIAS:7070"
  S3_CURL_CONFIG="$(mktemp)"
  printf 'user = "%s:%s"\n' "$S3_ACCESS_KEY" "$S3_SECRET" >"$S3_CURL_CONFIG"
  ROOT_ACCESS_KEY_ID="$S3_ACCESS_KEY" ROOT_SECRET_ACCESS_KEY="$S3_SECRET" \
    docker run -d --name "$name" --network "$network" --network-alias "$S3_ALIAS" \
    -p "127.0.0.1:$port:7070" --tmpfs /gw --tmpfs /meta -e ROOT_ACCESS_KEY_ID -e ROOT_SECRET_ACCESS_KEY \
    "$S3_IMAGE" --port :7070 posix --sidecar /meta /gw >/dev/null
  for i in $(seq 1 30); do
    [ "$(s3_curl -o /dev/null -w '%{http_code}' -X PUT "$(s3_url)")" = 200 ] && return 0
    [ "$i" -lt 30 ] && sleep 1
  done
  docker logs "$name" >&2 || true
  die "the S3 stand-in did not start"
}

s3_url() {
  printf 'http://127.0.0.1:%s/%s%s\n' "$S3_PORT" "$S3_BUCKET" "${1:+/$1}"
}

s3_curl() {
  curl -s -K "$S3_CURL_CONFIG" --aws-sigv4 aws:amz:us-east-1:s3 "$@"
}

s3_keys() {
  s3_curl "$(s3_url)?list-type=2&prefix=$1" | grep -oE '<Key>[^<]*</Key>' | sed 's/<Key>//; s:</Key>::' | sort
}

s3_get() {
  [ "$(s3_curl -o "$2" -w '%{http_code}' "$(s3_url "$1")")" = 200 ]
}

s3_put() {
  [ "$(s3_curl -o /dev/null -w '%{http_code}' -T "$1" "$(s3_url "$2")")" = 200 ]
}

s3_down() {
  [ -z "${S3_NAME:-}" ] || docker rm -f "$S3_NAME" >/dev/null 2>&1 || true
  [ -z "${S3_CURL_CONFIG:-}" ] || rm -f "$S3_CURL_CONFIG"
}
