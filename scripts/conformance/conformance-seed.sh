#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright Logically Magic Inc. <hello@logicallymagic.com>
# SPDX-FileCopyrightText: Copyright Hamid Jahanzad <Hamid@Jahanzad.com>
# SPDX-FileCopyrightText: Copyright Contributors to the Sentin8
# SPDX-License-Identifier: Apache-2.0

# conformance-seed.sh - provision the OIDF conformance certification
# tenant through the platform's own API surface (DESIGN.md §9a.2, §9a.5).
#
# NO DIRECT SQL (E2E rule): everything goes through sentin8-cli (device
# flow + API passthrough) exactly like a human operator.
#
# The CLI is NOT expected on PATH - the script resolves its binary from
# the repo target dir (release preferred, debug fallback) and fails with
# a build hint when absent. JSON is parsed with python3 (no jq dep).
#
# Idempotent: re-running skips what already exists.
#
# Outputs (for the suite configuration form):
#   .tmp/conformance/cert-user.env   - test user credentials
#   stdout                           - org/env ids + client registrations

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"   # repo group root (sentin8/)
TMP="$ROOT/../.tmp/conformance"
mkdir -p "$TMP"

# Resolve the CLI binary from the repo targets (release > debug).
CLI=""
for c in "$ROOT/sentin8-cli/target/release/sentin8-cli" \
         "$ROOT/sentin8-cli/target/debug/sentin8-cli"; do
  [ -x "$c" ] && CLI="$c" && break
done
if [ -z "$CLI" ]; then
  echo "[conformance-seed] sentin8-cli binary not found under" \
       "sentin8-cli/target - run 'make build' (or build-one SERVICE=cli) first." >&2
  exit 1
fi

ALIAS="${CONFORMANCE_ALIAS:-sentin8-local}"
CALLBACK="https://localhost.emobix.co.uk:8443/test/a/${ALIAS}/callback"
USER_EMAIL="${CONFORMANCE_USER_EMAIL:-cert-user@conformance-local.local.sentin8.dev}"
USER_PASSWORD="${CONFORMANCE_USER_PASSWORD:-Certification!2026}"
ORG_SLUG="conformance-local"

log() { printf '[conformance-seed] %s\n' "$*"; }

