# Sentin8 Platform — OIDF Certification: WHAT IS NOT DONE

The complement of `done.md`. **Every number and every cell name below is
scraped from the OIDF catalog pages**, not hand-tallied.

Re-verified 2026-11-24 by scraping all **38 tables across 38 catalog
pages** and matching the `Hamid Jahanzad` / `Sentin8` row in each.

## The numbers

| Bucket | What it is | Total cells | Done | **Open** |
|---|---|---|---|---|
| **OP** | OpenID Provider / issuer / verifier (server-side, non-jurisdiction) | 50 | 45 | **5** |
| **JOP** | Jurisdiction OP overlays (UK, AU, BR, KSA, CBUAE, ConnectID, superseded) | 50 | 0 | **50** |
| **RP** | Relying Party role (all RP pages) | 72 | 0 | **72** |
| | **TOTAL** | **172** | **45** | **127** |

So: **127 cells are not done.** Only **5** of them are gaps in the code we
already ship. The other **122** are two separate programmes (jurisdiction
overlays + the RP role).


---

# Part 1 — The 5 OP gaps (real platform work, small)

These are the only open cells on pages we otherwise pass. They are **the
entire remaining gap in the code we ship**: four cells are one DPoP-binding
fix plus one new spec, and the fifth is a filing we simply never made.


## FAPI2 OP SP+MS Final — 4 open of 11

Catalog page: <https://openid.net/certification/certified-fapi-2-0-op-security-profile-final-message-signing-final/>

| Open cell | Status |
|---|---|
| FAPI2SP OP Client Credentials MTLS + MTLS | **Open** |
| FAPI2SP OP Client Credentials MTLS + DPoP | **Open** |
| FAPI2SP OP Client Credentials private key + MTLS | **Open** |
| FAPI2SP OP Client Credentials private key + DPoP | **Open** |

## OID4VCI+HAIP — 1 open of 10

Catalog page: <https://openid.net/certification/certified-oid4vci-haip-final/>

| Open cell | Status |
|---|---|
| OID4VCI-1.0+HAIP-1.0 Issuer mdoc issuer_initiated | **Open** |

### Gap 1 — FAPI2 OP Client Credentials (4 cells) → story `OIDF-CCGRANT-1`

The suite plan is one we already drive (`fapi2-security-profile-final-test-plan`),
selected by the variant `fapi_profile=fapi_client_credentials_grant`.

**Already works:** the grant itself (`handle_client_credentials` in
`sentin8-auth/src/oauth.rs`), the discovery advertisement, the profile gate,
`refresh_token` omission, mTLS `cnf` binding.

**The defect:** `handle_client_credentials` hardcodes `token_type: "Bearer"`
and discards the `jkt` from `validate_and_verify_dpop`. So the two **DPoP**
cells fail. Fix = the pattern already used 200 lines away in the auth-code
path (`if dpop_jkt.is_some() { "DPoP" } else { "Bearer" }`) + stamping
`cnf.jkt`.

**Work:** endpoint fix (~S) + `tests/fapi2-client-credentials.spec.ts` +
seed clients + Makefile/package.json wiring. **Size: S–M.**

### Gap 2 — VCI Issuer mdoc `issuer_initiated` (1 cell) → no code

`tests/oid4vci-haip.spec.ts` already loops `FORMAT_CELLS × FLOW_CELLS`, so
this plan runs locally. It was simply **never filed** — the published row
carries exactly three issuer zips, and this is the fourth. **Size: S**
(re-verify the cell, then submit).


---

# Part 2 — The 50 jurisdiction OP cells

Every one of these pages has a Sentin8 row with **all cells blank** —
we have never run any of them. They are grouped below by what closing
them actually costs.

## 2a. Superseded drafts — 15 cells (close, do not pursue)

| Page | Cells |
|---|---|
| FAPI2 OP SP ID2 + MS ID1 (superseded) | 7 |
| FAPI1 OP Second Implementer's Draft (incl UK-OB) | 8 |

We hold the **Final** versions of both (see `done.md` §3 and §5). Certifying
a superseded draft adds no catalog value. **Recommendation: formally close
as "superseded".**

## 2b. Low-value jurisdiction claims — 8 cells

