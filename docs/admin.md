# Administrator guide

This guide takes a Cadence Lab installation from `./install.sh` to teams
working with agents: first sign-in, teams and invites, GitHub, single sign-on,
the CLI and agents, embeddings, backups and upgrades, monitoring. A cluster
of Kubernetes takes the Helm chart instead: [Kubernetes (Helm)](#kubernetes-helm).

Commands below run in the directory of the installation: where the package
of a release is unpacked (`./cadence` by default). For a direct
`docker compose` command export the version first:

```bash
export CADENCE_VERSION=$(cat VERSION)
```

`<host>` is the address people open: your domain in the `tls` mode, the
public address of your proxy in the `proxy` mode.

- [Install](#install)
- [Several installations on one machine](#several-installations-on-one-machine)
- [Behind your reverse proxy](#behind-your-reverse-proxy)
- [External PostgreSQL](#external-postgresql)
- [Secrets in files](#secrets-in-files)
- [Kubernetes (Helm)](#kubernetes-helm)
- [First sign-in with the administrator token](#first-sign-in-with-the-administrator-token)
- [Teams, projects and invites](#teams-projects-and-invites)
- [First cycle and roles](#first-cycle-and-roles)
- [GitHub App](#github-app)
- [Single sign-on with OIDC](#single-sign-on-with-oidc)
- [CLI and agents](#cli-and-agents)
- [Embeddings](#embeddings)
- [Backups](#backups)
- [Upgrades and rollback](#upgrades-and-rollback)
  ([releases and mirrors](#releases-and-mirrors),
  [moving a git installation](#moving-a-git-installation-to-release-packages))
- [Air-gapped installation](#air-gapped-installation): a registry mirror
  or an archive of the version, signatures verified offline
- [Monitoring](#monitoring)
- [Security](#security) ([audit log](#audit-log))
- [Verifying a release](#verifying-a-release)
  ([known scanner findings](#known-scanner-findings))
- [Troubleshooting](#troubleshooting)

## Install

One line downloads the package of the latest release, verifies it against
the `checksums.txt` of the release, unpacks it into `./cadence` and runs
`./install.sh` there with the flags after `sh -s --`:

```bash
curl -fsSL https://github.com/cadence-lab-tech/self-hosted/releases/latest/download/get-cadence.sh | sh -s -- --domain cadence.example.com
```

`get-cadence.sh` is a POSIX `sh` script and needs `curl`, `tar`,
`sha256sum` (or `shasum`) and Docker; git is not needed, and neither is
`bash`, except for a release whose scripts are still bash (v0.13.0 and
older, `--version`): then it checks for `bash` before it unpacks anything.
Its own flags:

| flag | variable | |
|---|---|---|
| `--version vX.Y.Z` | `CADENCE_INSTALL_VERSION` | the release to install, default the latest |
| `--dir DIR` | `CADENCE_INSTALL_DIR` | where to unpack, default `./cadence`; must not exist or be empty |
| | `CADENCE_RELEASES_URL` | a mirror of the releases, see [Releases and mirrors](#releases-and-mirrors) |
| | `CADENCE_VERIFY` | `auto` (default), `require` or `off`: what to do with the signatures, see [Verifying a release](#verifying-a-release) |

It stops before unpacking anything if the checksum does not match, if there
is no such release, or if the directory already has a `.env` (then
`./upgrade.sh` there is what you want). The checksum protects against a
broken or altered download, not against a release replaced at its source.
For that, from v0.9.0 `checksums.txt` and both images are signed by the
release workflows of our repositories, and `docker-compose.yml` of the
package pins the images by digest. With [cosign](https://docs.sigstore.dev/cosign/system_config/installation/)
3.x in `PATH` the installer verifies both: `get-cadence.sh` the signature
of `checksums.txt` before it creates the directory, `install.sh` the
signatures of the images before it asks anything, checks an external
database or writes `.env`:

```
✓ the signature of checksums.txt of v0.12.0 verified: signed by https://github.com/cadence-lab-tech/self-hosted/.github/workflows/release.yml@refs/heads/main
▸ verifying the signatures of the images of v0.12.0
✓ ghcr.io/cadence-lab-tech/sdlc-pipeline-backend@sha256:… is signed by https://github.com/cadence-lab-tech/sdlc-pipeline-backend/.github/workflows/release.yml@refs/tags/v0.12.0
✓ ghcr.io/cadence-lab-tech/sdlc-pipeline-frontend@sha256:… is signed by https://github.com/cadence-lab-tech/sdlc-pipeline-frontend/.github/workflows/release.yml@refs/tags/v0.12.0
```

Without `cosign` it warns once and installs, as before; a signature that
does not verify stops it with nothing installed. `CADENCE_VERIFY=require`
also refuses without `cosign`, `off` skips the check — the table of what
happens when is in [Verifying a release](#verifying-a-release).

### clab in the package

From the release after v0.13.0 the package carries `clab` of its own
version for Linux and macOS, amd64 and arm64 — `bin/clab-linux-amd64`,
`bin/clab-linux-arm64`, `bin/clab-darwin-amd64`, `bin/clab-darwin-arm64`
(the CLI only, not `clab-runner`) — and `install.sh`, `upgrade.sh`,
`backup.sh` and `restore.sh` are short POSIX `sh` wrappers: each picks the
`clab` of the machine by `uname -s` and `uname -m` and runs its
`clab server install`, `upgrade`, `backup` or `restore` on its own
directory with the arguments as given. One implementation serves the
scripts and `clab server`; the machine needs Docker and no `bash`,
`openssl` or `clab` of its own.

- **Flags, variables, `.env`** are those of the scripts before — they are
  the ones of `clab server`, which takes the same; `./install.sh --help`
  (and `--help` of the others) prints the help of its `clab server`
  command.
- **Exit codes:** 0 — done; 1 — refused or failed (`.env` exists, a taken
  name or port, a signature that does not verify, a backup of another
  version without `--ignore-version`, ...); 2 — a wrong argument (an unknown
  flag, a missing value). Before, `upgrade.sh`, `backup.sh` and
  `restore.sh` exited with 1 for an unknown flag too.
- **What they print for you to run next** is in the form of the scripts:
  the cron lines of `install.sh` are `/path/to/cadence/backup.sh …`, the
  rollback of a failed upgrade is `tar -xpzf backups/package-…` and
  `./restore.sh --yes …`, and a second `./install.sh` points at
  `./upgrade.sh`. All of it runs without `clab` in `PATH`.
- **Upgrades replace it.** The `clab` in `bin/` is a file of the package:
  `./upgrade.sh` puts the one of the new version in place with the rest,
  the package copy of the old version in `backups/` keeps the old one, and
  the rollback brings it back. It does not update the `clab` of people and
  agents, and it never touches a `bin/clab` of yours: the names differ.
- **The same installation with your `clab`.** `clab server … --dir
  /path/to/cadence` of the same version (or newer) manages an installation
  the scripts made, and the scripts one that `clab server install` made;
  `bin/clab-<os>-<arch> server status` shows its state.
- **A machine the package has no `clab` for** (another OS or CPU), or a
  `clab` that does not run there (a partition mounted `noexec`): the
  script exits with 1, names the platform, changes nothing and prints the
  way out — install `clab` of the version in `VERSION` from the tap and run
  it on the directory, or let the scripts run it:

  ```bash
  curl -fsSL https://raw.githubusercontent.com/cadence-lab-tech/homebrew-tap/main/install.sh | CLAB_VERSION=v0.14.0 sh
  clab server backup --dir /opt/cadence
  CADENCE_CLAB=/usr/local/bin/clab /opt/cadence/backup.sh   # the same through the script
  ```

  `CADENCE_CLAB` — the path of the `clab` the scripts run instead of the
  one in `bin/`, of the version in `VERSION` or newer.
- **How long.** The scripts stay, as wrappers, at least two minor releases
  after the first one with them; dropping them later is announced in the
  notes of a release first.

**With clab.** `clab` v0.8.0 and later installs the same way with one command
and needs neither `curl`, `tar`, `sha256sum` nor `bash` — only Docker
(`brew install cadence-lab-tech/tap/clab`, see [CLI and agents](#cli-and-agents)):

```bash
clab server install --domain cadence.example.com --email ops@example.com
clab server install --mode proxy --http-addr 127.0.0.1:8080 --yes
```

It downloads the package of the release with its `checksums.txt`, verifies
the checksum, unpacks the package, writes `.env` exactly as `install.sh`
does, starts the stack and prints the address, the administrator token
(once) and the cron line of the nightly backup. It takes the flags and
variables of `install.sh` from the table below, `--name` and `--yes`
(`-y`) included, and two of its own:

| flag | |
|---|---|
| `--version vX.Y.Z` | the release to install; default the latest release that is not newer than `clab` itself. A release newer than `clab` is refused with the command that updates `clab` |
| `--dir DIR` | the installation directory, default `$CADENCE_DIR`, else `./cadence`. It must not exist, be empty, or hold an unpacked package without `.env` — then that package is installed in place, with no download, and `--version` must match its `VERSION` |

Every refusal — a `.env` already there, a taken installation name, a busy
port, a missing domain in the `tls` mode, a checksum or a signature that
does not match — comes before `.env` is written, and nothing is changed.
From v0.12.0 it verifies the signatures as the scripts do, with the same
`CADENCE_VERIFY` and the same messages: of the package before the directory
is created, of the images before the answers; installed in place (`--dir`
with an unpacked package) it verifies the images only — there is no
downloaded `checksums.txt` to check. If the images cannot
be pulled or the stack does not become ready, `.env` is kept and the command
prints how to start the stack. The result is the same directory as with
`get-cadence.sh`: `clab server` and the scripts of the package both manage
it afterwards. `install.sh` of the package is this very command, run by the
`clab` in the package ([clab in the package](#clab-in-the-package)).

By hand, the same steps:

```bash
v=v0.6.0   # the release to install
curl -fsSLO https://github.com/cadence-lab-tech/self-hosted/releases/download/$v/cadence-self-hosted-$v.tar.gz
curl -fsSLO https://github.com/cadence-lab-tech/self-hosted/releases/download/$v/checksums.txt
sha256sum --ignore-missing -c checksums.txt
mkdir cadence && tar -xpzf cadence-self-hosted-$v.tar.gz -C cadence && cd cadence
./install.sh
```

With `clab` v0.8.0+ the last line can be `clab server install --dir cadence`
run next to the unpacked directory: it installs that package in place.

`install.sh` checks Docker, compose v2, free ports and the domain, asks for
the mode, writes `.env` (mode 600) with a generated database password,
administrator token and webhook secret, creates an empty
`compose.override.yml` for [local compose changes](#local-compose-changes),
pulls the images of `VERSION`, starts the stack and waits until it is ready.
It prints the address and the administrator token once; the token stays in
`.env`. With the one-line installer the flags below go after `sh -s --`, for
example `get-cadence.sh | sh -s -- --mode proxy --http-addr 127.0.0.1:8080 --team acme`;
through the pipe it has no terminal and asks nothing.

Flags and environment variables for an unattended run:

| flag | variable | |
|---|---|---|
| `--mode tls\|proxy` | `CADENCE_MODE` | default `tls` |
| `--domain` | `SDLC_DOMAIN` | `tls` mode: host name with a DNS record pointing here |
| `--email` | `ACME_EMAIL` | `tls` mode: Let's Encrypt notices |
| `--http-addr` | `CADENCE_HTTP_ADDR` | `proxy` mode: where Caddy listens, default `127.0.0.1:8080` |
| `--team`, `--team-name` | `SDLC_BOOTSTRAP_TEAM`, `SDLC_BOOTSTRAP_TEAM_NAME` | optional first team |
| `--with-starter` | | from v0.14.0: once the stack is up, create the starter project in the first team (`--team` is required), apply `bundles/starter.json` and activate its cycles; see [First cycle and roles](#first-cycle-and-roles) |
| `--project KEY` | | with `--with-starter`: the key of the project, 2-16 characters `A-Z`, `0-9` and `_` starting with a letter (asked in a terminal) |
| `--project-name NAME` | | with `--with-starter`: its display name, default the key |
| `--name` | `COMPOSE_PROJECT_NAME` | installation name on this machine, default `cadence`; see below |
| `--external-db URL` | `CADENCE_EXTERNAL_DB` | keep the data in your own PostgreSQL instead of the container; see [External PostgreSQL](#external-postgresql) |
| `--external-db-ca FILE` | `CADENCE_EXTERNAL_DB_CA` | the CA of that server: copied to `secrets/db-ca.pem`, `sslmode=verify-full` |
| `--yes` | | ask nothing (also when there is no terminal) |
| | `SDLC_ADMIN_TOKEN` | use this administrator token instead of generating one |

**A first project in the same command.** With `--with-starter` the
installation ends with a working project instead of an empty instance:

```bash
./install.sh --mode proxy --http-addr 127.0.0.1:8080 --team acme --with-starter --project ACME --yes
```

The team, the key and `bundles/starter.json` of the package are checked
before `.env` is written. Once the stack is up, the installer creates the
project `ACME` in the team `acme` with the administrator token, applies the
starter bundle and activates both cycles, then prints the address of the
project and the next steps: signing in, inviting a lead and people
(`clab invite create`), giving the team access (`clab team grant`) and the
first task. It talks only to the API of this installation, through its
Caddy on this machine (`proxy`: `CADENCE_HTTP_ADDR`; `tls`: `127.0.0.1:443`
with the certificate of your domain checked as usual, waiting up to
`CADENCE_READY_TIMEOUT` for Let's Encrypt), and stores the token nowhere
new. If this step fails, the stack keeps running and `.env` is kept; the
installer prints the command that finishes it, `clab server starter` with
the same team and key (see [First cycle and roles](#first-cycle-and-roles)).

`install.sh` runs once. With an existing `.env` it stops and changes nothing:
a new database password would no longer open the existing database volume.
Further changes go into `.env` by hand; apply them with
`docker compose up -d`, which recreates only the containers whose settings
changed.

**Installation name.** `--name` names this installation *on the machine*: it
is the Docker Compose project of the installation — the prefix of its
containers, volumes and network (`cadence-postgres-1`, `cadence_postgres`).
It is not related to projects inside Cadence Lab: teams, projects and tasks
are created in the UI, as many as you need, inside one installation. Most
machines run one installation and keep the default `cadence`. `install.sh`
writes the name into `.env` as `COMPOSE_PROJECT_NAME`, and from there
`docker compose`, the scripts and `clab server` take it. It refuses a name
another installation on this machine already uses — see the next section.

## Several installations on one machine

A machine can run more than one installation, for example a staging one next
to production. Each one needs its own directory, its own port (or domain)
and its own **installation name** — again, the name of the installation on
the machine (its Docker Compose project), not a project inside Cadence Lab:
one installation already holds any number of teams and projects, so a second
installation is for a separate instance, not for another project.

```bash
curl -fsSL https://github.com/cadence-lab-tech/self-hosted/releases/latest/download/get-cadence.sh | sh -s -- --dir cadence-stage --name cadence-stage --mode proxy --http-addr 127.0.0.1:8081
```

- The name lives in `.env` as `COMPOSE_PROJECT_NAME` (lowercase letters,
  digits, `-` and `_`). `docker compose` in the directory of the
  installation, `./backup.sh` from cron, `./upgrade.sh`, `./restore.sh` and
  `clab server --dir <installation>` all work with that installation and no
  other — nothing needs to be exported.
- `install.sh` takes the name from `--name`, else from `COMPOSE_PROJECT_NAME`
  in the environment, else `cadence`; `--name` and a different variable at
  once are refused. A name already in use on the machine — Docker has
  containers or volumes of that compose project — is refused before anything
  is written, with the directory of the installation that uses it: two
  installations under one name would share containers and volumes, and the
  new database password would break the existing one.
- `upgrade.sh`, `backup.sh`, `restore.sh` and `clab server backup`,
  `restore` and `upgrade` refuse when `COMPOSE_PROJECT_NAME` in the
  environment names another installation than the one in `.env`: the
  variable left in a terminal of the staging installation must not restore
  production. Run them without it (`unset COMPOSE_PROJECT_NAME`).
  `clab server status` only warns and reports the name in its `Name:` line.
- Installations made before v0.7.1 have no name in `.env` and remain
  `cadence` — the default in `docker-compose.yml`; upgrades do not edit
  `.env` and nothing changes for them. If such an installation was started
  with `COMPOSE_PROJECT_NAME` exported, the scripts refuse with the one step
  that fixes it — add the name to its `.env` once:

  ```bash
  echo COMPOSE_PROJECT_NAME=cadence-stage >> /opt/cadence-stage/.env
  ```

- Never change the name of a live installation: its volumes carry it, and
  under a new name compose would start with empty ones.
- A `docker compose` command typed by hand puts a `COMPOSE_PROJECT_NAME` of
  the environment above `.env`, and compose cannot refuse it: check
  `echo $COMPOSE_PROJECT_NAME` is empty before running compose commands in an
  installation directory.

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

## External PostgreSQL

By default the data lives in the `postgres` container of the stack and its
`postgres` volume. A company that runs its databases itself — Amazon RDS,
Google Cloud SQL, Azure Database for PostgreSQL, its own cluster — can keep
the data there instead. The stack then has no `postgres` container; the API
applies the schema to your database on start, as it does to its own.

```bash
curl -fsSL https://github.com/cadence-lab-tech/self-hosted/releases/latest/download/get-cadence.sh | sh -s -- --mode proxy --http-addr 127.0.0.1:8080 --external-db 'postgres://cadence:PASSWORD@db.internal:5432/cadence' --external-db-ca ./rds-ca.pem
./install.sh --domain cadence.example.com --email ops@example.com --external-db 'postgres://cadence:PASSWORD@db.internal:5432/cadence?sslmode=verify-full&sslrootcert=system'
clab server install --mode proxy --http-addr 127.0.0.1:8080 --external-db 'postgres://cadence:PASSWORD@db.internal:5432/cadence' --external-db-ca rds-ca.pem
```

Quote the URL: it has `?` and `&`. Percent-encode the characters of the
password that a URL reserves (`@` is `%40`, `/` is `%2F`, `%` is `%25`, `'` is
`%27`). The path to the CA may be relative: `get-cadence.sh` resolves it
before it changes into the new directory.

**Before anything is written** the installer checks the database twice: as
the service will see it — `/api dbcheck` of the backend image of `VERSION`,
the same driver and TLS as the API — and as the backup client will (`psql`
of `db-client`, below). It refuses, naming the cause and what to do, when the
URL does not parse or has a parameter the two do not read the same way; the
host is unreachable; TLS, the CA or the host name do not match; the password
is wrong; the server is older than 15 or newer than 18; `vector` is missing
(or older than 0.5.0) and the role cannot create it, and the same for
`pgcrypto`; the role cannot create objects in the schema `public`; the
database has tables that are not Cadence Lab's; or the schema of Cadence Lab
in it is newer than the images. A database that already holds the schema of
this or an older version is accepted with a warning: the installation takes
its data over. The directory stays as it was, without `.env`: fix the cause
and run `./install.sh` there again with the same flags (or
`clab server install --dir` the same directory). The same check runs by hand
at any time, read-only:

```bash
docker compose run --rm --no-deps -T api dbcheck          # add --json for a machine-readable report
```

`.env` gets `CADENCE_DB=external`, the URL in `SDLC_DATABASE_URL` (mode 600,
like the rest of `.env`; never printed by the scripts) and
`compose.external-db.yml` in `COMPOSE_FILE` after the file of the mode;
`POSTGRES_PASSWORD` stays empty. The external mode needs Docker Compose 2.20
or newer; the bundled mode keeps working on older ones.
The URL can live in a file of `secrets/` instead of `.env`
(`SDLC_DATABASE_URL_FILE`), or only its password
(`SDLC_DATABASE_PASSWORD_FILE`): [Secrets in files](#secrets-in-files),
"External database".

### Server, extensions and the role

- **PostgreSQL 15, 16, 17 or 18.** The backup client is PostgreSQL 18
  (`pgvector/pgvector:pg18-trixie`), whose `pg_dump` reads all of them.
- **Extensions `vector` (pgvector 0.5.0 or newer) and `pgcrypto`.** On a
  managed server only an administrative role may create `vector`; do it once,
  connected to the database of Cadence Lab:

  ```sql
  -- as rds_superuser (Amazon RDS), cloudsqlsuperuser (Cloud SQL),
  -- azure_pg_admin (Azure; allow-list VECTOR and PGCRYPTO in azure.extensions first)
  CREATE EXTENSION IF NOT EXISTS vector;
  CREATE EXTENSION IF NOT EXISTS pgcrypto;
  ```

  If the role of Cadence Lab may create them itself, the API does it on the
  first start.
- **A database and a role of their own, the role owning the database:**

  ```sql
  CREATE ROLE cadence LOGIN PASSWORD '...';
  CREATE DATABASE cadence OWNER cadence;
  ```

  The role needs no superuser and no `CREATEDB`: it creates the tables,
  indexes and functions of the schema in `public`. Without ownership of the
  database grant it the schema instead:
  `GRANT USAGE, CREATE ON SCHEMA public TO cadence;`. Do not share the
  database with other applications: the installer refuses foreign tables,
  and a restore removes every object of `public` it can.

### TLS and the URL

`SDLC_DATABASE_URL` is `postgres://USER:PASSWORD@HOST:PORT/DATABASE?PARAMETERS`
(the `key=value` form is not supported). `sslmode` must be named:

| `sslmode` | |
|---|---|
| `verify-full` | the certificate is signed by the CA of `sslrootcert` and names the host of the URL. The default with `--external-db-ca` |
| `verify-ca` | signed by that CA, any host name |
| `require` | encrypted, the server is not verified — the installer warns |
| `prefer`, `allow`, `disable` | possibly unencrypted — the installer warns loudly; only on a network you trust |

`verify-full` and `verify-ca` need `sslrootcert`: a file under `/secrets`
(`--external-db-ca FILE` copies it to `secrets/db-ca.pem` with mode 644, so
that the service, uid 65532, can read it) or `system` for a CA the system
trusts (a server behind a public CA). Without `sslmode` the installer
refuses: both clients would silently fall back to `prefer`. Amazon RDS
publishes its CA bundle at
<https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem>; Cloud SQL
and Azure offer theirs in the console.

The parameters the service (pgx) and the backup client (libpq) read the same
way are the only ones allowed: `host`, `port`, `dbname`, `user`,
`password`, `sslmode`, `sslrootcert`, `sslcert`, `sslkey`, `sslpassword`,
`sslsni`, `sslnegotiation`, `channel_binding`, `connect_timeout`,
`target_session_attrs`, `application_name`, `options`. Others — pool
settings such as `pool_max_conns` included — are refused by name: one of the
clients would read them differently or fail. A client certificate goes the
same way as the CA: put it into `secrets/` (readable by uid 65532) and name
`/secrets/<file>` in `sslcert` and `sslkey`.

### Connections and pools

The API and the worker hold a pool each, up to `SDLC_DB_MAX_CONNS`
connections (10), and wait `SDLC_DB_CONNECT_TIMEOUT` (30s) for the database
on start; set both in `.env`. The stack opens at most
`SDLC_DB_MAX_CONNS × (API replicas + 1 worker)` connections, plus one for a
backup or a restore; keep that below `max_connections` of the server minus
what other clients need. A connection pooler in front of the server
(PgBouncer, RDS Proxy) is supported only in `session` mode: the service holds
session advisory locks while it migrates and uses prepared statements, which
the `transaction` and `statement` modes break.

### Backups, restore and snapshots

`./backup.sh`, `clab server backup` and the backup step of an upgrade run
`pg_dump` of the backup client `db-client` (a container of the profile
`tools`, in the network of the installation, with `secrets/` as `/secrets`)
against `SDLC_DATABASE_URL`. The password reaches it as `PGPASSWORD`, never
on a command line. The files and their names are those of the bundled mode
(see [Backups](#backups)): the same dump without owners, privileges and
extensions, so a backup of the bundled database restores into an external
one and back.

`./restore.sh FILE` and `clab server restore FILE` check that the database
answers, stop the API and the worker, and in **one transaction** create the
extensions if they are missing (when the role may), remove every object of
the schema `public` except those of the extensions, and load the dump. No
`DROP DATABASE`, no connection to the database `postgres`, no superuser: the
role of the URL is enough. A failed load is rolled back and leaves the
database as it was.

`./backup.sh verify` and `clab server backup verify` load the dump into a
throwaway PostgreSQL on this machine (the image of `db-client`), not into
your server: nothing is created there (see
[Checking that a backup restores](#checking-that-a-backup-restores)).

Snapshots and point-in-time recovery of your provider complement the dumps;
`pg_dump` stays the backup the scripts know about. To go back to a snapshot:
restore it into a new instance with the tools of the provider, point
`SDLC_DATABASE_URL` in `.env` at it, run `docker compose run --rm --no-deps -T api dbcheck`,
then `export CADENCE_VERSION=$(cat VERSION) && docker compose up -d`. The
schema in the snapshot must be that of `VERSION`: a snapshot taken before an
upgrade goes with the package files of the old version
(`backups/package-<version>-<date>.tar.gz`), exactly as a dump does.

### Upgrades

`./upgrade.sh` and `clab server upgrade` need no `postgres` container. Before
the backup they check the database with the images of the new version and
the compose files of its package (`/api dbcheck`); a database they cannot
use stops the upgrade while nothing has changed. The printed rollback
(`tar -xpzf …` and `./restore.sh --yes …`) restores the backup into the same
external database.

### Moving from the bundled database

There is no automatic move; it takes one backup and one restore, with a
downtime of both:

1. Prepare the database, the role and the extensions as above; put the CA
   into `secrets/db-ca.pem` (mode 644) if the URL names it. Check them from
   the installation:
   `docker compose run --rm --no-deps -T -e SDLC_DATABASE_URL='postgres://…' api dbcheck --install`
   (in the bundled mode the variable has to be given explicitly like this).
2. Take a backup: `./backup.sh` (on v0.10.0 or later, whose dumps carry no
   owners and extensions).
3. Stop the stack: `docker compose down` (keep the volumes).
4. In `.env` set `CADENCE_DB=external`, `SDLC_DATABASE_URL='postgres://…'`
   and add `compose.external-db.yml` to `COMPOSE_FILE` after the file of the
   mode.
5. Create the containers on the new settings and restore the backup into the
   new database (the restore reaches the blobs volume through the `api`
   container, which `down` removed):
   `docker compose create && ./restore.sh --yes backups/cadence-<version>-<date>.sql.gz`
   — it starts the stack on the external database.
6. When everything is in place, remove the old volumes:
   `docker volume rm <name>_postgres <name>_pgdata` (`<name>_pgdata` holds
   the data of PostgreSQL 17 on an installation moved from it, see
   [PostgreSQL 18](#postgresql-18), and is empty otherwise).

A dump of a PostgreSQL 17 server names `transaction_timeout`, which servers
15 and 16 do not know; the restore drops that line, so moving to an older
external server works too.

## Secrets in files

`install.sh` writes the secrets of the installation into `.env` (mode 600),
and that stays the default. Where `.env` must hold no secrets — it is read
by whoever has the directory, it lands in backups of the machine, and its
values show up in `docker inspect` — every secret also comes from a file
(since v0.13.0; the images of earlier versions read no `*_FILE`):

- **`X_FILE` for every secret `X`.** The value is the path of a file inside
  the containers; its content is the value of `X`. A trailing newline (`\n`
  or `\r\n`) is cut, the lines inside a value (a PEM key) are kept. An empty
  `X_FILE` counts as unset, like an empty `X`.
- **One form at a time.** `X` and `X_FILE` both set stop the service on
  start with an error that names both — no silent choice. A value left in
  `.env` after the move to a file shows up at once instead of hiding behind
  the file.
- **A file that cannot be read stops the start:** missing, a directory,
  unreadable for the user of the container, or empty. The error names
  `X_FILE`, the path and the reason, never the content, and the process
  stops before it reaches the database or the network. The API then never
  becomes healthy; `docker compose logs api` shows the reason.
- **Values are never printed:** not in the logs of the API, the worker,
  `/api dbcheck`, `/api backup-s3`, the scripts and `clab server`, not in
  `GET /v1/instance`.
- **Where the files live.** `secrets/` of the installation is mounted as
  `/secrets` into `api` and `worker` (and `db-client` with an external
  database): `X_FILE=/secrets/<file>`. Docker secrets of
  `compose.secrets.yml` and of `compose.override.yml` are mounted as
  `/run/secrets/<name>`; name the file `secrets/<name>` after the secret.
  The scripts and `clab server` read a file themselves for an external
  database (below) and, in `clab server starter`, for the administrator
  token, and only from `secrets/`: `/secrets/<file>` and
  `/run/secrets/<name>` are `secrets/<file>` and `secrets/<name>` to them; a
  path elsewhere is refused before anything runs, naming the variable. A
  file you cannot read yourself (owned by 65532, mode `400`, as the table
  recommends) `clab server` reads with a one-off `alpine:3` container as
  root, like the blobs archive of a backup: `secrets/` mounted read-only, no
  network, no log of the container; the value comes back to `clab` only,
  never in arguments or output.

The secrets — this table matches the list in the code of the service, and a
new secret comes with a row here:

| Variable | File form | Read by | Owner and mode of the file |
|---|---|---|---|
| `SDLC_DATABASE_URL` | `SDLC_DATABASE_URL_FILE` | api, worker, `/api dbcheck`; external database: also `backup.sh`, `restore.sh`, `upgrade.sh`, `clab server` | your user, group 65532, `440` |
| `SDLC_DATABASE_PASSWORD_FILE` | the only form: the password put into the URL | api, worker, `/api dbcheck` (and the scripts with an external database) | bundled: 65532, group 999, `440`; external: your user, group 65532, `440` |
| `SDLC_ADMIN_TOKEN` | `SDLC_ADMIN_TOKEN_FILE` | api, `clab server starter` | 65532, `400` |
| `SDLC_GITHUB_TOKEN` | `SDLC_GITHUB_TOKEN_FILE` | api, worker | 65532, `400` |
| `SDLC_GITHUB_TOKEN_<NAME>` | `SDLC_GITHUB_TOKEN_<NAME>_FILE` | api, worker (tokens of repositories by their secret name) | 65532, `400` |
| `SDLC_GITHUB_APP_KEY_FILE` | a path already, no value form | api, worker | 65532, `400` ([GitHub App](#github-app)) |
| `SDLC_GITHUB_APP_CLIENT_SECRET` | `SDLC_GITHUB_APP_CLIENT_SECRET_FILE` | api | 65532, `400` |
| `SDLC_GITHUB_WEBHOOK_SECRET` | `SDLC_GITHUB_WEBHOOK_SECRET_FILE` | api | 65532, `400` |
| `SDLC_EMBEDDINGS_API_KEY` | `SDLC_EMBEDDINGS_API_KEY_FILE` | api, worker | 65532, `400` |
| `SDLC_VOYAGE_API_KEY` | `SDLC_VOYAGE_API_KEY_FILE` | api, worker | 65532, `400` |
| `SDLC_BLOB_S3_ACCESS_KEY_ID` | `SDLC_BLOB_S3_ACCESS_KEY_ID_FILE` | api, worker | 65532, `400` |
| `SDLC_BLOB_S3_SECRET_ACCESS_KEY` | `SDLC_BLOB_S3_SECRET_ACCESS_KEY_FILE` | api, worker | 65532, `400` |
| `SDLC_BLOB_S3_SESSION_TOKEN` | `SDLC_BLOB_S3_SESSION_TOKEN_FILE` | api, worker (not passed by `docker-compose.yml`: add it in `compose.override.yml`) | 65532, `400` |
| `OTEL_EXPORTER_OTLP_HEADERS` | `OTEL_EXPORTER_OTLP_HEADERS_FILE` | api ([Tracing](#tracing)) | 65532, `400` |
| `OTEL_EXPORTER_OTLP_TRACES_HEADERS` | `OTEL_EXPORTER_OTLP_TRACES_HEADERS_FILE` | api (not passed by `docker-compose.yml`: add it in `compose.override.yml`) | 65532, `400` |
| `BACKUP_S3_ACCESS_KEY_ID` | `BACKUP_S3_ACCESS_KEY_ID_FILE` | `/api backup-s3`, run by `backup.sh` and `clab server` as your user | your user, `400` |
| `BACKUP_S3_SECRET_ACCESS_KEY` | `BACKUP_S3_SECRET_ACCESS_KEY_FILE` | `/api backup-s3` as your user | your user, `400` |
| `POSTGRES_PASSWORD` | `POSTGRES_PASSWORD_FILE` | the `postgres` container (its image reads the file) | 65532, group 999, `440` — the same file as `SDLC_DATABASE_PASSWORD_FILE` |

The `AWS_*` variables the blob storage falls back to have no file form: the
names are not ours. Neither has the bare secret name of a repository token
kept for configurations made before the GitHub App.

**Owners and modes.** Without swarm a Docker secret is the file itself,
mounted read-only: the owner and the mode on the host are what the container
sees (`uid`, `gid` and `mode` of a compose secret do nothing there). The
service runs as uid 65532, the `postgres` image as uid 999, the scripts and
`/api backup-s3` as you. The directory `secrets/` keeps mode `711`: it can be
passed through but not listed. Hand a file over to the service with a
throwaway container, as for the key of the GitHub App:

```bash
docker run --rm -v "$PWD/secrets:/s" alpine:3 \
  sh -c 'chown 65532:65532 /s/admin_token && chmod 400 /s/admin_token && chmod 711 /s'
```

### compose.secrets.yml

The overlay `compose.secrets.yml` moves the two secrets every installation
has to Docker secrets: the password of the bundled database
(`secrets/postgres_password`: `POSTGRES_PASSWORD_FILE` of `postgres`,
`SDLC_DATABASE_PASSWORD_FILE` of api and worker) and the administrator token
(`secrets/admin_token`: `SDLC_ADMIN_TOKEN_FILE` of api). It goes into
`COMPOSE_FILE` right after the file of the mode — with an external database
before `compose.external-db.yml`, which turns the password of the bundled
database off again (the scripts refuse the other order):

```bash
COMPOSE_FILE=docker-compose.yml:compose.tls.yml:compose.secrets.yml:compose.override.yml
COMPOSE_FILE=docker-compose.yml:compose.proxy.yml:compose.secrets.yml:compose.external-db.yml:compose.override.yml
```

**Moving an installation from `.env`** (the stack keeps its data; the
password must be the very one in `.env`: `postgres` sets a password only
when it creates the volume, and a new one would lock the service out):

1. Write the two values of `.env` into files and hand them over:

   ```bash
   (umask 077 && set -a && . ./.env &&
     printf '%s\n' "$POSTGRES_PASSWORD" >secrets/postgres_password &&
     printf '%s\n' "$SDLC_ADMIN_TOKEN" >secrets/admin_token)
   docker run --rm -v "$PWD/secrets:/s" alpine:3 sh -c \
     'chown 65532:999 /s/postgres_password && chmod 440 /s/postgres_password &&
      chown 65532:65532 /s/admin_token && chmod 400 /s/admin_token && chmod 711 /s'
   ```

   With an external database there is no bundled password: write only
   `admin_token` and move the URL as described below.
2. In `.env` empty `POSTGRES_PASSWORD=` and `SDLC_ADMIN_TOKEN=`, and add
   `compose.secrets.yml` to `COMPOSE_FILE` as above.
3. Apply: `export CADENCE_VERSION=$(cat VERSION) && docker compose up -d`
   (or `./upgrade.sh` to the same or a newer version). Sign in with the same
   token: the data and the token are those of before.

A value forgotten in `.env` stops the API (`both SDLC_ADMIN_TOKEN and
SDLC_ADMIN_TOKEN_FILE are set: keep one of them`) or `postgres` (`both
POSTGRES_PASSWORD and POSTGRES_PASSWORD_FILE are set (but are exclusive)`):
empty it and run `docker compose up -d` again. The database is not touched.

**Back to `.env`:** put the values back into `POSTGRES_PASSWORD` and
`SDLC_ADMIN_TOKEN`, drop `compose.secrets.yml` from `COMPOSE_FILE`, run
`docker compose up -d` and delete the two files.

### Other secrets

Any other secret of the table goes as `X_FILE=/secrets/<file>` in `.env`
with the file in `secrets/`, owner and mode from the table, and an empty `X`:

```bash
# .env
SDLC_GITHUB_WEBHOOK_SECRET=
SDLC_GITHUB_WEBHOOK_SECRET_FILE=/secrets/github_webhook_secret
```

or as a Docker secret of `compose.override.yml`:

```yaml
# compose.override.yml
secrets:
  github_webhook_secret:
    file: ./secrets/github_webhook_secret
services:
  api:
    secrets: [github_webhook_secret]
    environment:
      SDLC_GITHUB_WEBHOOK_SECRET_FILE: /run/secrets/github_webhook_secret
```

Apply with `docker compose up -d`. The keys of the
[off-machine copy](#off-machine-copy) are read by `/api backup-s3`, which
`backup.sh` runs as you: `BACKUP_S3_ACCESS_KEY_ID_FILE=/secrets/backup-s3-key-id`
and `BACKUP_S3_SECRET_ACCESS_KEY_FILE=/secrets/backup-s3-secret-key`, both
files yours with mode `400` (`chmod 400 secrets/backup-s3-*`). Cron must run
the backup as the same user.

### External database

The URL with its password in a file — `SDLC_DATABASE_URL_FILE` — or the URL
without a password in `.env` and only the password in a file —
`SDLC_DATABASE_PASSWORD_FILE` (a URL with a password and the file together
are refused):

```bash
# .env, the URL in a file
SDLC_DATABASE_URL=
SDLC_DATABASE_URL_FILE=/secrets/db-url
# .env, only the password in a file
SDLC_DATABASE_URL='postgres://cadence@db.internal:5432/cadence?sslmode=verify-full&sslrootcert=/secrets/db-ca.pem'
SDLC_DATABASE_PASSWORD_FILE=/secrets/db-password
```

Both the service and the backup client need the file: `backup.sh`,
`restore.sh`, `upgrade.sh` and `clab server` read it on this machine as you
and give the password to `db-client` as `PGPASSWORD`, never on a command
line. So the file is yours and readable by the group 65532:

```bash
docker run --rm -v "$PWD/secrets:/s" alpine:3 sh -c "chown $(id -u):65532 /s/db-url && chmod 440 /s/db-url"
```

A file outside `secrets/` (`SDLC_DATABASE_URL_FILE=/etc/…` mounted by an
override) works for the service, but the backup refuses it before the dump,
naming the variable: keep the file in `secrets/`.
`docker compose run --rm --no-deps -T api dbcheck` reads the file as the
service does.

### Kubernetes

The same `X_FILE` variables carry secrets of Kubernetes into the pods: mount
the secret as a volume and point `X_FILE` at its keys (for the database
`SDLC_DATABASE_URL_FILE` or `SDLC_DATABASE_PASSWORD_FILE`). A key written
with `echo` ends with a newline; it is cut. A missing key stops the pod on
start, naming the variable. The Helm chart of Cadence Lab is built on this:
[Kubernetes (Helm)](#kubernetes-helm).

## Kubernetes (Helm)

Next to the compose package, Cadence Lab installs into a Kubernetes cluster
with the Helm chart `charts/cadence` of this repository, from v0.13.0. The
chart runs the same images of the same version — the API, the worker and
the UI as three Deployments — on your PostgreSQL and your S3 bucket, with
the secrets in Secrets of the cluster; the Ingress of the cluster takes the
place of the Caddy of the package. The settings are the `SDLC_*` variables
of `docker-compose.yml` with the same defaults. The chart has no database,
no Caddy and no volumes.

### What you need

- **Kubernetes 1.27 or newer and Helm 3.8 or newer** (charts from an OCI
  registry).
- **An ingress controller** that passes a stream through: MCP answers with
  server-sent events. The controller must not buffer the responses of
  `/mcp`, must keep a request open for an hour, and must take a request
  body of 64 MiB (the largest artifact). For ingress-nginx the annotations
  of the example below do it; for another controller set its equivalents.
- **PostgreSQL with pgvector**, as for an
  [external database](#server-extensions-and-the-role): the role, the
  extensions and `sslmode`. The pods reach it from the cluster.
- **An S3 bucket** and its keys: the pods of the API and of the worker share
  no volume, so artifact content lives in the bucket (`blobs.s3.bucket`).
- **The certificate of the host**: a Secret of type `kubernetes.io/tls`
  (cert-manager or yours) named in `ingress.tls.secretName`, or TLS that
  ends before the Ingress.
- **Pod Security `restricted`** for the namespace, from the chart 0.14.0:
  every pod meets it — the API, the worker, the precheck and the UI. The
  frontend image runs Caddy as uid 65532 on port 8080, and from the chart
  0.16.0 every container, the UI included, drops all capabilities and adds
  none. The charts 0.14.x and 0.15.x add to the UI the one capability
  `restricted` allows, binding ports below 1024: the Caddy binary of their
  image carried it as a file capability. The chart 0.13.0 needs
  `baseline`: its UI image runs as root.
- **The images of the version of the chart.** The chart runs the UI as
  uid 65532 on port 8080 with no capability added, which the frontend image
  does from v0.16.0. `image.tag` pointing at an older frontend image leaves
  the UI pod failing: the Caddy of v0.14.x and v0.15.x does not start
  (`operation not permitted`: its binary carries a file capability the pod
  does not have), an image before v0.14.0 (root, port 80 only) is never
  ready.

### The chart

The chart of a release is published with the release as an OCI artifact,
`oci://ghcr.io/cadence-lab-tech/charts/cadence`; its version is the version
of the package without the `v` (Cadence Lab v0.13.0 is the chart 0.13.0). It
is signed like `checksums.txt` of the package — see
[Verifying a release](#verifying-a-release):

```bash
helm show values oci://ghcr.io/cadence-lab-tech/charts/cadence --version 0.13.0
```

`image.backend.digest` and `image.frontend.digest` of the chart pin the
images by the same digests as `docker-compose.yml` of the version. A mirror
in `image.registry` keeps them (copy with `crane copy` or
`skopeo copy --all`); an empty digest drops the pin and is only for
development checks. `charts/cadence` of a checkout of this repository on the
tag `vX.Y.Z` is the same chart.

### Secrets

No secret goes into the values: Helm keeps the values of a release in a
Secret of its own and shows them with `helm get values`, and the chart
refuses a URL of the database with a password in `database.url`. The chart
refers to Secrets that exist before the installation and mounts their keys
read-only as files under `/secrets/<secret>/<key>`; every secret `X` of the
service gets `X_FILE` with that path ([Secrets in files](#secrets-in-files)).
`secrets.name` is the Secret, and each entry of `secrets.keys` names a key
in it — or `<secret>/<key>` of another Secret. An empty entry passes
nothing.

| `secrets.keys.` | the service gets | required |
|---|---|---|
| `SDLC_DATABASE_URL` | `SDLC_DATABASE_URL_FILE`: the URL with its password | one of the two |
| `SDLC_DATABASE_PASSWORD` | `SDLC_DATABASE_PASSWORD_FILE`: the password put into `database.url`, the URL without one | one of the two |
| `SDLC_ADMIN_TOKEN` | `SDLC_ADMIN_TOKEN_FILE` | yes |
| `SDLC_BLOB_S3_ACCESS_KEY_ID` | `SDLC_BLOB_S3_ACCESS_KEY_ID_FILE` | yes |
| `SDLC_BLOB_S3_SECRET_ACCESS_KEY` | `SDLC_BLOB_S3_SECRET_ACCESS_KEY_FILE` | yes |
| `SDLC_BLOB_S3_SESSION_TOKEN` | `SDLC_BLOB_S3_SESSION_TOKEN_FILE` | no |
| `SDLC_GITHUB_TOKEN` | `SDLC_GITHUB_TOKEN_FILE` | no |
| `SDLC_GITHUB_APP_KEY_FILE` | `SDLC_GITHUB_APP_KEY_FILE`: the private key of the [GitHub App](#github-app) | no |
| `SDLC_GITHUB_APP_CLIENT_SECRET` | `SDLC_GITHUB_APP_CLIENT_SECRET_FILE` | no |
| `SDLC_GITHUB_WEBHOOK_SECRET` | `SDLC_GITHUB_WEBHOOK_SECRET_FILE` | no |
| `SDLC_EMBEDDINGS_API_KEY` | `SDLC_EMBEDDINGS_API_KEY_FILE` | no |
| `SDLC_VOYAGE_API_KEY` | `SDLC_VOYAGE_API_KEY_FILE` | no |
| `OTEL_EXPORTER_OTLP_HEADERS` | `OTEL_EXPORTER_OTLP_HEADERS_FILE`, the API only: the headers of the exporter of [traces](#tracing) | no |
| `OTEL_EXPORTER_OTLP_TRACES_HEADERS` | `OTEL_EXPORTER_OTLP_TRACES_HEADERS_FILE`, the API only: the per-signal headers, replacing the ones above | no |

`secrets.githubTokens` maps the secret name of a repository token to its
key (`ACME: github-token-acme` gives `SDLC_GITHUB_TOKEN_ACME_FILE`), and
`secrets.files` mounts keys without a variable — the CA of the database for
`sslrootcert=/secrets/<secret>/<key>` of the URL. The worker gets no
sign-in or webhook secret and no headers of traces; the precheck only the
database.

A key missing in its Secret keeps the pod from starting: its events name
the Secret and the key (`kubectl -n cadence describe pod`). A key written
with `echo` ends with a newline; it is cut. Make the Secret from files, so
that no value is on a command line:

```bash
kubectl create namespace cadence
kubectl label namespace cadence pod-security.kubernetes.io/enforce=restricted
openssl rand -hex 32 | sed 's/^/sdlc_/' >admin-token
kubectl -n cadence create secret generic cadence \
  --from-file=admin-token --from-file=db-password --from-file=db-ca.pem \
  --from-file=s3-access-key-id --from-file=s3-secret-access-key
rm admin-token
```

Keep the administrator token where you keep the secrets of the cluster:
it is the first sign-in.

### Values

The example below is what the check of the chart installs, with your
addresses. Settings of `docker-compose.yml` go in `config.shared` (the API
and the worker, which must agree on them: the leases, the model of the
embeddings), `config.api` and `config.worker`, as variables with their
values — `config.shared.SDLC_LOG_LEVEL: debug`; `helm show values` lists
them with the defaults of compose. What compose fixes the chart fixes too
and refuses in `config`: `SDLC_ENV=production`, `SDLC_STRICT_GATES`,
`SDLC_MCP_ENABLED`, `SDLC_AUTO_MIGRATE` (the API only), `SDLC_TENANCY=single`,
`SDLC_PROJECT_CREATION=teams`. A variable that compose does not pass goes in
`extraEnv`; a secret is refused in both.

```yaml
# cadence-values.yaml
ingress:
  className: nginx
  host: cadence.example.com
  tls:
    secretName: cadence-tls
  annotations:
    nginx.ingress.kubernetes.io/proxy-buffering: "off"
    nginx.ingress.kubernetes.io/proxy-request-buffering: "off"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "3600"
    nginx.ingress.kubernetes.io/proxy-body-size: 64m
database:
  url: postgres://cadence@db.internal:5432/cadence?sslmode=verify-full&sslrootcert=/secrets/cadence/db-ca.pem
blobs:
  s3:
    bucket: acme-cadence
    endpoint: https://s3.eu-central-1.amazonaws.com
    region: eu-central-1
    prefix: cadence/
secrets:
  name: cadence
  keys:
    SDLC_DATABASE_PASSWORD: db-password
    SDLC_ADMIN_TOKEN: admin-token
    SDLC_BLOB_S3_ACCESS_KEY_ID: s3-access-key-id
    SDLC_BLOB_S3_SECRET_ACCESS_KEY: s3-secret-access-key
  files: [db-ca.pem]
config:
  shared:
    SDLC_LOG_LEVEL: info
```

`blobs.s3.pathStyle` is `true` by default, as the service has it; set it to
`false` for a provider that wants virtual-hosted addresses.

### Install

```bash
helm install cadence oci://ghcr.io/cadence-lab-tech/charts/cadence --version 0.13.0 \
  -n cadence -f cadence-values.yaml --wait --timeout 10m
```

1. A rendering without the database, the bucket, its keys, the
   administrator token or `ingress.host` stops before anything reaches the
   cluster, naming the missing key.
2. The hook `pre-install` runs `/api dbcheck --install` of the backend image
   of the version as a Job (`cadence-dbcheck`), with the secrets of the
   database only. A database it refuses — no `vector`, a wrong password, a
   weak `sslmode` the server refuses — fails `helm install` before any
   Deployment is created; `kubectl -n cadence logs job/cadence-dbcheck`
   names the reason, never the password. Fix the database or the Secret,
   `helm uninstall cadence -n cadence` and install again.
3. The API applies the migrations on start under an advisory lock: several
   replicas (`api.replicas`) start at once safely, one of them migrates.
   `/readyz` answers 200 after the migrations; the startup probe gives them
   `api.startupProbe.failureThreshold` x `api.startupProbe.periodSeconds`
   (ten minutes by default) before the pod is restarted.
4. The worker waits for the API as in compose: its init container asks
   `/readyz` of the Service `cadence-api` once and is restarted by the
   kubelet with a backoff until it answers, so on a long migration the
   worker starts up to a few minutes after the API.

Then sign in as described in the notes `helm install` prints, and go on
with [teams and projects](#teams-projects-and-invites) and the
[first cycle](#first-cycle-and-roles): from here everything is as in
compose. `clab auth login --host https://<host> --with-token` takes the
token from stdin.

### Upgrades and rollback

```bash
helm upgrade cadence oci://ghcr.io/cadence-lab-tech/charts/cadence --version 0.14.0 \
  -n cadence -f cadence-values.yaml --wait --timeout 10m
```

- **Back up first**, by the means of your database and bucket (below).
- **The precheck** (`pre-upgrade`, `/api dbcheck` of the new image) runs
  before anything changes: a refusal fails `helm upgrade`, the pods of the
  installed version keep running.
- **`Recreate`.** `api.strategy` and `worker.strategy` are `Recreate`: the
  old pods stop before the new ones start, the downtime is that of
  `./upgrade.sh`. Migrations only go forward, and the code of a version is
  not promised to run on the schema of the next; a `RollingUpdate` (old and
  new pods on one schema for a while) is your decision.
- **Rollback.** `helm rollback` does not take the schema back. When the new
  version does not come up, restore the database and the bucket from the
  backup made before the upgrade, then `helm rollback cadence -n cadence`
  (or install the chart of the version of the backup). A chart older than
  the schema must not run on it.
- Changing only the values (`--set config.shared.SDLC_LOG_LEVEL=debug`,
  the replicas) on the same version recreates the pods; the data stays.
- **From the chart 0.13.0 to 0.14.0 or newer, Pod Security.** A namespace
  of the chart 0.13.0 enforces `baseline`. Upgrade first, then tighten the
  namespace: the pods of 0.13.0 would be refused under `restricted` as soon
  as they restart, those of the new chart meet it. No warning from the dry
  run means every running pod meets it:

  ```bash
  kubectl label --dry-run=server --overwrite namespace cadence pod-security.kubernetes.io/enforce=restricted
  kubectl label --overwrite namespace cadence pod-security.kubernetes.io/enforce=restricted
  ```

### Backups

`backup.sh`, `restore.sh` and `clab server` belong to the compose package
and do not touch a cluster. Back up with the means of your platform:

- **The database:** the snapshots or point-in-time recovery of your managed
  PostgreSQL, or `pg_dump` with the options of
  [the dump contract](#backups-restore-and-snapshots) (without owners,
  privileges and the extensions `vector` and `pgcrypto`).
- **The bucket:** versioning of the bucket, or its replication to another
  one.
- **Restore** the database and the bucket to the same moment, then install
  the chart of the version that made the backup (a newer one migrates the
  schema forward, which is fine; an older one is not).

### Monitoring

The API (`cadence-api`, port `metrics`) and the worker
(`cadence-worker-metrics`) serve Prometheus metrics on port 9090 inside the
cluster: Services of type ClusterIP, never routed by the Ingress, without a
token — `/metrics` through the Ingress is the UI. Point a scrape job or your
ServiceMonitor at them, or set `metrics.podAnnotations: true` for a
Prometheus that discovers pods by `prometheus.io/*` annotations;
`metrics.enabled: false` turns the listeners off. The
[metrics](#metrics) and the [alert rules](#alert-rules) are the same as in
compose; traces go by `OTEL_*` in `config.api` ([Tracing](#tracing)), and
their headers, a secret, by `secrets.keys.OTEL_EXPORTER_OTLP_HEADERS`.

### Limits

The chart brings no PostgreSQL, no autoscaling (`api.replicas` and
`worker.replicas` are numbers), no PodDisruptionBudget, NetworkPolicy,
ServiceMonitor or PrometheusRule, and no backups of its own.

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

`install.sh --team platform --with-starter --project PLAT` creates the team
and the project with its roles and cycles in one go, and
`clab server starter` adds such a project on an installation that already
runs: see [First cycle and roles](#first-cycle-and-roles).

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
project has no roles and no cycle yet, so an invite or a token with `--roles`
is refused with `not_found` until they are set up: see
[First cycle and roles](#first-cycle-and-roles).

Project access levels are `viewer`, `agent` (takes tasks), `maintainer` (edits
the cycle and roles, approves) and `admin` (manages members and tokens). A
team gets access to a project as a whole:

```bash
clab team grant platform --project PLAT --level maintainer
```

The same is available in the UI: team pages and project settings. Someone
who has already signed in can be added directly, without an invite:
`clab team add platform user:alice --role lead`.

## First cycle and roles

A new project is empty: no cycle, no roles. Tasks cannot be created and
agents cannot be given a role until a maintainer sets them up. The package
ships a starter: `bundles/starter.json`, a bundle of five roles and two
cycles.

**One command (from v0.14.0).** The installer sets the starter up for you
with `--with-starter` (see [Install](#install)):

```bash
./install.sh --mode proxy --http-addr 127.0.0.1:8080 --team acme --with-starter --project ACME --yes
```

On a machine where Cadence Lab already runs - installed without the flag,
or after the step failed - `clab server starter` does the same on the
installation directory, with the administrator token of the installation
(`SDLC_ADMIN_TOKEN` in `.env`, or the file of `SDLC_ADMIN_TOKEN_FILE` in
`secrets/`, also when [compose.secrets.yml](#composesecretsyml) sets it; a
file owned by the service it reads with a one-off `alpine:3` container, see
[Secrets in files](#secrets-in-files)) and the team of
`SDLC_BOOTSTRAP_TEAM` unless `--team` names another:

```bash
clab server starter --dir /opt/cadence --project PLAT --team platform --project-name Platform
```

It creates the project if there is none, applies the bundle and activates
its cycles, and needs no sign-in. Running it again changes nothing: the
project exists, roles and cycles report `unchanged`, active cycles stay
active, and drafts the bundle left behind are activated. It never overwrites
rules of your own: if the project already has another instruction of a
starter role, or another active cycle for tasks or epics, it stops with
nothing changed and points at the manual path below
(`clab import --project PLAT --file bundles/starter.json --dry-run` shows
the difference). Teams' access to the project, invites and tokens stay
yours to give; it prints the commands.

**By hand.** `clab import` applies the bundle to a project:

```bash
export SDLC_PROJECT=PLAT
clab import --file bundles/starter.json --dry-run    # the report: what would be created
clab import --file bundles/starter.json              # roles, and both cycles as drafts
clab workflow list                                   # the two drafts and their ids
clab workflow activate <id of Starter>
clab workflow activate <id of Starter epics>
```

Imported cycles arrive as drafts, because an active cycle is never changed
in place: activation is a separate, deliberate step. Activating "Starter"
declares the task type `task`, "Starter epics" the type `epic`; from then on
tasks and epics can be created. Importing the same bundle again changes
nothing: roles report `unchanged` (a changed role instruction becomes a new
version of the role), and a cycle that matches an existing version, active
or draft, reports `unchanged` too. A changed cycle arrives as a new draft:
activate it if you meant to change the cycle. On v0.5.1 and older every
import creates a new draft of each cycle, whether it changed or not; leave
those drafts alone or activate the one you meant.

**What the starter contains.** Agents work as specialists, each on its own
status; a transition to the next status is closed by gates:

| status | role | leaves through | gates |
|---|---|---|---|
| New | — | Start | the tasks that block this one are closed (`clab relate A --to B --rel blocks`) |
| Analysis | `analyst` | Analysis done | `analysis.brief` and `analysis.acceptance_criteria` submitted; a human approval |
| Development | `developer` | Development done | `dev.change_summary` and `dev.test_report` submitted; an open pull request linked in every repository of the task |
| Review | `reviewer` | Review passed | `review.verdict` submitted and its `verdict` is `pass` |
| QA | `qa` | QA passed | `qa.report` submitted; a human approval |
| Done, Cancelled | — | | |

Every backward transition (back to analysis, back to development, QA
failed) requires a `problem.report` artifact, so a task never goes back
without a stated reason, and `cancel` is available from any status. A
task linked as blocked by another (`clab relate A --to B --rel blocks`, or
the orchestrator's breakdown of an epic) cannot start until the blocking
task is done or cancelled. Epics
run on "Starter epics": Planning → Breakdown (`orchestrator` splits the epic
into tasks, a human approves the breakdown) → In progress → Done, which is
held until every child task is closed.

The starter deliberately has no gates that need a GitHub App (CI status of
the pull request, drift of the code base under the task): it works on an
instance without one. The pull request gate only needs the link to the
pull request, which the agent sets (`clab link`, or `sdlc_link_repo_ref`
over MCP).

**Making it yours.** Roles and cycles are data of the project, not code.
Edit them in the UI (Roles, Cycle editor: a draft is edited and then
activated as a new version) or round-trip them through the CLI:

```bash
clab export > my-bundle.json        # repositories, roles, documents, the active cycles
# edit my-bundle.json
clab import --file my-bundle.json   # new role versions and a new draft of the cycle
```

A bundle also carries project documents (conventions, architecture notes,
glossaries) that agents read as context, and it can be applied to several
projects at once: `clab import --from PLAT --to WEB,MOBILE` copies the rules
of one project to others. `clab import-guide` prints instructions for an
agent that assembles a bundle from what is already written in your
repositories (`CLAUDE.md`, `CONTRIBUTING.md`, ADRs, review checklists).

**The first task.** With the cycles active:

```bash
clab create --title "Describe the first change" --repos my-repo   # a task; --type epic for an epic
clab transition PLAT-1 --to start                                 # New → Analysis
clab queue                                                        # what agents can pick up, and as which role
```

Give the agent its role. A person's agent gets the roles from the person's
membership: `clab invite create --project PLAT --level agent --roles analyst,developer`
(see above); an unattended agent gets a token with the roles:

```bash
clab token create --name analyst-bot --for agent:analyst-bot --project PLAT --roles analyst
```

On the developer's machine, `clab mcp install` registers the MCP server of
the project with the agent (see [CLI and agents](#cli-and-agents)); the
prompt `work_on_task` in it takes a task, submits the artifacts of the role's
contract and requests the transition. The gates that need a human —
"Approved by a human" after analysis and the final approval after QA — are
closed in the task card in the UI or from the CLI:

```bash
clab gates PLAT-1                                                  # what holds the transition
clab decide PLAT-1 --transition analysis_done --gate human_approval
```

Approvals are given by people, never by agents, in any configuration.

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

The client secret and the webhook secret can live in files of `secrets/`
instead of `.env`: `SDLC_GITHUB_APP_CLIENT_SECRET_FILE`,
`SDLC_GITHUB_WEBHOOK_SECRET_FILE` ([Secrets in files](#secrets-in-files)).

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

Every `clab` command, `clab version` and `clab auth login` included,
compares its version with the server's and prints a warning to stderr once
per command when the CLI is older than the server by any release, even a
patch:

```
clab: CLI v0.6.0 старше сервера v0.6.1 (https://cadence.example.com), обновите CLI:
  brew upgrade clab
  # или ровно версию сервера: curl -fsSL https://raw.githubusercontent.com/cadence-lab-tech/homebrew-tap/main/install.sh | CLAB_VERSION=v0.6.1 sh
```

A CLI installed with Homebrew is told `brew upgrade clab`, with the install
script and the server's `CLAB_VERSION` next to it; any other CLI is told
the install script. A CLI newer than the server by one minor version is
fine and stays quiet (Homebrew installs the latest release, and servers are
upgraded later); newer by more than that, it warns with the install script
and the server's version. The output, `--json` and the exit code do not
change, and nothing turns the warning off. The check needs clab v0.5.0 or
newer; the warning about a CLI older than the server by a patch or one
minor version comes with clab v0.6.1. Homebrew does not update the CLI by
itself: `brew upgrade clab` after a server upgrade - `./upgrade.sh` reminds
of it (upgrades from v0.6.1 on). Release archives for Windows are on the
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

### Connecting developers

Send your colleagues to `https://<host>/docs` (the "Подключение" item of the
side menu): the page has the commands for your instance and the project they
pick, each with a copy button - install the CLI, sign in, link the local
project, connect MCP by hand, and the list of agent skills. In short, after
`clab auth login`, in the root of a local clone of the project's repository:

```bash
clab setup                                  # MCP of the project + the agent kit in .claude/
clab setup --dry-run                        # what it would do, changing nothing
clab setup --scope user                     # the kit in ~/.claude/ and MCP for every directory
clab setup --agent other                    # no Claude Code: print the MCP configuration for another agent
```

`clab setup` registers the project's MCP server with Claude Code (as
`clab mcp install` does) and writes the agent kit - the skills `clab-work`,
`clab-run`, `clab-backlog`, `clab-status`, `clab-rules`, the reference
`clab-guide` and the sub-agent `clab-stage` - into `.claude/` of the
project, with a manifest `.claude/clab-kit.json`. The project comes from
`--project <KEY>`, `SDLC_PROJECT` or the `origin` remote. No token is
written to any of these files; `--scope project` with a token is refused,
as with `clab mcp install`.

The kit comes from your instance (`GET /v1/agent-kit`, open like
`/v1/instance`), and its version is the version of your server: after
`./upgrade.sh`, running `clab setup` again updates it. GitHub is needed only
to install the CLI, not for the kit. A second run changes nothing that is
already up to date, and files a developer edited after installation are
kept with a warning (`--force` overwrites them). A server released before
`clab setup` existed answers 404 there: `clab setup` then connects MCP only
and names the server's version.

One configuration (`~/.config/clab`) holds several hosts. The one you signed
in to last is the default; `--host` picks another for one command:

```bash
clab auth login --host https://cadence.acme.internal
clab --host https://cadence.acme.internal tasks
```

The CLI has no default host. Until you sign in with
`clab auth login --host https://<host>` (or set
`SDLC_API_URL=https://<host>/v1` in the environment), every command makes
no network request, prints this line to stderr and exits with code 1:

```
хост не настроен: clab auth login --host https://sdlc.example.com
```

`clab version` prints its own version and the same line, and exits with
code 0. The line is the CLI's own message, quoted as it prints it; it reads
"host is not configured". This is so from clab v0.10.1; older CLIs without
a host went to `http://localhost:8088`.

Agents that run unattended (CI, `clab-runner`) get a token of their own,
issued by a project or team admin, rather than a person's session:

```bash
clab token create --name ci --for agent:ci-bot --project PLAT --roles developer --days 90
```

`clab-runner` comes with `clab` (Homebrew and the release archives) and
takes its address and token from the environment only: it does not read the
configuration of `clab auth login`.

```bash
SDLC_API_URL=https://<host>/v1 SDLC_TOKEN=<token> SDLC_PROJECT=PLAT clab-runner
```

Without `SDLC_API_URL` the runner does not start: it logs an error naming
the variable and exits with code 2, before any request. This is so from
clab-runner v0.10.2; older runners without the variable went to
`http://localhost:8088/v1`.

### What the runner gives the agent

The runner's own token (`SDLC_TOKEN`) stays with the runner: it polls the
queue, claims tasks, keeps the lease alive, releases tasks and reports the
cost of a run. The agent it starts gets a **task token** instead: after the
claim the runner issues a token bound to the claimed stage run of that task
(`POST /v1/tasks/<KEY>/task-token`). With it the agent writes only to its
own task and run and reads only around that task, whatever the runner's
token or a person's session may do. The token
lives as long as the lease: it stops working on the transition, on release
and when the lease expires, and when the agent exits - successfully, with an
error, on `SDLC_RUNNER_TIMEOUT` or because the runner is stopping - the
runner also revokes it. The token is never written to the runner's log, to
the agent's command line or to the output of `SDLC_RUNNER_DRY_RUN` (a dry
run issues no token at all).

The agent gets the task token in two places, both in a temporary directory
(mode `0700`) removed after the agent exits:

- `mcp.json` - the MCP server `sdlc` of the project with
  `Authorization: Bearer <task token>`;
- `CLAB_CONFIG_DIR` - a `clab` configuration with this one host and the task
  token, so `clab` inside the agent goes with the task token, not with the
  configuration of the person who runs the runner. `clab whoami` there shows
  the task and the role of the run.

The agent does not inherit the runner's environment. It gets only these
variables, if the runner has them:

| Group | Variables |
|---|---|
| shell and user | `PATH`, `HOME`, `USER`, `LOGNAME`, `SHELL`, `TMPDIR`, `TERM`, `TZ`, `LANG`, `LC_*`, `XDG_*` |
| proxy and certificates | `HTTP_PROXY`, `HTTPS_PROXY`, `NO_PROXY` (and in lower case), `SSL_CERT_FILE`, `SSL_CERT_DIR`, `NODE_EXTRA_CA_CERTS` |
| git over SSH | `SSH_AUTH_SOCK` |
| Claude Code | `ANTHROPIC_*`, `CLAUDE_*` |

plus `SDLC_API_URL`, `SDLC_PROJECT`, `SDLC_TOKEN` (the task token) and
`CLAB_CONFIG_DIR`, which the runner sets itself. Anything else the agent
needs - `GH_TOKEN` for `gh`, `AWS_*` for Bedrock, the variables of your own
agent - name in `SDLC_RUNNER_ENV`, comma-separated, a trailing `*` for a
prefix:

```bash
SDLC_RUNNER_ENV=GH_TOKEN,AWS_* SDLC_API_URL=https://<host>/v1 SDLC_TOKEN=<token> SDLC_PROJECT=PLAT clab-runner
```

`GH_TOKEN` and `GITHUB_TOKEN` are not passed unless named there. Names
starting with `SDLC_` or `CLAB_` are never passed, even if named in
`SDLC_RUNNER_ENV`: the runner logs a warning at start and ignores them.

The default agent command runs Claude Code with `--strict-mcp-config`: the
agent sees only the `sdlc` server from the runner's `mcp.json`, not the MCP
servers in the Claude Code settings of the person running the runner (where
`clab mcp install` puts the person's own token). If you set your own
`SDLC_RUNNER_COMMAND`, isolating the MCP configuration of your agent is up
to you.

A runner talking to a server that cannot issue task tokens (older than
v0.11.0) logs a warning - the server does not issue a task token, the agent
got the runner's token - and starts the agent with the runner's token, as
before; the environment is still cleared. Upgrade the runner together with
the server: an older runner against a new server still hands the agent its
own token. Any other refusal to issue the token (the lease is lost or held
by someone else, no access, a server error) does not start the agent: the
runner releases the task with a note saying the task token was not issued
and why.

The limit of all this: without a sandbox the agent runs as the same user on
the same machine, so it can still read that person's `~/.config/clab` and
other files in their home directory. The task token keeps an honest agent
from reaching beyond its task by default; hard isolation of the agent's
process is the job of a sandbox, which is not part of the runner yet.

This is so from clab-runner v0.11.0.

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
database made inside the Postgres container, or with an
[external database](#external-postgresql) by the backup client `db-client` —
and, when artifact content
lives in the `blobs` volume (`SDLC_BLOB_S3_BUCKET` is empty), the archive of
that volume next to it, `….blobs.tar.gz`. A dump smaller than 1 KB is treated
as a failure, and so is a database that does not answer: no dump file is
left then. Backups older than `KEEP_DAYS` (14) are deleted;
`BACKUP_DIR` writes elsewhere. From v0.10.0 the dump is plain SQL without
owners, privileges and extensions (`pg_dump --no-owner --no-privileges
--exclude-extension`): it loads into an empty database as its owner, the
bundled one or an external one; the restore creates the extensions first.

Schedule it nightly for root (or a user in the `docker` group):

```bash
0 3 * * * /opt/cadence/backup.sh >> /opt/cadence/backups/backup.log 2>&1
0 5 * * 0 /opt/cadence/backup.sh verify >> /opt/cadence/backups/backup.log 2>&1
```

The second line checks every Sunday that the newest backup restores (see
[Checking that a backup restores](#checking-that-a-backup-restores)).
`./backup.sh --help` lists the commands and the variables.

With `clab` v0.7.0 or later the same backup is `clab server backup` — see
[Managing the installation with clab server](#managing-the-installation-with-clab-server).

Backups on the same machine protect against a bad upgrade or a mistaken
deletion, not against losing the machine: set up the
[off-machine copy](#off-machine-copy). With an S3 bucket for artifact
content (`SDLC_BLOB_S3_*`), that bucket is yours to back up (versioning or
replication): the backups then hold the database only.

### Off-machine copy

With a bucket in `.env`, every backup — the nightly one, `./backup.sh` by
hand and the one `upgrade.sh` takes — also goes to S3: AWS S3, MinIO,
Cloudflare R2, Yandex Object Storage, Timeweb S3 and other S3-compatible
storage.

```bash
# .env
BACKUP_S3_BUCKET=acme-cadence-backups
BACKUP_S3_ENDPOINT=https://s3.eu-central-1.amazonaws.com   # empty: the AWS endpoint of the region
BACKUP_S3_REGION=eu-central-1                               # empty: us-east-1
BACKUP_S3_PREFIX=cadence/                                   # empty: the root of the bucket
BACKUP_S3_ACCESS_KEY_ID=AKIA...
BACKUP_S3_SECRET_ACCESS_KEY=...
BACKUP_S3_PATH_STYLE=true                                   # empty: true; false - bucket.endpoint/key
BACKUP_S3_KEEP=14                                           # empty: 14
```

No restart is needed: the scripts read `.env` on every run. After the local
files are written, `./backup.sh` uploads under `BACKUP_S3_PREFIX`

- `cadence-<version>-<date>.sql.gz` — the dump;
- `cadence-<version>-<date>.blobs.tar.gz` — the archive of the `blobs`
  volume, when there is one;
- `cadence-<version>-<date>.sha256` — the sha256 of both, in the format of
  `sha256sum`, uploaded last: a backup without it is an upload that did not
  finish.

Large dumps go up in parts (multipart, 16 MiB each): the memory used does
not grow with the dump. Then the bucket keeps the newest `BACKUP_S3_KEEP`
complete backups and deletes the older ones — backups taken before an
upgrade count like the nightly ones. Only objects named
`cadence-vX.Y.Z-<date>.sql.gz`, `.blobs.tar.gz` or `.sha256` right under the
prefix are ever deleted; other objects of the bucket, and anything in
deeper "directories", are never touched. The local rotation (`KEEP_DAYS`)
stays as it is.

The output names what went where:

```
✓ 2026-10-20 03:00:04 /opt/cadence/backups/cadence-v0.10.0-20261020-030000.sql.gz (1.2M)
▸ uploading cadence-v0.10.0-20261020-030000.sql.gz to s3://acme-cadence-backups/cadence/
✓ uploaded cadence-v0.10.0-20261020-030000.sql.gz, cadence-v0.10.0-20261020-030000.blobs.tar.gz, cadence-v0.10.0-20261020-030000.sha256 to s3://acme-cadence-backups/cadence/ (1.4M)
✓ s3://acme-cadence-backups/cadence/ keeps 14 of BACKUP_S3_KEEP=14 backups; removed cadence-v0.10.0-20261006-030000
```

A failed upload — the network, the keys, no such bucket — prints the reason
(the HTTP status and the code of S3, never the keys), keeps the local backup
and the copies already in the bucket, and **exits with status 1**, so cron
mail and your monitoring see it. In `upgrade.sh` (and `clab server
upgrade`) it is only a warning: the upgrade goes on, its rollback uses the
local file. `./backup.sh --no-upload` takes one backup without the copy.

The upload runs in a throwaway container of the backend image (`/api
backup-s3`, v0.10.0+): the machine needs no `aws`, `rclone` or other tool,
and no other image is pulled. The keys reach it through its environment,
never on a command line, and are not printed.

The bucket: give the backups a bucket — or at least a prefix — and keys of
their own, allowed only to put, get, list and delete objects there (for AWS:
`s3:PutObject`, `s3:GetObject`, `s3:DeleteObject` on
`arn:aws:s3:::acme-cadence-backups/cadence/*` and `s3:ListBucket` on the
bucket with the prefix as a condition). Keep it in another account, region or
provider than the machine. Versioning or object lock on the bucket protects
the copies against a leaked key: with them the retention deletes only the
current versions. The copy is not encrypted by Cadence Lab: use the
encryption of the storage (SSE) and keep the keys out of reach of the
machine's other users (`.env` is mode 600), or keep them out of `.env`
altogether: `BACKUP_S3_ACCESS_KEY_ID_FILE` and
`BACKUP_S3_SECRET_ACCESS_KEY_FILE` take files of `secrets/`
([Secrets in files](#secrets-in-files)).

### Checking that a backup restores

```bash
./backup.sh verify                                               # the newest backup of VERSION
./backup.sh verify backups/cadence-v0.10.0-20261020-030000.sql.gz   # this file
clab server backup verify                                        # the same with clab v0.10.0+
```

`verify` takes the newest backup of the version in `VERSION` from the bucket
(when `BACKUP_S3_BUCKET` is set; it checks the sums of `.sha256` on the way
down), else from `backups/`, or the file you name. It loads the dump into a
**throwaway PostgreSQL** next to the stack — a container of the image of
the installation (`postgres`, or `db-client` with an external database) on a
network of its own — checks the schema with `/api dbcheck` of the images of
this version, counts the rows and reads the blobs archive through:

```
▸ verifying cadence-v0.10.0-20261020-030000.sql.gz (1.2M) from s3://acme-cadence-backups/cadence/
▸ loading it into a throwaway PostgreSQL (pgvector/pgvector:pg18-trixie); the stack keeps running
✓ loaded in 3s
✓ schema 51: the schema of the images of v0.10.0
✓ blobs archive cadence-v0.10.0-20261020-030000.blobs.tar.gz: 214 files
✓ backup cadence-v0.10.0-20261020-030000.sql.gz restores: schema 51, 4 projects, 312 tasks, 1480 artifacts
```

The running stack and its database are not touched — nothing stops, there
is no downtime — and with an external database nothing is created on your
server. The throwaway container, its volume and its network are removed
whatever the outcome, and so is the copy downloaded from the bucket. Exit
status: 0 — the backup restores; 1 — it does not, with the reason: a sum
that does not match (`the checksum of … does not match`: the copy in the
bucket is damaged or was changed), the error of `psql` on a dump that does
not load, a schema the images of this version do not take, a damaged blobs
archive, or `nothing to verify`. A backup of another version is refused
with the same hint as `restore.sh`; `--ignore-version` checks it anyway
and reports the version of its schema. With a bucket that has no backup of
this version yet (right after an upgrade, before the next nightly backup)
`verify` warns and checks the newest local one.

### Restoring on a new machine

When the machine is gone, the bucket has the backups:

1. Install Cadence Lab on the new machine ([Install](#install)), best the
   version of the backup — it is in the name of the backup,
   `cadence-v0.10.0-…`. With an external database point it at the database
   you restore into.
2. Put the `BACKUP_S3_*` lines into `.env` of the new installation.
3. Download the backup and restore it:

   ```bash
   ./backup.sh fetch                                   # the newest backup in the bucket
   ./backup.sh fetch cadence-v0.10.0-20261020-030000   # or this one
   ./restore.sh --yes backups/cadence-v0.10.0-20261020-030000.sql.gz
   ```

`fetch` writes the dump (and the blobs archive) into `backups/`, checks the
sums of `.sha256` and prints the `restore.sh` command; a damaged copy is
refused, and a file whose sum does not match never lands in `backups/` nor
replaces a file there. If the installed version is not
the version of the backup, `restore.sh` refuses and prints the command that
puts the package files of that version in place first, as for any backup
of another version (below). `clab server backup fetch` and
`clab server restore --yes` do the same. Without `fetch` any S3 client
works too: download the three files of the backup into `backups/`, check
them with `sha256sum -c cadence-<version>-<date>.sha256` and restore.

Then put back what is not in a backup: `secrets/` (the key of the GitHub
App, the CA of an external database) and the settings of `.env` you
changed — keep a copy of both somewhere safe, apart from the bucket.

### Restore

```bash
./restore.sh backups/cadence-v0.5.0-20261008-030000.sql.gz
clab server restore backups/cadence-v0.6.1-20261008-030000.sql.gz   # the same with clab v0.7.0+
```

It stops the API and the worker, drops and recreates the database from the
dump (with an external database: removes the objects of Cadence Lab and
loads the dump in one transaction, see
[External PostgreSQL](#backups-restore-and-snapshots)), puts the `blobs`
archive back if there is one, starts the stack and waits until it is ready. **Everything written after the backup is lost.** It
asks for confirmation; `--yes` skips it.

The backup must match the running version (`VERSION`). If it was taken on
another version, `restore.sh` refuses, says which one and prints the command
that puts the package files of that version in place first: the copy
`upgrade.sh` kept when it left that version, or else the package of its
release:

```bash
tar -xpzf backups/package-v0.6.0-20261008-030000.tar.gz && ./restore.sh backups/cadence-v0.6.0-20261008-030000.sql.gz
```

Versions before v0.6.0 have no package in their release, and an
installation that came from them with git has no copy of their files in
`backups/` either: its first upgrade ran the old `upgrade.sh`, which checked
the new tag out. For such a version the hint takes the files from git while
the directory is still a git clone (`--force`: the files of later packages
differ from the tag; `.env`, `secrets/`, `backups/` and
`compose.override.yml` are not tracked and stay as they are):

```bash
git -c advice.detachedHead=false checkout --force v0.5.3 && ./restore.sh backups/cadence-v0.5.3-20261008-030000.sql.gz
```

If the tag is not in the clone yet, the hint fetches it first:
`git fetch --tags origin && git -c advice.detachedHead=false checkout --force v0.5.3`
(the remote is `CADENCE_GIT_REMOTE`, `origin` by default). Without `.git` —
or without git on the machine — the hint unpacks the source archive of the
tag from GitHub over the directory:

```bash
curl -fsSL https://github.com/cadence-lab-tech/self-hosted/archive/refs/tags/v0.5.3.tar.gz | tar -xpzf - --strip-components=1 && ./restore.sh backups/cadence-v0.5.3-20261008-030000.sql.gz
```

That archive is the whole repository at the tag, so `ci/` and `.github/`
come with it, and the directory is no git clone: the `upgrade.sh` of v0.5.x
upgrades with git and cannot move it forward again. To come back to v0.6.0
or later from there, put the package files of that version in place by hand
and restore its backup, as for any other version
(`curl -fsSLO https://github.com/cadence-lab-tech/self-hosted/releases/download/v0.6.0/cadence-self-hosted-v0.6.0.tar.gz && tar -xpzf cadence-self-hosted-v0.6.0.tar.gz && rm cadence-self-hosted-v0.6.0.tar.gz`),
then upgrade with `./upgrade.sh` as usual. A mirror (`CADENCE_RELEASES_URL`)
carries only releases, so the source archive always comes from GitHub.

## Upgrades and rollback

```bash
./upgrade.sh            # the latest release
./upgrade.sh v0.6.0     # the release v0.6.0
clab server upgrade     # the same with clab v0.7.0+ (see "Managing the installation with clab server")
```

Each version is a release `vX.Y.Z` of this repository with the package of
that version; `VERSION` in it names the images, and from v0.9.0
`docker-compose.yml` pins them to the digests of that release, so the
upgrade pulls exactly the bytes that were signed, even if a tag in the
registry moves (see [Verifying a release](#verifying-a-release)). git is not
needed. The script:

1. finds the target — the latest release, or the one given — and refuses to
   go to an older version: migrations only go forward;
2. downloads the package of the release and verifies it against the
   `checksums.txt` of the release; with `cosign` 3.x it also verifies the
   signature of that `checksums.txt` and, once the package is unpacked
   aside, the signatures of both images of the new version — the digests
   its `docker-compose.yml` pins, with your `compose.override.yml` — before
   the external database is checked by them, before the backup and before
   any file changes. A signature that does not verify stops the upgrade
   with nothing changed; `CADENCE_VERIFY` in `.env` (or the environment)
   decides about no `cosign`, see [Verifying a release](#verifying-a-release);
3. compares the package files here with `package.sha256` of the running
   version and stops, listing them, if any was edited (keep your settings in
   `.env` and local compose changes in `compose.override.yml`, see below);
   `./upgrade.sh --force v0.6.0` replaces the edited files, and their edited
   copies stay in the package copy of step 5;
4. takes a backup of the current version; with an
   [external database](#external-postgresql) it first checks the database
   with the images of the new version and stops if they cannot use it;
5. keeps the current package files in
   `backups/package-<version>-<date>.tar.gz`, then replaces them with the new
   ones and removes the files the new package no longer has; `.env`,
   `compose.override.yml`, `backups/`, `secrets/` and files of your own are
   never touched;
6. pulls the images of the new version — if that fails, it puts the files
   back and the running stack is untouched;
7. starts the stack (the API applies migrations itself), reloads Caddy and
   waits for readiness (`CADENCE_READY_TIMEOUT`, 300 s), the routes of
   Caddy included from v0.16.0 (see [The UI on port 8080](#the-ui-on-port-8080));
8. reminds to update `clab` on the machines of people and agents to the new
   version: `brew upgrade clab`, or the install script of the tap with
   `CLAB_VERSION`, then `clab version` (see "CLI and agents"). The server
   does not update the CLI; until it is updated, every `clab` command warns
   that the CLI is older than the server. The upgrade runs the script of the
   version it starts from, so the reminder shows on upgrades from v0.6.1 on.

The upgrade runs the `upgrade.sh` of the version it starts from. The first
upgrade from v0.13.0 or older to a release with
[clab in the package](#clab-in-the-package) runs that old bash script: it
puts the wrappers and `bin/clab-*` (new files of the package) in place and
removes `lib.sh`, which the new package no longer has; its rollback brings
the bash scripts back. From then on `./upgrade.sh` is `clab server upgrade`
of the `clab` in `bin/`, which replaces itself with the `clab` of the new
version and, if the new version does not become ready, prints a rollback
that brings the old one back with the other package files. The first
upgrade to v0.12.0, the release that brings the verification, runs the old
script and verifies no signature (check them by hand, as in
[Verifying a release](#verifying-a-release), or upgrade with `clab server
upgrade` v0.12.0+, which verifies from the first upgrade on). Every later
`./upgrade.sh` verifies.

Skipping versions is fine, with one exception: from v0.13.0 or older
straight to v0.16.0 or newer. From v0.16.0 the UI listens on port 8080
only (see [The UI on port 8080](#the-ui-on-port-8080)), and the bash
`upgrade.sh` of v0.13.0 and older, like `clab` before v0.14.0, waits for
the UI on port 80: it never sees the new version ready, exits with an error
and prints the rollback, although the new version runs. So either go
through a release in between - `./upgrade.sh v0.15.0` (or v0.14.1), then
`./upgrade.sh` to the version you want - or run the upgrade with `clab`
v0.14.0 or newer, in the directory of the installation:

```bash
brew upgrade clab                 # or the install script of the tap, see "CLI and agents"
clab server upgrade v0.16.0       # or --dir /opt/cadence
```

An installation of v0.14.1 or newer upgrades with the `clab` of its
package, which waits for the UI on either port: nothing to do there.

On an arm64 machine (Apple Silicon, Graviton,
Ampere) the upgrade to v0.5.3 or later recreates `api`, `worker` and `ui`
from native linux/arm64 images instead of the amd64 ones that ran under
emulation before; `postgres`, `caddy` and the data are not affected. If the
new version does not become ready, the script exits with an error, shows the
logs and prints the rollback with the exact package copy and backup, for
example:

```
✗ v0.7.0 did not become ready in 300s (logs above). The database may already be migrated.
  To return to v0.6.0 and its backup:
  tar -xpzf backups/package-v0.6.0-20261008-030000.tar.gz   # package files of v0.6.0
  ./restore.sh --yes backups/cadence-v0.6.0-20261008-030000.sql.gz   # data as of the backup, starts v0.6.0
```

Releases are published as GitHub Releases of this repository; watch it
(Releases and Security alerts) to hear about them and about security fixes
(see [Security](#security)).

### The UI on port 8080

From v0.16.0 the `ui` container listens on port 8080 only; v0.14.x and
v0.15.x listen on 80 and 8080, older versions on 80 only. The `Caddyfile`
of the package goes to `ui:8080` and is replaced together with the image,
so the upgrade and its rollback need nothing from you.

What the package does not replace is yours to move: a `Caddyfile` edited by
hand and carried over after `upgrade --force`, a Caddyfile of your own
mounted in `compose.override.yml`, a proxy of your own in the network of
compose - anything that goes to port 80 of the UI (`ui` with no port or
with `:80`). Point it at `ui:8080` before the upgrade: port 8080 already
answers in v0.14.x and v0.15.x. Missed, the site answers 502 everywhere
but `/v1`, `/mcp`, `/webhooks`, `/healthz` and `/readyz`.

From v0.16.0 `clab server` (`install`, `upgrade`, `restore` and the
scripts over them) sees that: once the API and the UI answer, readiness
also asks the admin API of Caddy inside the `caddy` container
(`http://127.0.0.1:2019/reverse_proxy/upstreams`) for the upstreams of the
loaded configuration and asks each of them from there, and in proxy mode
asks `/` through the route (`http://localhost/` inside the container; only
502 and 504 count as a failure, a 401 of your basic auth or a 404 do not).
All of it is plain HTTP: in tls mode neither HTTPS nor `SDLC_DOMAIN` is
asked, so readiness does not wait for a certificate. A route that does not
reach its upstream for three steps in a row (about 9 s) ends the wait at
once with exit code 1, not after `CADENCE_READY_TIMEOUT` (`ui:PORT` is the
upstream of your route):

```
✗ the stack runs v0.16.0, but the upstream ui:PORT of the loaded Caddy configuration does not answer from the caddy container.
  The api and ui services are up (ui answers directly), but the site answers 502 everywhere except /v1, /mcp, /webhooks, /healthz and /readyz.
  The UI image listens on port 8080 only from v0.16.0: point the route of your Caddyfile at ui:8080, then reload Caddy:
  docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile
  Check the site: curl -sS -o /dev/null -w '%{http_code}\n' https://cadence.example.com/
  See docs/admin.md, "The UI on port 8080".
  The database may already be migrated: fixing the route needs no new upgrade. Or return to v0.15.0 and its backup:
  ...
```

The stack then runs the new version: fix the route rather than upgrade
again; the printed rollback is the other way out. A Caddyfile of your own
without the admin API (`admin off`, or `admin` on another address) gets a
warning instead - "the routes of Caddy are not checked", readiness is the
direct probes only (and `/` in proxy mode). A proxy of your own outside
the `caddy` container is not seen at all: check it with `curl`.

The upgrade to v0.16.0 itself runs the `clab` of the version it starts from
(see [Upgrades and rollback](#upgrades-and-rollback)): `./upgrade.sh` of
v0.15.x leaves the routes unchecked and reports the new version ready over
a route to port 80 of the UI. Move the route first, or run the upgrade with `clab`
v0.16.0, in the directory of the installation:

```bash
curl -fsSL https://raw.githubusercontent.com/cadence-lab-tech/homebrew-tap/main/install.sh | CLAB_VERSION=v0.16.0 sh
clab server upgrade v0.16.0                              # or --dir /opt/cadence
CADENCE_CLAB=/usr/local/bin/clab ./upgrade.sh v0.16.0    # the same through the script
```

The fix is the same `ui:8080` in your route, then:

```bash
docker compose exec -T caddy caddy reload --config /etc/caddy/Caddyfile   # or restart your own proxy
```

### PostgreSQL 18

The bundled database is PostgreSQL 18 on Debian 13
(`pgvector/pgvector:pg18-trixie`), its data in the volume `postgres`
(`<name>_postgres`), mounted at `/var/lib/postgresql` as the images of
PostgreSQL 18 and newer expect it. Earlier releases ran PostgreSQL 17 on
Debian 12 (`pgvector/pgvector:pg17`) with the data in the volume `pgdata`.
A new major version of PostgreSQL does not read the files of the old one,
so the first upgrade from a release on PostgreSQL 17 moves the data, without
a step of yours:

1. `docker compose up -d` of the new version - whichever `upgrade.sh` or
   `clab server upgrade` runs it, also the bash `upgrade.sh` of v0.13.0 -
   starts the one-off service `pg-upgrade-dump`: PostgreSQL 17 starts on the
   volume `pgdata` with no network, every database and role is dumped
   (`pg_dumpall`, compressed) into the volume `postgres`, and it stops;
2. then `pg-upgrade-load`: a new PostgreSQL 18 cluster is created next to
   its data directory, the dump is loaded into it, and only a complete
   cluster takes the place of the data directory; a mark of the move is
   written last;
3. then `postgres` starts on PostgreSQL 18, and the API and the worker on
   it. The cluster is new on Debian 13, so there is no
   `collation version mismatch` and nothing to `REINDEX`.

The upgrade waits for the move whatever its length - `up -d` returns when it
is done, and `CADENCE_READY_TIMEOUT` counts only after it. It takes about as
long as a backup and a restore of the database: minutes for a few gigabytes.
The free disk it needs is about the size of the database (the new cluster)
plus the compressed dump, which is removed after the load; the volume
`pgdata` stays as it was. Check before the upgrade:

```bash
docker compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d postgres -At -c "SELECT pg_size_pretty(sum(pg_database_size(oid))) FROM pg_database"'
df -h "$(docker info -f '{{.DockerRootDir}}')"
```

`clab` v0.15.0 and newer (`clab server upgrade`) says before the backup that
the upgrade moves the data, with the size of the database, and refuses with
nothing changed when the disk of the volumes has less free space than that.
Older `clab` checks nothing - and the first move is exactly when the
installation runs an older one: `./upgrade.sh` runs the `clab` in `bin/` of
the version it starts from (see [Upgrades and rollback](#upgrades-and-rollback)),
v0.14.x for a release on PostgreSQL 17, and the bash `upgrade.sh` of v0.13.0
or older has no `clab` at all. So for the first move either upgrade with
`clab` v0.15.0 or newer, in the directory of the installation:

```bash
curl -fsSL https://raw.githubusercontent.com/cadence-lab-tech/homebrew-tap/main/install.sh | CLAB_VERSION=v0.15.0 sh
clab server upgrade v0.15.0                              # or --dir /opt/cadence
CADENCE_CLAB=/usr/local/bin/clab ./upgrade.sh v0.15.0    # the same through the script
```

(`brew upgrade clab` does as well; on a closed network take
`bin/clab-<os>-<arch>` of the package in the archive of v0.15.0, see
[Air-gapped installation](#air-gapped-installation)), or check the free
space by hand as above and run `./upgrade.sh v0.15.0` as usual. Later
upgrades run the `clab` of v0.15.0 or newer from `bin/` and check by
themselves. What the move does is in the logs:

```bash
docker compose logs pg-upgrade-dump pg-upgrade-load
```

The settings of the old cluster that are not data: its `pg_hba.conf` is
carried over, `postgresql.conf` and `ALTER SYSTEM` (`postgresql.auto.conf`)
are not - the cluster starts with the settings of the image, and a setting
of yours goes into `compose.override.yml` as `command: postgres -c …`. A
`compose.override.yml` that mounts something at `/var/lib/postgresql/data`
of `postgres` stops it: the images of PostgreSQL 18 refuse to start with a
mount there. Mount it at `/var/lib/postgresql` instead.

**When the move fails** - no free space, the machine stops - `docker compose
up` fails, the upgrade prints the rollback, and `postgres` does not start on
a half-loaded cluster: without the mark the move is not done, and the next
`docker compose up -d` (or `./upgrade.sh`) starts it over. The volume
`pgdata` is not changed. Free the space and upgrade again, or run the
rollback as printed.

**The rollback** as the upgrade prints it - the package files of the
previous version and `./restore.sh --yes` of its backup - starts PostgreSQL
17 on the volume `pgdata` with the data of the backup. Upgrading again later
moves the data again: the old cluster changed after the move, so the data
written on the previous version since the rollback comes along. The
PostgreSQL 18 cluster of the earlier move (with what was written on the new
version before the rollback) is not deleted: the move keeps it aside in the
volume `postgres` as `cadence-upgrade/replaced-<date>`, and so it does with a
cluster an interrupted move left in place. Without a change of the old
cluster, `docker compose up -d` on the new version moves nothing: both
services log `nothing to do` and exit. If the old volume changes while
PostgreSQL 18 runs on the moved data - something started PostgreSQL 17 on it
by hand - `docker compose up -d` stops with an error and touches nothing:
remove the old volume (below) to keep PostgreSQL 18 as it is.

The clusters kept aside, and their removal once you do not need them:

```bash
export CADENCE_VERSION=$(cat VERSION)
docker compose run --rm --no-deps --entrypoint sh pg-upgrade-load -c 'du -sh /var/lib/postgresql/cadence-upgrade/replaced-*'
docker compose run --rm --no-deps --entrypoint sh pg-upgrade-load -c 'rm -rf /var/lib/postgresql/cadence-upgrade/replaced-*'
```

**Removing the old volume.** Once the new version runs and you will not
roll back to a release on PostgreSQL 17, the volume `pgdata` only takes
disk. Remove it with the stopped container that holds it, in the directory
of the installation:

```bash
docker compose rm -f pg-upgrade-dump
docker volume rm "$(grep '^COMPOSE_PROJECT_NAME=' .env | cut -d= -f2 | grep . || echo cadence)_pgdata"
```

The next `docker compose up -d` creates it again empty, and
`pg-upgrade-dump` finds nothing to move. A rollback after that is a restore
of a backup on an empty volume - the `./restore.sh` of the previous version
creates the database and loads it as on a new machine.

### Releases and mirrors

Each release `vX.Y.Z` carries assets with names that do not change:
`cadence-self-hosted-vX.Y.Z.tar.gz` (the package: compose files, Caddyfile,
`.env.example`, `VERSION`, the scripts, `bin/clab-<os>-<arch>` — from the
release after v0.13.0, `clab` of the version, so a mirror needs nothing
else for the scripts —, `bundles/`, `docs/`, `README.md`, `LICENSE`,
`SECURITY.md` and `package.sha256`), `checksums.txt`,
`get-cadence.sh` and, from v0.9.0, `checksums.txt.sigstore.json` — the
signature of `checksums.txt` (see [Verifying a release](#verifying-a-release)). A
machine that cannot reach GitHub takes them from a mirror:
`CADENCE_RELEASES_URL` points `get-cadence.sh` and `upgrade.sh` at any
HTTP(S) address or directory (`file:///srv/cadence-releases`) with the
layout

```
download/v0.9.0/cadence-self-hosted-v0.9.0.tar.gz
download/v0.9.0/checksums.txt
download/v0.9.0/checksums.txt.sigstore.json
download/v0.9.0/get-cadence.sh
latest/download/…              # a copy of the latest release, for "the latest"
```

The images come from `ghcr.io/cadence-lab-tech`, or from a registry mirror
in `CADENCE_REGISTRY` in `.env`. `docker-compose.yml` pins them by digest
(`sdlc-pipeline-backend:v0.9.0@sha256:…`), so a mirror must keep the digests:
copy the whole index with all its platforms and attestations, for example
`crane copy ghcr.io/cadence-lab-tech/sdlc-pipeline-backend:v0.9.0 mirror.example.com/cadence/sdlc-pipeline-backend:v0.9.0`
or `skopeo copy --all docker://… docker://…`; a mirror that rebuilds or
re-pushes single-platform images has other digests, and the pull fails.
Signatures are checked against `ghcr.io` by the same digest. From the
release after v0.12.0 the `caddy` service runs the frontend image too, so
the mirror needs no `caddy:2-alpine`; `pgvector/pgvector` still comes from
Docker Hub (or your Docker Hub mirror), two tags of it: `pg18-trixie` (the
database, and the backup client of an external database) and `pg17` (the
move from PostgreSQL 17, see [PostgreSQL 18](#postgresql-18)); the upgrade
pulls both, and a mirror without one of them fails the pull with the stack
untouched. `clab server images list` prints every image a version needs
([Air-gapped installation](#air-gapped-installation)).

A mirror of the releases must keep `checksums.txt.sigstore.json` of every
release from v0.9.0 on: with `cosign` on the machine, a release without it
is refused even with `CADENCE_VERIFY=auto` (a dropped signature is no
reason to skip the check) — copy the asset to the mirror, or set
`CADENCE_VERIFY=off`. A machine that reaches neither `ghcr.io` nor Sigstore
verifies offline when the mirror of the releases also holds
`download/vX.Y.Z/trusted_root.json` of Sigstore — `clab server images
load` puts it there, with the signatures of the images in the archive or
in your registry mirror: see [Air-gapped installation](#air-gapped-installation).
Without it such a machine cannot verify: `auto` warns `images not
verified: ghcr.io is unreachable from this host` and goes on, `require`
refuses.

### Moving a git installation to release packages

Installations made before v0.6.0 are git clones of this repository, and
their `upgrade.sh` works with git. The first upgrade to v0.6.0 or later runs
that old script as before — `./upgrade.sh v0.6.0` checks out the tag
`v0.6.0` — and brings in the new scripts. From then on `upgrade.sh` takes
release packages: it does not need git, does not mind `.git` either, and
`.git` can be removed (`rm -rf .git .gitignore .github ci`, all of them
leftovers of the clone). While you might still go back to a version before
v0.6.0, keep `.git`: such a version has no package, and in a clone the way
back is a `git checkout` of its tag; without `.git` it is the source archive
of the tag (see [Backups](#backups)).

The old script refuses to run over edited tracked files. If you edited any
(the usual one is `docker-compose.yml`), move the change into
`compose.override.yml` (below), put the file back with
`git checkout -- docker-compose.yml`, then upgrade. If you had
`docker-compose.override.yml` listed in `COMPOSE_FILE`, it keeps working;
new installations name the file `compose.override.yml`.

### Local compose changes

Do not edit the package files: `upgrade.sh` stops over local edits of them.
Put compose additions into `compose.override.yml`. `install.sh` creates it
empty and lists it last in `COMPOSE_FILE` in `.env`, so `docker compose` and
the scripts read it with no further edit, and `upgrade.sh` never touches it:

```yaml
# compose.override.yml
services:
  api:
    extra_hosts: ["host.docker.internal:host-gateway"]
  worker:
    extra_hosts: ["host.docker.internal:host-gateway"]
```

Apply it with `docker compose up -d`. An installation from before v0.6.0 has
no such file and its `COMPOSE_FILE` does not list one: create the file and
append `:compose.override.yml` to `COMPOSE_FILE` in `.env`. `upgrade.sh`
warns when an override file exists but `COMPOSE_FILE` does not list it.

A Caddyfile or a proxy of your own that serves the UI goes to `ui:8080`:
from v0.16.0 it is the only port of the UI, and a route to its port 80
answers 502 after the upgrade (see [The UI on port 8080](#the-ui-on-port-8080)).
From v0.16.0 `clab server` refuses to call such a stack ready; a Caddyfile
of your own with `admin off` is not checked, with a warning.

## Air-gapped installation

A machine without internet access gets a version from a registry mirror of
your network or from one archive you carry over. Both keep what an
installation with internet access has: the images run by the digests
`docker-compose.yml` pins, and the signatures of the package and of both
images are verified — offline, with the `trusted_root.json` of Sigstore that
comes along. It takes `clab` of the release after v0.14.1 or newer
(`clab server images`); an archive of a version is loaded by `clab` of that
version or newer.

### What a version needs

```bash
clab server images list --version v0.15.0     # a release: its package is downloaded and its signature verified
clab server images list --dir /opt/cadence    # the version of an installation, with CADENCE_REGISTRY of its .env
```

It prints one line per image: every image of the compose files of the
package in every profile (the bundled PostgreSQL, the client of an external
one, the move from PostgreSQL 17), and `alpine:3`, which `clab server` runs
itself for backups, restores and reading a file of `secrets/` it cannot read
as your user. Our two images come with their tag and digest, the others by
tag:

```
alpine:3
ghcr.io/cadence-lab-tech/sdlc-pipeline-backend:v0.15.0@sha256:…
ghcr.io/cadence-lab-tech/sdlc-pipeline-frontend:v0.15.0@sha256:…
pgvector/pgvector:pg17
pgvector/pgvector:pg18-trixie
```

The list comes from the compose files of the version, never from a list in
this guide: it changes with them.

### Tools

Besides Docker the closed machine needs, to load an archive,
[regctl](https://github.com/regclient/regclient/releases) v0.9.2 or later
(it copies the images with their signatures) and, to verify,
[cosign](https://github.com/sigstore/cosign/releases) 3.x. Both are single
static binaries: download them where you have access, check them, carry them
with the archive and put them into `PATH`.

```bash
# cosign: the sum from the checksums of its release
curl -fsSLO https://github.com/sigstore/cosign/releases/download/v3.1.3/cosign-linux-amd64
curl -fsSL https://github.com/sigstore/cosign/releases/download/v3.1.3/cosign_checksums.txt | grep ' cosign-linux-amd64$' | sha256sum -c
# regctl: its signature, made by the release workflow of regclient
curl -fsSLO https://github.com/regclient/regclient/releases/download/v0.9.2/regctl-linux-amd64
curl -fsSL https://github.com/regclient/regclient/releases/download/v0.9.2/metadata.tgz | tar -xz regctl-linux-amd64.sig regctl-linux-amd64.pem
chmod +x cosign-linux-amd64 regctl-linux-amd64
./cosign-linux-amd64 verify-blob --certificate regctl-linux-amd64.pem --signature regctl-linux-amd64.sig \
  --certificate-identity https://github.com/regclient/regclient/.github/workflows/go.yml@refs/tags/v0.9.2 \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com regctl-linux-amd64
install -m 755 cosign-linux-amd64 /usr/local/bin/cosign
install -m 755 regctl-linux-amd64 /usr/local/bin/regctl
```

Without `regctl` (or with one older than v0.9.2) `save` and `load` stop
before they do anything and say where to get it. Without `cosign`
`CADENCE_VERIFY` decides as everywhere ([Automatic verification](#automatic-verification)):
`auto` warns once and goes on, `require` refuses, `off` does not verify.

### A registry mirror of your network

Copy our two images into it with the whole index — every platform, the
attestations, the signature and the OpenVEX — so that the digests stay and
the signatures can be verified there:

```bash
regctl image copy --referrers ghcr.io/cadence-lab-tech/sdlc-pipeline-backend:v0.15.0 registry.corp.example/cadence/sdlc-pipeline-backend:v0.15.0
regctl image copy --referrers ghcr.io/cadence-lab-tech/sdlc-pipeline-frontend:v0.15.0 registry.corp.example/cadence/sdlc-pipeline-frontend:v0.15.0
```

(`crane copy` and `skopeo copy --all` keep the digests too, but not the
signatures.) Set `CADENCE_REGISTRY=registry.corp.example/cadence`: the
installers write it to `.env` from the environment, and `image.registry`
for [Helm](#kubernetes-helm). `CADENCE_REGISTRY` covers our images only:
`pgvector` and `alpine` come by tag from Docker Hub — through a Docker Hub
mirror of your network (`registry-mirrors` of Docker), or from an archive as
below, which loads them into Docker of the machine in either case. The
releases of the package come from a [mirror of the releases](#releases-and-mirrors);
for offline verification it also needs `download/vX.Y.Z/trusted_root.json`,
which an archive brings.

### An archive

On a machine with internet access (GitHub, `ghcr.io`, Docker Hub, Sigstore),
Docker, `regctl` and `cosign`:

```bash
clab server images save --version v0.15.0 --output cadence-v0.15.0-airgap.tar
```

The archive — about 0.8 GB — holds every image of the version with all its
platforms (ours with their signatures, attestations and OpenVEX), the
release of the package (`download/v0.15.0/`: the package with `bin/clab-*`,
`checksums.txt` and its signature, `get-cadence.sh`) with the
`trusted_root.json` of Sigstore, and the image of the temporary registry
that `load` runs. `save` verifies the signature of `checksums.txt` and of
both images before it writes anything, writes the archive next to
`--output` and renames it (a failure leaves nothing, an existing file is not
overwritten) and prints its SHA-256. The trust in the archive on the other
side is the trust in its transfer: **compare the SHA-256 on the closed
machine** with the one `save` printed, over a channel other than the one
that carried the archive.

On the closed machine — no access to the internet is needed:

```bash
sha256sum cadence-v0.15.0-airgap.tar
tar -xf cadence-v0.15.0-airgap.tar download/v0.15.0/cadence-self-hosted-v0.15.0.tar.gz   # the clab of the version, if the machine has none
tar -xzf download/v0.15.0/cadence-self-hosted-v0.15.0.tar.gz bin/clab-linux-amd64
bin/clab-linux-amd64 server images load cadence-v0.15.0-airgap.tar
bin/clab-linux-amd64 server images load cadence-v0.15.0-airgap.tar --registry registry.corp.example/cadence   # or into your registry
```

`load` verifies before anything reaches Docker or your registry: the
checksum of the package and the signature of `checksums.txt` with the
`trusted_root.json` of the archive, then the signatures of both images in a
temporary registry on `127.0.0.1` that it runs from the archive and removes
in any outcome, `Ctrl-C` included (an interrupted `load` says only
`✗ interrupted. Nothing was loaded.`; with `--registry`, once our images
have reached your registry, it names them instead). The digests it checks are the pins of the
signed package, not of the archive. Every Sigstore bundle attached to our
images must verify for the identity of the release — a bundle altered or
slipped in next to a genuine one is not carried on — and the OpenVEX of
both images is verified as an attestation too (`cosign verify-attestation
--offline --type openvex`), so a scanner that reads it from your registry
reads ours. A signature or an OpenVEX that does not verify stops it:
`✗ … did not verify …`, nothing loaded.

**Only what is verified leaves the archive.** `load` copies each image
without its referrers, then — one by one — the Sigstore bundles it has just
verified: the signature and the OpenVEX of our two images. Any other
referrer in the archive goes neither to the temporary registry nor to
yours: an unsigned OpenVEX (as `oras attach` puts it), an in-toto statement,
anything attached to a platform manifest rather than to the index, and every
bundle when signatures are not verified (`CADENCE_VERIFY=off`, `auto`
without `cosign`, an archive without `trusted_root.json`). One line names
what was left out, and it does not change the outcome:

```
! not carried from the archive, not a verified Sigstore bundle of the release: application/vnd.openvex+json of sdlc-pipeline-backend
```

A genuine archive prints no such line. The attestations of BuildKit (SBOM
and provenance) are manifests inside the index of the image, under its
signed digest: they travel as part of the image, and `regctl` lists them as
referrers of the platform manifests in any registry it copies the image to.
Load with the same `CADENCE_VERIFY` you install with: loaded without
verification, your registry has no signatures, and an installation that
verifies against it refuses.

Then:

- **without `--registry`** the images are pulled from the temporary registry
  into Docker of this machine and tagged as the compose files name them;
- **with `--registry HOST[/PATH]`** our two images go to your registry with
  the same digests and their verified signature and OpenVEX (the credentials are those of
  `docker login`, TLS settings those of your `regctl`), the others into
  Docker of this machine. It prints the `CADENCE_REGISTRY` to use.

Either way it puts the release next to the archive, in
`download/v0.15.0/` — the mirror of the releases for
`CADENCE_RELEASES_URL=file://…` — changes no `.env` and prints the next
command. Loading the same archive again changes nothing.

**The image store of Docker.** Without `--registry` the compose files find
our images by tag *and digest* only with the
[containerd image store](https://docs.docker.com/engine/storage/containerd/)
of Docker (`docker info` shows `driver-type io.containerd.snapshotter.v1`;
the default of new installations of Docker 29). The classic `overlay2`
storage cannot keep the digest of a pulled-and-tagged image: on it `load`
refuses — `✗ after docker pull and docker tag, … is not found by its
digest` — removes what it added, and names both ways out: turn the
containerd image store on (`{"features": {"containerd-snapshotter": true}}`
in `/etc/docker/daemon.json`, then restart Docker; the images of the classic
storage are not visible after the switch, load or pull them again) or load
into a registry with `--registry`. Do not empty `CADENCE_BACKEND_DIGEST` to
get around it: that drops the guarantee of the pins.

### Install, upgrade and roll back without network

```bash
# without a registry: the images are in Docker of this machine
CADENCE_RELEASES_URL=file:///srv/airgap bin/clab-linux-amd64 server install --version v0.15.0 --mode proxy --http-addr 127.0.0.1:8080
# with your registry
CADENCE_REGISTRY=registry.corp.example/cadence CADENCE_RELEASES_URL=file:///srv/airgap bin/clab-linux-amd64 server install --version v0.15.0 --mode proxy
# the one-line installer of the release does the same
CADENCE_RELEASES_URL=file:///srv/airgap sh /srv/airgap/download/v0.15.0/get-cadence.sh --version v0.15.0 --mode proxy
```

(`/srv/airgap` — the directory of the archive, where `load` put
`download/`.) With `cosign` the installation verifies `checksums.txt` with
the `trusted_root.json` of that mirror once Sigstore does not answer, and
the images once `ghcr.io` does not answer: in `CADENCE_REGISTRY` offline,
by digest; without a registry it takes an image that is in Docker of this
machine exactly by the reference of the compose files, pin included, as
verified — `load` verified its signature, and its digest is the pin of the
signed package: `✓ … verified when loaded: same digest as the pin of the
signed package`. `CADENCE_VERIFY=require` passes either way. Our images
that are already on the machine by their pin are not pulled; the others
(`pgvector`) are pulled whenever their registry answers, as on a machine with
internet access, and stay as they are when it does not (one `!` line);
`.env` keeps `CADENCE_REGISTRY`.

`./backup.sh`, `./restore.sh`, `clab server backup verify` and
`clab server status` need no network after `load`, cron included.

To upgrade, load the archive of the new version next to the old one and
run the upgrade against the same mirror:

```bash
bin/clab-linux-amd64 server images load /srv/airgap/cadence-v0.16.0-airgap.tar
cd /opt/cadence && CADENCE_RELEASES_URL=file:///srv/airgap ./upgrade.sh v0.16.0
```

The images of the old version stay in Docker (or in your registry): the
rollback that a failed upgrade prints runs on them without network — keep
them until the new version has proved itself.

The scripts of a package work in a closed network from the release after
v0.14.1: they run the `clab` of their package. For an archive of an earlier
version (v0.13.0 to v0.14.1) run `clab server install` (or the scripts with
`CADENCE_CLAB=`) of a newer `clab`.

## Monitoring

Since v0.10.0 the API and the worker expose metrics in the Prometheus format
at `/metrics`, each on its own port inside the compose network:
`http://api:9090/metrics` and `http://worker:9090/metrics`. The port comes
from `SDLC_METRICS_ADDR` (`:9090` when unset; an empty value in `.env`
turns the listeners off). The endpoints need no token, so the package
publishes neither port and Caddy does not route `/metrics` — a request to
`https://<host>/metrics` gets the UI. Logs are JSON already
(`docker compose logs api worker`); metrics are for alerting.

No metric carries project data: no project or task keys, repositories,
handles or tokens. Routes appear as templates
(`/v1/projects/:projectKey/tasks`), anything else as `unmatched`.

### Letting Prometheus in

Either way goes into `compose.override.yml` ([local compose
changes](#local-compose-changes)) and is applied with `docker compose up -d`.

**Prometheus in the same compose network** — nothing is published but its
own UI on loopback. Put `prometheus.yml` and `cadence-alerts.yml` (below)
next to `docker-compose.yml`:

```yaml
# compose.override.yml
services:
  prometheus:
    image: prom/prometheus:v3.5.0
    restart: unless-stopped
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - ./cadence-alerts.yml:/etc/prometheus/cadence-alerts.yml:ro
    ports: ["127.0.0.1:9091:9090"]
```

```yaml
# prometheus.yml
rule_files: [cadence-alerts.yml]
scrape_configs:
  - job_name: cadence-api
    static_configs: [{targets: ["api:9090"]}]
  - job_name: cadence-worker
    static_configs: [{targets: ["worker:9090"]}]
```

**Prometheus elsewhere** — publish the two ports on loopback (for a
Prometheus or an agent on this machine) or on an internal interface behind
your firewall, never on a public address:

```yaml
# compose.override.yml
services:
  api:
    ports: ["127.0.0.1:9101:9090"]
  worker:
    ports: ["127.0.0.1:9102:9090"]
```

and scrape `127.0.0.1:9101` as `cadence-api` and `127.0.0.1:9102` as
`cadence-worker`. The job names are what the rules below expect in `up`.

### Metrics

The API reports its own process: requests, webhooks, its database pool. The
state of the database — the index queue, leases, unreadable branches — is
reported by the worker alone, taken on its lease tick (every minute,
`SDLC_LEASE_SWEEP_INTERVAL`), not on every scrape. There is one worker; if
you run several API replicas, sum their request metrics, the queue is never
counted twice.

| Metric | Type | Where | Meaning |
|---|---|---|---|
| `cadence_build_info` | gauge | both | always 1; labels `component` (`api`, `worker`), `version`, `go_version` |
| `cadence_http_request_duration_seconds` | histogram | api | request duration by `method`, `route` (template or `unmatched`) and `code` class (`2xx`, `4xx`, `5xx`) |
| `cadence_audit_write_failures_total` | counter | api | [audit log](#audit-log) entries that could not be saved; the call itself went through (from v0.11.0) |
| `cadence_webhook_deliveries_total` | counter | api | webhook deliveries by `provider` and `outcome`: `queued` (accepted and applied), `ignored`, `duplicate`, `bad_signature`, `disabled` (no `SDLC_GITHUB_WEBHOOK_SECRET`), `error` |
| `cadence_db_pool_connections` | gauge | both | pool connections by `state`: `acquired`, `idle`, `constructing` |
| `cadence_db_pool_max_connections` | gauge | both | pool size, `SDLC_DB_MAX_CONNS` (10) |
| `cadence_db_pool_acquires_total` | counter | both | connections taken from the pool |
| `cadence_db_pool_acquire_seconds_total` | counter | both | total time spent taking connections, waiting included |
| `cadence_db_pool_empty_acquires_total` | counter | both | takes that had to wait for a free connection |
| `cadence_db_pool_empty_acquire_wait_seconds_total` | counter | both | total time spent waiting for a free connection |
| `cadence_db_pool_canceled_acquires_total` | counter | both | takes abandoned before a connection came |
| `cadence_db_pool_new_connections_total` | counter | both | connections the pool opened |
| `cadence_worker_job_duration_seconds` | histogram | worker | duration of one pass of a job, by `job` |
| `cadence_worker_job_errors_total` | counter | worker | failed passes by `job` |
| `cadence_worker_job_last_success_timestamp_seconds` | gauge | worker | Unix time of the last pass without an error, by `job`; appears after the first one |
| `cadence_worker_state_refreshed_timestamp_seconds` | gauge | worker | Unix time of the database snapshot behind the queue, lease and branch metrics |
| `cadence_index_queue_runs` | gauge | worker | indexing runs by `state`: `queued` (retries included), `running` |
| `cadence_index_queue_oldest_age_seconds` | gauge | worker | age of the oldest queued run; 0 when the queue is empty |
| `cadence_index_runs_total` | counter | worker | executed indexing runs by `result`: `completed`, `failed` |
| `cadence_index_run_duration_seconds` | histogram | worker | duration of an indexing run |
| `cadence_leases` | gauge | worker | stages held by agents by `state`: `live`, `expired` (not returned yet) |
| `cadence_leases_expired_total` | counter | worker | stages the worker returned to the queue because their lease expired |
| `cadence_repository_head_failures` | gauge | worker | watched branches whose head could not be read on two passes or more |

Both processes also expose the standard `go_*` and `process_*` metrics.
The `job` label of the worker: `lease_sweep` (returning expired leases),
`ops_state` (the database snapshot), and with indexing on (the default,
`SDLC_INDEX_ENABLED`) `index_enqueue`, `index_run`, `drift`, `index_prune`,
`repo_ref_sync`, `knowledge`, `embed_refresh`, `overlaps`; `blob_gc` runs
hourly and `embed_cache_gc` every six hours, neither at start; `audit_gc`
(the [audit log](#audit-log) retention) runs hourly unless
`SDLC_AUDIT_RETENTION_DAYS=0`, not at start either. A job that
is turned off or has not run yet has no `last_success` series.

For Postgres and Caddy use their own exporters: `postgres_exporter` and the
`metrics` directive of Caddy.

### Alert rules

A starting set; thresholds are examples to tune. `promtool check rules`
accepts the file as is:

```yaml
# cadence-alerts.yml
groups:
  - name: cadence
    rules:
      - alert: CadenceDown
        expr: up{job=~"cadence-api|cadence-worker"} == 0
        for: 2m
        annotations:
          summary: "{{ $labels.job }} does not answer on /metrics"
      - alert: CadenceLeaseSweepStalled
        expr: time() - cadence_worker_job_last_success_timestamp_seconds{job="lease_sweep"} > 600
        for: 5m
        annotations:
          summary: "The worker has not returned expired leases for 10 minutes"
      - alert: CadenceIndexingStalled
        expr: time() - cadence_worker_job_last_success_timestamp_seconds{job="index_run"} > 1800
        for: 5m
        annotations:
          summary: "The worker has not taken an indexing run for 30 minutes"
      - alert: CadenceWorkerJobErrors
        expr: increase(cadence_worker_job_errors_total[15m]) > 3
        annotations:
          summary: "Worker job {{ $labels.job }} keeps failing; see docker compose logs worker"
      - alert: CadenceIndexQueueBacklog
        expr: cadence_index_queue_oldest_age_seconds > 1800
        for: 10m
        annotations:
          summary: "An indexing run has waited in the queue for over 30 minutes"
      - alert: CadenceIndexRunsFailing
        expr: increase(cadence_index_runs_total{result="failed"}[1h]) > 3
        annotations:
          summary: "Indexing runs fail; the project's Index page names the repository"
      - alert: CadenceRepositoryUnreadable
        expr: cadence_repository_head_failures > 0
        for: 30m
        annotations:
          summary: "A watched branch cannot be read: check the GitHub App or token"
      - alert: CadenceWebhookBadSignature
        expr: increase(cadence_webhook_deliveries_total{outcome="bad_signature"}[15m]) > 0
        annotations:
          summary: "GitHub webhook signatures do not match SDLC_GITHUB_WEBHOOK_SECRET"
      - alert: CadenceApiErrors
        expr: |
          sum(rate(cadence_http_request_duration_seconds_count{code="5xx"}[5m]))
            / sum(rate(cadence_http_request_duration_seconds_count[5m])) > 0.05
        for: 10m
        annotations:
          summary: "More than 5% of API requests fail with 5xx"
      - alert: CadenceApiSlow
        expr: |
          histogram_quantile(0.95,
            sum by (le) (rate(cadence_http_request_duration_seconds_bucket[5m]))) > 2
        for: 10m
        annotations:
          summary: "The 95th percentile of API requests is above 2 seconds"
      - alert: CadenceDbPoolSaturated
        expr: |
          cadence_db_pool_connections{state="acquired"}
            / ignoring(state) cadence_db_pool_max_connections > 0.9
          or rate(cadence_db_pool_empty_acquire_wait_seconds_total[5m]) > 0.5
        for: 10m
        annotations:
          summary: "{{ $labels.job }} waits for database connections; raise SDLC_DB_MAX_CONNS"
      - alert: CadenceLeasesExpiring
        expr: increase(cadence_leases_expired_total[1h]) > 5
        annotations:
          summary: "Agents lose their leases: they crash or send heartbeats less often than SDLC_LEASE_TTL"
```

### Tracing

Since v0.12.0 the API can send one span per request to your OpenTelemetry
collector, Tempo, Jaeger or APM over OTLP/HTTP (protobuf). Metrics answer
"how many and how often", a trace answers "what happened to this request":
which route is slow, where the 5xx come from, how long an MCP call of an
agent takes. Tracing is off by default: with no `OTEL_*` set the API creates
no exporter and opens no connection to any collector, `localhost:4318`
included.

Turn it on in `.env` and apply with `docker compose up -d` (only `api` is
recreated):

```sh
OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318
```

The API then logs one line `трассировки включены` ("tracing is on") with the
address it posts to (`<endpoint>/v1/traces`), without credentials and without
headers. The variables are the standard ones of the OpenTelemetry
specification; the package passes these to the API:

| Variable | Default | Meaning |
|---|---|---|
| `OTEL_EXPORTER_OTLP_ENDPOINT` | empty: off | base URL of the collector, `http://` or `https://`; spans go to `<endpoint>/v1/traces` |
| `OTEL_EXPORTER_OTLP_HEADERS` | empty | headers for the collector, `key1=value1,key2=value2`, values %-encoded (`Authorization=Bearer%20xyz`) — an APM key, for instance; a secret: since v0.13.0 also `OTEL_EXPORTER_OTLP_HEADERS_FILE` ([Secrets in files](#secrets-in-files)); never logged and not shown in `/v1/instance` |
| `OTEL_TRACES_EXPORTER` | empty | `otlp` turns tracing on without an endpoint (the SDK default `https://localhost:4318`), `none` turns it off whatever the endpoint |
| `OTEL_SERVICE_NAME` | `cadence-api` | `service.name` of the spans |
| `OTEL_RESOURCE_ATTRIBUTES` | empty | more resource attributes, `deployment.environment=prod,team=platform`; `service.version` is always the version of the installation and cannot be overridden |
| `OTEL_TRACES_SAMPLER` | `parentbased_always_on` | which requests are traced; `parentbased_traceidratio` with `OTEL_TRACES_SAMPLER_ARG=0.1` keeps 10% |
| `OTEL_TRACES_SAMPLER_ARG` | empty | the argument of the sampler |

Other `OTEL_EXPORTER_OTLP_*` settings of the specification (the per-signal
`OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`, TLS certificates, timeout,
compression) and `OTEL_SDK_DISABLED=true` (off whatever else is set) work
too when added to the `environment` of `api` in `compose.override.yml`. So
do the per-signal headers `OTEL_EXPORTER_OTLP_TRACES_HEADERS` (or
`OTEL_EXPORTER_OTLP_TRACES_HEADERS_FILE`): when set, they replace
`OTEL_EXPORTER_OTLP_HEADERS` as a whole, as the specification says.

**The headers are checked on start** (since v0.13.0), even with tracing
off. A pair without `=`, a key that is not a valid header name or a value
with a broken `%`-escape (a literal `%` is `%25`) stops the API with an
error naming the variable (or its `_FILE`), the number of the pair and the
reason — never the key or the value. Before v0.13.0 such a pair was dropped
silently, and the collector got the spans without the key; the part of the
string that did not parse went to the log. Empty pairs (`a=b,`) are
skipped. Setting both `OTEL_EXPORTER_OTLP_HEADERS` and its `_FILE` stops the
API as for any other secret.

Only OTLP over HTTP with protobuf is supported. `OTEL_EXPORTER_OTLP_PROTOCOL`
other than `http/protobuf` (`grpc`, `http/json`), `OTEL_TRACES_EXPORTER`
other than `otlp` or `none`, or an endpoint that is not an `http://` or
`https://` URL stop the API on start with an error naming the variable; the
healthcheck of `api` turns red and no data is touched. Fix `.env` and run
`docker compose up -d` again. A collector that speaks only gRPC (port 4317)
needs its HTTP receiver (port 4318) enabled.

**What a span carries.** The name is the method and the route template —
`GET /v1/tasks/:taskKey`, `POST /mcp/projects/:projectKey` — or just the
method for a path that matches no route. Attributes: `http.request.method`,
`http.route`, `http.response.status_code`, `network.protocol.version`; a 5xx
response marks the span as an error. No path with values, no query string,
no headers (`Authorization`, cookies), no body, no client address, no
handle or token, no sign-in code of the CLI — the same rule as for metric
labels. A `traceparent` header of the caller is honoured: the span of the
API joins the caller's trace. `baggage` is ignored.

**What is not traced.** `/healthz` and `/readyz` (the healthcheck hits them
every five seconds), the worker, `clab`, and anything inside a request:
database queries, calls to GitHub, to the embeddings provider or to S3 get
no child spans, and the API passes no `traceparent` on. Metrics and logs
over OTLP are not provided either; logs stay with `docker compose logs`.

**An unreachable collector** does not slow requests down: spans are sent in
batches in the background and dropped when the collector does not take
them. Export errors go to the log as a warning at most once a minute, with
the number of the ones skipped. On stop (`docker compose stop api`,
`upgrade.sh`) the API finishes the requests in flight and then sends what
it has, within the same shutdown limit as without tracing; a collector that
does not answer does not make the stop longer, the tail of spans is lost.

A collector in the same compose network, printing what it receives, to try
it out ([local compose changes](#local-compose-changes)):

```yaml
# compose.override.yml
services:
  otel-collector:
    image: otel/opentelemetry-collector:0.139.0
    restart: unless-stopped
    command: ["--config=/etc/otelcol/config.yaml"]
    volumes:
      - ./otel-collector.yaml:/etc/otelcol/config.yaml:ro
```

```yaml
# otel-collector.yaml
receivers:
  otlp:
    protocols:
      http:
        endpoint: 0.0.0.0:4318
exporters:
  debug:
    verbosity: detailed
service:
  pipelines:
    traces:
      receivers: [otlp]
      exporters: [debug]
```

with `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector:4318` in `.env`;
`docker compose logs otel-collector` shows the spans. Replace `debug` with
the exporter of your backend. A collector on the host itself is
`http://host.docker.internal:4318`; on Linux that name needs
`extra_hosts: ["host.docker.internal:host-gateway"]` for `api` in
`compose.override.yml`, as for [embeddings on the host](#embeddings).

## Security

The security policy is [`SECURITY.md`](../SECURITY.md) in the root of the
installation and of each public repository of Cadence Lab: how to report a
vulnerability, response times, disclosure and CVE.

- **Reporting.** Privately, through GitHub: "Report a vulnerability" on the
  Security tab of
  [cadence-lab-tech/self-hosted](https://github.com/cadence-lab-tech/self-hosted/security/advisories/new)
  or of the repository of the affected component. It is the only channel;
  do not open a public issue.
- **Supported versions.** During the beta, security fixes go into the
  latest minor `0.x` only, as a new release on top of it; older versions get
  no backports. Stay on the latest release: `./upgrade.sh` (or
  `clab server upgrade`) and `brew upgrade clab` on the machines of people
  and agents. A support window for older versions comes with 1.0.
- **Notifications.** On
  [cadence-lab-tech/self-hosted](https://github.com/cadence-lab-tech/self-hosted)
  choose Watch → Custom → Releases and Security alerts. A security fix is
  published as a GitHub Security Advisory with a CVE in the repository of
  the vulnerable code, and the release that fixes it has a "Security"
  section in its notes with a link to the advisory.
- **After a fix.** Upgrade to the fixing release as described in
  [Upgrades and rollback](#upgrades-and-rollback); the advisory names the
  affected and fixed versions and any step beyond the upgrade.
- **Users of the containers.** The API and the worker run as uid 65532;
  the UI too, from v0.14.0 (before, its image ran as root), and from
  v0.16.0 it listens on port 8080 only, its Caddy binary carries no file
  capability, and it writes nothing at runtime, so it runs with no
  capabilities on a read-only root. The entry point `caddy` runs the same
  frontend image as root, by `user: "0:0"` in `docker-compose.yml`: it
  binds 80 and 443, and the certificates in its volume `caddy_data` belong
  to root. In Kubernetes every pod of the chart runs as uid 65532 under Pod
  Security `restricted`, from the chart 0.16.0 with no capability added
  ([Kubernetes (Helm)](#kubernetes-helm)).
- **Is it ours?** Releases from v0.9.0 are signed; how to check the
  package, the images, the CLI, their SBOM and provenance, and which scanner
  findings are known not to apply — [Verifying a release](#verifying-a-release).

### Audit log

Cadence Lab records who did what — a person in the web interface, a person
through their own AI (`clab`, MCP with a personal token), or an agent of a
stage — in an audit log in the database (from the release that adds the
`audit_log` table; no step on upgrade, the migration runs on start).

**What is written.** Every MCP tool call that reaches the tool, successful
or failed, except `sdlc_heartbeat` (a lease renewal every five minutes);
every change through the API (`POST`, `PUT`, `PATCH`, `DELETE` under `/v1`):
tasks, artifacts, transitions and gate decisions, roles, workflows,
bundles, documents, repositories, members, teams and tokens; every refusal
with `401` or `403`, reads included, when a token was presented — a revoked
or expired token is named. Each entry has the time, the project and task,
the principal, the token (name, prefix and kind: `api` for a personal
token, `session` for the web interface, or a newer kind), the channel
(`mcp` or `rest`), the tool or route, the parameters, the outcome (`ok` or
the error code, and the HTTP status for the API) and the request id that
links it to the log of the `api` container.

**What is not written.** Successful reads; responses; the content of
artifacts and documents and any string longer than 4 KB — only its size and
sha256; tokens, sign-in codes, invite links, passwords and other secrets
(`[redacted]`); requests without a token at all (scanners); the worker's own
passes. A failed write to the log never fails the call: it is logged at
`error` by the `api` container and counted by
`cadence_audit_write_failures_total` ([Monitoring](#monitoring)).

**Retention.** `SDLC_AUDIT_RETENTION_DAYS` in `.env`, 180 by default; the
worker deletes older entries hourly (the `audit_gc` job). `0` keeps the log
forever. A negative or non-numeric value stops the `worker` on start with
an error naming the variable (the `api` does not read it). Deleting a
project deletes its log; the deletion itself stays in the instance log.

**Reading it.** A maintainer of a project reads the log of a task and of the
project, the system administrator also the entries without a project
(teams, principals, tokens without a project, deleted projects):

```bash
clab audit CLAB-42                         # one task
clab audit --project CLAB --outcome forbidden --since 2026-10-01
clab audit --instance --channel rest       # entries without a project
clab audit CLAB-42 --json                  # the server's answer as is
```

Filters: `--task`, `--principal`, `--token` (id or prefix), `--channel`,
`--action`, `--outcome`, `--since`, `--until`, `--limit`, `--cursor` —
`clab audit --help`. The same is `GET /v1/tasks/{KEY}/audit`,
`GET /v1/projects/{KEY}/audit` and `GET /v1/audit`. The web interface shows
the log from the release that adds its audit pages; until then use `clab
audit`.

**Size.** An entry is about a kilobyte, and an agent makes hundreds of tool
calls per task: the log is usually the fastest-growing table. It is part of
the database, so it is in every backup (`./backup.sh`) and restored with
it; shorten `SDLC_AUDIT_RETENTION_DAYS` if the database or the backups grow
faster than you want.

## Verifying a release

From v0.9.0 every part of a release can be traced to the workflow that built
it. Nothing here needs a key or an account: the signatures are made by
[Sigstore](https://www.sigstore.dev/) without keys — each one carries a
short-lived certificate for the identity of the GitHub Actions workflow that
signed it, and is recorded in the public transparency log. You need
[cosign](https://docs.sigstore.dev/cosign/system_config/installation/) 3.x
and Docker with `buildx`. Versions before v0.9.0 are not signed. With
`cosign` on the machine of the installation the scripts and `clab server`
verify the package and the images themselves (see
[Automatic verification](#automatic-verification) below); the commands
after it do the same by hand, and more.

| what | signed by (`--certificate-identity`) |
|---|---|
| image `sdlc-pipeline-backend` | `https://github.com/cadence-lab-tech/sdlc-pipeline-backend/.github/workflows/release.yml@refs/tags/vX.Y.Z` |
| image `sdlc-pipeline-frontend` | `https://github.com/cadence-lab-tech/sdlc-pipeline-frontend/.github/workflows/release.yml@refs/tags/vX.Y.Z` |
| `checksums.txt` of the package | `https://github.com/cadence-lab-tech/self-hosted/.github/workflows/release.yml@refs/heads/main` |
| the Helm chart `charts/cadence` (from v0.13.0) | `https://github.com/cadence-lab-tech/self-hosted/.github/workflows/release.yml@refs/heads/main` |
| `checksums.txt` of the `clab` archives | `https://github.com/cadence-lab-tech/sdlc-pipeline-backend/.github/workflows/release.yml@refs/tags/vX.Y.Z` |

The issuer of every certificate is `https://token.actions.githubusercontent.com`.
A signature by any other identity — another workflow, another repository,
another tag — is not ours: if a check fails, do not install that release and
report it privately (see [Security](#security)).

### Automatic verification

`get-cadence.sh`, `install.sh`, `./upgrade.sh` and `clab server install`
and `upgrade` (v0.12.0+) verify the signatures with the `cosign` they find
in `PATH` — it must be 3.x (the format of the signature bundle; an older
one counts as none):

- the signature of `checksums.txt` of the release by its
  `checksums.txt.sigstore.json`, with the identity of `self-hosted` on
  `main` — right after the download, before the package is unpacked, then
  the checksum of the package as before (`get-cadence.sh`,
  `clab server install`, both upgrades);
- the signatures of `sdlc-pipeline-backend` and `sdlc-pipeline-frontend`,
  each at `ghcr.io/cadence-lab-tech/<image>@<digest>` with the identity of
  its `release.yml` on the tag of `VERSION`; the digest is the one the
  compose configuration of that version runs — the pin of
  `docker-compose.yml`, your `compose.override.yml` included — whatever
  `CADENCE_REGISTRY` the images are pulled from (`install.sh`,
  `clab server install`, also in place, and both upgrades, for the new
  version). It comes before anything runs an image of the version: before
  the check of an external database, before `.env` is written, and in an
  upgrade before the backup, the files and the pull.

`CADENCE_VERIFY` — in the environment, and for an installed system also in
its `.env`, which wins over the environment like every variable of the
package — decides the rest. The installers do not write it to `.env`;
without it the mode is `auto`:

| case | `auto` (default) | `require` | `off` |
|---|---|---|---|
| `cosign` 3.x is there, the signatures verify | a `✓` line for each | the same | no check, one line `▸ signature verification is off (CADENCE_VERIFY=off)` |
| a signature does not verify, or is by another identity | refused, nothing changed | refused | — |
| no `cosign`, or one older than 3.x | one `!` warning, goes on | refused before anything is done | — |
| a version before v0.9.0 (not signed) | `!` warning, goes on | refused | — |
| a release of v0.9.0+ without `checksums.txt.sigstore.json` (a mirror that dropped it) | refused | refused | — |
| an image without a digest (an empty `CADENCE_BACKEND_DIGEST`, an image of `compose.override.yml`) | `!` warning: not pinned, not verified | refused | — |
| `ghcr.io` does not answer (a registry mirror in a closed network) | `!` warning: images not verified, goes on | refused | — |
| the same, with `trusted_root.json` in the mirror of the releases (after `clab server images load`, from the release after v0.14.1) | `checksums.txt` and the images in `CADENCE_REGISTRY` verified offline; images only in Docker of this machine: `✓ … verified when loaded` | the same | — |

A refusal names what failed — the package or the image with its digest —
and the identity it expected, says what to do and that nothing was
installed or changed. `cosign` needs to reach `ghcr.io` and Sigstore (the
public good instance) for the check — or, in a closed network, the
`trusted_root.json` of Sigstore that `clab server images save` carries
over ([Air-gapped installation](#air-gapped-installation)): then
`checksums.txt` and the images are verified offline, and `require` works
there too.
The first upgrade to v0.12.0 runs the older `upgrade.sh`, which verifies
nothing — see [Upgrades and rollback](#upgrades-and-rollback).

### By hand

**The package**, before unpacking it:

```bash
v=v0.9.0
base=https://github.com/cadence-lab-tech/self-hosted/releases/download/$v
curl -fsSLO "$base/checksums.txt" -O "$base/checksums.txt.sigstore.json" -O "$base/cadence-self-hosted-$v.tar.gz"
cosign verify-blob --bundle checksums.txt.sigstore.json \
  --certificate-identity https://github.com/cadence-lab-tech/self-hosted/.github/workflows/release.yml@refs/heads/main \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  checksums.txt
sha256sum --ignore-missing -c checksums.txt
```

**The images**, by the digests `docker-compose.yml` of the installation
pins — in the directory of the installation, before `./install.sh` or after
an upgrade. The images are verified at `ghcr.io` whatever `CADENCE_REGISTRY`
says: the digest names the same bytes in a mirror.

```bash
v=$(cat VERSION)
for repo in sdlc-pipeline-backend sdlc-pipeline-frontend; do
  ref=$(CADENCE_VERSION=$v docker compose config --images | grep "/$repo:" | head -n 1)
  cosign verify \
    --certificate-identity "https://github.com/cadence-lab-tech/$repo/.github/workflows/release.yml@refs/tags/$v" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    "ghcr.io/cadence-lab-tech/$repo@${ref##*@}" >/dev/null && echo "$repo $v: signature verified"
done
```

The signature covers the digest of the image index, and with it everything
the index lists: the image of each platform and its attestations.

**The Helm chart** (from v0.13.0), by the digest of the OCI artifact
`helm pull` fetched, before `helm install` or `helm upgrade`; install that
archive, or the chart by the same digest. The digests its values pin are the
images above:

```bash
v=0.13.0
digest=$(helm pull oci://ghcr.io/cadence-lab-tech/charts/cadence --version $v 2>&1 | awk '$1 == "Digest:" { print $2 }')
cosign verify \
  --certificate-identity https://github.com/cadence-lab-tech/self-hosted/.github/workflows/release.yml@refs/heads/main \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  "ghcr.io/cadence-lab-tech/charts/cadence@$digest" >/dev/null && echo "chart $v ($digest): signature verified"
tar -xzOf cadence-$v.tgz cadence/values.yaml | grep -E 'digest: '
```

**SBOM.** Each platform of each image has a software bill of materials
(SPDX 2.3) — the Go modules of `/api`, `/worker` and `/clab` with their
versions; for the frontend also the npm packages its bundle is built from
(in `AdditionalSPDXs`):

```bash
docker buildx imagetools inspect ghcr.io/cadence-lab-tech/sdlc-pipeline-backend:v0.9.0 --format '{{json .SBOM}}' > sbom-backend.json
jq -r '."linux/amd64".SPDX.packages[] | "\(.name) \(.versionInfo)"' sbom-backend.json
docker buildx imagetools inspect ghcr.io/cadence-lab-tech/sdlc-pipeline-frontend:v0.9.0 --format '{{json .SBOM}}' |
  jq -r '."linux/amd64".AdditionalSPDXs[].packages[] | "\(.name) \(.versionInfo)"'
```

**Provenance.** Each platform has a SLSA v1 provenance of its build: the run
of `release.yml` that built it (`builder.id`), the repository and the commit
of the tag, the build arguments:

```bash
docker buildx imagetools inspect ghcr.io/cadence-lab-tech/sdlc-pipeline-backend:v0.9.0 --format '{{json .Provenance}}' |
  jq '."linux/amd64".SLSA | {builder: .runDetails.builder.id, vcs: [.. | objects | .vcs? // empty][0]}'
```

**The CLI.** The `clab` archives of a release lie in the releases of
[cadence-lab-tech/homebrew-tap](https://github.com/cadence-lab-tech/homebrew-tap/releases)
with their `checksums.txt` and its signature (Homebrew and the install
script of the tap check the checksum):

```bash
v=v0.9.0
base=https://github.com/cadence-lab-tech/homebrew-tap/releases/download/$v
curl -fsSLO "$base/checksums.txt" -O "$base/checksums.txt.sigstore.json"
cosign verify-blob --bundle checksums.txt.sigstore.json \
  --certificate-identity "https://github.com/cadence-lab-tech/sdlc-pipeline-backend/.github/workflows/release.yml@refs/tags/$v" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  checksums.txt
```

### Known scanner findings

A scanner that matches by module version may report vulnerabilities that do
not affect Cadence Lab. Each such finding in our images is stated in
machine-readable [OpenVEX](https://openvex.dev/) — the file
`.github/release/openvex.json` of the backend and of the frontend repository
at the tag of the release, attached to the image as a signed attestation
(the frontend image has one from the release after v0.12.0):

| finding | component | status | why |
|---|---|---|---|
| [GO-2026-5932](https://pkg.go.dev/vuln/GO-2026-5932) | `golang.org/x/crypto` in `/api` of the backend image | not affected, vulnerable code not present | the advisory is about the `golang.org/x/crypto/openpgp` packages; none of them is in the binaries, the module is there for other packages |
| [GO-2026-5932](https://pkg.go.dev/vuln/GO-2026-5932) | `golang.org/x/crypto` in `/usr/bin/caddy` of the frontend image | not affected, vulnerable code not present | the same advisory; we build Caddy from source, and the build fails if any `golang.org/x/crypto/openpgp` package gets into it |
| [CVE-2026-85091](https://nvd.nist.gov/vuln/detail/CVE-2026-85091) | `zlib` 1.3.2-r0 of the Alpine base of the frontend image | not affected, vulnerable code not in execute path | the only process of the image is Caddy, a static Go binary without cgo that does not load libz; only `apk` and `curl` link it, and neither the image nor the package runs them. It goes away when `caddy:2-alpine` is republished with zlib 1.3.2-r1 |

```bash
v=$(cat VERSION)
# the signed VEX attached to each image
for repo in sdlc-pipeline-backend sdlc-pipeline-frontend; do
  cosign verify-attestation --type openvex \
    --certificate-identity "https://github.com/cadence-lab-tech/$repo/.github/workflows/release.yml@refs/tags/$v" \
    --certificate-oidc-issuer https://token.actions.githubusercontent.com \
    "ghcr.io/cadence-lab-tech/$repo:$v" | jq -r .payload | base64 -d | jq .predicate.statements
done

# scanners with the VEX: from the registry or from the file of the tag
trivy image --vex oci --show-suppressed ghcr.io/cadence-lab-tech/sdlc-pipeline-frontend:"$v"
curl -fsSL -o openvex-frontend.json "https://raw.githubusercontent.com/cadence-lab-tech/sdlc-pipeline-frontend/$v/.github/release/openvex.json"
trivy image --vex openvex-frontend.json --show-suppressed ghcr.io/cadence-lab-tech/sdlc-pipeline-frontend:"$v"
grype ghcr.io/cadence-lab-tech/sdlc-pipeline-frontend:"$v" --vex openvex-frontend.json
curl -fsSL -o openvex-backend.json "https://raw.githubusercontent.com/cadence-lab-tech/sdlc-pipeline-backend/$v/.github/release/openvex.json"
trivy image --vex openvex-backend.json ghcr.io/cadence-lab-tech/sdlc-pipeline-backend:"$v"
grype ghcr.io/cadence-lab-tech/sdlc-pipeline-backend:"$v" --vex openvex-backend.json
```

**The backend image.** The operating system layer has no known findings:
from the release after v0.11.0 the image is built on
`gcr.io/distroless/static-debian13:nonroot`. Up to v0.11.0 it was built on
`static-debian12`, which gets no Debian LTS updates, and a scanner reports
tzdata `DLA-4792-1` and ca-certificates `DLA-4845-1` in it; the services
trust the CA bundle of the image for TLS (GitHub, OIDC, embeddings, S3), so
upgrade rather than suppress them. The user and group of the image stay
`nonroot` (65532): the `blobs` volume of an existing installation needs no
change.

**The frontend image and the entry point.** From the release after v0.12.0
the frontend image runs Caddy built from source by its `Dockerfile` — the
same release of Caddy and the same standard modules as the official
distribution, compiled on the current patch of Go 1.26 with the current
`golang.org/x/net` and without cgo. The same image runs both `ui` (the
static files) and `caddy`, the entry point of the stack: `caddy` is pinned
by the digest of the frontend image, its signature is verified with the
release, and the `Caddyfile` of the package is mounted over the one inside,
as before; the `caddy_data` and `caddy_config` volumes do not change, and
`caddy:2-alpine` is no longer pulled. Up to v0.12.0 both ran `/usr/bin/caddy`
of `caddy:2-alpine`, built upstream on go1.26.8 with `golang.org/x/net`
v0.59.0, and a scanner reports 20 findings in it (5 HIGH, on 2026-10-21) in
`net/http`, `crypto/tls`, `crypto/x509` and `x/net/http2`. Some are
reachable — a `Range` header served by `file_server` in `ui`, HTTP/2 on the
public port of `caddy` — so upgrade rather than suppress them; until then,
`CADENCE_MODE=proxy` behind your own proxy keeps TLS and HTTP/2 away from
that Caddy.

```bash
# the Go and the modules our Caddy is built with
docker run --rm ghcr.io/cadence-lab-tech/sdlc-pipeline-frontend:"$(cat VERSION)" caddy build-info |
  grep -E '^go|caddy/v2|golang.org/x/net'
```

Grype (not Trivy) also reports findings of the Alpine base without a fix in
Alpine — OpenSSL (`libssl3`, `libcrypto3`), `curl`, `nghttp2-libs`,
`busybox` (its `wget`). They come from `caddy:2-alpine` itself and are the
same in every image built on it. None of them is on the path of Caddy: Go
has its own TLS and HTTP/2, and Caddy links no C library; `curl` and
`ssl_client` are never run, and the package runs `busybox wget` in the
`caddy` container only for plain HTTP inside the compose network and the
container (`http://ui:8080/` on start, from v0.16.0 also the admin API of
Caddy at `http://127.0.0.1:2019/reverse_proxy/upstreams`, the upstreams it
lists and `http://localhost/` in proxy mode, the metrics in its checks)
with URLs of its own.
They go away with the base image once Alpine ships the fixes.

**Third-party images: `postgres`, `db-client` and the move to
PostgreSQL 18.** `pgvector/pgvector:pg18-trixie` (the `postgres` service,
and the backup client `db-client` with an
[external database](#external-postgresql)) and `pgvector/pgvector:pg17`
(`pg-upgrade-dump`, which reads the data of PostgreSQL 17 once, see
[PostgreSQL 18](#postgresql-18)) are used by tag, as their maintainers
publish them. `pg18-trixie` is Debian 13 (trixie), `pg17` Debian 12
(bookworm). On 2026-10-22 Trivy reports in `pg18-trixie` 318 findings in
Debian packages (1 CRITICAL) and in `pg17` 466 (15 CRITICAL); each has 61
in `/usr/local/bin/gosu`. By class:

| class | `pg18-trixie` on 2026-10-22 | `pg17` on 2026-10-22 | what it means here |
|---|---|---|---|
| fixed in Debian (`fixed`) | 5: xz-utils, pcre2 | 54: perl, tzdata, pcre2 | the image upstream was built before the fix; `docker compose pull` (and `./upgrade.sh`, which pulls) brings a rebuilt image without a release of ours |
| no fix in Debian (`affected`, `fix_deferred`, `will_not_fix`): glibc, util-linux, perl, libxml2, sqlite, OpenSSL, GnuTLS, Kerberos, LDAP and others | 313 (the CRITICAL one: libxml2) | 412 | not reachable in the stack: `postgres` publishes no port, only the API and the worker connect to it, with a password over the compose network; the schema has no `xml` columns and only the `pgcrypto`, `plpgsql` and `vector` extensions; the image has no PL/Perl or PL/Python; over the network clients sign in with `scram-sha-256` (`trust` is only for connections inside the container), no GSSAPI, LDAP or certificates; sqlite is there only for `gpg`, which the database does not run |
| `gosu` (Go 1.24.6) | 61, all fixed in newer Go | 61 | `gosu` runs once, when the container starts: it drops root and executes `postgres`; no network, TLS or HTTP is on its path |

`pgvector/pgvector:pg17` runs only as `pg-upgrade-dump`: a container with no
port that starts on every `docker compose up`, finds nothing to move once
the data is in PostgreSQL 18 (or on a fresh installation) and exits; it
starts PostgreSQL 17 - with no network, on a socket of its own - only for
the move. Its image stays on the machine, held by the exited container;
`docker compose rm -f pg-upgrade-dump && docker image rm
pgvector/pgvector:pg17` removes it, and the next `docker compose pull`
brings it back.

With a policy that allows no image with an open CRITICAL, use your own
managed PostgreSQL ([external PostgreSQL](#external-postgresql),
`CADENCE_DB=external`): the stack then runs no `postgres` and no move, and
`pgvector/pgvector:pg18-trixie` remains only as `db-client`, a container
that runs `pg_dump` and `psql` against your database for backups and exits.

Why no VEX: an OpenVEX statement must be checkable against the image, and
these images are not ours — they change with every rebuild upstream,
hundreds of statements at a time.

```bash
# the findings of the third-party images by status
for image in pgvector/pgvector:pg18-trixie pgvector/pgvector:pg17; do
  trivy image -q --scanners vuln --format json "$image" |
    jq -r --arg image "$image" '.Results[] | "\($image) \(.Type): " +
      ([(.Vulnerabilities // [])[].Status] | group_by(.) | map("\(.[0]) \(length)") | join(", "))'
done

# no PL/Perl or PL/Python in the image: 0
docker run --rm pgvector/pgvector:pg18-trixie sh -c 'dpkg -l | grep -cE "plperl|plpython" || true'

# in the directory of the installation: postgres publishes no port (null),
# the extensions and the xml columns of the database, how clients sign in
export CADENCE_VERSION=$(cat VERSION)
docker compose config --format json | jq '.services.postgres.ports'
docker compose exec -T postgres sh -c 'psql -U "$POSTGRES_USER" -d "$POSTGRES_DB" -At' <<'SQL'
select string_agg(extname, ', ' order by extname) from pg_extension;
select count(*) from information_schema.columns where data_type = 'xml';
SQL
docker compose exec -T postgres sh -c 'grep -Ev "^(#|$)" "$PGDATA/pg_hba.conf"'
```

How base images are kept up to date:

- every `FROM` of the backend and frontend `Dockerfile` is pinned by digest
  (`golang:1.26-alpine`, `distroless/static-debian13:nonroot`,
  `node:24-alpine`, `caddy:2-alpine`); Dependabot proposes a new digest of
  the same tag once a week, and the image is built on the pull request
  before it is merged;
- the release of Caddy and the Go modules it is built with are pinned in
  `caddy/go.mod` and `caddy/go.sum` of the frontend; Dependabot proposes a
  new patch or minor release of Caddy and new `golang.org/x/*` modules once
  a week;
- a new base reaches your installation with the next release; a finding in a
  base image that affects Cadence Lab is a reason for a patch release on its
  own;
- a new line of a base image (Go, Node, Caddy, Debian) is a separate change,
  never an automatic one;
- the third-party images of the stack, `pgvector/pgvector:pg18-trixie` and
  `pgvector/pgvector:pg17`, are used by tag: `docker compose pull` brings
  their fixes, see the classes above.

```bash
# the operating system and the binaries of the images of the release
trivy image --scanners vuln --vex oci ghcr.io/cadence-lab-tech/sdlc-pipeline-backend:"$(cat VERSION)"
trivy image --scanners vuln --vex oci ghcr.io/cadence-lab-tech/sdlc-pipeline-frontend:"$(cat VERSION)"
```

## Managing the installation with clab server

`clab` v0.7.0 and later manages the installation on its machine with the
same guarantees as the scripts — `.env` is never rewritten, a downgrade is
refused, a backup comes before an upgrade, a failed upgrade prints the
rollback. From the release after v0.13.0 the scripts *are* `clab server`:
wrappers of the `clab` in `bin/` of the package
([clab in the package](#clab-in-the-package)). Your own `clab` — of the
version of the installation or newer, from the tap — runs the same steps
by name:

```bash
clab server install --mode proxy --http-addr 127.0.0.1:8080   # = get-cadence.sh | sh: a new installation in ./cadence (v0.8.0+)
clab server status                       # directory, installation name, versions of the stack and of clab, mode, database, services
clab server backup                       # = ./backup.sh (with the off-machine copy when BACKUP_S3_BUCKET is set)
clab server backup verify                # = ./backup.sh verify: does the newest backup restore (v0.10.0+)
clab server backup fetch                 # = ./backup.sh fetch: the newest backup from the bucket (v0.10.0+)
clab server restore backups/cadence-v0.7.0-20261008-030000.sql.gz   # = ./restore.sh (asks; --yes skips)
clab server upgrade                      # = ./upgrade.sh: the latest release
clab server upgrade --force v0.7.1       # = ./upgrade.sh --force v0.7.1
clab server starter --project PLAT       # the starter project in the team of SDLC_BOOTSTRAP_TEAM (v0.14.0+)
clab server images list --dir .          # the images of the version (from the release after v0.14.1)
clab server images save --version v0.15.0 --output cadence-v0.15.0-airgap.tar   # one archive for a closed network
clab server images load cadence-v0.15.0-airgap.tar   # load it there, verified offline
```

`clab server images` has no script of its own: run it with the `clab` of
the package (`bin/clab-<os>-<arch> server images …`) or your own; see
[Air-gapped installation](#air-gapped-installation).

`clab server` needs no sign-in: it works with the files of the installation
and Docker (`docker compose`) on this machine. Only the starter project
(`starter` and `install --with-starter`, v0.14.0+) goes to the API, and only
to the API of this installation, through its Caddy on this machine with the
administrator token of the installation; the configuration of `clab` and its
sign-ins are not used. It finds
the installation in `--dir DIR`, else in `CADENCE_DIR`, else in the current
directory or the nearest one above it with `VERSION` and `package.sha256`;
`clab server install` creates it in `--dir DIR`, else `CADENCE_DIR`, else
`./cadence` (see [Install](#install)).
It reads the same `.env` and the same variables as the scripts
(`BACKUP_DIR`, `KEEP_DAYS`, `BACKUP_S3_*`, `CADENCE_READY_TIMEOUT`, `CADENCE_RELEASES_URL`,
and from v0.12.0 `CADENCE_VERIFY`: `install` and `upgrade` verify the
signatures as the scripts do, see [Automatic verification](#automatic-verification)),
takes the installation name from `COMPOSE_PROJECT_NAME` in `.env` and refuses
another one in the environment, like the scripts (see
[Several installations on one machine](#several-installations-on-one-machine)),
writes the same files under the same names, takes `--external-db` and
`--external-db-ca` and backs up, restores and upgrades an
[external database](#external-postgresql) the same way (v0.10.0+), and
prints the same rollback, with `clab server restore --yes` in place of
`./restore.sh --yes`. Output is in English, like the scripts.

For cron give the full path of `clab` (cron's `PATH` is short) and the
directory:

```bash
0 3 * * * /usr/local/bin/clab server backup --dir /opt/cadence >> /opt/cadence/backups/backup.log 2>&1
0 5 * * 0 /usr/local/bin/clab server backup verify --dir /opt/cadence >> /opt/cadence/backups/backup.log 2>&1
```

The off-machine copy needs the backend image of v0.10.0 or later (`/api
backup-s3`): a newer `clab` on an older installation with `BACKUP_S3_BUCKET`
set makes the local backup, refuses the copy with `need Cadence Lab v0.10.0
or newer` and exits with status 1.

Versions: `clab server` manages installations from v0.6.0 on (older ones are
git clones: upgrade them with their own `./upgrade.sh` first). The stack may
not be newer than `clab`: an older `clab` refuses and prints the command
that updates it (`brew upgrade clab`, or the install script of the tap with
`CLAB_VERSION`). An upgrade to a release newer than `clab` goes on with a
warning; update `clab` right after it. `clab server install` installs
v0.6.0 and later and never a release newer than itself: without `--version`
it takes the latest release that `clab` can manage. On Windows `clab server`
refuses: run the Linux `clab` inside WSL2. The scripts and `clab server`
manage an installation either of them made; from the release after v0.13.0
the scripts run the `clab` of the package, and they stay at least two minor
releases after it.

## Troubleshooting

```bash
export CADENCE_VERSION=$(cat VERSION)
docker compose ps                       # what runs and what is healthy
docker compose logs --tail 100 api      # the API: migrations, sign-in, MCP
docker compose logs --tail 100 worker   # indexing, embeddings, leases
docker compose logs --tail 100 caddy    # TLS certificates and routing
curl -s https://<host>/readyz           # {"status":"ok","database":"ok"}
curl -s https://<host>/v1/instance      # version, profile and sign-in methods
docker compose exec caddy wget -qO- http://worker:9090/metrics | grep '^cadence_'   # since v0.10.0
```

- **`CADENCE_VERSION is not set`** — run compose with
  `export CADENCE_VERSION=$(cat VERSION)` or use the scripts.
- **No certificate in the `tls` mode** — the domain must resolve to this
  machine and ports 80 and 443 must be reachable; Caddy retries by itself.
  Behind a corporate proxy use the `proxy` mode instead.
- **Agents hang on MCP calls behind a proxy** — the proxy buffers `/mcp/`;
  see [Behind your reverse proxy](#behind-your-reverse-proxy).
- **`clab`: `хост не настроен`** ("host is not configured") — the CLI has
  no host yet: `clab auth login --host https://<host>`; see
  [CLI and agents](#cli-and-agents). `clab-runner` refuses to start for the
  same reason without `SDLC_API_URL=https://<host>/v1`.
- **GitHub App: `Bad credentials`** — the key file is unreadable for uid
  65532 or the machine clock is off.
- **External database: the API does not become ready** — run
  `docker compose run --rm --no-deps -T api dbcheck`: it names what is wrong
  (TLS, the password, the extensions, the privileges, the schema). A host
  that is `localhost` in the URL is the container itself; use the address of
  the database server as the containers see it.
- **External database: `too many connections`** — lower
  `SDLC_DB_MAX_CONNS` in `.env` or raise `max_connections` of the server;
  see [Connections and pools](#connections-and-pools).
- **Off-machine copy fails** — `./backup.sh` names the reason after
  `upload to s3://… failed`: `403 Forbidden AccessDenied` or
  `SignatureDoesNotMatch` — the keys or their rights (see
  [Off-machine copy](#off-machine-copy)); `404 Not Found NoSuchBucket` — the
  bucket or `BACKUP_S3_ENDPOINT`/`BACKUP_S3_REGION`; `dial tcp` or
  `no such host` — the containers cannot reach the endpoint (a firewall, a
  proxy, `BACKUP_S3_PATH_STYLE=false` for storage that needs path-style).
  The local backup is kept; `./backup.sh verify` shows whether the copies
  already in the bucket restore.
- **`verify` fails** — the reason is the last line: a checksum that does not
  match means the copy in the bucket is damaged (verify an older one by name
  after `./backup.sh fetch NAME`, and check what changed it); a `psql` error
  means the dump does not load — take a new backup and verify it at once.
  A `verify` killed half-way leaves nothing behind: its container and network
  carry the label `com.cadence.verify` (`docker ps -a --filter
  label=com.cadence.verify`).
- **External database: backups fail, the service works** — the backup
  client (`psql`, `pg_dump`) reads the URL with libpq; the installer checks
  both, but a URL edited in `.env` later is not checked:
  `docker compose run --rm --no-deps -T api dbcheck` and `./backup.sh` show
  the error.