# jget <json> <dotted-path> - extract a scalar via python3 (empty input
# yields '').
jget() { python3 -c "
import json,sys
try:
    d=json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
cur=d
for part in sys.argv[2].split('.'):
    if not part:
        continue
    if part.endswith(']'):
        k,idx=part[:-1].split('[')
        if k:
            cur=cur.get(k) if isinstance(cur,dict) else None
        if isinstance(cur,list):
            cur=cur[int(idx)]
    else:
        cur=cur.get(part) if isinstance(cur,dict) else None
print(cur if cur is not None else '')
" "$1" "$2"; }

# clipi - read stdin, strip everything before the first '[' or '{' (the
# CLI prints a version banner line before the JSON body).
clipi() { python3 -c "
import sys
raw=sys.stdin.read()
i=min([x for x in (raw.find('['), raw.find('{')) if x>=0] or [-1])
sys.stdout.write(raw[i:] if i>=0 else '')
"; }

# by_slug <json-array> <slug> <field> - find an element with the slug
# and print one of its fields ('' when absent or unparseable).
by_slug() { python3 -c "
import json,sys
try:
    items=json.loads(sys.argv[1])
except Exception:
    sys.exit(0)
sys.stdout.write(next((it.get(sys.argv[3],'') for it in items if it.get('slug')==sys.argv[2]), ''))
" "$1" "$2" "$3"; }

# ccall - invoke the CLI (banner stripped from stdout on stdout).
ccall() { "$CLI" call "$@" 2>/dev/null | clipi; }

# ── 0. Platform reachability gate ────────────────────────────────────
# The CLI talks to the running platform (auth/sys via proxy :443). A
# dead fleet produces DNS/connection errors that cascade confusingly
# later - fail with the start hint instead.
AUTH_HOST="${SENTIN8_SENTIN8_AUTH_URL:-https://auth.ops.sys.local.sentin8.dev}"
if ! curl -sk -o /dev/null --max-time 5 "$AUTH_HOST/v1/health" 2>/dev/null \
   && ! getent hosts auth.ops.sys.local.sentin8.dev >/dev/null 2>&1; then
  log "platform not reachable at $AUTH_HOST - start it first:"
  log "  make start   (from $ROOT; classical mode for rig runs:"
  log "               SENTIN8_TLS_PQ_MODE=classical in the root .env)"
  exit 1
fi

# ── 1. Credential gate (operator identity; org/env/DCR/user-data calls
# below ride the stored CLI tokens, auto-refreshed by `call`).
if ! "$CLI" call sys GET /v1/o >/dev/null 2>&1; then
  log "no valid CLI credentials for the operator identity."
  log "run once interactively: sentin8-cli signin"
  exit 1
fi

# ── 2. Organization + env (idempotent via slug lookup) ───────────────
# The env must exist BEFORE the cert-user sign-up: the user provisions
# into the tenant resolved from the sign-up hostname
# (auth.cert.conformance-local.local.sentin8.dev → org/env), so the
# OIDF suite's browser sign-in finds them in the cert tenant.
# GET /v1/o returns a TOP-LEVEL ARRAY of orgs (widened limit - the
# default page is 50 and a busy platform can exceed it).
ORG_ID="$(by_slug "$(ccall sys GET '/v1/o?limit=200')" "$ORG_SLUG" id)"

if [ -z "$ORG_ID" ]; then
  log "creating org $ORG_SLUG"
  ORG_JSON="$(ccall sys POST /v1/o \
    --body "{\"slug\":\"$ORG_SLUG\",\"display_name\":\"OIDF Conformance Local\"}")"
  ORG_ID="$(jget "$ORG_JSON" id)"
  if [ -z "$ORG_ID" ]; then
    # 409 = a concurrent run created it - re-lookup.
    ORG_ID="$(by_slug "$(ccall sys GET '/v1/o?limit=200')" "$ORG_SLUG" id)"
  fi
  [ -n "$ORG_ID" ] || { log "FAILED: org create returned no id"; exit 1; }
else
  log "org $ORG_SLUG exists ($ORG_ID)"
fi

# GET /v1/e?org_id=... returns a top-level array of envs.
ENV_ID="$(by_slug "$(ccall sys GET "/v1/e?org_id=$ORG_ID")" cert id)"

if [ -z "$ENV_ID" ]; then
  log "creating env 'cert' in $ORG_SLUG"
  ENV_JSON="$(ccall sys POST /v1/e \
    --body "{\"org_id\":\"$ORG_ID\",\"slug\":\"cert\",\"display_name\":\"Certification\"}")"
  ENV_ID="$(jget "$ENV_JSON" id)"
  if [ -z "$ENV_ID" ]; then
    ENV_ID="$(by_slug "$(ccall sys GET "/v1/e?org_id=$ORG_ID")" cert id)"
  fi
  [ -n "$ENV_ID" ] || { log "FAILED: env create returned no id"; exit 1; }
else
  log "env 'cert' exists ($ENV_ID)"
fi

log "org=$ORG_ID env=$ENV_ID"

# ── 2b. Security profile (runbook §3): the cert env's OIDC posture.
# The env inherits the platform row (fapi_2: PAR+JARM+DPoP) when no
# env row exists - the OIDC Core/Logout profiles must run against the
# `standard` posture (plain code flow, RS256 for the suite's Java
# client). Override per run via CONFORMANCE_PROFILE for the FAPI
# plans (fapi_2 / fapi_1_advanced / fapi_ciba - see README §4).
PROFILE="${CONFORMANCE_PROFILE:-standard}"
# ID-token/DPoP signing family for the run - FAPI 2.0 SP (FAPI2-SP-FINAL 5.4-1) admits PS256/ES256/EdDSA/Ed25519; the platform families are MLDSA65/RS256/ES256 -> ES256 for FAPI runs.
ALG="${CONFORMANCE_SIGNING_ALG:-RS256}"
# The user-rejects modules reach the consent screen's Deny ONLY when
# the client requires consent - FAPI profiles set it true.
CONSENT_REQUIRED="false"
case "$PROFILE" in
  fapi_*) CONSENT_REQUIRED="true";;
esac
case "$PROFILE" in
  fapi_2|fapi_2_message_signing|fapi_ciba) ALG="ES256";;
esac
log "setting env security profile to $PROFILE"
# Per-profile flag posture (auth DESIGN §9a.5/§9a.3; OC-13): the flags
# ride the TARGET profile - not the `standard` subset for every run.
# `standard` = plain OIDC Core (RS256, everything off). The FAPI
# postures turn on exactly what their certification profile mandates.
case "$PROFILE" in
  standard)
    FLAGS='"require_par":false,"require_jarm":false,"require_dpop":false,"require_iss":false,"require_mtls":false,"require_http_signatures":false,"require_jwt_introspection":false';;
  fapi_2)
    FLAGS='"require_par":true,"require_jarm":true,"require_dpop":true,"require_iss":true,"require_mtls":false,"require_http_signatures":false,"require_jwt_introspection":false';;
  fapi_2_message_signing)
    FLAGS='"require_par":true,"require_jarm":true,"require_dpop":true,"require_iss":true,"require_mtls":false,"require_http_signatures":true,"require_jwt_introspection":true';;
  fapi_1_advanced)
    FLAGS='"require_par":true,"require_jarm":true,"require_dpop":false,"require_iss":true,"require_mtls":true,"require_http_signatures":false,"require_jwt_introspection":false';;
  fapi_ciba)
    FLAGS='"require_par":false,"require_jarm":false,"require_dpop":false,"require_iss":true,"require_mtls":false,"require_http_signatures":false,"require_jwt_introspection":false';;
  *)
    FLAGS='"require_par":false,"require_jarm":false,"require_dpop":false,"require_iss":false,"require_mtls":false,"require_http_signatures":false,"require_jwt_introspection":false';;
