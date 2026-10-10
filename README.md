# Cadence Lab — self-hosted

Cadence Lab runs a configurable software development cycle where AI agents
work as specialists — analyst, architect, developer, reviewer, QA — and every
step is gated: artifacts submitted, a cross-check by another role passed, a
human approval given. Statuses, roles and gates are data your teams edit, not
code.

This repository is everything a company needs to run Cadence Lab on its own
machine: a Docker Compose stack, install, upgrade, backup and restore scripts,
and the [administrator guide](docs/admin.md). Agents connect to your instance
from developers' machines over MCP; nothing goes through us.

> **Beta.** The container images are not public yet: the quick start below
> does not work until they are published. Watch this repository for the
> first release.

## Quick start

On a Linux machine with Docker:

```bash
git clone https://github.com/cadence-lab-tech/self-hosted.git cadence && cd cadence
./install.sh            # asks for the mode and the domain, generates secrets, starts the stack
```

Then open the printed address, sign in with the printed administrator token
and follow [docs/admin.md](docs/admin.md).

`install.sh` runs in one of two modes:

- **`tls`** — Caddy serves your domain over HTTPS and obtains the certificate
  from Let's Encrypt itself. Needs a DNS record pointing at the machine and
  ports 80 and 443 open to the internet.
- **`proxy`** — plain HTTP on `127.0.0.1:8080` (configurable) behind your own
  reverse proxy or load balancer, which terminates TLS.

Without a terminal it asks nothing:
`./install.sh --mode proxy --http-addr 127.0.0.1:8080 --yes`.

## Requirements

| | minimum | for a few teams |
|---|---|---|
| OS | Linux x86_64 (amd64) | |
| CPU | 2 vCPU | 4 vCPU |
| RAM | 4 GB | 8 GB |
| Disk | 20 GB SSD | 50 GB SSD; code indexes and backups grow with repositories |
| Software | Docker Engine 24+ with the compose v2 plugin, git, openssl | |
| Network | `tls`: ports 80 and 443 from the internet; `proxy`: one port for your proxy | outbound HTTPS to `ghcr.io`, GitHub and your embeddings provider, if any |

GitHub has to reach `https://<host>/webhooks/github` if you connect a GitHub
App.

## What is in here

| | |
|---|---|
| `VERSION` | the version of Cadence Lab this checkout runs; both images use it |
| `docker-compose.yml` | Postgres with pgvector, the API, the worker, the UI and Caddy; only Caddy publishes ports |
| `compose.tls.yml`, `compose.proxy.yml` | the published ports of each mode, picked by `COMPOSE_FILE` in `.env` |
| `Caddyfile` | routing and TLS for both modes, picked by `CADENCE_MODE` |
| `.env.example` | every setting, with where to get its value; `install.sh` turns it into `.env` |
| `install.sh` | first installation: checks, secrets, `.env`, start |
| `upgrade.sh` | backup, package files of the new version, new images, start, readiness check |
| `backup.sh`, `restore.sh` | database dump and the artifact volume; restore with a version check |
| `lib.sh` | helpers the scripts share |
| `docs/admin.md` | the administrator guide |
| `ci/` | checks that CI runs on the published images |

## Upgrading

```bash
./upgrade.sh            # the latest version on main
./upgrade.sh v0.6.0     # a specific version
```

The script takes a backup first and prints the exact rollback commands if
the new version does not come up. Details: [docs/admin.md](docs/admin.md#upgrades-and-rollback).

## Releases

Each Cadence Lab release is a version `vX.Y.Z` shared by the backend, the
frontend and the CLI. A release opens a pull request here that changes only
`VERSION`; CI brings the stack up on the new images, and after the merge the
commit is tagged `vX.Y.Z`. The pull request is opened with the repository
secret `RELEASE_PR_TOKEN` — a fine-grained token for this repository with
Contents and Pull requests read and write — because pull requests opened by
`GITHUB_TOKEN` do not start CI. While the images are private, CI also needs
`GHCR_READ_TOKEN` (read:packages).

## License and beta terms

Cadence Lab is source-available under the
[Functional Source License 1.1, ALv2 Future License](LICENSE) (FSL-1.1-ALv2).
You may run it for your company, change it and use it for any purpose except
offering it to others as a competing product or service. Each version
becomes Apache 2.0 two years after its release.

During the beta, running Cadence Lab on your own infrastructure is free of
charge, without a usage limit. These terms may change when the beta ends;
versions you already run stay under the license they were released with.
