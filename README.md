<picture>
  <source media="(prefers-color-scheme: dark)" srcset="assets/logo-mark-dark.svg">
  <img src="assets/logo-mark-light.svg" alt="Cadence Lab" height="48">
</picture>

# Cadence Lab — self-hosted

Cadence Lab runs a configurable software development cycle where AI agents
work as specialists — analyst, architect, developer, reviewer, QA — and every
step is gated: artifacts submitted, a cross-check by another role passed, a
human approval given. Statuses, roles and gates are data your teams edit, not
code.

This repository is everything a company needs to run Cadence Lab on its own
machine: a Docker Compose stack, install, upgrade, backup and restore scripts,
and the [administrator guide](docs/admin.md). Each release publishes them as
one package; installing and upgrading need no git. Agents connect to your
instance from developers' machines over MCP; nothing goes through us. An
agent that reaches a human approval waits for it on the server with
`clab wait`, without holding the chat: approve in the chat, on the task
card or with `clab decide`, and it goes on
([waiting for an approval](docs/admin.md#waiting-for-an-approval)).

A Kubernetes cluster takes the Helm chart `charts/cadence` instead (from
v0.13.0): the same images and settings on your PostgreSQL and S3 bucket,
published as `oci://ghcr.io/cadence-lab-tech/charts/cadence` and signed like
the package ([Kubernetes (Helm)](docs/admin.md#kubernetes-helm)).

## Quick start

On a Linux machine with Docker, one line downloads the package of the latest
release, verifies its checksum, unpacks it into `./cadence` and runs
`install.sh` there:

```bash
curl -fsSL https://github.com/cadence-lab-tech/self-hosted/releases/latest/download/get-cadence.sh | sh -s -- --domain cadence.example.com
```

The scripts of the package — `install.sh`, `upgrade.sh`, `backup.sh` and
`restore.sh` — run `clab server` of the `clab` the package carries for the
machine, of the same version as the stack (`bin/clab-<os>-<arch>`: Linux and
macOS, amd64 and arm64), with the same flags: the machine needs Docker, and
`curl` and `tar` for the one-line installer — no `bash`, `openssl` or CLI of
its own ([clab in the package](docs/admin.md#clab-in-the-package)).

With the CLI installed (`brew install cadence-lab-tech/tap/clab`, v0.8.0+),
the same is `clab server install --domain cadence.example.com --email ops@example.com`:
no `curl`, `tar` or `bash` needed, only Docker
([docs/admin.md](docs/admin.md#install)).

Then open the printed address, sign in with the printed administrator token
and follow [docs/admin.md](docs/admin.md): a team and a project, the starter
cycle and roles from `bundles/starter.json`, the GitHub App, single sign-on,
the CLI and agents.

From v0.14.0 the first team and project come with the installation: with
`--team KEY --with-starter --project KEY` the installer also creates the
project in that team, applies `bundles/starter.json` and activates its
cycles, so tasks and invites work right away:

```bash
curl -fsSL https://github.com/cadence-lab-tech/self-hosted/releases/latest/download/get-cadence.sh | sh -s -- --domain cadence.example.com --team acme --with-starter --project ACME
```

On an installation made without it, `clab server starter --dir cadence --project ACME --team acme`
does the same ([first cycle and roles](docs/admin.md#first-cycle-and-roles)).

The same by hand, from the [releases](https://github.com/cadence-lab-tech/self-hosted/releases):

```bash
v=v0.6.0   # the release to install
curl -fsSLO https://github.com/cadence-lab-tech/self-hosted/releases/download/$v/cadence-self-hosted-$v.tar.gz
curl -fsSLO https://github.com/cadence-lab-tech/self-hosted/releases/download/$v/checksums.txt
sha256sum --ignore-missing -c checksums.txt
mkdir cadence && tar -xpzf cadence-self-hosted-$v.tar.gz -C cadence && cd cadence
./install.sh            # asks for the mode and the domain, generates secrets, starts the stack
```

`install.sh` runs in one of two modes:

- **`tls`** — Caddy serves your domain over HTTPS and obtains the certificate
  from Let's Encrypt itself. Needs a DNS record pointing at the machine and
  ports 80 and 443 open to the internet.
- **`proxy`** — plain HTTP on `127.0.0.1:8080` (configurable) behind your own
  reverse proxy or load balancer, which terminates TLS.

Without a terminal it asks nothing:
`./install.sh --mode proxy --http-addr 127.0.0.1:8080 --yes`. The one-line
installer passes its flags on to `install.sh` (`--version vX.Y.Z` and
`--dir DIR` are its own), and through a pipe it has no terminal either:
`get-cadence.sh | sh -s -- --mode proxy --http-addr 127.0.0.1:8080` asks nothing.

One installation holds any number of teams and projects. A second
installation on the same machine (say, staging next to production) needs its
own directory, port and installation name — the name of the installation on
the machine, its Docker Compose project, not a project inside Cadence Lab:
`get-cadence.sh | sh -s -- --dir cadence-stage --name cadence-stage --mode proxy --http-addr 127.0.0.1:8081`.
The name is kept in `.env`; see
[docs/admin.md](docs/admin.md#several-installations-on-one-machine).

The data lives in the Postgres container of the stack by default. To keep it
in your own PostgreSQL 15-18 instead (Amazon RDS, Cloud SQL, Azure, your
cluster) pass its URL and the CA of the server; the database is checked
before anything is written:
`get-cadence.sh | sh -s -- --mode proxy --http-addr 127.0.0.1:8080 --external-db 'postgres://cadence:PASSWORD@db.internal:5432/cadence' --external-db-ca ./db-ca.pem`.
See [docs/admin.md](docs/admin.md#external-postgresql) for the extensions,
the privileges of the role, TLS, backups and moving an existing installation.

The checksum protects against a broken or altered download, not against a
release replaced at its source. From v0.9.0 the package and the images are
signed by the release workflows of our repositories (Sigstore, no keys),
carry an SBOM and a build provenance, and `docker-compose.yml` pins the
images by digest. With [cosign](https://docs.sigstore.dev/cosign/system_config/installation/)
3.x on the machine the installer, `./upgrade.sh` and `clab server` verify
the signatures of the package and of both images before they change
anything; `CADENCE_VERIFY` says what they do without it (`auto` warns,
`require` refuses, `off` skips the check). The
commands that check all of it by hand are in
[docs/admin.md](docs/admin.md#verifying-a-release).

A machine without internet access installs from a registry mirror of your
network or from one archive of the version that `clab server images save`
builds and `clab server images load` loads there, with the signatures
verified offline:
[docs/admin.md](docs/admin.md#air-gapped-installation).

## Requirements

| | minimum | for a few teams |
|---|---|---|
| OS | Linux x86_64 (amd64) or arm64 (aarch64: Graviton, Ampere and the like) | |
| CPU | 2 vCPU | 4 vCPU |
| RAM | 4 GB | 8 GB |
| Disk | 20 GB SSD | 50 GB SSD; code indexes and backups grow with repositories |
| Software | Docker Engine 24+ with the compose v2 plugin; curl and tar for the one-line installer | [cosign](https://docs.sigstore.dev/cosign/system_config/installation/) 3.x: the installer and the upgrades [verify the release](docs/admin.md#verifying-a-release) with it (recommended; `CADENCE_VERIFY=require` makes it required) |
| Database | none: the stack runs PostgreSQL 18 with pgvector (an installation on PostgreSQL 17 [moves](docs/admin.md#postgresql-18) on its upgrade) | your own PostgreSQL 15-18 with pgvector 0.5+ and pgcrypto, and Docker Compose 2.20+ ([external PostgreSQL](docs/admin.md#external-postgresql)) |
| Network | `tls`: ports 80 and 443 from the internet; `proxy`: one port for your proxy | outbound HTTPS to `ghcr.io`, GitHub and your embeddings provider, if any |

GitHub has to reach `https://<host>/webhooks/github` if you connect a GitHub
App.

## Evaluating on a laptop

To try Cadence Lab before giving it a server, run the same package on a
laptop with Docker Desktop (macOS, Windows with WSL 2, Linux), in `proxy`
mode on a local port, and sign in at `http://127.0.0.1:8080`:

```bash
curl -fsSL https://github.com/cadence-lab-tech/self-hosted/releases/latest/download/get-cadence.sh | sh -s -- --dir cadence-lab --mode proxy --http-addr 127.0.0.1:8080 --team acme
```

The images are built for linux/amd64 and linux/arm64, so on Apple Silicon
and other arm64 machines the stack runs natively since v0.5.3 (older
versions shipped amd64-only images and ran under emulation; see
`docs/admin.md`, "Upgrades and rollback"). A laptop is still not
production: when the evaluation is over, deploy on a server.
`brew install cadence-lab-tech/tap/clab` gives a native CLI;
`clab auth login --host http://127.0.0.1:8080` signs it in, and `clab setup`
in a local clone connects it to a project: MCP and the agent skills, from
the instance itself ([connecting developers](docs/admin.md#connecting-developers),
or `/docs` in the UI). When done,
`docker compose down -v` in `cadence-lab` removes the containers and the data.

## What is in here

| | |
|---|---|
| `VERSION` | the version of Cadence Lab this package runs; both images use it |
| `docker-compose.yml` | PostgreSQL 18 with pgvector, the API, the worker, the UI and Caddy; only Caddy publishes ports, and it runs the frontend image of the release (our Caddy, built from source), so the entry point is pinned and signed with the release; the API and the worker serve Prometheus metrics inside the network ([monitoring](docs/admin.md#monitoring)) |
| `compose.tls.yml`, `compose.proxy.yml` | the published ports of each mode, picked by `COMPOSE_FILE` in `.env` |
| `compose.external-db.yml` | your own PostgreSQL instead of the container (`CADENCE_DB=external`): no `postgres`, the backup client `db-client` |
| `compose.override.yml` | not in the package: your local compose changes, created by `install.sh` and listed in `COMPOSE_FILE` |
| `Caddyfile` | routing and TLS for both modes, picked by `CADENCE_MODE` |
| `.env.example` | every setting, with where to get its value; `install.sh` turns it into `.env` |
| `install.sh` | first installation: checks, secrets, `.env`, start |
| `upgrade.sh` | backup, package files of the new release, new images, start, readiness check |
| `backup.sh`, `restore.sh` | database dump and the artifact volume, the bundled or an external database, and an off-machine copy in an S3 bucket; `backup.sh verify` checks that a backup restores; restore with a version check |
| `postgres/major-upgrade.sh` | not run by hand: `docker-compose.yml` runs it before `postgres` to move the data of PostgreSQL 17 into PostgreSQL 18 on the first upgrade from a release on 17, and it does nothing after that ([PostgreSQL 18](docs/admin.md#postgresql-18)) |
| `bin/clab-<os>-<arch>` | `clab` of the version of the package for Linux and macOS, amd64 and arm64: the four scripts above are short `sh` wrappers that run its `clab server install`, `upgrade`, `backup` and `restore` on their directory ([clab in the package](docs/admin.md#clab-in-the-package)); they make the package about 12 MB |
| `docs/admin.md` | the administrator guide |
| `SECURITY.md` | the security policy: reporting a vulnerability, response times, supported versions |
| `bundles/starter.json` | a starter of roles and cycles for a new project, applied by `install.sh --with-starter`, `clab server starter` or `clab import` |
| `package.sha256` | in the package only: the sha256 of each of its files, against which `upgrade.sh` finds local edits |
| `get-cadence.sh` | the one-line installer, published next to the package (not in it) |
| `charts/cadence` | not in the package: the Helm chart for Kubernetes, published with each release as an OCI artifact ([Kubernetes (Helm)](docs/admin.md#kubernetes-helm)) |
| `ci/` | not in the package: building it (`ci/package.sh`, with `clab` from the release of the same version in the [tap](https://github.com/cadence-lab-tech/homebrew-tap)) and the checks CI runs on the published images |

## Upgrading

```bash
./upgrade.sh            # the latest release
./upgrade.sh v0.6.0     # a specific release
```

The script downloads the package of the release and verifies its checksum,
takes a backup, replaces the package files and prints the exact rollback
commands if the new version does not come up. It never touches `.env`,
`compose.override.yml`, `backups/` or `secrets/`, and stops if a package
file was edited here. Installations from before v0.6.0 move over with
their first upgrade ([docs/admin.md](docs/admin.md#moving-a-git-installation-to-release-packages)).
The `clab` in `bin/` is part of the package: the upgrade replaces it with
the one of the new version, and the rollback brings the previous one back.
After the upgrade, update `clab` on the machines of people and agents to
the same version (`brew upgrade clab`); upgrades from v0.6.1 on remind of
it.
Details: [docs/admin.md](docs/admin.md#upgrades-and-rollback).

## Releases

Each Cadence Lab release is a version `vX.Y.Z` shared by the backend, the
frontend and the CLI. A release opens a pull request here that changes only
`VERSION` — once the images are signed and the archives of `clab` of the
version are in the release of the tap, which the package carries; CI brings
the stack up on the new images, and after the merge the
commit is tagged `vX.Y.Z` and the GitHub Release `vX.Y.Z` is published with
three assets:

| | |
|---|---|
| `cadence-self-hosted-vX.Y.Z.tar.gz` | the package: everything above but `ci/` and `get-cadence.sh` |
| `checksums.txt` | sha256 of the other two |
| `get-cadence.sh` | the one-line installer |

The names do not change from release to release: installers and `upgrade.sh`
of every version find the assets by them. `CADENCE_RELEASES_URL` points
`get-cadence.sh` and `upgrade.sh` at a mirror with the same layout
(`download/vX.Y.Z/<asset>`, `latest/download/<asset>`).

The pull request is opened with the repository secret `RELEASE_PR_TOKEN` — a
fine-grained token for this repository with Contents and Pull requests read
and write — because pull requests opened by `GITHUB_TOKEN` do not start CI.

Security fixes ship as releases too, with a "Security" section in the notes
and a GitHub Security Advisory. Watch this repository (Releases and Security
alerts) to hear about them. Report vulnerabilities privately as described in
[SECURITY.md](SECURITY.md), never in a public issue; during the beta only
the latest minor `0.x` gets security fixes
([docs/admin.md](docs/admin.md#security)).

## License and beta terms

Cadence Lab is source-available under the
[Functional Source License 1.1, ALv2 Future License](LICENSE) (FSL-1.1-ALv2).
You may run it for your company, change it and use it for any purpose except
offering it to others as a competing product or service. Each version
becomes Apache 2.0 two years after its release.

During the beta, running Cadence Lab on your own infrastructure is free of
charge, without a usage limit. These terms may change when the beta ends;
versions you already run stay under the license they were released with.
