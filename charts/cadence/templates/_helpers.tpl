{{/*
Names and labels.
*/}}
{{- define "cadence.fullname" -}}
{{- if contains .Chart.Name .Release.Name -}}
{{- .Release.Name | trunc 50 | trimSuffix "-" -}}
{{- else -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 50 | trimSuffix "-" -}}
{{- end -}}
{{- end -}}

{{- define "cadence.selectorLabels" -}}
app.kubernetes.io/name: {{ .Chart.Name }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end -}}

{{- define "cadence.labels" -}}
{{ include "cadence.selectorLabels" . }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
helm.sh/chart: {{ printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" }}
{{- end -}}

{{- define "cadence.serviceAccountName" -}}
{{- if .Values.serviceAccount.create -}}
{{- default (include "cadence.fullname" .) .Values.serviceAccount.name -}}
{{- else -}}
{{- default "default" .Values.serviceAccount.name -}}
{{- end -}}
{{- end -}}

{{/*
The image of "backend" or "frontend": <registry>/<repository>:<tag>@<digest>,
without @<digest> when the digest is empty.
  include "cadence.image" (list . "backend")
*/}}
{{- define "cadence.image" -}}
{{- $root := index . 0 -}}
{{- $img := index $root.Values.image (index . 1) -}}
{{- $ref := printf "%s/%s:%s" (trimSuffix "/" $root.Values.image.registry) $img.repository (default $root.Chart.AppVersion $root.Values.image.tag) -}}
{{- if $img.digest -}}
{{- if not (regexMatch "^sha256:[0-9a-f]{64}$" $img.digest) -}}
{{- fail (printf "image.%s.digest is %q: expected sha256:<64 hex>, or empty to drop the pin" (index . 1) $img.digest) -}}
{{- end -}}
{{- $ref = printf "%s@%s" $ref $img.digest -}}
{{- end -}}
{{- $ref -}}
{{- end -}}

{{/*
The secrets of the service (docs/admin.md, "Secrets in files"; the list
internal/secrets of the backend): the key of secrets.keys, the variable that
carries the path of its file, and who reads it. The api reads every one; the
worker all but the sign-in and webhook secrets; the precheck of the
database only the database.
*/}}
{{- define "cadence.secretVars" -}}
SDLC_DATABASE_URL: {env: SDLC_DATABASE_URL_FILE, readers: [api, worker, dbcheck]}
SDLC_DATABASE_PASSWORD: {env: SDLC_DATABASE_PASSWORD_FILE, readers: [api, worker, dbcheck]}
SDLC_ADMIN_TOKEN: {env: SDLC_ADMIN_TOKEN_FILE, readers: [api]}
SDLC_GITHUB_TOKEN: {env: SDLC_GITHUB_TOKEN_FILE, readers: [api, worker]}
SDLC_GITHUB_APP_KEY_FILE: {env: SDLC_GITHUB_APP_KEY_FILE, readers: [api, worker]}
SDLC_GITHUB_APP_CLIENT_SECRET: {env: SDLC_GITHUB_APP_CLIENT_SECRET_FILE, readers: [api]}
SDLC_GITHUB_WEBHOOK_SECRET: {env: SDLC_GITHUB_WEBHOOK_SECRET_FILE, readers: [api]}
SDLC_EMBEDDINGS_API_KEY: {env: SDLC_EMBEDDINGS_API_KEY_FILE, readers: [api, worker]}
SDLC_VOYAGE_API_KEY: {env: SDLC_VOYAGE_API_KEY_FILE, readers: [api, worker]}
SDLC_BLOB_S3_ACCESS_KEY_ID: {env: SDLC_BLOB_S3_ACCESS_KEY_ID_FILE, readers: [api, worker]}
SDLC_BLOB_S3_SECRET_ACCESS_KEY: {env: SDLC_BLOB_S3_SECRET_ACCESS_KEY_FILE, readers: [api, worker]}
SDLC_BLOB_S3_SESSION_TOKEN: {env: SDLC_BLOB_S3_SESSION_TOKEN_FILE, readers: [api, worker]}
{{- end -}}

{{/*
A reference to a key of a Secret: "<key>" of secrets.name, or
"<secret>/<key>" of another Secret (a key has no "/"). Prints
{secret, key, path} as YAML; nothing for an empty reference.
  include "cadence.secretRef" (list . <entry> "<what, for errors>")
*/}}
{{- define "cadence.secretRef" -}}
{{- $root := index . 0 -}}
{{- $entry := toString (default "" (index . 1)) -}}
{{- $what := index . 2 -}}
{{- if $entry -}}
{{- $secret := $root.Values.secrets.name -}}
{{- $key := $entry -}}
{{- if contains "/" $entry -}}
{{- $parts := splitn "/" 2 $entry -}}
{{- $secret = $parts._0 -}}
{{- $key = $parts._1 -}}
{{- if not (regexMatch "^[a-z0-9]([-.a-z0-9]*[a-z0-9])?$" $secret) -}}
{{- fail (printf "%s: %q is not the name of a Secret (<secret>/<key>)" $what $secret) -}}
{{- end -}}
{{- end -}}
{{- if not $secret -}}
{{- fail (printf "%s names the key %q, but secrets.name is empty: set the Secret the keys are in" $what $key) -}}
{{- end -}}
{{- if not (regexMatch "^[-._a-zA-Z0-9]+$" $key) -}}
{{- fail (printf "%s: %q is not a key of a Secret" $what $key) -}}
{{- end -}}
secret: {{ $secret | quote }}
key: {{ $key | quote }}
path: {{ printf "/secrets/%s/%s" $secret $key | quote }}
{{- end -}}
{{- end -}}

{{/*
The secret files a reader (api, worker, dbcheck) gets: a list of
{env, secret, key, path}; env is empty for secrets.files.
  include "cadence.secretFiles" (list . "api") | fromYaml
*/}}
{{- define "cadence.secretFiles" -}}
{{- $root := index . 0 -}}
{{- $reader := index . 1 -}}
{{- $vars := include "cadence.secretVars" $root | fromYaml -}}
{{- $out := list -}}
{{- range $name, $entry := $root.Values.secrets.keys -}}
{{- $var := index $vars $name -}}
{{- if not $var -}}
{{- fail (printf "secrets.keys.%s: no such secret; the secrets are %s (docs/admin.md, \"Secrets in files\")" $name (keys $vars | sortAlpha | join ", ")) -}}
{{- end -}}
{{- $ref := include "cadence.secretRef" (list $root $entry (printf "secrets.keys.%s" $name)) | fromYaml -}}
{{- if and $ref (has $reader $var.readers) -}}
{{- $out = append $out (merge (dict "env" $var.env) $ref) -}}
{{- end -}}
{{- end -}}
{{- if ne $reader "dbcheck" -}}
{{- range $name, $entry := $root.Values.secrets.githubTokens -}}
{{- if not (regexMatch "^[A-Z0-9_]+$" $name) -}}
{{- fail (printf "secrets.githubTokens.%s: the name of a repository token is upper case letters, digits and _ (SDLC_GITHUB_TOKEN_<NAME>)" $name) -}}
{{- end -}}
{{- $ref := include "cadence.secretRef" (list $root $entry (printf "secrets.githubTokens.%s" $name)) | fromYaml -}}
{{- if $ref -}}
{{- $out = append $out (merge (dict "env" (printf "SDLC_GITHUB_TOKEN_%s_FILE" $name)) $ref) -}}
{{- end -}}
{{- end -}}
{{- end -}}
{{- range $i, $entry := $root.Values.secrets.files -}}
{{- $ref := include "cadence.secretRef" (list $root $entry (printf "secrets.files[%d]" $i)) | fromYaml -}}
{{- if $ref -}}
{{- $out = append $out (merge (dict "env" "") $ref) -}}
{{- end -}}
{{- end -}}
{{- dict "files" $out | toYaml -}}
{{- end -}}

{{/*
The volume of the secret files of a reader: one projected volume, each key
at <secret>/<key>, read-only for the group 65532 of the pod (fsGroup). A
key missing in its Secret keeps the volume from mounting: the event of the
pod names the Secret and the key.
*/}}
{{- define "cadence.secretVolume" -}}
{{- $files := (include "cadence.secretFiles" . | fromYaml).files -}}
{{- if $files }}
- name: secrets
  projected:
    # 0440, written in decimal: YAML 1.1 and 1.2 read 0440 differently.
    defaultMode: 288
    sources:
      {{- $seen := dict }}
      {{- range $files }}
      {{- if not (hasKey $seen .path) }}
      {{- $_ := set $seen .path true }}
      - secret:
          name: {{ .secret | quote }}
          items:
            - key: {{ .key | quote }}
              path: {{ printf "%s/%s" .secret .key | quote }}
      {{- end }}
      {{- end }}
{{- end }}
{{- end -}}

{{- define "cadence.secretMount" -}}
{{- $files := (include "cadence.secretFiles" . | fromYaml).files -}}
{{- if $files }}
- name: secrets
  mountPath: /secrets
  readOnly: true
{{- end }}
{{- end -}}

{{/*
The values the chart cannot do without (docs/admin.md, "Kubernetes
(Helm)"): the rendering stops with the key to set.
*/}}
{{- define "cadence.validate" -}}
{{- $v := .Values -}}
{{- if not $v.ingress.host -}}
{{- fail "ingress.host is required: the address people open, e.g. cadence.example.com" -}}
{{- end -}}
{{- $k := $v.secrets.keys -}}
{{- if and $k.SDLC_DATABASE_URL $v.database.url -}}
{{- fail "database.url and secrets.keys.SDLC_DATABASE_URL are both set: the URL comes from one of them (with the URL in the values, the password goes in secrets.keys.SDLC_DATABASE_PASSWORD)" -}}
{{- end -}}
{{- if and $k.SDLC_DATABASE_URL $k.SDLC_DATABASE_PASSWORD -}}
{{- fail "secrets.keys.SDLC_DATABASE_PASSWORD goes with database.url, the URL without a password; with secrets.keys.SDLC_DATABASE_URL the password is in that URL" -}}
{{- end -}}
{{- if $v.database.url -}}
{{- if regexMatch "^[a-zA-Z][-+.a-zA-Z0-9]*://[^/@?#]*:[^/@?#]*@" $v.database.url -}}
{{- fail "database.url has a password: a URL with a password is a secret - put it in a Secret and name its key in secrets.keys.SDLC_DATABASE_URL, or drop the password from the URL and name its key in secrets.keys.SDLC_DATABASE_PASSWORD" -}}
{{- end -}}
{{- if not $k.SDLC_DATABASE_PASSWORD -}}
{{- fail "database.url needs secrets.keys.SDLC_DATABASE_PASSWORD: the key of the Secret with the password of the database" -}}
{{- end -}}
{{- else if not $k.SDLC_DATABASE_URL -}}
{{- fail "the database is required: secrets.keys.SDLC_DATABASE_URL (the key of the Secret with the URL), or database.url with secrets.keys.SDLC_DATABASE_PASSWORD" -}}
{{- end -}}
{{- if not $v.blobs.s3.bucket -}}
{{- fail "blobs.s3.bucket is required: artifact content lives in an S3 bucket (the pods share no volume)" -}}
{{- end -}}
{{- if not $k.SDLC_BLOB_S3_ACCESS_KEY_ID -}}
{{- fail "secrets.keys.SDLC_BLOB_S3_ACCESS_KEY_ID is required: the key of the Secret with the access key of blobs.s3.bucket" -}}
{{- end -}}
{{- if not $k.SDLC_BLOB_S3_SECRET_ACCESS_KEY -}}
{{- fail "secrets.keys.SDLC_BLOB_S3_SECRET_ACCESS_KEY is required: the key of the Secret with the secret key of blobs.s3.bucket" -}}
{{- end -}}
{{- if not $k.SDLC_ADMIN_TOKEN -}}
{{- fail "secrets.keys.SDLC_ADMIN_TOKEN is required: the key of the Secret with the administrator token (the first sign-in)" -}}
{{- end -}}
{{- end -}}

{{/*
The environment of the API ("api") or the worker ("worker"): the values
fixed in docker-compose.yml, config.shared and config.<reader>, the bucket,
the metrics listener, the secret files and extraEnv.
*/}}
{{- define "cadence.env" -}}
{{- $root := index . 0 -}}
{{- $reader := index . 1 -}}
{{- $v := $root.Values -}}
{{- $fixed := dict "SDLC_ENV" "production" -}}
{{- if eq $reader "api" -}}
{{- $_ := set $fixed "SDLC_HTTP_ADDR" ":8080" -}}
{{- $_ := set $fixed "SDLC_AUTO_MIGRATE" "true" -}}
{{- $_ := set $fixed "SDLC_STRICT_GATES" "true" -}}
{{- $_ := set $fixed "SDLC_MCP_ENABLED" "true" -}}
{{- $_ := set $fixed "SDLC_TENANCY" "single" -}}
{{- $_ := set $fixed "SDLC_PROJECT_CREATION" "teams" -}}
{{- else -}}
{{- $_ := set $fixed "SDLC_AUTO_MIGRATE" "false" -}}
{{- end -}}
{{- $_ := set $fixed "SDLC_DATABASE_URL" (default "" $v.database.url) -}}
{{- $_ := set $fixed "SDLC_BLOB_S3_BUCKET" $v.blobs.s3.bucket -}}
{{- $_ := set $fixed "SDLC_BLOB_S3_ENDPOINT" (default "" $v.blobs.s3.endpoint) -}}
{{- $_ := set $fixed "SDLC_BLOB_S3_REGION" (default "" $v.blobs.s3.region) -}}
{{- $_ := set $fixed "SDLC_BLOB_S3_PREFIX" (default "" $v.blobs.s3.prefix) -}}
{{- $_ := set $fixed "SDLC_BLOB_S3_PATH_STYLE" (ternary "true" "false" (ne (toString $v.blobs.s3.pathStyle) "false")) -}}
{{- $_ := set $fixed "SDLC_METRICS_ADDR" (ternary ":9090" "" (ne (toString $v.metrics.enabled) "false")) -}}
{{- $config := merge (deepCopy (default dict (index $v.config $reader))) (deepCopy (default dict $v.config.shared)) -}}
{{- range $name, $_ := $config -}}
{{- if hasKey $fixed $name -}}
{{- fail (printf "config.%s: %s is set by the chart and cannot be changed (docs/admin.md, \"Kubernetes (Helm)\")" $reader $name) -}}
{{- end -}}
{{- end -}}
{{- $vars := include "cadence.secretVars" $root | fromYaml -}}
{{- range $name, $_ := $config -}}
{{- if or (hasKey $vars $name) (hasSuffix "_FILE" $name) -}}
{{- fail (printf "config: %s is a secret: name its key in secrets.keys, not a value" $name) -}}
{{- end -}}
{{- end -}}
{{- $all := merge (deepCopy $fixed) $config -}}
{{- range $v.extraEnv -}}
{{- if or (hasKey $all .name) (hasKey $vars .name) (hasSuffix "_FILE" .name) -}}
{{- fail (printf "extraEnv: %s is a variable of the chart or a secret: set it in config or secrets.keys" .name) -}}
{{- end -}}
{{- end -}}
{{- range $name := keys $all | sortAlpha }}
- name: {{ $name }}
  value: {{ index $all $name | toString | quote }}
{{- end }}
{{- range (include "cadence.secretFiles" (list $root $reader) | fromYaml).files }}
{{- if .env }}
- name: {{ .env }}
  value: {{ .path | quote }}
{{- end }}
{{- end }}
{{- with $v.extraEnv }}
{{ toYaml . }}
{{- end }}
{{- end -}}

{{/*
The security context of the pods of the backend image (distroless,
uid 65532): Pod Security "restricted".
*/}}
{{- define "cadence.podSecurityContext" -}}
runAsNonRoot: true
runAsUser: 65532
runAsGroup: 65532
fsGroup: 65532
seccompProfile:
  type: RuntimeDefault
{{- end -}}

{{- define "cadence.containerSecurityContext" -}}
runAsNonRoot: true
runAsUser: 65532
runAsGroup: 65532
allowPrivilegeEscalation: false
readOnlyRootFilesystem: true
capabilities:
  drop: [ALL]
seccompProfile:
  type: RuntimeDefault
{{- end -}}