esac
# FAPI 2.0 Security Profile (final) 5.3.2.1-9: refresh rotation PROHIBITED - the
# suite's refresh-token module re-runs the PREVIOUS refresh token and expects it
# to still succeed (the rotation-off posture). `standard`/`fapi_1_advanced` keep
# rotation ON (Basic-OP's reuse-revocation + FAPI1 rotation requirements).
case "$PROFILE" in
  fapi_2|fapi_2_message_signing) ROTATION="false";;
  *) ROTATION="true";;
esac
ccall auth PUT /v1/security-profile --env "$ENV_ID" --body "{
    \"scope\":\"env\",
    \"org_id\":\"$ORG_ID\",
    \"env_id\":\"$ENV_ID\",
    \"profile\":\"$PROFILE\",
    $FLAGS,
    \"require_pkce\":true,
    \"signing_alg\":\"$ALG\",
    \"refresh_rotation\":$ROTATION
  }" >/dev/null && log "profile=$PROFILE set ({$FLAGS}, $ALG, rotation=$ROTATION)"

# ── 3. Certification user (idempotent sign-up in the CERT tenant) ──
# The suite drives the user's sign-in through the browser UI; the
# sign-up itself provisions into the tenant resolved from the cert
# env's own auth hostname (the signup path reads the tenant from the
# hostname, matching browser behavior).
CERT_AUTH_HOST="https://auth.cert.conformance-local.local.sentin8.dev"
log "ensuring certification user $USER_EMAIL (cert tenant)"
"$CLI" signup --sentin8-auth-url "$CERT_AUTH_HOST" \
  --email "$USER_EMAIL" --password "$USER_PASSWORD" \
  --first-name "Conformance" --last-name "Certification" \
  || log "sign-up says exists - continuing"

