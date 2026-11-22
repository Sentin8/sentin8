# OIDF Conformance Rig Runbook (local certification testing)
[![License: Apache 2.0](https://img.shields.io/badge/License-Apache_2.0-blue.svg)](../../../../LICENSE)
[![Built with Rust](https://img.shields.io/badge/Built%20with-Rust-orange.svg)](https://www.rust-lang.org/)
[![Docs](https://img.shields.io/badge/docs/read-3aa757.svg)](https://sentin8.dev/docs/products/auth)
[![Website](https://img.shields.io/badge/website-sentin8.dev-1a73e8.svg)](https://sentin8.dev)


> Scope: everything Sentin8:Auth implements **except Front-Channel
> Logout and Implicit/Hybrid OP** (deliberate design exclusions - see
> `sentin8-auth/DESIGN.md` §9a). The OIDF suite is free to run; the
> open-source fee waiver applies at submission time.

## 1. Prerequisites

- Docker + Compose plugin.
- `127.0.0.1 localhost.emobix.co.uk` in `/etc/hosts`.
- The local platform running (`make start` from `sentin8/`) **in
  classical mode** so the suite's Java client can talk to it:
  `SENTIN8_TLS_PQ_MODE=classical` in the root `.env` for rig runs
  (the platform's emergency-rollback mode: TLS 1.2/1.3 classical
  groups + RS256 JWT signing - the same protocol logic, suite-visible
  algorithms).
- The Acme root CA trusted by the suite's Java runtime: import
  `.run/secrets/acme-ca/root-ca.crt` into the server container
  truststore, or run `make conformance-ca` to bake it into a derived
  image (recommended).
- The **suite ingress leaf** (no self-signed warnings): `make infra-tls`
  mints `.run/secrets/infra-tls/conformance-suite-server.crt/.key`
  (CN `conformance-suite`, SAN `localhost.emobix.co.uk`, signed by the
  platform CA the OS already trusts); `make conformance-up` mounts the
  pair into the suite's nginx (auth DESIGN §9a.2 step 1b). Run
  `make infra-tls` once before the first `conformance-up` if the
  material is missing.

## 1b. Rig domain mode (RIGMODE-1)

The OP hostname under the rig is a make selection (auth DESIGN
9a.2 item 2c) - no `.env` edit:

```bash
make conformance-domain-local                            # loopback wildcard (default)
CONFORMANCE_DOMAIN=oidf.sentin8.dev \
  make conformance-domain-platform                       # real domain, platform CA
CONFORMANCE_DOMAIN=real.domain.example \
  CONFORMANCE_ACME_UPSTREAM_URL=https://acme-staging-v02.api.letsencrypt.org/directory \
  make conformance-domain-public                         # real domain, upstream CA
```

The chosen target writes `conformance/domain.env` (repo root, gitignored)
- the ONE override block every rig consumer reads: `start-conformance`
sources it after `.env` (so it wins), the seed/generator derive the
tenant hosts from it, and `conformance-up` regenerates the suite
container's family `extra_hosts` from it. After a mode change, restart
the fleet (leaf caches are hostname-scoped): `make stop &&
make conformance-up`.

| Mode | `SENTIN8_DOMAIN` | Leaf issuer | Publicly resolvable |
|---|---|---|---|
| `local` | `local.sentin8.dev` | platform CA (HTTP-01 short-circuit) | resolves to 127.0.0.1 |
| `platform` | operator domain (wildcard zone → the box) | platform CA | yes |
| `public` | operator domain | upstream CA via acme's relay | yes, port 80 open |

### 1c. Ingress reachability - when a mode actually needs the internet path

The three modes differ in what must reach this box from OUTSIDE:

| Mode | Who connects from outside | Inbound requirement |
|---|---|---|
| `local` | none - everything runs on this box | none |
| `platform` | none for the campaign (browser, suite server, CLI, seed are all local) | none for the rig; only a REMOTE human browser testing `https://auth...` needs it |
| `public` | the upstream CA's http-01 validator (port 80) | REQUIRED - the challenge never arrives otherwise and orders time out |

On a WSL2 dev box the internet path has an extra hop the platform
cannot provision itself (Windows-side, one-time, elevated PowerShell):

```
internet -> router(public IP) -> Windows host(LAN IP) --portproxy--> WSL2 VM -> sentin8-proxy
```

The router forwards `*.oidf.sentin8.dev`'s ports to the Windows LAN
IP; WSL2 sits behind the Windows NAT, so the last hop needs a `netsh
portproxy` - and because the WSL2 VM IP changes on every WSL restart,
a static one dies silently. `scripts/windows/wsl-portproxy.ps1` (in the group
tree) reconciles the forwarding to the live IP:

```powershell
# one-time install (also copies itself to C:\Scripts and registers the
# logon + 5-minute refresh task):
powershell -ExecutionPolicy Bypass -File scripts\windows\wsl-portproxy.ps1 -RegisterTask

# verify from the WSL side (hits the Windows host directly - no hairpin):
#   echo | openssl s_client -connect <windows-LAN-IP>:443 \
#     -servername auth.cert.conformance-local.oidf.sentin8.dev | openssl x509 -noout -subject
```

The script listens on `0.0.0.0:80,443`, deletes only its OWN stale
rows (our ports + a WSL-range connect address), keeps the firewall
rule idempotent, and logs to
`C:\ProgramData\sentin8\wsl-portproxy.log`. Verify the LAST hop
externally with a public port-checker on the public IP (an in-box
hairpin probe fails regardless - it egresses and has no shortcut
back; do not trust its verdict).

## 2. Start the suite

```bash
make conformance-up      # pulls + starts mongo, suite server, nginx
```

Suite UI: https://localhost.emobix.co.uk:8443/ (self-signed cert warning
is expected; accept it).

## 3. Seed the certification tenant (no direct SQL)

Provision through the platform's own API surface - the same rule as the
E2E suite applies (no `psql`, no direct DB writes):

```bash
make conformance-seed
```

The seed script (via `sentin8-cli call` + sign-up):
1. Signs up / signs in the certification user (`cert@…`).
2. Creates org `conformance-local` + env `cert`.
3. Sets the env's security profile to the target per run (the env row
   otherwise INHERITS the platform's `fapi_2` posture - PAR+JARM+DPoP -
   which plain OIDC Core tests cannot pass; `standard` = plain code
   flow + RS256, all FAPI flags off; override with `CONFORMANCE_PROFILE`
   for FAPI runs, but the FAPI profiles ALSO need their flags re-enabled
   on the row - the seed sets the `standard` flag shape only):
   - `standard` for OIDC Core/Config/Dynamic + Logout profiles,
   - `fapi_2` for FAPI 2 Security Profile / Message Signing,
   - `fapi_1_advanced` for FAPI 1 Advanced,
   - `fapi_ciba` for CIBA runs.
4. Registers the conformance clients through the DCR endpoint (or the
   admin API for pre-registered variants), each with the suite callback
   in `redirect_uris`:
   - `client_secret_basic` client, `client_secret_post` client,
   - `private_key_jwt` client (suite-supplied JWK),
   - `tls_client_auth` client (suite-supplied cert),
   - public PKCE client (`token_endpoint_auth_method: none`),
   - CIBA client with `backchannel_client_notification_endpoint` set to
     the suite's ping callback (ping-mode runs).
   Redirect URI shape:
   `https://localhost.emobix.co.uk:8443/test/a/sentin8-local/callback`.

## 4. Run the profiles

In the suite UI: "Create a new test plan" → pick the profile → fill the
configuration (discovery URL, client credentials, test user) → ALIAS
`sentin8-local`. Per profile:

| Profile plan | Security profile | Notes |
|---|---|---|
| OIDC Core: Basic OP | `standard` | run first; browser automation signs in the seeded user |
| OIDC Core: Config OP | `standard` | discovery completeness (DESIGN §9a.4) |
| OIDC Core: Dynamic OP | `standard` | DCR + WebFinger; the suite registers its own clients |
| Logout: RP-Initiated | `standard` | `state` echo on the registered post-logout redirect |
| Logout: Back-Channel | `standard` | logout token shape (`events`/`sid`, no `nonce`) |
| FAPI 2: Security Profile | `fapi_2` | PAR + DPoP (client ES256) + JARM + `iss` |
| FAPI 2: Message Signing | `fapi_2_message_signing` | adds HTTP signatures + signed introspection |
| FAPI 1: Advanced (final) | `fapi_1_advanced` | mTLS/private_key_jwt + JAR + `s_hash` |
| FAPI-CIBA: Poll | `fapi_ciba` | binding_message enforced |
| FAPI-CIBA: Ping | `fapi_ciba` | the suite's ping callback must be reachable from auth |

Result rule: every test must end PASSED / WARNING / REVIEW (no FAILED,
no INTERRUPTED) **and none may be SKIPPED** before the profile counts as
locally green - a suite skip means discovery advertised the capability
away, which is a coverage hole with the same priority as a failure (auth
DESIGN §9a.10). Export each run's logs (JSON + log-detail.html) into
`.tmp/conformance/results/`.

### 4b. The VCI family seats (battery table extract)

The battery's VCI families run the FULL catalog cell matrix per
certification catalog (OIDF-VCIMDOC-1, auth DESIGN §9a.19x):

| Family (family key) | Plan | Cells |
|---|---|---|
| `vci-issuer` (cert-vci) | `oid4vci-1_0-issuer-test-plan` | sd_jwt_vc x 14 module-variants |
| `vci-haip` (cert-haip) | `oid4vci-1_0-issuer-haip-test-plan` | `credential_format` (sd_jwt_vc, mdoc) x flow (wallet_initiated, issuer_initiated) - 6 plans |
| `vci-wallet` (cert-wallet) | `oid4vci-1_0-wallet-test-plan` + `oid4vci-1_0-wallet-haip-test-plan` | plain plan + HAIP campaign: format (sd_jwt_vc, mdoc) x flow (wallet, issuer_initiated by_value/by_reference) - 6 HAIP plans (the mdoc cells need `WALCERT_HOLDER_URL` - campaign mode) |
| `oid4vp-wallet` (cert-vpw) | `oid4vp-1final-wallet-haip-test-plan` | `credential_format` (sd_jwt_vc, iso_mdl) x response mode (direct_post.jwt, dc_api.jwt) |

The mdoc cells' trust anchor is the SUITE's own IACA root
(`/mdoc-iaca-root.pem`, fetched live at plan-create time); the
registered clients carry the mdoc configuration scope
(`eudi.pid.mdoc.1`).

## 5. CIBA ping connectivity (local)

The suite's ping callback lives inside its docker network. For local
ping runs, point the CIBA client's
`backchannel_client_notification_endpoint` at the host-reachable alias
`https://localhost.emobix.co.uk:8443/test/a/sentin8-local/callback`
and ensure the auth service can resolve + reach it (same `/etc/hosts`
entry; the platform's CA is in the auth host's trust store already).

## 6. Teardown

```bash
make conformance-down     # stop (keeps mongo volume for history)
make conformance-purge    # stop + delete the volume (clean slate)
```

## 6b. HOSTED target - the OIDF production suite (auth DESIGN 9a.2d)

The same harness drives `https://www.certification.openid.net` - the
OIDF-operated instance certification results must run on for a
submission. No suite Docker stack runs there; the differences are the
suite base + the API auth:

1. **Sign in once (interactive).** The instance requires a real
   Google/GitLab sign-in (no devmode dummy user). The bootstrap spec
   opens the browser for it and then mints the campaign's API bearer
   token under the signed-in session (`POST /api/token` - the same
   call the suite's Tokens page makes; admins cannot mint - use a
   non-admin account):

   ```bash
   make conformance-hosted-bootstrap
   # or: cd sentin8-auth-oidf && CONFORMANCE_SUITE_TARGET=hosted \
   #       pnpm exec playwright test tests/suite-token-bootstrap.spec.ts
   ```

   The token (24h TTL by default; `CONFORMANCE_SUITE_TOKEN_PERMANENT=true`
   mints a permanent one - delete it from the suite after the
   campaign) persists to `.tmp/conformance/suite-token.env` (chmod 600).
2. **Publicly reachable OP.** The suite's server-side clients AND the
   browser callbacks must reach the certification host - run the
   platform fleet in the `public` rig domain mode (§1, §1b; the
   portproxy collateral is the same):

   ```bash
   make conformance-hosted-up   # start-conformance + the mode check; NO suite docker
   ```
3. **Seed with the hosted callback.** The seed builds the DCR callback
   from the same switch:

   ```bash
   CONFORMANCE_SUITE_TARGET=hosted \
     SENTIN8_SENTIN8_AUTH_URL="https://auth.ops.sys.oidf.sentin8.dev" \
     make conformance-seed-all
   ```
   (each per-env callback becomes
   `https://www.certification.openid.net/test/a/<alias>/callback`).
4. **Run the battery.** The runner gates the token (a missing one
   fails loud with the bootstrap hint) and carries it to every suite
   call as `Authorization: Bearer`:

   ```bash
   CONFORMANCE_SUITE_TARGET=hosted \
     SENTIN8_SENTIN8_AUTH_URL="https://auth.ops.sys.oidf.sentin8.dev" \
     make conformance-hosted    # or: bash conformance/conformance-run-all.sh <families>
   ```

   A suite 401 mid-battery is answered loud - re-run the bootstrap,
   never a silent re-login.
5. **`staging.certification.openid.net`** (the suite's master branch,
   continuously deployed): pass
   `CONFORMANCE_SUITE_URL=https://staging.certification.openid.net`
   instead of the target switch - the token bootstrap + battery read
   the same override.

## 7. Submission (operator step, after local green)

Publish the runs on the OIDF suite, file the certification requests per
profile family under the open-source fee waiver (attestation statement
required for Dynamic OP), and record the granted "OpenID Certified"
marks in `sentin8-auth/README.md`.