# sentin8/ Platform Group - Business Requirements & Functionality

> Audience: product owners, business analysts, and anyone evaluating what
> the platform group **does for the business**. For architecture read
> `README.md`/`DESIGN.md`; for the split's design of record read
> `../design/sentin8-repository-split-design.md`.

## 1. Business Purpose

- Single identity, authorization, and audit plane for every vertical
  product the company ships.
- One-time platform investment (TLS, eventing, storage, scheduling,
  observability) reused by all verticals - vertical teams ship product,
  not infrastructure.
- A fleet a single operator can run: one supervisor (captain), one CLI,
  one data plane.

## 2. Business Scope (What the Group Provides)

| Capability | Provided by | Business meaning |
|---|---|---|
| Identity: sign-in, OAuth/OIDC/FAPI, sessions, JWKS | `sentin8-auth` | Users sign in once; every app trusts it |
| Certificates: internal CA, automatic TLS | `sentin8-acme` | Every service is TLS-encrypted by default |
| Routing: single public ingress | `sentin8-proxy` | One front door for the whole platform |
| Eventing: durable streams, triggers, DLQ | `sentin8-bus` | Services integrate without point-to-point APIs |
| Data + objects | `sentin8-db`, `sentin8-storage` | Tenant-isolated persistence and files |
| Notifications | `sentin8-post` | Email/SMS/push delivery for all services |
| Analytics/telemetry | `sentin8-stat` | Product and ops metrics |
| Secrets | `sentin8-secrets` | Credential storage by reference |
| Scheduling, workflows, functions | `sentin8-cron`, `sentin8-flow`, `sentin8-func` | Automation without bespoke infra |
| Orchestration | `sentin8-sys`, `sentin8-app` | Orgs, environments, app store |
| Client access | `sentin8-bff`, `sentin8-web` | Tokens never reach browsers; app hosting |
| AI | `sentin8-ai` | Embeddings/completions as a shared capability |

## 3. What the Group Does NOT Own

| Concern | Owner |
|---|---|
| Vertical business logic (banking, hotels, …) | the `{vertical}/` groups |
| Vertical data | per-vertical databases (enroll-created, on the shared PG instance) |
| Dev infrastructure for vertical groups | provided by THIS group (`docker-compose.yml`, §2.2.1) |

## 4. Business Rules & Invariants

1. A vertical cannot exist without the platform: every vertical repo pins
   `sentin8-sdk` (its identity, TLS, and eventing come from here).
2. Platform services never depend on a vertical (one-way DAG).
3. Every tenant action is authorized by Shield and audited.
4. The platform is the single operator surface: start, stop, upgrade,
   enroll - via `sentin8-cli` + `sentin8-captain`.

## 5. Roles & Use Cases

| Role | Uses |
|---|---|
| Platform operator | `sentin8-cli`, `sentin8-captain` - fleet lifecycle |
| Vertical dev team | clones ONE repo; the SDK pin carries the platform |
| Release engineer | `sentin8-packaging` - deb packages + vendored registry |
| QA | `sentin8-e2e` - browser-level cross-service suites |

## 6. KPIs / Success Criteria

- Single-repo onboarding: clone → build → run with zero sibling checkouts.
- Fleet boot: captain reaches all-Active with health-gated tiers.
- Split hygiene: 90 repos, zero path deps, zero stale pins.

## 7. Acceptance Criteria

1. All 25 platform-group repos build independently from their git pins.
2. `make infra-up && make build` in this folder is a working day-1 loop.
3. Vertical groups consume this group via `sentin8-sdk` git tag only.

## 8. Open Business Questions

- Remote hosting (GitHub org + tag renaming) when repos are pushed.
- RS-4 owner-API conversions (cross-schema grant retirement).

---

**Design attribution:** sentin8 and its underlying concepts were designed by Hamid Jahanzad <Hamid@Jahanzad.com>.
