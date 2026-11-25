# Closing C (Jurisdiction OP) + D (RP Role) — Plan & Sizing

Research-first plan for the 122 remaining OIDF catalog cells left out of
`done.md` (see `not-done.md` §C and §D). Written 2026-11-24 after reading
the conformance-suite source (GitLab `openid/conformance-suite`, project
`4175605`, branch `master`) and auditing our own RP code.

---

## 0. Direct answer: what is our auth client, is it an RP?

**Yes — we already ship RP code, in three places.** The gap is not
capability, it is *certifiability*: none of it is packaged as a
conformant, testable RP endpoint.

| Component | Path | What it is | RP-conformance readiness |
|---|---|---|---|
| **`sentin8-auth-client`** | `sentin8-sdk/identity/auth-client/src/lib.rs` (1,785 lines) | Generic OIDC/OAuth client: discovery, `authorize_url` with PKCE-S256, `exchange_code`, `refresh_token`, `revoke_token`, `introspect_token`, `verify_token` (JWKS-backed), `user_info` | **Partial.** No `nonce` on authorize, no `at_hash`/`c_hash`/`s_hash` validation, no `iss` validation, no id_token decryption, no logout. `verify_token` checks signature + `exp` only. |
| **`sentin8-sdk-identity-fapi`** | `sentin8-sdk/identity/fapi/src/` (1,985 lines, 8 files) | Full FAPI RP stack: PAR push, JAR request objects, DPoP proofs w/ nonce, JARM validation, mTLS aliases, `private_key_jwt` client assertions, discovery, JWKS cache | **Strong — closest to certifiable.** This is the crate the FAPI RP cells would certify. |
| **`sentin8-bff`** | `sentin8-bff/src/handlers.rs` | Production RP: `/auth/login` → authorize w/ PKCE + state cookie, `/auth/callback` → `exchange_code` | **Works, not conformant.** Uses the FAPI client, but it is an app surface, not a test harness. |
| `wallet8` / `wallet8-sdk` | separate vertical repo | OID4VP/OID4VCI **wallet** role (already certified) | n/a — wallet role ≠ RP role |

So the honest answer: **we are an RP in production (the BFF), and we own
a real FAPI RP library — but we have never packaged an RP as a
certifiable artefact, and the generic `auth-client` is missing most
id_token validation.**

---

## 1. The structural difference that drives all the sizing

This is the single most important finding, and it changes the shape of
the work from everything we have done so far.

**In every campaign shipped to date, the suite is the CLIENT and we are
the SERVER.** The suite drives browser URLs, and our harness drives the
browser. OPs, issuers, verifiers: all of that is server-side.

**In an RP campaign the roles invert: the suite becomes the OP/AS**, and
our code becomes the *client under test*. From the OIDF RP instructions:

> "When you are testing a relying party, you configure it to use the
> conformance suite as the identity provider... The conformance suite
> essentially provides a 'fake' OpenID Provider / OAuth2 Authorization
> Server. When you start a test, you will see the 'issuer' and
> 'discoveryUrl' in the 'exported values' section. The test will show as
> 'WAITING' status and in most cases the next step is to start the login
> flow in your relying party."

Confirmed in `AbstractOIDCCClientTest.java`:
- `start()` → `setStatus(Status.WAITING)` — it waits for **the RP to call it**
- `handleHttp(path, ...)` routes `authorize`, `token`, `jwks`, `userinfo`, `webfinger`

### Consequences

1. **The harness needs a new driver mode.** Today `fixtures/runner.ts`
   polls WAITING → drives a browser → reads our server's log. RP tests
   need WAITING → **run an RP client against the suite's `issuer`** →
   the suite advances on *its own* inbound requests. This is a new
   fixture, not a tweak.
2. **The RP under test must be reachable by the suite**, over HTTPS, on
   a stable host, with a registered `redirect_uri`.
3. **The RP must be a headless HTTP service**, not a Flutter UI: the
   suite's "browser" step is just "some user-agent hits the RP's login
   URL". A JSON/redirect HTTP endpoint suffices — no new Flutter work.