# ── 3. Conformance clients (DCR endpoint - same path Dynamic OP runs) ─
# Registered via DCR so the exact registration surface under test is the
# one the suite exercises. Each client gets the suite callback.
#
# CRITICAL (OIDF-SCOPE-1 follow-up, live 2026-10-21): the DCR endpoint
# resolves its tenant from the TLS-injected env header of the host it is
# CALLED on - the CLI `call` passthrough targets auth.ops.sys (SYSTEM env)
# and its --env query param does NOT re-target DCR. The clients MUST live
# in the CERT env (their token exchanges then resolve under the cert env's
# RLS context) - so registration goes DIRECTLY against the cert env's own
# auth hostname, exactly like the suite itself will.
dcr() { # dcr <name> <json-extra>
  local name="$1" extra="${2:-}"
  # The CIBA variant REPLACES grant_types (the base authorization_code/
  # refresh_token pair is invalid for a CIBA-only client); JSON forbids
  # duplicate fields, so the base pair is omitted whenever the extra
  # supplies its own grant_types.
  local grants="\"grant_types\":[\"authorization_code\",\"refresh_token\"],"
  if [[ "$extra" == *'"grant_types"'* ]]; then grants=""; fi
  # Same rule for redirect_uris: the extra may supply its own array
  # (e.g. the happy-flow client2's query-parameter variant).
  local uris="\"redirect_uris\":[\"$CALLBACK\"],"
  if [[ "$extra" == *'"redirect_uris"'* ]]; then uris=""; fi
  local body="{
    \"client_name\":\"$name\",
    $uris
    $grants
    \"response_types\":[\"code\"],
    \"scope\":\"openid profile email phone address offline_access\",
    \"code_challenge_method\":\"S256\",
    \"consent_required\":$CONSENT_REQUIRED${extra:+,$extra}
  }"
  # banner-strip not needed (curl output); parse client fields with jget.
  curl -sk -X POST "$CERT_AUTH_HOST/oauth/register" \
    -H 'Content-Type: application/json' -d "$body"
}

log "registering suite clients (DCR against the cert env host)"
# Idempotency: the suite's clients are identified by NAME in the cert env.
# A re-seed replaces them (DCR issues a fresh secret each time - stale rows
# would fail client-auth with a mismatched secret). Old rows are deleted
# through the admin API (no direct SQL - E2E rule).
ccall auth GET "/v1/admin/oauth-clients?page_size=200" --env "$ENV_ID" | python3 -c "
import json,sys
try:
    items=json.load(sys.stdin).get('clients', [])
except Exception:
    sys.exit(0)
for c in items:
    if (c.get('client_name') or '').startswith('cert-'):
        print(c.get('id',''))
" | while read -r cid; do
  [ -n "$cid" ] && ccall auth DELETE "/v1/admin/oauth-clients/$cid" --env "$ENV_ID" >/dev/null
done
BASIC_JSON="$(dcr "cert-basic-basic" '"token_endpoint_auth_method":"client_secret_basic"')"
POSTC_JSON="$(dcr "cert-basic-post" '"token_endpoint_auth_method":"client_secret_post"')"
PKCE_JSON="$(dcr "cert-public-pkce" '"token_endpoint_auth_method":"none"')"

# CIBA client: ping delivery points at the suite callback (poll + ping).
# Single-line JSON (curl -d with embedded newlines inside quoted values
# broke the body in the shell heredoc shape).
CIBA_JSON="$(dcr "cert-ciba" "\"grant_types\":[\"urn:openid:params:grant-type:ciba\",\"refresh_token\"],\"token_endpoint_auth_method\":\"client_secret_post\",\"backchannel_client_notification_endpoint\":\"$CALLBACK\"")"

# Client ids/secrets print AND persist (.tmp/conformance/seed-out.txt -
# the OIDF automation harness reads it for the suite plan configs).
SEED_OUT="$TMP/seed-out.txt"
: > "$SEED_OUT"
emit_client() { # emit_client <name> <json>
  echo "client_id($1)=$(jget "$2" client_id)" | tee -a "$SEED_OUT"
  echo "client_secret($1)=$(jget "$2" client_secret)" | tee -a "$SEED_OUT"
}
emit_client basic "$BASIC_JSON"
emit_client post "$POSTC_JSON"
emit_client pkce "$PKCE_JSON"
emit_client ciba "$CIBA_JSON"
echo "org_id=$ORG_ID" >> "$SEED_OUT"
echo "env_id=$ENV_ID" >> "$SEED_OUT"
chmod 600 "$SEED_OUT"

