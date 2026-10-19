# Administrator guide

This guide takes a Cadence Lab installation from `./install.sh` to teams
working with agents: first sign-in, teams and invites, GitHub, single sign-on,
the CLI and agents, embeddings, backups and upgrades.

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
- [Security](#security)
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
`sha256sum` (or `shasum`), `bash` and Docker; git is not needed. Its own
flags:

| flag | variable | |
|---|---|---|
| `--version vX.Y.Z` | `CADENCE_INSTALL_VERSION` | the release to install, default the latest |
| `--dir DIR` | `CADENCE_INSTALL_DIR` | where to unpack, default `./cadence`; must not exist or be empty |
| | `CADENCE_RELEASES_URL` | a mirror of the releases, see [Releases and mirrors](#releases-and-mirrors) |

It stops before unpacking anything if the checksum does not match, if there
is no such release, or if the directory already has a `.env` (then
`./upgrade.sh` there is what you want). The checksum protects against a
broken or altered download, not against a release replaced at its source.
For that, from v0.9.0 `checksums.txt` and both images are signed by the
release workflows of our repositories, and `docker-compose.yml` of the
package pins the images by digest; the installer does not check the
signatures itself yet — check them by hand as in
[Verifying a release](#verifying-a-release) before you run it, or after.

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
port, a missing domain in the `tls` mode, a checksum that does not match —
comes before `.env` is written, and nothing is changed. If the images cannot
be pulled or the stack does not become ready, `.env` is kept and the command
prints how to start the stack. The result is the same directory as with
`get-cadence.sh`: `clab server` and the scripts of the package both manage
it afterwards.

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
| `--name` | `COMPOSE_PROJECT_NAME` | installation name on this machine, default `cadence`; see below |
| `--external-db URL` | `CADENCE_EXTERNAL_DB` | keep the data in your own PostgreSQL instead of the container; see [External PostgreSQL](#external-postgresql) |
| `--external-db-ca FILE` | `CADENCE_EXTERNAL_DB_CA` | the CA of that server: copied to `secrets/db-ca.pem`, `sslmode=verify-full` |
| `--yes` | | ask nothing (also when there is no terminal) |
| | `SDLC_ADMIN_TOKEN` | use this administrator token instead of generating one |

`install.sh` runs once. With an existing `.env` it stops and changes nothing:
a new database password would no longer open the existing database volume.
Further changes go into `.env` by hand; apply them with
`docker compose up -d`, which recreates only the containers whose settings
changed.

**Installation name.** `--name` names this installation *on the machine*: it
is the Docker Compose project of the installation — the prefix of its
containers, volumes and network (`cadence-postgres-1`, `cadence_pgdata`).
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
`pgdata` volume. A company that runs its databases itself — Amazon RDS,
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

### Server, extensions and the role

- **PostgreSQL 15, 16, 17 or 18.** The backup client is PostgreSQL 18
  (`pgvector/pgvector:pg18`), whose `pg_dump` reads all of them.
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

1. Prepare the database, the role and the extensions as above, and check
   them from the installation:
   `docker compose run --rm --no-deps -T -e SDLC_DATABASE_URL='postgres://…' api dbcheck --install`
   (in the bundled mode the variable has to be given explicitly like this).
2. Take a backup: `./backup.sh` (on v0.10.0 or later, whose dumps carry no
   owners and extensions).
3. Stop the stack: `docker compose down` (keep the volumes).
4. In `.env` set `CADENCE_DB=external`, `SDLC_DATABASE_URL='postgres://…'`
   and add `compose.external-db.yml` to `COMPOSE_FILE` after the file of the
   mode; put the CA into `secrets/db-ca.pem` (mode 644) if the URL names it.
5. Restore the backup into the new database:
   `./restore.sh --yes backups/cadence-<version>-<date>.sql.gz` — it starts
   the stack on the external database.
6. When everything is in place, remove the old volume:
   `docker volume rm <name>_pgdata`.

A dump of a PostgreSQL 17 server names `transaction_timeout`, which servers
15 and 16 do not know; the restore drops that line, so moving to an older
external server works too.

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
cycles that `clab import` applies to a project.

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
```

With `clab` v0.7.0 or later the same backup is `clab server backup` — see
[Managing the installation with clab server](#managing-the-installation-with-clab-server).

Backups on the same machine protect against a bad upgrade or a mistaken
deletion, not against losing the machine: copy `backups/` elsewhere —
`rsync` or `rclone` to another host or bucket after the backup, or snapshots
of the disk. With an S3 bucket for artifact content, the bucket is yours to
back up (versioning or replication).

Restore:

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
   `checksums.txt` of the release;
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
   waits for readiness (`CADENCE_READY_TIMEOUT`, 300 s);
8. reminds to update `clab` on the machines of people and agents to the new
   version: `brew upgrade clab`, or the install script of the tap with
   `CLAB_VERSION`, then `clab version` (see "CLI and agents"). The server
   does not update the CLI; until it is updated, every `clab` command warns
   that the CLI is older than the server. The upgrade runs the script of the
   version it starts from, so the reminder shows on upgrades from v0.6.1 on.

Skipping versions is fine. On an arm64 machine (Apple Silicon, Graviton,
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

### Releases and mirrors

Each release `vX.Y.Z` carries assets with names that do not change:
`cadence-self-hosted-vX.Y.Z.tar.gz` (the package: compose files, Caddyfile,
`.env.example`, `VERSION`, the scripts, `bundles/`, `docs/`, `README.md`,
`LICENSE`, `SECURITY.md` and `package.sha256`), `checksums.txt`,
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
Signatures are checked against `ghcr.io` by the same digest.

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
- **Is it ours?** Releases from v0.9.0 are signed; how to check the
  package, the images, the CLI, their SBOM and provenance, and which scanner
  findings are known not to apply — [Verifying a release](#verifying-a-release).

## Verifying a release

From v0.9.0 every part of a release can be traced to the workflow that built
it. Nothing here needs a key or an account: the signatures are made by
[Sigstore](https://www.sigstore.dev/) without keys — each one carries a
short-lived certificate for the identity of the GitHub Actions workflow that
signed it, and is recorded in the public transparency log. You need
[cosign](https://docs.sigstore.dev/cosign/system_config/installation/) 3.x
and Docker with `buildx`; `cosign` is recommended on the machine of the
installation but not required by the scripts. Versions before v0.9.0 are
not signed.

| what | signed by (`--certificate-identity`) |
|---|---|
| image `sdlc-pipeline-backend` | `https://github.com/cadence-lab-tech/sdlc-pipeline-backend/.github/workflows/release.yml@refs/tags/vX.Y.Z` |
| image `sdlc-pipeline-frontend` | `https://github.com/cadence-lab-tech/sdlc-pipeline-frontend/.github/workflows/release.yml@refs/tags/vX.Y.Z` |
| `checksums.txt` of the package | `https://github.com/cadence-lab-tech/self-hosted/.github/workflows/release.yml@refs/heads/main` |
| `checksums.txt` of the `clab` archives | `https://github.com/cadence-lab-tech/sdlc-pipeline-backend/.github/workflows/release.yml@refs/tags/vX.Y.Z` |

The issuer of every certificate is `https://token.actions.githubusercontent.com`.
A signature by any other identity — another workflow, another repository,
another tag — is not ours: if a check fails, do not install that release and
report it privately (see [Security](#security)).

**The package**, before unpacking it (`get-cadence.sh` verifies only the
checksum):

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
not affect Cadence Lab. Each such finding is stated in machine-readable
[OpenVEX](https://openvex.dev/) — the file `.github/release/openvex.json` of
the backend repository at the tag of the release, attached to the backend
image as a signed attestation:

| finding | component | status | why |
|---|---|---|---|
| [GO-2026-5932](https://pkg.go.dev/vuln/GO-2026-5932) | `golang.org/x/crypto` in `/api` of the backend image | not affected, vulnerable code not present | the advisory is about the `golang.org/x/crypto/openpgp` packages; none of them is in the binaries, the module is there for other packages |

```bash
# the signed VEX attached to the image
cosign verify-attestation --type openvex \
  --certificate-identity "https://github.com/cadence-lab-tech/sdlc-pipeline-backend/.github/workflows/release.yml@refs/tags/v0.9.0" \
  --certificate-oidc-issuer https://token.actions.githubusercontent.com \
  ghcr.io/cadence-lab-tech/sdlc-pipeline-backend:v0.9.0 | jq -r .payload | base64 -d | jq .predicate.statements

# scanners with the VEX: from the registry or from the file of the tag
trivy image --vex oci --show-suppressed ghcr.io/cadence-lab-tech/sdlc-pipeline-backend:v0.9.0
curl -fsSLO https://raw.githubusercontent.com/cadence-lab-tech/sdlc-pipeline-backend/v0.9.0/.github/release/openvex.json
trivy image --vex openvex.json ghcr.io/cadence-lab-tech/sdlc-pipeline-backend:v0.9.0
grype ghcr.io/cadence-lab-tech/sdlc-pipeline-backend:v0.9.0 --vex openvex.json
```

## Managing the installation with clab server

`clab` v0.7.0 and later manages the installation on its machine with the
same guarantees as the scripts — `.env` is never rewritten, a downgrade is
refused, a backup comes before an upgrade, a failed upgrade prints the
rollback — so the same steps go without bash and its tools:

```bash
clab server install --mode proxy --http-addr 127.0.0.1:8080   # = get-cadence.sh | sh: a new installation in ./cadence (v0.8.0+)
clab server status                       # directory, installation name, versions of the stack and of clab, mode, database, services
clab server backup                       # = ./backup.sh
clab server restore backups/cadence-v0.7.0-20261008-030000.sql.gz   # = ./restore.sh (asks; --yes skips)
clab server upgrade                      # = ./upgrade.sh: the latest release
clab server upgrade --force v0.7.1       # = ./upgrade.sh --force v0.7.1
```

`clab server` needs no sign-in: it works with the files of the installation
and Docker (`docker compose`) on this machine, not with the API. It finds
the installation in `--dir DIR`, else in `CADENCE_DIR`, else in the current
directory or the nearest one above it with `VERSION` and `package.sha256`;
`clab server install` creates it in `--dir DIR`, else `CADENCE_DIR`, else
`./cadence` (see [Install](#install)).
It reads the same `.env` and the same variables as the scripts
(`BACKUP_DIR`, `KEEP_DAYS`, `CADENCE_READY_TIMEOUT`, `CADENCE_RELEASES_URL`),
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
```

Versions: `clab server` manages installations from v0.6.0 on (older ones are
git clones: upgrade them with their own `./upgrade.sh` first). The stack may
not be newer than `clab`: an older `clab` refuses and prints the command
that updates it (`brew upgrade clab`, or the install script of the tap with
`CLAB_VERSION`). An upgrade to a release newer than `clab` goes on with a
warning; update `clab` right after it. `clab server install` installs
v0.6.0 and later and never a release newer than itself: without `--version`
it takes the latest release that `clab` can manage. On Windows `clab server`
refuses: run the Linux `clab` inside WSL2. The scripts keep working as they
are, and either of them manages an installation the other one made.

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
- **External database: the API does not become ready** — run
  `docker compose run --rm --no-deps -T api dbcheck`: it names what is wrong
  (TLS, the password, the extensions, the privileges, the schema). A host
  that is `localhost` in the URL is the container itself; use the address of
  the database server as the containers see it.
- **External database: `too many connections`** — lower
  `SDLC_DB_MAX_CONNS` in `.env` or raise `max_connections` of the server;
  see [Connections and pools](#connections-and-pools).
- **External database: backups fail, the service works** — the backup
  client (`psql`, `pg_dump`) reads the URL with libpq; the installer checks
  both, but a URL edited in `.env` later is not checked:
  `docker compose run --rm --no-deps -T api dbcheck` and `./backup.sh` show
  the error.