4. **Test isolation.** RP tests mutate RP state (tokens, sessions). Each
   module needs a clean RP, so the RP needs a reset/stateless mode.

---

## 2. Bucket C — Jurisdiction OP overlays (50 cells)

### 2.1 Composition

All **14 jurisdiction OP catalog pages**, enumerated cell-by-cell from
the OIDF tables (independently re-derived, matches `not-done.md` §C):

| # | Page | Open cells | Page URL |
|---|---|---|---|
| 1 | FAPI1 OP — UK Open Banking | 2 | `certified-fapi1-op-uk-open-banking` |
| 2 | FAPI1 OP — Australia CDR | 3 | `certified-fapi1-op-australia-cdr` |
| 3 | FAPI1 OP — Brazil Open Banking | 9 | `certified-fapi1-op-brazil-open-banking` |
| 4 | FAPI1 OP — Brazil Open Finance (FAPI-BR v2) | 2 | `certified-fapi1-op-brazil-open-finance-fapi-br-v2` |
| 5 | FAPI1 OP — Brazil Open Insurance | 9 | `certified-fapi1-op-brazil-open-insurance` |
| 6 | FAPI1 OP — Brazil Open Insurance (FAPI-BR v2) | 2 | `certified-fapi1-op-brazil-open-insurance-fapi-br-v2` |
| 7 | FAPI1 OP — KSA Open Banking | 2 | `certified-fapi1-op-ksa-open-banking` |
| 8 | FAPI1 OP — Second Implementer's Draft (incl. UK-OB) | 8 | `certified-fapi1-op-second-implementers-draft-including-uk-open-banking` |
| 9 | FAPI2 OP — KSA Open Banking | 2 | `certified-fapi2-op-ksa-open-banking` |
| 10 | CBUAE FAPI 2.0 OP Message Signing | 1 | `certified-cbuae-fapi-2-0-op-message-signing` |
| 11 | CBUAE FAPI 2.0 OP Message Signing ID1 | 1 | `certified-cbuae-fapi-2-0-op-message-signing-id1` |
| 12 | Australia FAPI 2.0 OP ConnectID Final | 1 | `certified-australia-fapi-2-0-op-connectid-final` |
| 13 | Australia FAPI 2.0 OP ConnectID ID draft | 1 | `certified-australia-fapi-2-0-op-connectid-implementers-draft` |
| 14 | FAPI 2.0 OP SP 2nd ID + MS 1st ID (superseded) | 7 | `certified-fapi-2-0-op-security-profile-second-implementers-draft-message-signing-first-implementers-draft` |
| | **Total** | **50** | **14 pages** |

Grouped:

| Group | Cells | Pages |
|---|---|---|
| Brazil (OB / OPIN / OF v2 / OPIN v2) | 22 | 4 |
| FAPI1 second-ID draft (incl. UK-OB) | 8 | 1 |
| UK Open Banking | 2 | 1 |
| Australia CDR | 3 | 1 |
| **FAPI1 KSA Open Banking** | 2 | 1 |
| **FAPI2 KSA Open Banking** | 2 | 1 |
| **Superseded FAPI2 OP ID2** | 7 | 1 |
| CBUAE (final + ID1) | 2 | 2 |
| Australia ConnectID (final + draft) | 2 | 2 |
| **Total** | **50** | **14** |

> **Correction (2026-11-24).** An earlier revision of this file showed
> 48 cells / 13 pages — it omitted the **FAPI2 OP — KSA Open Banking**
> row and mis-labelled "KSA Open Banking" as a single page. The
> catalog tally is 50; `not-done.md` §C was correct throughout. Verified
> by re-scraping all 14 pages: every one carries a Sentin8 row with
> blank cells and no other rows.

### 2.2 What each group actually requires

These are **not** plan re-runs. Reading `FAPI1AdvancedFinalClientTestPlan.certificationProfileName()`
and `FAPI2SPFinalTestPlan.certificationProfileName()` shows each
jurisdiction profile adds *protocol surface*, not just config:

