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
instance from developers' machines over MCP; nothing goes through us.

## Quick start

On a Linux machine with Docker, one line downloads the package of the latest
release, verifies its checksum, unpacks it into `./cadence` and runs
`install.sh` there:

```bash
curl -fsSL https://github.com/cadence-lab-tech/self-hosted/releases/latest/download/get-cadence.sh | sh -s -- --domain cadence.example.com
```

With the CLI installed (`brew install cadence-lab-tech/tap/clab`, v0.8.0+),
the same is `clab server install --domain cadence.example.com --email ops@example.com`:
no `curl`, `tar` or `bash` needed, only Docker
([docs/admin.md](docs/admin.md#install)).

Then open the printed address, sign in with the printed administrator token
and follow [docs/admin.md](docs/admin.md): a team and a project, the starter
cycle and roles from `bundles/starter.json`, the GitHub App, single sign-on,
the CLI and agents.

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

The checksum protects against a broken or altered download, not against a
release replaced at its source; signed releases are planned.

## Requirements

| | minimum | for a few teams |
|---|---|---|
| OS | Linux x86_64 (amd64) or arm64 (aarch64: Graviton, Ampere and the like) | |
| CPU | 2 vCPU | 4 vCPU |
| RAM | 4 GB | 8 GB |
| Disk | 20 GB SSD | 50 GB SSD; code indexes and backups grow with repositories |
| Software | Docker Engine 24+ with the compose v2 plugin, curl, tar, openssl | |
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
`clab auth login --host http://127.0.0.1:8080` signs it in. When done,
`docker compose down -v` in `cadence-lab` removes the containers and the data.

## What is in here

| | |
|---|---|
| `VERSION` | the version of Cadence Lab this package runs; both images use it |
| `docker-compose.yml` | Postgres with pgvector, the API, the worker, the UI and Caddy; only Caddy publishes ports |
| `compose.tls.yml`, `compose.proxy.yml` | the published ports of each mode, picked by `COMPOSE_FILE` in `.env` |
| `compose.override.yml` | not in the package: your local compose changes, created by `install.sh` and listed in `COMPOSE_FILE` |
| `Caddyfile` | routing and TLS for both modes, picked by `CADENCE_MODE` |
| `.env.example` | every setting, with where to get its value; `install.sh` turns it into `.env` |
| `install.sh` | first installation: checks, secrets, `.env`, start |
| `upgrade.sh` | backup, package files of the new release, new images, start, readiness check |
| `backup.sh`, `restore.sh` | database dump and the artifact volume; restore with a version check |
| `lib.sh` | helpers the scripts share |
| `docs/admin.md` | the administrator guide |
| `bundles/starter.json` | a starter of roles and cycles for a new project, applied with `clab import` |
| `package.sha256` | in the package only: the sha256 of each of its files, against which `upgrade.sh` finds local edits |
| `get-cadence.sh` | the one-line installer, published next to the package (not in it) |
| `ci/` | not in the package: building it (`ci/package.sh`) and the checks CI runs on the published images |

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
After the upgrade, update `clab` on the machines of people and agents to
the same version (`brew upgrade clab`); upgrades from v0.6.1 on remind of
it.
Details: [docs/admin.md](docs/admin.md#upgrades-and-rollback).

## Releases

Each Cadence Lab release is a version `vX.Y.Z` shared by the backend, the
frontend and the CLI. A release opens a pull request here that changes only
`VERSION`; CI brings the stack up on the new images, and after the merge the
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

## License and beta terms

Cadence Lab is source-available under the
[Functional Source License 1.1, ALv2 Future License](LICENSE) (FSL-1.1-ALv2).
You may run it for your company, change it and use it for any purpose except
offering it to others as a competing product or service. Each version
becomes Apache 2.0 two years after its release.

During the beta, running Cadence Lab on your own infrastructure is free of
charge, without a usage limit. These terms may change when the beta ends;
versions you already run stay under the license they were released with.
