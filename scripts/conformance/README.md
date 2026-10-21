# OIDF Conformance Rig Runbook (local certification testing)

> Scope: everything Sentin8:Auth implements **except Front-Channel
> Logout and Implicit/Hybrid OP** (deliberate design exclusions — see
> `sentin8-auth/DESIGN.md` §9a). The OIDF suite is free to run; the
> open-source fee waiver applies at submission time.

## 1. Prerequisites

- Docker + Compose plugin.
- `127.0.0.1 localhost.emobix.co.uk` in `/etc/hosts`.
- The local platform running (`make start` from `sentin8/`) **in
  classical mode** so the suite's Java client can talk to it:
  `SENTIN8_TLS_PQ_MODE=classical` in the root `.env` for rig runs
  (the platform's emergency-rollback mode: TLS 1.2/1.3 classical
  groups + RS256 JWT signing — the same protocol logic, suite-visible
  algorithms).
- The Acme root CA trusted by the suite's Java runtime: import
  `.run/secrets/acme-ca/root-ca.crt` into the server container
  truststore, or run `make conformance-ca` to bake it into a derived
  image (recommended).

## 2. Start the suite

```bash
make conformance-up      # pulls + starts mongo, suite server, nginx
```

Suite UI: https://localhost.emobix.co.uk:8443/ (self-signed cert warning
is expected; accept it).

## 3. Seed the certification tenant (no direct SQL)

Provision through the platform's own API surface — the same rule as the
E2E suite applies (no `psql`, no direct DB writes):

```bash
make conformance-seed
```

The seed script (via `sentin8-cli call` + sign-up):
1. Signs up / signs in the certification user (`cert@…`).
2. Creates org `conformance-local` + env `cert`.
3. Sets the env's security profile to the target per run:
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
no INTERRUPTED) before the profile counts as locally green. Export each
run's logs (JSON + log-detail.html) into `.tmp/conformance/results/`.

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

## 7. Submission (operator step, after local green)

Publish the runs on the OIDF suite, file the certification requests per
profile family under the open-source fee waiver (attestation statement
required for Dynamic OP), and record the granted "OpenID Certified"
marks in `sentin8-auth/README.md`.