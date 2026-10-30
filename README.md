# sentin8/ - Platform Group

> The Sentin8 platform: identity (Auth/Prox), bus, storage, cron, flow,
> func, dash, ai, CLI, captain, Flutter SDK. All repositories are
> independent git repos; this folder is a plain group directory (RS §4.4).

[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](LICENSE)
[![Built with Rust](https://img.shields.io/badge/Built%20with-Rust-orange.svg)](https://www.rust-lang.org/)
[![Docs](https://img.shields.io/badge/docs-read-3aa757.svg)](BUSINESS.md)

The Sentin8 platform: the shared library workspace (`sentin8-sdk`), the two
starters (`sentin8-cli`, `sentin8-captain`), the 17 platform services, the
Flutter package and platform apps, e2e, and packaging. Every repository in
this folder is an **independent git repo**; this folder is a plain group
directory (RS §4.4).

> **This group owns the dev infrastructure**: `docker-compose.yml` here is
> the single compose file for the whole tree - all vertical groups consume
> this PostgreSQL 18 + Valkey over localhost (RS §2.2.1). Both data planes
> run **certificate identity** (group DESIGN.md §3.1, §3.2): TLS-only,
> client-cert authentication, no data-plane passwords - `make infra-tls`
> mints the server leaves + operator pairs and seeds `pg_hba.conf`/
> `pg_ident.conf` BEFORE `make infra-up`.

## Layout

| Repo | Role |
|---|---|
| `sentin8-sdk` | THE shared workspace: all platform crates + service SDK crates + facade crate `sentin8` (tag `sdk-v0.1.0`) |
| `sentin8-cli` | Starter: platform bootstrap (`db bootstrap` → platform.sql), composable enrollment, captain control |
| `sentin8-captain` | Starter: process supervisor, health-gated tier spawning (D6) |
| `sentin8-{svc}` × 18 | Platform services: auth, acme, proxy, bus, db, storage, post, stat, secrets, sign, func, cron, flow, ai, sys, app, bff, web |
| `sentin8-flutter` | Shared Flutter package (native + web infra) |
| `sentin8-site-engine` | `@sentin8/site-engine` - the shared Docusaurus engine (theme, components, harvester, site scaffolder) behind sentin8.dev + every `{vertical}.dev` site (WEB) |
| `sentin8-site` | The public platform website at sentin8.dev (Docusaurus on the site engine; harvests the unit repos' docs trios) |
| `sentin8-auth-ui`, `sentin8-dash` | Platform Flutter apps |
| `sentin8-e2e` | Playwright cross-service suites |
| `sentin8-packaging` | deb split + vendored registry |

## Quickstart

```bash
make infra-up      # TLS-only PG 18 + Valkey (infra-tls mint → compose up)
make build         # sdk -> flutter bundles -> starters -> services (DAG order)
make start         # cold boot: provision-on-boot converges the platform
                   # registration (roles, identity rows, ACL/grant rows),
                   # then boots the platform core
```

`make enroll` stays as the manual convergence surface (composable, RS §6) -
`make start` runs the same pass automatically on every cold boot
(provision-on-boot, CLI DESIGN §4.2), so identity rows survive any reset
without remembering to enroll each repo.

A single-repo team never needs this folder's Makefile - clone e.g.
`sentin8-auth` alone; `cargo build` fetches the SDK pin and builds. Vertical
groups are built from their own group folders; vertical services ride the
captain via `SENTIN8_CAPTAIN_CATALOG_PATHS` (root .env) - this group never
builds or references a vertical (AGENTS rule 1).

## The core appliance (dev split-plane)

Vertical development against a stable, dockerized core (group DESIGN §3.3,
captain DESIGN §11.11):

```bash
make core-up       # core fleet (17 services) + PG + Valkey in ONE container,
                   # published on 127.0.0.1 only (443/5432/6379/18000)
                   # then: make enroll  (bootstraps + enrolls the virgin DB)
# verticals run on the HOST exactly as today (same DSNs, same DNS)
```

- Verticals keep their identical workflow: `*.local.sentin8.dev` still
  resolves to 127.0.0.1; PG/Valkey DSNs stay `localhost`.
- Hand a core service to the host for debugging (gdb, hot rebuilds):
  stop it on the appliance, start it on the host, traffic follows the
  registry (both directions verified live):
  ```bash
  export SENTIN8_CORE_APPLIANCE_IP=127.0.0.1   # enable per-key routing
  sentin8-cli captain stop-instance 127.0.0.1:8005   # auth leaves docker
  sentin8-cli captain start sentin8:auth             # spawns on the HOST
  sentin8-cli captain upgrade-instance 172.22.216.164:8003   # host rebuild loop
  # reverse: stop-instance <host-key> + start sentin8:auth -> back in docker
  ```
- The appliance captain's control socket is bind-mounted out
  (`.run/core-sock/captain.sock`) - the host CLI drives it with
  kernel-proven peer credentials, no device-flow sign-in for lifecycle ops.
- `make start` refuses while the appliance is up (double-boot guard).
  First boot converges in waves - captain's last-resort respawner parks
  and retries storm-timed-out services until the fleet is fully Active.

> Group docs: `README.md` (this file) - overview; `DESIGN.md` - the group's
> detailed design; `BUSINESS.md` - business requirements. Service-level
> docs live in each service repo. Design of record for the split:
> `../design/sentin8-repository-split-design.md`.

---

**Architecture & Design:** sentin8 and its underlying concepts were designed by [Hamid Jahanzad](https://www.linkedin.com/in/hamidjahanzad/).
