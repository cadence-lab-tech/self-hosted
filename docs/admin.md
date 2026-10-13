# Administrator guide

This guide takes a Cadence Lab installation from `./install.sh` to teams
working with agents: first sign-in, teams and invites, GitHub, single sign-on,
the CLI and agents, embeddings, backups and upgrades.

Commands below run in the directory of the package (the clone of this
repository). For a direct `docker compose` command export the version first:

```bash
export CADENCE_VERSION=$(cat VERSION)
```

`<host>` is the address people open: your domain in the `tls` mode, the
public address of your proxy in the `proxy` mode.

- [Install](#install)
- [Behind your reverse proxy](#behind-your-reverse-proxy)
- [First sign-in with the administrator token](#first-sign-in-with-the-administrator-token)
- [Teams, projects and invites](#teams-projects-and-invites)
- [GitHub App](#github-app)
- [Single sign-on with OIDC](#single-sign-on-with-oidc)
- [CLI and agents](#cli-and-agents)
- [Embeddings](#embeddings)
- [Backups](#backups)
- [Upgrades and rollback](#upgrades-and-rollback)
- [Troubleshooting](#troubleshooting)

## Install

```bash
git clone https://github.com/cadence-lab-tech/self-hosted.git cadence && cd cadence
./install.sh
```

The script checks Docker, compose v2, free ports and the domain, asks for the
mode, writes `.env` (mode 600) with a generated database password,
administrator token and webhook secret, pulls the images of `VERSION`, starts
the stack and waits until it is ready. It prints the address and the
administrator token once; the token stays in `.env`.

Flags and environment variables for an unattended run:

| flag | variable | |
|---|---|---|
| `--mode tls\|proxy` | `CADENCE_MODE` | default `tls` |
| `--domain` | `SDLC_DOMAIN` | `tls` mode: host name with a DNS record pointing here |
| `--email` | `ACME_EMAIL` | `tls` mode: Let's Encrypt notices |
| `--http-addr` | `CADENCE_HTTP_ADDR` | `proxy` mode: where Caddy listens, default `127.0.0.1:8080` |
| `--team`, `--team-name` | `SDLC_BOOTSTRAP_TEAM`, `SDLC_BOOTSTRAP_TEAM_NAME` | optional first team |
| `--yes` | | ask nothing (also when there is no terminal) |
| | `SDLC_ADMIN_TOKEN` | use this administrator token instead of generating one |

`install.sh` runs once. With an existing `.env` it stops and changes nothing:
a new database password would no longer open the existing database volume.
Further changes go into `.env` by hand; apply them with
`docker compose up -d`, which recreates only the containers whose settings
changed.

## Behind your reverse proxy

In the `proxy` mode Caddy serves plain HTTP on `CADENCE_HTTP_ADDR`. Your proxy
terminates TLS and forwards everything for `<host>` there. It must:

- pass the `Host` header through;
- **not buffer responses on `/mcp/`**: agents talk MCP over streamable HTTP
  with server-sent events, and a buffered stream hangs. Allow long-lived
  responses (minutes);
- let GitHub reach `https://<host>/webhooks/github` from the internet if you
  connect a GitHub App, even if the rest of the instance is internal-only.

nginx, for example:

```nginx
server {
    listen 443 ssl;
    server_name cadence.example.com;
    # ssl_certificate ...;

    client_max_body_size 64m;

    location / {
        proxy_pass http://127.0.0.1:8080;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_http_version 1.1;
        proxy_buffering off;
        proxy_read_timeout 1h;
    }
}
```

A proxy on another machine needs `CADENCE_HTTP_ADDR=0.0.0.0:8080` (or the
address of the internal interface) and a firewall that admits only the proxy.
Sign-in redirects are built from the address in the browser, so nothing in
`.env` needs the public host name in this mode.

## First sign-in with the administrator token

The administrator token from `install.sh` (`SDLC_ADMIN_TOKEN` in `.env`)
belongs to the principal `admin` (`SDLC_ADMIN_HANDLE`), the global
administrator.

- **UI:** open `<host>` and paste the token on the sign-in page.
- **CLI:** `clab auth login --host https://<host> --with-token`, then paste the
  token (see [CLI and agents](#cli-and-agents) for installing `clab`).

Keep the token for emergencies. People sign in through GitHub or your
identity provider, and agents use tokens issued for them; the administrator
token is not something to share.

## Teams, projects and invites

The instance runs in the `single` profile (`SDLC_TENANCY=single`): there are
no personal teams, plans or quotas. Projects live in teams, and with
`SDLC_PROJECT_CREATION=teams` they are created by the administrator and by
leads of teams allowed to do so.

```bash
clab team create platform --name "Platform"            # a team (skip if --team was given to install.sh)
clab team update platform --can-create-projects        # its leads may create projects
clab project create PLAT --name "Platform" --team platform
```

People get in by invite: the command prints a link to send; whoever opens it
and signs in joins.

```bash
clab invite create --team platform --role lead          # a team lead
clab invite create --team platform                      # a team member
clab invite create --project PLAT --level agent --roles developer,reviewer
clab invite list --team platform
clab invite revoke <id>
```

`--roles` names specialist roles that already exist in the project. A new
project has no roles and no cycle yet: a maintainer sets them up in the UI
(roles and cycle editors) or imports a bundle with `clab import`. Until then
an invite or a token with `--roles` is refused with `not_found`.

Project access levels are `viewer`, `agent` (takes tasks), `maintainer` (edits
the cycle and roles, approves) and `admin` (manages members and tokens). A
team gets access to a project as a whole:

```bash
clab team grant platform --project PLAT --level maintainer
```

The same is available in the UI: team pages and project settings. Someone
who has already signed in can be added directly, without an invite:
`clab team add platform user:alice --role lead`.

## GitHub App

Without a GitHub App the instance works — tasks, artifacts, the cycle, gates
and approvals — but it does not index code, does not follow pull requests and
receives no webhooks. Pull requests can still be linked to tasks by hand.

One app serves the whole instance. It reads repositories with installation
tokens and lets people sign in with GitHub. Create it in your GitHub
organization: **Settings → Developer settings → GitHub Apps → New GitHub
App**.

1. **Name and homepage:** any; the homepage can be `https://<host>`.
2. **Identifying and authorizing users:**
   - Callback URLs: `https://<host>/login/github` and
     `https://<host>/settings/github/callback`.
   - Leave "Request user authorization (OAuth) during installation" off.
3. **Post installation:** Setup URL `https://<host>/settings/github/callback`,
   with **Redirect on update** on.
4. **Webhook:** active, URL `https://<host>/webhooks/github`, secret — the
   value of `SDLC_GITHUB_WEBHOOK_SECRET` from `.env` (`install.sh` generated
   it).
5. **Repository permissions, read-only:** Contents: Read, Metadata: Read,
   Pull requests: Read, Checks: Read. Nothing else, and no write access:
   Cadence Lab never writes to your repositories.
6. **Subscribe to events:** Push, Pull request, Check run. Installation events
   come without a subscription.
7. **Where can this app be installed:** "Only on this account" is enough for
   one organization.

After creating it:

- **Generate a private key** and put it into `secrets/github-app.pem`. The
  service runs as uid 65532 and has no shell, so hand the file over with a
  throwaway container:

  ```bash
  docker run --rm -v "$PWD/secrets:/s" alpine:3 \
    sh -c 'chown 65532:65532 /s/github-app.pem && chmod 400 /s/github-app.pem && chmod 711 /s'
  ```

- **Generate a client secret.**
- Fill in `.env`:

  ```bash
  SDLC_GITHUB_APP_ID=123456                         # "App ID" on the app page
  SDLC_GITHUB_APP_KEY_FILE=/secrets/github-app.pem  # path inside the container
  SDLC_GITHUB_APP_CLIENT_ID=Iv23li...               # "Client ID"
  SDLC_GITHUB_APP_CLIENT_SECRET=...                 # the client secret
  SDLC_GITHUB_APP_SLUG=cadence-acme                 # from github.com/apps/<slug>
  ```

- Apply: `docker compose up -d`.

The sign-in page now has "Sign in with GitHub", and team pages and project
settings have "Connect GitHub": install the app on the organization, come
back, and pick the repositories for the project. From the CLI:
`clab team github <team>` lists the installations of a team and
`clab repo add <owner>/<name>` (run with `SDLC_PROJECT=<KEY>`) links a
repository; the installation is found automatically.

The machine clock must be right: GitHub rejects app tokens signed "in the
future" with `Bad credentials`, which looks exactly like a revoked key.

## Single sign-on with OIDC

People can sign in with your identity provider (Keycloak, Okta, Microsoft
Entra ID, Google Workspace, Authentik, ...). The browser runs the
authorization code flow with PKCE and hands the ID token to the backend,
which verifies its signature, issuer, audience and expiry. Register an
application at the provider:

- type: **public client / single-page application** (no client secret,
  PKCE S256);
- redirect URI: `https://<host>/login`;
- scopes: `openid profile email`;
- allowed web origin (CORS) for the token endpoint: `https://<host>` — the
  browser calls the token endpoint itself;
- optional: a `groups` claim in the ID token.

Then in `.env`:

```bash
SDLC_OIDC_ISSUER=https://idp.example.com/realms/acme   # issuer URL, as in .well-known/openid-configuration
SDLC_OIDC_CLIENT_ID=cadence                            # also checked as the token audience
# SDLC_OIDC_GROUPS_CLAIM=groups
```

and `docker compose up -d`. The sign-in page gets "Sign in with provider".

Team membership follows provider groups when a team is mapped to them; the
mapping is set by the administrator, roles inside the team stay manual:

```bash
clab team groups platform --set cadence-platform
```

## CLI and agents

Everyone uses the same CLI, `clab`, from the public tap; companies do not
build their own. It talks only to the host it signed in to: your instance,
not ours.

```bash
brew install cadence-lab-tech/tap/clab      # macOS and Linux with Homebrew: the latest version
```

Homebrew always installs the latest release. To install the version that
matches your server, use the install script of the tap with a version:

```bash
curl -fsSL https://raw.githubusercontent.com/cadence-lab-tech/homebrew-tap/main/install.sh \
  | CLAB_VERSION=v0.5.0 sh                   # the VERSION of your server
```

`clab version` shows both versions. Release archives for Windows are on the
tap's releases page.

Sign in and connect an agent:

```bash
clab auth login --host https://<host>       # opens the browser; --no-browser prints the link
clab auth status
cd ~/src/my-repo
clab mcp install                            # registers the MCP server of the project with Claude Code
```

`clab mcp install` writes the MCP server `https://<host>/mcp/projects/<KEY>`
of your instance with the CLI's token into the agent's configuration. The
project comes from the `origin` remote of the current directory, or from
`--project <KEY>`. For other agents, `clab mcp config` prints the JSON to
paste.

One configuration (`~/.config/clab`) holds several hosts. The one you signed
in to last is the default; `--host` picks another for one command:

```bash
clab auth login --host https://cadence.acme.internal
clab --host https://cadence.acme.internal tasks
```

Agents that run unattended (CI, `clab-runner`) get a token of their own,
issued by a project or team admin, rather than a person's session:

```bash
clab token create --name ci --for agent:ci-bot --project PLAT --roles developer --days 90
```

## Embeddings

Search over code and artifacts is full-text by default
(`SDLC_EMBEDDINGS_PROVIDER=none`): no external calls, nothing to configure.
With an embeddings provider the worker also computes vectors and search
becomes hybrid. Changing the provider or the model later is safe: vectors are
recomputed in the background.

The model must return **1024-dimensional** vectors. The API and the worker
read the same variables, so they always use the same model.

**Voyage AI:**

```bash
SDLC_EMBEDDINGS_PROVIDER=voyage
SDLC_VOYAGE_API_KEY=pa-...
# SDLC_EMBEDDINGS_MODEL=voyage-code-3          # the default
```

**OpenAI-compatible servers** (`openai`). There is no default model: set it.

```bash
# OpenAI
SDLC_EMBEDDINGS_PROVIDER=openai
SDLC_EMBEDDINGS_API_KEY=sk-...
SDLC_EMBEDDINGS_MODEL=text-embedding-3-large   # asked for 1024 dimensions via `dimensions`

# Ollama (on the same machine, reachable from the containers)
SDLC_EMBEDDINGS_PROVIDER=openai
SDLC_EMBEDDINGS_URL=http://host.docker.internal:11434/v1
SDLC_EMBEDDINGS_MODEL=mxbai-embed-large        # 1024 dimensions
SDLC_EMBEDDINGS_SEND_DIMENSIONS=false

# Hugging Face text-embeddings-inference (TEI)
SDLC_EMBEDDINGS_PROVIDER=openai
SDLC_EMBEDDINGS_URL=http://tei.internal:8080/v1
SDLC_EMBEDDINGS_MODEL=BAAI/bge-large-en-v1.5   # 1024 dimensions
SDLC_EMBEDDINGS_SEND_DIMENSIONS=false

# vLLM
SDLC_EMBEDDINGS_PROVIDER=openai
SDLC_EMBEDDINGS_URL=http://vllm.internal:8000/v1
SDLC_EMBEDDINGS_MODEL=BAAI/bge-m3              # 1024 dimensions
SDLC_EMBEDDINGS_SEND_DIMENSIONS=false
```

`SDLC_EMBEDDINGS_SEND_DIMENSIONS=false` is for servers that reject the
`dimensions` field of the request; the model itself must then produce 1024
dimensions. On Linux, `host.docker.internal` needs
`extra_hosts: ["host.docker.internal:host-gateway"]` for api and worker in a
[local override](#local-compose-changes), or use the host's address.

**Input length.** Code and artifacts are indexed in chunks of up to 1600
characters, roughly 400–800 tokens. OpenAI and Voyage accept that. Models
with a 512-token window reject longer chunks, and one rejected chunk fails
its whole batch: vectors stop being computed and search quietly stays
full-text. Run TEI with `--auto-truncate`, configure Ollama to truncate, or
pick a model with a window of at least 1024 tokens.

**Symptom:** search results do not improve after enabling embeddings. The
worker logs the failures (its log messages are in Russian):

```bash
docker compose logs worker | grep 'досчёт эмбеддингов'
docker compose logs worker | grep 'эмбеддинги не посчитаны'
```

## Backups

```bash
./backup.sh
```

writes `backups/cadence-<version>-<YYYYmmdd-HHMMSS>.sql.gz` — a dump of the
database made inside the Postgres container — and, when artifact content
lives in the `blobs` volume (`SDLC_BLOB_S3_BUCKET` is empty), the archive of
that volume next to it, `….blobs.tar.gz`. A dump smaller than 1 KB is treated
as a failure. Backups older than `KEEP_DAYS` (14) are deleted;
`BACKUP_DIR` writes elsewhere.

Schedule it nightly for root (or a user in the `docker` group):

```bash
0 3 * * * /opt/cadence/backup.sh >> /opt/cadence/backups/backup.log 2>&1
```

Backups on the same machine protect against a bad upgrade or a mistaken
deletion, not against losing the machine: copy `backups/` elsewhere —
`rsync` or `rclone` to another host or bucket after the backup, or snapshots
of the disk. With an S3 bucket for artifact content, the bucket is yours to
back up (versioning or replication).

Restore:

```bash
./restore.sh backups/cadence-v0.5.0-20261008-030000.sql.gz
```

It stops the API and the worker, drops and recreates the database from the
dump, puts the `blobs` archive back if there is one, starts the stack and
waits until it is ready. **Everything written after the backup is lost.** It
asks for confirmation; `--yes` skips it.

The backup must match the running version (`VERSION`). If it was taken on
another version, `restore.sh` refuses and says which one; switch the package
files to it first:

```bash
git checkout v0.5.0 && ./restore.sh backups/cadence-v0.5.0-20261008-030000.sql.gz
```

## Upgrades and rollback

```bash
./upgrade.sh            # fast-forward to the latest main
./upgrade.sh v0.6.0     # the package files of the tag v0.6.0
```

Each version is a tag `vX.Y.Z` of this repository; `VERSION` in it names the
images. The script:

1. checks that tracked files are not modified (keep your settings in `.env`
   and local compose changes in `docker-compose.override.yml`, see below);
2. finds the target and refuses to go to an older version — migrations only go
   forward;
3. takes a backup of the current version;
4. switches the package files (`git checkout` of the tag, or
   `git pull --ff-only`);
5. pulls the images of the new version — if that fails, it puts the files
   back and the running stack is untouched;
6. starts the stack (the API applies migrations itself), reloads Caddy and
   waits for readiness (`CADENCE_READY_TIMEOUT`, 300 s).

Skipping versions is fine. If the new version does not become ready, the
script exits with an error, shows the logs and prints the rollback with the
exact commit and backup, for example:

```
✗ v0.6.0 did not become ready in 300s (logs above). The database may already be migrated.
  To return to v0.5.0 and its backup:
  git -c advice.detachedHead=false checkout 1a2b3c4…   # package files of v0.5.0
  ./restore.sh --yes backups/cadence-v0.5.0-20261008-030000.sql.gz   # data as of the backup, starts v0.5.0
```

Releases are announced as pull requests "Release vX.Y.Z" in this repository;
watch it (Releases or all activity) to hear about them.

### Local compose changes

Do not edit the tracked files: `upgrade.sh` refuses to run over local
changes. Put additions into `docker-compose.override.yml` (ignored by git) and
add it to `COMPOSE_FILE` in `.env` — with `COMPOSE_FILE` set, compose does not
pick the override up by itself:

```bash
COMPOSE_FILE=docker-compose.yml:compose.tls.yml:docker-compose.override.yml
```

```yaml
# docker-compose.override.yml
services:
  api:
    extra_hosts: ["host.docker.internal:host-gateway"]
  worker:
    extra_hosts: ["host.docker.internal:host-gateway"]
```

## Troubleshooting

```bash
export CADENCE_VERSION=$(cat VERSION)
docker compose ps                       # what runs and what is healthy
docker compose logs --tail 100 api      # the API: migrations, sign-in, MCP
docker compose logs --tail 100 worker   # indexing, embeddings, leases
docker compose logs --tail 100 caddy    # TLS certificates and routing
curl -s https://<host>/readyz           # {"status":"ok","database":"ok"}
curl -s https://<host>/v1/instance      # version, profile and sign-in methods
```

- **`CADENCE_VERSION is not set`** — run compose with
  `export CADENCE_VERSION=$(cat VERSION)` or use the scripts.
- **No certificate in the `tls` mode** — the domain must resolve to this
  machine and ports 80 and 443 must be reachable; Caddy retries by itself.
  Behind a corporate proxy use the `proxy` mode instead.
- **Agents hang on MCP calls behind a proxy** — the proxy buffers `/mcp/`;
  see [Behind your reverse proxy](#behind-your-reverse-proxy).
- **GitHub App: `Bad credentials`** — the key file is unreadable for uid
  65532 or the machine clock is off.