| Group | New platform surface required | Verdict |
|---|---|---|
| **Superseded FAPI2 OP ID2 (7)** | Nothing — we hold the **Final** versions | **Do not pursue.** Certifying a superseded draft adds zero value and will not be listed favourably. Recommend formally closing as "superseded". |
| **CBUAE (2), ConnectID AU (2), FAPI2 KSA (2), FAPI1 KSA (2)** | The suite *rejects* these on the FAPI2 SP plan (`throw ... "requires JAR, please use the message signing test plan"`). So they run on the **Message Signing** plan we already pass. KSA/ConnectID need: `purpose` claims, ConnectID trust-framework `verified_claims`, forced `openid`-only scope (ConnectID), KSA consent/`acr` profile. | **Feasible but low value** — 8 cells, each a distinct claim/consent model. |
| **Australia CDR (3 OP)** | CDR register integration, `cdr_arrangement_id` grant management (merge/replace/revoke), sharing-duration rules, the 90-day reauthorisation rule | **Real product work.** ~1-2 weeks of OP surface. |
| **UK Open Banking (2 OP)** | An **`intent_id`** obtained via a *client_credentials* call to the AS, then passed as an essential claim in the request object; ecosystem `acr` values | **Real product work** — needs the CC grant (bucket A) first, plus intent lifecycle. |
| **Brazil (22 OP)** | Directory **software statements**, `org_jwks`, consent-scoped `authorization_details`, `consentUrl` flow, `brazilCpf/Cnpj` claims, DCR variant with signed software statements | **Heaviest.** 22 cells, ~4-6 weeks of genuine OP feature work. |
| **FAPI1 second-ID draft (8)** | Superseded draft + a mix of UK-OB/AU-CDR/FAPI-RW behaviours | **Do not pursue** (superseded). |

**Total across all 14 pages: 50 OP cells** — 15 superseded (7 FAPI2-ID2
+ 8 FAPI1-ID2), 8 low-value jurisdiction claims, 25 real product work
(UK 2, AU-CDR 3, Brazil 22).

### 2.3 Bucket C sizing

| Option | Cells closed | Effort | Recommendation |
|---|---|---|---|
| **C-lite**: the 8 low-value jurisdiction cells (CBUAE 2, ConnectID 2, KSA 4) + formally close the 15 superseded-draft cells | 8 (+15 closed) | **M** (~1.5 wk) | Worth it only if a UAE/KSA/AU market is real |
| **C-uk**: C-lite + UK-OB OP | 10 (+15) | **L** (~3-4 wk) | Cheapest *useful* market (needs bucket A first) |
| **C-au**: C-lite + AU-CDR OP | 11 (+15) | **L** (~3-4 wk) | Needs CDR register + arrangement grants |
| **C-br**: C-lite + Brazil OP | 30 (+15) | **XL** (~6-8 wk) | Only if Brazil Open Finance/Insurance is a target market |
| **C-max**: all 50 | 50 | **XL** (~8-10 wk) | Includes the 15 superseded cells — **not recommended** |

**My recommendation: do not start bucket C.** Every group except the
15 superseded cells is market-driven, and Brazil/UK/CDR are separate
product programmes (directory onboarding, regulator certification,
consent lifecycle) — not conformance chores. Revisit per market.

---

## 3. Bucket D — RP role (72 cells)

### 3.1 Composition (verified plan names)