# ── 3c. FAPI2 static clients (plain_fapi plans run STATIC clients only -
# the plan does not expose a client_registration variant) ──
# The suite mints client_assertions from the jwks in the plan config's
# `client`/`client2` objects; the registered OP side holds the MATCHING
# public keys. Each client gets its OWN P-256 keypair (the suite rejects
# shared private keys) and the PRIVATE jwks rides seed-out for the
# harness config.
if [[ "$PROFILE" == fapi_* ]]; then
  log "registering FAPI2 static clients (private_key_jwt + jwks)"
  # The mtls cell's client auth is the CERTIFICATE (self_signed, DESIGN
  # 9a.12) - registered separately below; the jwks loop covers the
  # private_key_jwt cells.
  for cell in dpop; do
    for cl in main second; do
      KEYJSON="$(python3 - <<'PYGEN'
import base64, json
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

key = ec.generate_private_key(ec.SECP256R1())
pub = key.public_key().public_bytes(Encoding.X962, PublicFormat.UncompressedPoint)
x = base64.urlsafe_b64encode(pub[1:33]).rstrip(b'=').decode()
y = base64.urlsafe_b64encode(pub[33:65]).rstrip(b'=').decode()
d = key.private_numbers().private_value.to_bytes(32, 'big')
d_b64 = base64.urlsafe_b64encode(d).rstrip(b'=').decode()
kid = 'fapi2-key'
private = {"kty": "EC", "kid": kid, "crv": "P-256", "x": x, "y": y, "d": d_b64, "alg": "ES256"}
public = {"keys": [{"kty": "EC", "kid": kid, "use": "sig", "alg": "ES256", "crv": "P-256", "x": x, "y": y}]}
print(json.dumps({"private": private, "public": public}))
PYGEN
)"
      if [ -z "$KEYJSON" ]; then
        log "EC keygen failed for $cell/$cl - FAPI2 clients skipped"
        break 2
      fi
      PRIVJWKS="$(echo "$KEYJSON" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['private']))")"
      PUBJWKS="$(echo "$KEYJSON" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['public']))")"
      if [ "$cl" = main ]; then
        FJSON="$(dcr "cert-fapi2-$cell" "\"token_endpoint_auth_method\":\"private_key_jwt\",\"jwks\":$PUBJWKS")"
        emit_client "fapi2-$cell" "$FJSON"
        echo "private_jwks(fapi2-$cell)=$PRIVJWKS" >> "$SEED_OUT"
      else
        # The happy-flow's client2 uses the callback WITH extra
        # query parameters - the SUITE requires that exact URI
        # registered (not a prefix match). Register it verbatim.
        FJSON2="$(dcr "cert-fapi2-$cell-2" "\"token_endpoint_auth_method\":\"private_key_jwt\",\"jwks\":$PUBJWKS,\"redirect_uris\":[\"$CALLBACK?dummy1=lorem&dummy2=ipsum\"]")"
        emit_client "fapi2-second-$cell" "$FJSON2"
        echo "private_jwks(fapi2-second-$cell)=$PRIVJWKS" >> "$SEED_OUT"
      fi
    done
  done
fi

# ── 3d. FAPI2 mTLS cell clients (auth DESIGN §9a.12) ──
# The mtls cell's client authentication is the CERTIFICATE
# (self_signed_tls_client_auth, RFC 8705 §2.4): the seed mints a
# SELF-SIGNED EC P-256 client cert, registers the sha-256 thumbprint via
# DCR (WITH the client's signing jwks - the client still signs its
# request objects with the private_key_jwt-family key), and publishes to
# seed-out: the cert+key PEMs, the base64(DER) forms (the suite's
# PEMFormatter decodes config.mtls.* AS base64), and the client's
# private jwks (the suite signs request objects from config.client.jwks).
if [[ "$PROFILE" == fapi_* ]]; then
  log "registering FAPI2 mTLS cell clients (self_signed_tls_client_auth)"
  for cl in main second; do
    CERTJSON="$(python3 - <<'PYMTLS'
