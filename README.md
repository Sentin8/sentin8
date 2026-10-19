# sentin8/ - Platform Group

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
| `sentin8-{svc}` × 17 | Platform services: auth, acme, proxy, bus, db, storage, post, stat, secrets, func, cron, flow, ai, sys, app, bff, web |
| `sentin8-flutter` | Shared Flutter package (native + web infra) |
| `sentin8-site-engine` | `@sentin8/site-engine` - the shared Docusaurus engine (theme, components, harvester, site scaffolder) behind sentin8.dev + every `{vertical}.dev` site (WEB) |
| `sentin8-site` | The public platform website at sentin8.dev (Docusaurus on the site engine; harvests the unit repos' docs trios) |
| `sentin8-auth-ui`, `sentin8-dash` | Platform Flutter apps |
| `sentin8-e2e` | Playwright cross-service suites |
| `sentin8-packaging` | deb split + vendored registry |

## Quickstart

```bash
make infra-up      # TLS-only PG 18 + Valkey (infra-tls mint → compose up)
make build         # sdk -> starters -> 17 services (DAG order)
make enroll        # enroll every platform service repo (composable, RS §6)
```

A single-repo team never needs this folder's Makefile - clone e.g.
`sentin8-auth` alone; `cargo build` fetches the SDK pin and builds. Vertical
groups are built from their own group folders; vertical services ride the
captain via `SENTIN8_CAPTAIN_CATALOG_PATHS` (root .env) - this group never
builds or references a vertical (AGENTS rule 1).

> Group docs: `README.md` (this file) - overview; `DESIGN.md` - the group's
> detailed design; `BUSINESS.md` - business requirements. Service-level
> docs live in each service repo. Design of record for the split:
> `../design/sentin8-repository-split-design.md`.

---

**Design attribution:** sentin8 and its underlying concepts were designed by Hamid Jahanzad <Hamid@Jahanzad.com>.