| Page | Cells | Suite plan name(s) |
|---|---|---|
| OIDC RP — Basic | 1 | `oidcc-client-basic-certification-test-plan` |
| OIDC RP — Config | 1 | `oidcc-client-config-certification-test-plan` |
| OIDC RP — Dynamic | 1 | `oidcc-client-dynamic-certification-test-plan` |
| OIDC RP — Implicit | 1 | `oidcc-client-implicit-certification-test-plan` |
| OIDC RP — Hybrid | 1 | `oidcc-client-hybrid-certification-test-plan` |
| OIDC RP — Form Post (basic/implicit/hybrid) | 1 | `oidcc-client-formpost-{basic,implicit,hybrid}-certification-test-plan` |
| OIDC RP — 3rd Party-Init | 1 | `oidcc-client-test-3rd-party-init-login-test-plan` |
| OIDC RP Logout — RP-Initiated / Session / Front-Channel / Back-Channel | 4 | `OIDCCClient{RPInitiatedLogout,SessionManagement,FrontChannelLogout,BackChannelLogout}RP{Basic,Hybrid,Implicit}TestPlan` |
| FAPI1-Adv RP | 12 | `fapi1-advanced-final-client-test-plan` |
| FAPI2 RP SP+MS Final | 7 | `fapi2-security-profile-final-client-test-plan`, `fapi2-message-signing-final-client-test-plan` |
| **Superseded** FAPI2 RP ID2+MS ID1 | 16 | `fapi2-*-id{2,1}-client-test-plan` |
| FAPI-CIBA RP (BR-OF) | 1 | Brazil-specific |
| Jurisdiction RP (BR-OB 8, BR-OF 2, BR-OPIN 4+1, KSA 2, FAPI1-ID2 2, FAPI2-KSA 2, CBUAE 2, ConnectID 2) | 25 | mixed |

**Non-superseded, non-jurisdiction RP cells: 31**
(7 OIDC + 4 OIDC-logout + 12 FAPI1-Adv + 7 FAPI2 + 1 CIBA).

### 3.2 The one architectural prerequisite

A **certifiable RP harness**: a headless HTTPS RP service that

- boots from a config (issuer/discovery URL, client_id/secret or JWKS, redirect_uri)
- serves `/login` → builds the authorize request (PKCE, nonce, state, `response_type` per profile)
- serves `/callback` → validates the response, exchanges the code, **validates the id_token fully**
- serves `/logout`, `/post-logout`, and the front/back-channel logout receivers
- serves a JWKS endpoint when it registers `jwks_uri`
- can be driven for every negative case the suite injects

This is one new crate + one new fixture, and it is **shared by all 31
non-jurisdiction RP cells** — that is the leverage.

### 3.3 Gap analysis vs. what we own

| Requirement | Today | Work |
|---|---|---|
| Discovery-driven authorize + PKCE | ✅ `auth-client`, `fapi` | reuse |
| `nonce` on authorize | ❌ absent in `auth-client`; ✅ in FAPI path | small |
| `at_hash` / `c_hash` / `s_hash` validation | ❌ | **new** (~200 LOC) |
| `iss` validation (OIDC Core 3.1.3.7) | ❌ | small |
| id_token signature + `aud`/`azp` | ✅ partial | small |
| **id_token decryption (JWE)** | ❌ no JWE path | **new** — required by FAPI1 RP `EncryptedIdToken` + `RSA15` modules |
| PAR / JAR / DPoP / JARM / mTLS / pki-jwt | ✅ `fapi` crate | reuse |
| Front-channel logout receiver | ❌ | **new** (iframe HTML) |
| Back-channel logout receiver + logout-token validation | ❌ | **new** (ES256/RS256, `sid`, `events`, `iss`/`aud`) |
| Session-management `check_session_iframe` postMessage client | ❌ | **new** (browser-side JS + orchestration) |
| RP-Initiated Logout (`end_session` + `post_logout_redirect_uri`) | ❌ (only discovery field parsed) | **new** |
| 3rd-party-initiated login (`login_hint`/`iss` handling) | ❌ | small |
| Dynamic client registration as an RP | ❌ | small (DCR client) |
| Headless harness crate | ❌ | **new** (~1 crate) |
| Playwright fixture for RP mode | ❌ | **new** (~1 fixture) |

### 3.4 Bucket D sizing