| Page | Cells | What it needs |
|---|---|---|
| CBUAE FAPI2 OP MS | 1 | CBUAE JAR-mandating profile |
| CBUAE FAPI2 OP MS ID1 | 1 | superseded ID1 + CBUAE |
| AU ConnectID Final | 1 | ConnectID trust framework, purpose claims |
| AU ConnectID ID draft | 1 | superseded draft + ConnectID |
| FAPI1 OP KSA-OB | 2 | SAMA consent model, `acr` values |
| FAPI2 OP KSA-OB | 2 | KSA JAR/consent profile |

These run on plans we already pass; the work is profile-specific claims and
consent semantics. **Size: M (~1.5 wk) for all 8.**

## 2c. Real product work — 25 cells

| Page | Cells | What it needs | Size |
|---|---|---|---|
| FAPI1 OP UK-OB | 2 | `intent_id` obtained via client_credentials (needs Gap 1 first), ecosystem `acr` values | **L (~2 wk)** |
| FAPI1 OP AU-CDR | 3 | CDR register, `cdr_arrangement_id` grant management (merge/replace/revoke), 90-day re-authorisation | **L (~2 wk)** |
| FAPI1 OP BR-OB | 9 | Brazil directory software statements, `org_jwks`, consent scopes, `consentUrl` | **XL** |
| FAPI1 OP BR-OPIN | 9 | same, insurance products | **XL** |
| FAPI1 OP BR-OF v2 | 2 | FAPI-BR v2 rulebook | **L** |
| FAPI1 OP BR-OPIN v2 | 2 | FAPI-BR v2 + insurance | **L** |

Brazil as a group is **22 cells, ~4–6 weeks** of genuine OP feature work.

**Recommendation: market-driven only.** No market, no work.


---

# Part 3 — The 72 RP cells

We have **never** certified an RP. All 17 RP catalog pages have blank cells.

## Ownership — this is openfin8's job, not the platform's

`sentin8-auth/DESIGN.md` §9a.1 says *"RP-role certification belongs to
relying parties, not the OP/issuer/verifier platform"* — and that is
correct. **openfin8 is the relying party:**

- `openfin8-eopenca` = *"the open-finance **Data Recipient** demo app"*
  (a data recipient **is** a relying party)
- `openfin8-core/src/handlers.rs` runs the OAuth client: PAR push with
  PKCE-S256, `/fdx/consents/callback` code exchange with a DPoP proof
- `openfin8-uk/au` ceremony modules build the jurisdiction request objects
  (`response_type: "code id_token"` + nonce; CDR PAR shape)

The reusable client libraries live in the platform SDK
(`sentin8-sdk/identity/auth-client`, `sentin8-sdk/identity/fapi` — the
latter is a near-complete FAPI RP stack).

### The blocker: openfin8 validates no id_tokens

Grepping every `.rs` file in openfin8 for `id_token` outside response-type
literals returns **4 hits, all strings/assertions**. There is **zero**
id_token validation. openfin8 is an OAuth recipient, not an OIDC RP.

Missing: id_token signature/`aud`/`iss`/`nonce`/`at_hash`/`c_hash`
validation, id_token JWE decryption, RP-initiated logout, front-channel
logout iframe, back-channel logout-token validation, session-management
`check_session_iframe`, and the implicit/hybrid/form_post response paths
(it only does `code`).

## The cells, by sub-bucket

| Sub-bucket | Cells | Notes |
|---|---|---|
| OIDC RP Profiles | 7 | Basic, Implicit, Hybrid, Config, Dynamic, Form Post, 3rd Party-Init |
| OIDC RP Logout | 4 | RP-Initiated, Session, Front-Channel, Back-Channel |
| FAPI1-Adv RP | 12 | MTLS/PK × ±PAR × ±JARM (OIDC and OAuth variants) |
| FAPI2 RP SP+MS Final | 7 | 4 sender/auth cells + RP OpenID Connect + MS JAR/JARM |
| FAPI-CIBA RP (BR-OF) | 1 | Brazil Open Finance CIBA |
| **Subtotal — generic, worthwhile** | **31** | |
| FAPI2 RP SP ID2+MS ID1 (superseded) | 16 | superseded drafts — close |
| Jurisdiction RP (BR-OB 8, BR-OF v2 2, BR-OPIN 4+1, KSA 2, ID2 2, FAPI2-KSA 2, CBUAE 1+1, ConnectID 1+1) | 25 | market-driven |
| **Total** | **72** | |