import base64, hashlib, json
from cryptography import x509
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.x509.oid import NameOID
import datetime

cert_key = ec.generate_private_key(ec.SECP256R1())
name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "cert-fapi2-mtls")])
now = datetime.datetime.now(datetime.timezone.utc)
cert = (x509.CertificateBuilder()
        .subject_name(name).issuer_name(name)
        .public_key(cert_key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(minutes=5))
        .not_valid_after(now + datetime.timedelta(days=365))
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .add_extension(x509.KeyUsage(digital_signature=True, key_encipherment=False,
                                     content_commitment=False, data_encipherment=False,
                                     key_agreement=False, key_cert_sign=False,
                                     crl_sign=False, encipher_only=False,
                                     decipher_only=False), critical=True)
        .sign(cert_key, hashes.SHA256()))
der = cert.public_bytes(serialization.Encoding.DER)
key_der = cert_key.private_bytes(serialization.Encoding.DER,
                                 serialization.PrivateFormat.PKCS8,
                                 serialization.NoEncryption())
thumb = base64.urlsafe_b64encode(hashlib.sha256(der).digest()).rstrip(b'=').decode()
# The client's REQUEST-OBJECT signing key (separate from the TLS cert).
sig_key = ec.generate_private_key(ec.SECP256R1())
pub = sig_key.public_key().public_bytes(serialization.Encoding.X962,
                                        serialization.PublicFormat.UncompressedPoint)
x = base64.urlsafe_b64encode(pub[1:33]).rstrip(b'=').decode()
y = base64.urlsafe_b64encode(pub[33:65]).rstrip(b'=').decode()
d = sig_key.private_numbers().private_value.to_bytes(32, 'big')
d_b64 = base64.urlsafe_b64encode(d).rstrip(b'=').decode()
private_jwks = {"kty": "EC", "kid": "fapi2-mtls-key", "crv": "P-256", "x": x, "y": y, "d": d_b64, "alg": "ES256"}
public_jwks = {"keys": [{"kty": "EC", "kid": "fapi2-mtls-key", "use": "sig", "alg": "ES256", "crv": "P-256", "x": x, "y": y}]}
print(json.dumps({"cert_pem": cert.public_bytes(serialization.Encoding.PEM).decode(),
                  "key_pem": cert_key.private_bytes(serialization.Encoding.PEM,
                                                    serialization.PrivateFormat.PKCS8,
                                                    serialization.NoEncryption()).decode(),
                  "der_b64": base64.b64encode(der).decode(),
                  "thumbprint": thumb,
                  "private_jwks": private_jwks,
                  "public_jwks": public_jwks}))
PYMTLS
)"
    if [ -z "$CERTJSON" ]; then
      log "mTLS keygen failed ($cl) - mTLS clients skipped"
      break
    fi
    CERT_PEM="$(echo "$CERTJSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['cert_pem'])")"
    KEY_PEM="$(echo "$CERTJSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['key_pem'])")"
    THUMB="$(echo "$CERTJSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['thumbprint'])")"
    DER64="$(echo "$CERTJSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['der_b64'])")"
    PRIVJWKS="$(echo "$CERTJSON" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['private_jwks']))")"
    PUBJWKS="$(echo "$CERTJSON" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['public_jwks']))")"
    if [ "$cl" = main ]; then
      MJSON="$(dcr "cert-fapi2-mtls" "\"token_endpoint_auth_method\":\"self_signed_tls_client_auth\",\"self_signed_tls_client_auth_thumbprint\":\"$THUMB\",\"jwks\":$PUBJWKS")"
      emit_client "fapi2-mtls" "$MJSON"
    else
      MJSON2="$(dcr "cert-fapi2-mtls-2" "\"token_endpoint_auth_method\":\"self_signed_tls_client_auth\",\"self_signed_tls_client_auth_thumbprint\":\"$THUMB\",\"jwks\":$PUBJWKS,\"redirect_uris\":[\"$CALLBACK?dummy1=lorem&dummy2=ipsum\"]")"
      emit_client "fapi2-second-mtls" "$MJSON2"
    fi
    echo "mtls_cert_pem($cl)=$CERT_PEM" >> "$SEED_OUT"
    echo "mtls_key_pem($cl)=$KEY_PEM" >> "$SEED_OUT"
    echo "mtls_cert_der_b64($cl)=$DER64" >> "$SEED_OUT"
    echo "mtls_thumbprint($cl)=$THUMB" >> "$SEED_OUT"
    echo "private_jwks(fapi2-mtls-$cl)=$PRIVJWKS" >> "$SEED_OUT"
  done