| Sub-bucket | Cells | Effort | Notes |
|---|---|---|---|
| **D0. RP harness + id_token validation core** | 0 (enabler) | **L** (~2 wk) | New crate + fixture; unblocks everything below |
| **D1. OIDC RP Basic / Config / Dynamic / 3rd-Party** | 4 | **M** (~1 wk) | builds on D0 |
| **D2. OIDC RP Implicit + Hybrid + Form Post** | 3 | **M** (~1 wk) | response-type + form_post handling |
| **D3. OIDC RP Logout (4)** | 4 | **L** (~2 wk) | front-channel iframe, back-channel logout JWT, session mgmt postMessage |
| **D4. FAPI2 RP SP + MS Final** | 7 | **M** (~1.5 wk) | `fapi` crate is 80% there; JARM + JWE id_token are the gaps |
| **D5. FAPI1-Adv RP** | 12 | **L** (~2.5 wk) | 12 cells, incl. encrypted id_token + RSA1_5 negatives |
| **D6. FAPI-CIBA RP (BR-OF)** | 1 | **S** (~2 d) | needs Brazil CIBA config |
| **D-total (non-jurisdiction)** | **31** | **~10-11 wk** | sequential, one engineer |
| D-jurisdiction RP | 25 | **XL** (~6-8 wk) | Brazil/UK/CDR/KSA — market-driven |
| D-superseded RP ID2 | 16 | — | **do not pursue** |

---

## 4. Recommended sequencing and total size

```
D0  RP harness + id_token validation        L   2 wk   ← enabler, nothing ships without it
 ├─ D1 OIDC RP Basic/Config/Dynamic/3rd    M   1 wk   → +4 cells
 ├─ D2 OIDC RP Implicit/Hybrid/FormPost    M   1 wk   → +3 cells
 ├─ D3 OIDC RP Logout (4)                  L   2 wk   → +4 cells
 ├─ D4 FAPI2 RP SP+MS (7)                  M   1.5wk  → +7 cells
 └─ D5 FAPI1-Adv RP (12)                   L   2.5wk  → +12 cells
D6  FAPI-CIBA RP BR-OF                    S   2 d    → +1 cell
                                          ──────────
                                          10-11 wk → 31 cells
```

### Total effort (recommendation)

| Scope | Cells | Effort | When |
|---|---|---|---|
| **A (Client Credentials)** — from `not-done.md` | 4 | S–M | **now** — cheapest, last OP-side gap |
| **B (VCI mdoc issuer cell)** — submission only | 1 | S | **now** — verify + file |
| **Nothing from C** | 0 | — | market-driven; formally close the 15 superseded cells |
| **D0–D6 (non-jurisdiction RP)** | 31 | **~10-11 wk** | **only on an explicit product decision** |

### The decision you actually need to make

Bucket D is not a conformance chore — it is a **new certification
programme for a new role**, priced at ~11 engineering weeks, and it
reverses a documented product decision (`sentin8-auth/DESIGN.md` §9a.1:
"RP-role certification belongs to relying parties, not the
OP/issuer/verifier platform"). Three honest observations:

1. **We already are an RP in production** (the BFF), so the role is real
   — the design's exclusion is about *who certifies*, not *who acts*.
2. **The `fapi` crate makes D4/D5 cheaper than they look** (~4 of 11
   weeks); the expensive half is D0 + D3 (id_token JWE, front/back
   channel logout, session management).
3. **Certifying the RP role would be a differentiator** — very few
   implementations hold both OP and RP certification, and we would be
   among the few with OP + RP + wallet + issuer + verifier.

If the answer is yes, I would start at **D0** and treat D1 as the
first shippable increment. If the answer is no, bucket C and D should
both be marked "Closed — product decision" in `not-done.md` alongside
the 15 superseded cells, so the remaining gap reads as 122 *decided*
cells rather than 122 *pending* ones.

---

## 5. Open questions for you

1. **Is the RP role a product goal?** (This gates ~11 weeks of work.)
2. **Which markets, if any, are real** for bucket C — Brazil, UAE, KSA, AU?
   (Absent a market, C is pure cost.)
3. **Where should the RP-under-test live** — a new `sentin8-rp-conformance`
   crate, or an extension of `sentin8-sdk/identity/fapi`? (I would put the
   harness in `sentin8-auth-oidf` and keep the library changes in the SDK,
   so the certified code is the code we ship.)
4. **Should the BFF become the certified RP**, or a dedicated harness?
   (A dedicated harness is far safer — certifying the BFF would mean
   freezing its behaviour against 31 conformance plans.)