## The economics that matter

**RP is cheap per jurisdiction; OP is expensive.** Confirmed in
`FAPI1AdvancedFinalClientTestPlan.certificationProfileName()`: each
jurisdiction is a `switch` on `fapi_profile`, not a separate plan. So one
RP implementation passes `plain_fapi`, then UK-OB / AU-CDR / KSA with only
profile-specific claim changes.

| Path | Cells | Effort | Verdict |
|---|---|---|---|
| **D0** RP harness + id_token validation | 0 (enabler) | **L, ~2 wk** | Prerequisite for everything |
| D1 OIDC RP Basic/Config/Dynamic/3rd-Party | 4 | M, ~1 wk | needs D0 |
| D2 OIDC RP Implicit/Hybrid/Form Post | 3 | M, ~1 wk | needs D0 |
| D3 OIDC RP Logout | 4 | **L, ~2 wk** | the expensive half |
| D4 FAPI2 RP SP+MS Final | 7 | M, ~1.5 wk | `fapi` crate is ~80% there |
| D5 FAPI1-Adv RP | 12 | **L, ~2.5 wk** | 12 cells, needs JWE id_token |
| D6 FAPI-CIBA RP | 1 | S, ~2 d | needs Brazil config |
| **Generic RP total** | **31** | **~10–11 wk** | |
| + jurisdiction RP (25) | 25 | ~+0.5–1 wk each **once D5 lands** | cheap marginal cost |
| Superseded RP ID2 (16) | 16 | — | **close, do not pursue** |

**Sequencing insight:** because jurisdiction RP is nearly free once FAPI1
RP is certified, the RP work should be sequenced **immediately before the
first market entry**, not as a standalone programme. It converts an
11-week isolated cost into a ~2-week enabler that rides along with
whichever market you enter first.


---

# Part 4 — Families with no certification catalog

Verified absent (404 on every plausible URL; no such table on the
"All Certified Implementations" index):

| Family | Status |
|---|---|
| OpenID Shared Signals Framework (SSF / CAEP) | Conformance **tests** exist, **no** certified-implementations listing |
| OpenID Federation | Conformance **tests** exist (early-stage), **no** catalog |
| AuthZEN Authorization API | Conformance **tests** exist, **no** catalog |
| OpenID Connect for Identity Assurance (eKYC-IDA) | **Working group only** — no test page, no catalog |

**Action item:** `sentin8-auth/DESIGN.md` §9a.1 lists "Identity Assurance
(eKYC-IDA) — OP" as in-scope. That entry buys no catalog cell and should be
dropped or re-labelled.

---

# Summary — the honest answer to "what is not done?"

| | Cells | What it really means |
|---|---|---|
| **Code we ship is 5 cells short** | 5 | 4 = one DPoP fix + one spec; 1 = a filing we forgot |
| **Jurisdiction OP** | 50 | 15 = close as superseded; 8 = ~1.5 wk claims work; 25 = market-driven product work |
| **RP role** | 72 | 16 = close as superseded; 31 = ~11 wk (openfin8 owns it); 25 = nearly free after the 31 |

### What to do, in order

1. **Gap 1** — FAPI2 Client Credentials DPoP binding + spec → **+4 cells, S–M**
2. **Gap 2** — verify + file the VCI mdoc issuer cell → **+1 cell, S**
   *(← after these two, every non-jurisdiction OP-side cell is done: 50/50)*
3. **Formally close** the 31 superseded cells (15 JOP + 16 RP) in this file
   and in the catalog plan, so they read as *decided* not *pending*
4. **Decide the RP role.** If yes → **D0** first (~2 wk), then D4/D5, then
   each market's RP cells ride along nearly free
5. **Decide markets** for jurisdiction OP. No market → no work.

After steps 1–2 the platform holds **every non-jurisdictional OP-side
catalog cell (50/50)**, with 122 remaining cells being RP-role (72) and
jurisdiction overlays (50) — both owned by openfin8 / market decisions
rather than platform gaps.