fi

# ── 3a. TLS warm-up (runbook §5): the suite's Java client makes
# single-shot fetches with a short socket timeout; a cold auth instance
# must first fetch the tenant's leaf from Acme on-demand (~100ms when
# Acme is warm, seconds when its own boot races). One warm-up request
# lands the cert in the auth instance's resolver BEFORE the suite runs.
log "warming TLS cert for $CERT_AUTH_HOST"
curl -sk -m 20 -o /dev/null --retry 3 --retry-delay 2 \
  "$CERT_AUTH_HOST/.well-known/openid-configuration" \
  && log "TLS cert warm"

# ── 3b. Cert user phone + postal address (no-skip rule, auth DESIGN
# §9a.10) ── The OIDF scope tests assert claim PRESENCE for the
# `phone`/`address` scopes, so the certification user must carry
# phone/address data. Provisioned through the admin API (no direct
# SQL); idempotent via PUT (COALESCE update).
log "provisioning cert user phone + address (no-skip rule)"
# The user lives in the cert env; the admin list is env-scoped via the
# operator's env-targeted token, so look the cert user up by email in
# the cert env's list.
USER_ID="$(ccall auth GET "/v1/admin/users?limit=200" --env "$ENV_ID" | python3 -c "
import json,sys
try:
    items=json.load(sys.stdin).get('users',[])
except Exception:
    sys.exit(0)
print(next((u.get('id','') for u in items if u.get('email')=='$USER_EMAIL'), ''))
")"
if [ -n "$USER_ID" ]; then
  ccall auth PUT "/v1/admin/users/$USER_ID" --env "$ENV_ID" --body '{
    "phone": "+15551234567",
    "street_address": "1 Certification Way",
    "locality": "Springfield",
    "region": "IL",
    "postal_code": "62701",
    "country": "US",
    "oidc_profile": {
      "name": "Conformance Certification",
      "middle_name": "Q.",
      "given_name": "Conformance",
      "family_name": "Certification",
      "nickname": "CertUser",
      "preferred_username": "certuser",
      "profile": "https://conformance-local.local.sentin8.dev/profile/certuser",
      "picture": "https://conformance-local.local.sentin8.dev/avatars/certuser.png",
      "website": "https://conformance-local.local.sentin8.dev/~certuser",
      "gender": "female",
      "birthdate": "1990-04-15",
      "zoneinfo": "America/Chicago",
      "locale": "en-US"
    }
  }' >/dev/null
  log "cert user phone + address + profile family set ($USER_ID)"
else
  log "WARN: cert user not found via admin API - phone/address/profile NOT provisioned"
fi

# ── 4. Persist the suite configuration inputs ─────────────────────────
cat > "$TMP/cert-user.env" <<EOF
# OIDF conformance suite - certification tenant inputs (generated)
CONFORMANCE_ALIAS=$ALIAS
CONFORMANCE_CALLBACK=$CALLBACK
CONFORMANCE_USER_EMAIL=$USER_EMAIL
CONFORMANCE_USER_PASSWORD=$USER_PASSWORD
CONFORMANCE_ORG_ID=$ORG_ID
CONFORMANCE_ENV_ID=$ENV_ID
EOF
chmod 600 "$TMP/cert-user.env"
log "wrote $TMP/cert-user.env"
log "next: open https://localhost.emobix.co.uk:8443/ and create the test plans (runbook §4)"