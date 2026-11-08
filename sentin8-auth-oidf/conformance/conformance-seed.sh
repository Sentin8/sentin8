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
#   .tmp/conformance/seed-out/<env-slug>.txt - per-env seed facts
#   (.tmp/conformance/seed-out.txt = the env `cert` default, kept for
#    the single-env flows)
#   .tmp/conformance/cert-user-<env-slug>.env - test user credentials
#   stdout                           - org/env ids + client registrations
#
# Profile-per-env (DESIGN §9a.2,): each family seeds its OWN env
# (env slug + suite alias via CONFORMANCE_ENV_SLUG / CONFORMANCE_ALIAS;
# defaults = env `cert` + alias `sentin8-local`, the standard family).
# The env slug must be DNS-ALPHA (lowercase [a-z0-9-]); the suite alias
# must be URL-path-safe ([a-z0-9-]). One USER EMAIL PER ENV (derive the
# default from the slug: cert-user@{slug}.conformance-local... - email
# rate buckets are shared per address, so a shared email would couple
# the envs' bot-protection state).

set -euo pipefail

# The script lives in sentin8-auth-oidf/conformance/ (moved from
# scripts/conformance -): the SAME directory depth as before, so the
# group root (sentin8/) is still two levels up.
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
ENV_SLUG="${CONFORMANCE_ENV_SLUG:-cert}"
ORG_SLUG="conformance-local"
DOMAIN_SUFFIX="local.sentin8.dev"
# The per-env tenant identity : the auth host + the user email
# derive from the ENV SLUG; the suite callback/alias from the ALIAS.
ENV_SLUG_ALPHA_OK="$(printf '%s' "$ENV_SLUG" | grep -cE '^[a-z0-9][a-z0-9-]*$' || true)"
ALIAS_URL_OK="$(printf '%s' "$ALIAS" | grep -cE '^[a-z0-9][a-z0-9-]*$' || true)"
if [ "$ENV_SLUG_ALPHA_OK" != "1" ] || [ "$ALIAS_URL_OK" != "1" ]; then
  echo "[conformance-seed] invalid CONFORMANCE_ENV_SLUG ('$ENV_SLUG') or CONFORMANCE_ALIAS ('$ALIAS') - both must match ^[a-z0-9][a-z0-9-]*$" >&2
  exit 1
fi
CALLBACK="https://localhost.emobix.co.uk:8443/test/a/${ALIAS}/callback"
USER_EMAIL="${CONFORMANCE_USER_EMAIL:-cert-user@${ENV_SLUG}.${ORG_SLUG}.${DOMAIN_SUFFIX}}"
USER_PASSWORD="${CONFORMANCE_USER_PASSWORD:-Certification!2026}"
CERT_AUTH_HOST="https://auth.${ENV_SLUG}.${ORG_SLUG}.${DOMAIN_SUFFIX}"
# Per-env seed-out : env `cert` keeps the FLAT legacy paths (the
# single-env flows + the specs' fallback paths read them); every other
# env writes into seed-out/<slug>.txt (+ cert-user-<slug>.env).
if [ "$ENV_SLUG" = "cert" ]; then
  SEED_OUT="$TMP/seed-out.txt"
  CERT_USER_ENV="$TMP/cert-user.env"
  mkdir -p "$TMP"
else
  SEED_OUT="$TMP/seed-out/${ENV_SLUG}.txt"
  CERT_USER_ENV="$TMP/cert-user-${ENV_SLUG}.env"
  mkdir -p "$TMP/seed-out"
fi
: > "$SEED_OUT"

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
ENV_ID="$(by_slug "$(ccall sys GET "/v1/e?org_id=$ORG_ID")" "$ENV_SLUG" id)"

# The platform's SYSTEM env (sentin8-config SYSTEM_ENV_ID) - the realm
# where the org-scoped groups live (sentin8:org:{org_id}:admins).
SYSTEM_ENV_ID="00000000-0000-0000-0000-000000000002"

if [ -z "$ENV_ID" ]; then
  log "creating env '$ENV_SLUG' in $ORG_SLUG"
  ENV_JSON="$(ccall sys POST /v1/e \
    --body "{\"org_id\":\"$ORG_ID\",\"slug\":\"$ENV_SLUG\",\"display_name\":\"Certification - $ENV_SLUG\"}")"
  ENV_ID="$(jget "$ENV_JSON" id)"
  if [ -z "$ENV_ID" ]; then
    ENV_ID="$(by_slug "$(ccall sys GET "/v1/e?org_id=$ORG_ID")" "$ENV_SLUG" id)"
  fi
  [ -n "$ENV_ID" ] || { log "FAILED: env create returned no id"; exit 1; }
else
  log "env '$ENV_SLUG' exists ($ENV_ID)"
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
  fapi_2|fapi_2_message_signing|fapi_1_advanced|fapi_ciba|vci|vci_haip|vp) ALG="ES256";;
esac
log "setting env security profile to $PROFILE"
# Per-profile flag posture (auth DESIGN §9a.5/§9a.3;): the flags
# ride the TARGET profile - not the `standard` subset for every run.
# `standard` = plain OIDC Core (RS256, everything off). The FAPI
# postures turn on exactly what their certification profile mandates.
case "$PROFILE" in
  standard)
    FLAGS='"require_par":false,"require_jarm":false,"require_dpop":false,"require_iss":false,"require_mtls":false,"require_http_signatures":false,"require_jwt_introspection":false';;
  fapi_2)
    FLAGS='"require_par":true,"require_jarm":true,"require_dpop":true,"require_iss":true,"require_mtls":false,"require_http_signatures":false,"require_jwt_introspection":false';;
  fapi_2_message_signing)
    # The FINAL msg-signing plan's "request signing" = SIGNED REQUEST OBJECTS
    # (JAR signed_non_repudiation) - the happy flow's token POST is PLAIN;
    # no RFC 9421 HTTP-message-signature or introspection posture.
    FLAGS='"require_par":true,"require_jarm":true,"require_dpop":true,"require_iss":true,"require_mtls":false,"require_http_signatures":false,"require_jwt_introspection":false';;
  fapi_1_advanced)
    FLAGS='"require_par":true,"require_jarm":true,"require_dpop":false,"require_iss":true,"require_mtls":true,"require_http_signatures":false,"require_jwt_introspection":false';;
  fapi_ciba)
    FLAGS='"require_par":false,"require_jarm":false,"require_dpop":false,"require_iss":true,"require_mtls":false,"require_http_signatures":false,"require_jwt_introspection":false';;
  formpost)
    # The Form Post OP profile (auth DESIGN 9a.25): the plain OIDC
    # posture - the RESPONSE MODE (form_post) is the family's distinction,
    # not a flag set. The env rides the same RS256 signing family as the
    # standard family.
    FLAGS='"require_par":false,"require_jarm":false,"require_dpop":false,"require_iss":false,"require_mtls":false,"require_http_signatures":false,"require_jwt_introspection":false';;
  sm_session)
    # The Session-OP trio (auth DESIGN 9a.26): checks-session needs NO
    # flags - the check_session_iframe + the backchannel fanout ride the
    # handler paths.
    FLAGS='"require_par":false,"require_jarm":false,"require_dpop":false,"require_iss":false,"require_mtls":false,"require_http_signatures":false,"require_jwt_introspection":false';;
  vp)
    # The OID4VP verifier family (auth DESIGN 9a.27): the verifier
    # requests ride the eudi_wallet connection + the issuance-chain x5c
    # (the HAIP plan's trust anchor). The plain OIDC token posture.
    FLAGS='"require_par":false,"require_jarm":false,"require_dpop":false,"require_iss":false,"require_mtls":false,"require_http_signatures":false,"require_jwt_introspection":false';;
  vci)
    # OID4VCI issuer cells: the suite's vci profile drives PAR-pushed
    # authorization (the credential offer's pre-authorized codes ride the
    # pushed flow); no JARM (the code response stays plain - the suite
    # parses a standard code redirect), no mTLS (private_key_jwt +
    # dpop-only sender constraint).
    FLAGS='"require_par":true,"require_jarm":false,"require_dpop":false,"require_iss":true,"require_mtls":false,"require_http_signatures":false,"require_jwt_introspection":false';;
  vci_haip)
    # OID4VCI HAIP cells: the vci posture PLUS attestation-based client
    # authentication (draft-ietf-oauth-attestation-based-client-auth;
    # auth DESIGN §9a.19). Sender constraint = DPoP (the plan's whole
    # fapi2 family runs sender_constrain=dpop - the require-dpop gate
    # enforces it server-side, auth DESIGN §9a.22). The allow flag + the
    # trust anchor (the attester's self-signed leaf PEM) + the expected
    # attestation iss ride the profile row - discovery then advertises
    # attest_jwt_client_auth and the attestation alg lists.
    FLAGS='"require_par":true,"require_jarm":false,"require_dpop":true,"require_iss":true,"require_mtls":false,"require_http_signatures":false,"require_jwt_introspection":false';;
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
# OID4VCI key-ATTESTATION issuer key (the rig plays the attester): the
# suite signs key-attestation+jwt with this key and the plan config
# publishes its PUBLIC JWKS as vci_key_attestation_jwks (the trusted
# attester set). The private form goes to seed-out for the harness.
VCIATT_KEYS="$(VCIATT_CN="vci-attester${ENV_SLUG:+-$ENV_SLUG}.${ORG_SLUG}.${DOMAIN_SUFFIX}" python3 - <<'PYGENVCIATT'
import base64, datetime, json, os
from cryptography import x509
from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat
from cryptography.x509.oid import NameOID

key = ec.generate_private_key(ec.SECP256R1())
pub = key.public_key().public_bytes(Encoding.X962, PublicFormat.UncompressedPoint)
x = base64.urlsafe_b64encode(pub[1:33]).rstrip(b'=').decode()
y = base64.urlsafe_b64encode(pub[33:65]).rstrip(b'=').decode()
d = key.private_numbers().private_value.to_bytes(32, 'big')
d_b64 = base64.urlsafe_b64encode(d).rstrip(b'=').decode()
kid = 'vci-attester-key'
# The attestation signer key needs an x5c chain (VCIGenerateKeyAttestation:
# "A x5c entry is required in the client's signing key"). Self-issue a
# leaf certificate for the attester and embed the DER chain base64.
name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, os.environ['VCIATT_CN'])])
now = datetime.datetime.now(datetime.timezone.utc)
cert = (x509.CertificateBuilder()
        .subject_name(name).issuer_name(name)
        .public_key(key.public_key())
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(days=1))
        .not_valid_after(now + datetime.timedelta(days=3650))
        .add_extension(x509.BasicConstraints(ca=False, path_length=None), critical=True)
        .sign(key, hashes.SHA256()))
x5c = [base64.b64encode(cert.public_bytes(serialization.Encoding.DER)).decode()]
leaf_pem = cert.public_bytes(serialization.Encoding.PEM).decode()
private = {"kty": "EC", "kid": kid, "crv": "P-256", "x": x, "y": y, "d": d_b64, "alg": "ES256", "x5c": x5c}
public = {"keys": [{"kty": "EC", "kid": kid, "use": "sig", "alg": "ES256", "crv": "P-256", "x": x, "y": y, "x5c": x5c}]}
print(json.dumps({"private": private, "public": public, "leaf_pem": leaf_pem}))
PYGENVCIATT
)"
VCIATT_PRIV=$(echo "$VCIATT_KEYS" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['private']))")
VCIATT_PUB=$(echo "$VCIATT_KEYS" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['public']))")
VCIATT_PEM=$(echo "$VCIATT_KEYS" | python3 -c "import json,sys; print(json.load(sys.stdin).get('leaf_pem','').rstrip())")

# Attestation profile fields (vci_haip only): the trust anchor PEM
# (attester self-signed leaf) + the expected attestation iss ride the
# security profile row (auth DESIGN 9a.19); empty otherwise.
ATTESTATION_FIELDS=""
ATTESTATION_FIELDS_BASE=""
ATTESTATION_JSON_ANCHOR=""
if [ "$PROFILE" == "vci_haip" ] || [ "$PROFILE" == "vp" ]; then
  # vci_haip: the attester block (DESIGN 9a.19) rides the profile row.
  # vp: NO attestation fields - only the pass-1 PUT + issuance chain
  # below run for the verifier family (DESIGN 9a.27).
  if [ "$PROFILE" == "vci_haip" ]; then
  ATTESTATION_ANCHOR="$VCIATT_PEM"
  # The attester identity rides the ENV : env `cert` keeps the
  # legacy form (the specs' hardcoded constant); other envs suffix the
  # slug. The specs read `attestation_issuer(vciatt)` from seed-out -
  # matching rows override the constant.
  if [ "$ENV_SLUG" = "cert" ]; then
    ATTESTATION_ISSUER="https://vci-attester.conformance-local"
  else
    ATTESTATION_ISSUER="https://vci-attester-${ENV_SLUG}.conformance-local"
  fi
  ATTESTATION_JSON_ANCHOR="$(printf '%s' "$ATTESTATION_ANCHOR" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))")"
  ATTESTATION_ISSUER_JSON="$(printf '%s' "$ATTESTATION_ISSUER" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))")"
  ATTESTATION_FIELDS=",\"allow_client_attestation\":true,\"client_attestation_trust_anchor_pem\":$ATTESTATION_JSON_ANCHOR,\"client_attestation_issuer\":$ATTESTATION_ISSUER_JSON"
  fi
  # Pass 1: PUT the profile (no issuance material yet) so the
  # cert-host JWKS resolves the ES256 family (the tenant-plane
  # filter) - runs for vci_haip AND vp (the verifier request objects
  # sign with the same tenant ES256 key the issuance leaf wraps).
  ccall auth PUT /v1/security-profile --env "$ENV_ID" --body "{
    \"scope\":\"env\",
    \"org_id\":\"$ORG_ID\",
    \"env_id\":\"$ENV_ID\",
    \"profile\":\"$PROFILE\",
    $FLAGS,
    \"require_pkce\":true,
    \"signing_alg\":\"$ALG\",
    \"refresh_rotation\":$ROTATION
    $ATTESTATION_FIELDS_BASE
  }" >/dev/null || true
  # HAIP issuance chain (the credential/status x5c): the rig's
  # issuance CA signs a LEAF on the ISSUER's ES256 public key (read
  # from the live JWKS). The profile carries leaf (std-b64 DER) + CA
  # (PEM); the harness pins the SAME CA as the credential/status trust
  # anchor. The issuer never holds the CA key.
  #
  # RICAL (ISO/IEC 18013-5 Annex F.3.2): the SAME block mints the Reader
  # Issuer CA List - the COSE_Sign1-signed CBOR document listing the
  # issuance CA as a reader CA (isTrustAnchor=true). The suite's
  # RicalTrustManager resolves the request object's x5c chain BY THE
  # LEAF'S AKI against the RICAL entries' SKI - so the CA gains a SKI
  # extension and the leaf an AKI (multipaz findCaCertificate).
  HAIP_JWKS="$(curl -sk "$CERT_AUTH_HOST/.well-known/jwks.json")"
  HAIP_ISSUANCE_JSON="$(export HAIP_JWKS HAIP_ISSUER_URL="$CERT_AUTH_HOST" HAIP_RICAL_URL="$CERT_AUTH_HOST/.well-known/rical"; python3 <<'PYGENHAIP'
import os, json, base64, datetime
import cryptography.hazmat.primitives.asymmetric.ec as ec
from cryptography import x509
from cryptography.hazmat.primitives import serialization, hashes
from cryptography.x509.oid import NameOID, ExtensionOID
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature

issuer_url = os.environ["HAIP_ISSUER_URL"]
rical_url = os.environ.get("HAIP_RICAL_URL", "")
d = json.loads(os.environ["HAIP_JWKS"])
import sys
pub = next((k for k in d.get("keys", [])
            if k.get("alg") == "ES256" and k.get("use") == "sig"), None)
if pub is None:
    sys.exit(0)
x = int.from_bytes(base64.urlsafe_b64decode(pub["x"] + "=="), "big")
y = int.from_bytes(base64.urlsafe_b64decode(pub["y"] + "=="), "big")
pk = ec.EllipticCurvePublicNumbers(x, y, ec.SECP256R1()).public_key()
x_b64 = base64.urlsafe_b64encode(x.to_bytes(32, "big")).rstrip(b"=").decode()
y_b64 = base64.urlsafe_b64encode(y.to_bytes(32, "big")).rstrip(b"=").decode()

ca_key = ec.generate_private_key(ec.SECP256R1())
now = datetime.datetime.now(datetime.timezone.utc)
ca_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "sentin8-haip-issuance-ca")])
ca = (x509.CertificateBuilder()
      .subject_name(ca_name).issuer_name(ca_name)
      .public_key(ca_key.public_key())
      .serial_number(x509.random_serial_number())
      .not_valid_before(now - datetime.timedelta(days=1))
      .not_valid_after(now + datetime.timedelta(days=3650))
      .add_extension(x509.BasicConstraints(ca=True, path_length=1), critical=True)
      .add_extension(x509.KeyUsage(
          digital_signature=True, key_cert_sign=True, crl_sign=True,
          content_commitment=False, data_encipherment=False,
          encipher_only=False, decipher_only=False,
          key_agreement=False, key_encipherment=False), critical=True)
      .add_extension(x509.SubjectKeyIdentifier.from_public_key(ca_key.public_key()), critical=False)
      .sign(ca_key, hashes.SHA256()))
ca_ski = ca.extensions.get_extension_for_class(x509.SubjectKeyIdentifier).value.digest
# The serial stays a python int (the RICAL entry encodes it as a CBOR
# uint - ValidateRicalStructure: "'serialNumber' must be a biguint...").
leaf_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, issuer_url)])
leaf = (x509.CertificateBuilder()
        .subject_name(leaf_name).issuer_name(ca_name)
        .public_key(pk)
        .serial_number(x509.random_serial_number())
        .not_valid_before(now - datetime.timedelta(days=1))
        .not_valid_after(now + datetime.timedelta(days=3650))
        # multipaz validateCertificationTrustPath: the chain's FIRST
        # cert (the request object's signer) must carry the
        # digitalSignature key usage ("Certificate is not a signing
        # certificate" otherwise).
        .add_extension(x509.KeyUsage(
            digital_signature=True, key_cert_sign=False, crl_sign=False,
            content_commitment=False, data_encipherment=False,
            encipher_only=False, decipher_only=False,
            key_agreement=False, key_encipherment=False), critical=True)
        .add_extension(x509.SubjectKeyIdentifier.from_public_key(pk), critical=False)
        .add_extension(x509.AuthorityKeyIdentifier.from_issuer_subject_key_identifier(
            x509.SubjectKeyIdentifier(ca_ski)), critical=False)
        .sign(ca_key, hashes.SHA256()))

# ── The RICAL (ISO/IEC 18013-5 Annex F.3.2) ───────────────────────
# A COSE_Sign1: protected header {alg: -7 (ES256), x5chain: [provider
# cert DER]} (labels 1 and 33), payload = the CBOR map below. The RICAL
# provider is the ecosystem operator publishing the reader CA list -
# the seed mints its key + self-signed cert, and lists the issuance CA
# as the reader CA (isTrustAnchor=true, no trust constraints).

# Minimal CBOR encoder (RFC 8949): the RICAL uses tstr-keyed maps,
# arrays, bstr, tstr, booleans, and small/negative ints - no tags
# except the date-time strings (standard tag 0 wrapping an ISO-8601
# tstr - multipaz's getAsDateTimeString requires Tagged(0, Tstr)).
def _head(major, val):
    m = major << 5
    if val < 24:
        return bytes([m | val])
    elif val < 0x100:
        return bytes([m | 24, val])
    elif val < 0x10000:
        return bytes([m | 25]) + val.to_bytes(2, "big")
    elif val < 0x100000000:
        return bytes([m | 26]) + val.to_bytes(4, "big")
    else:
        return bytes([m | 27]) + val.to_bytes(8, "big")

def cbor_tstr(s):
    return _head(3, len(s)) + s.encode()

def cbor_bstr(b):
    return _head(2, len(b)) + b

def cbor_int(n):
    # A CBOR integer: uints up to 64 bits via the head, the tag-2
    # biguint (an unsigned-bignum byte string - RFC 8949 3.4.3) for
    # larger serials (ValidateRicalStructure accepts both forms),
    # negative ints via the standard major-1 head.
    if n < 0:
        return _head(1, -n - 1)
    if n < 2 ** 64:
        return _head(0, n)
    big = n.to_bytes((n.bit_length() + 7) // 8, "big")
    return cbor_tagged(2, cbor_bstr(big))

def cbor_bool(v):
    return bytes([0xF5 if v else 0xF4])

def cbor_null():
    return bytes([0xF6])

def cbor_tagged(tag, inner):
    return _head(6, tag) + inner

def cbor_date(iso):
    # RFC 8949 3.3.1 tag 0: a text string with an ISO-8601 date/time.
    return cbor_tagged(0, cbor_tstr(iso))

def cbor_array(items):
    out = _head(4, len(items))
    for it in items:
        out += it
    return out

def cbor_map(pairs):
    out = _head(5, len(pairs))
    for k, v in pairs:
        out += k
        out += v
    return out

rical_provider_key = ec.generate_private_key(ec.SECP256R1())
rical_provider_name = x509.Name([x509.NameAttribute(NameOID.COMMON_NAME, "sentin8-rical-provider")])
rical_provider_cert = (x509.CertificateBuilder()
      .subject_name(rical_provider_name).issuer_name(rical_provider_name)
      .public_key(rical_provider_key.public_key())
      .serial_number(x509.random_serial_number())
      .not_valid_before(now - datetime.timedelta(days=1))
      .not_valid_after(now + datetime.timedelta(days=3650))
      .add_extension(x509.BasicConstraints(ca=True, path_length=None), critical=True)
      .add_extension(x509.SubjectKeyIdentifier.from_public_key(rical_provider_key.public_key()), critical=False)
      .sign(rical_provider_key, hashes.SHA256()))

def iso(dt):
    # kotlin.time.Instant.parse form: RFC 3339 with explicit offset.
    return dt.strftime("%Y-%m-%dT%H:%M:%SZ")

date_now = now
next_update = now + datetime.timedelta(days=30)
not_after = now + datetime.timedelta(days=3650)

payload = cbor_map([
    (cbor_tstr("version"), cbor_tstr("1.0")),
    (cbor_tstr("provider"), cbor_tstr("sentin8-conformance")),
    (cbor_tstr("date"), cbor_date(iso(date_now))),
    (cbor_tstr("type"), cbor_tstr("https://openid.net/conformance/rical")),
    (cbor_tstr("nextUpdate"), cbor_date(iso(next_update))),
    (cbor_tstr("notAfter"), cbor_date(iso(not_after))),
    # `id` OMITTED (getOrNull -> null; a present id must be a number).
    (cbor_tstr("latestRicalUrl"), cbor_tstr(rical_url)),
    (cbor_tstr("extensions"), cbor_map([])),
    (cbor_tstr("certificateInfos"), cbor_array([
        cbor_map([
            (cbor_tstr("certificate"), cbor_bstr(ca.public_bytes(serialization.Encoding.DER))),
            (cbor_tstr("isTrustAnchor"), cbor_bool(True)),
            (cbor_tstr("ski"), cbor_bstr(ca_ski)),
            # ValidateRicalStructure requires serialNumber (the CA
            # certificate's serial - a CBOR uint, the biguint form).
            (cbor_tstr("serialNumber"), cbor_int(ca.serial_number)),
            (cbor_tstr("trustConstraints"), cbor_array([])),
            (cbor_tstr("extensions"), cbor_map([])),
        ]),
    ])),
])

# COSE_Sign1 (RFC 9052 4.1): [protected bstr, unprotected map, payload
# bstr, signature bstr]; Sig_structure = ["Signature1", protected,
# external_aad, payload] signed with ES256 (-7).
protected = cbor_map([
    (cbor_int(1), cbor_int(-7)),
    (cbor_int(33), cbor_array([cbor_bstr(rical_provider_cert.public_bytes(serialization.Encoding.DER))])),
])
sig_structure = cbor_array([
    cbor_tstr("Signature1"),
    cbor_bstr(protected),
    cbor_bstr(b""),
    cbor_bstr(payload),
])
sig_der = rical_provider_key.sign(sig_structure, ec.ECDSA(hashes.SHA256()))
# DER (r,s) -> two fixed-width 32-byte big-endian ints (the COSE ES256
# raw signature form, RFC 9053 2.1).
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
r, s = decode_dss_signature(sig_der)
def b64u_int(n):
    b = n.to_bytes((n.bit_length() + 7) // 8 or 1, "big")
    return b
cose_sig = b64u_int(r) + b64u_int(s)
# P-256 signature = raw 64-byte r||s
cose_sign1 = cbor_array([
    cbor_bstr(protected),
    cbor_map([]),
    cbor_bstr(payload),
    cbor_bstr(cose_sig),
])
rical_b64 = base64.b64encode(cose_sign1).decode()

print(json.dumps({
  "leaf_der_b64": base64.b64encode(leaf.public_bytes(serialization.Encoding.DER)).decode(),
  "ca_pem": ca.public_bytes(serialization.Encoding.PEM).decode(),
  "x": x_b64,
  "y": y_b64,
  "kid": pub["kid"],
  "rical_b64": rical_b64,
}))
PYGENHAIP
)"
  HAIP_LEAF_DER_B64="$(echo "$HAIP_ISSUANCE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['leaf_der_b64'])")"
  # An EMPTY issuance
  # JSON means the tenant JWKS carries no ES256 key - the pass-1
  # profile PUT has not made the ES256 family resolve on this host yet
  # (a stale host-context cache, or the seed ran before the env row).
  # Writing the attestation row now would land with EMPTY anchors and
  # the family's attestation tests would fail far from the cause.
  # Fail loud (DESIGN §9a.5, seed step 2): report the state and let
  # the operator re-run the seed.
  if [ -z "$HAIP_LEAF_DER_B64" ]; then
    log "FATAL: issuance chain NOT built for profile=$PROFILE - no ES256 key in the JWKS at $CERT_AUTH_HOST (the pass-1 profile PUT must land first; a stale host-context cache may pin the tenant to the platform family - re-run the seed)"
    exit 1
  fi
  HAIP_CA_PEM="$(echo "$HAIP_ISSUANCE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['ca_pem'])")"
  # x5c leaf PEM for the seed-out + the profile JSON fields.
  HAIP_LEAF_PEM="$(python3 - "$HAIP_LEAF_DER_B64" <<'PYHAIPPEM'
import sys, base64
b64 = base64.b64encode(base64.b64decode(sys.argv[1])).decode()
print("-----BEGIN CERTIFICATE-----")
for i in range(0, len(b64), 64):
    print(b64[i:i+64])
print("-----END CERTIFICATE-----")
PYHAIPPEM
)"
  HAIP_LEAF_JSON="$(printf '%s' "$HAIP_LEAF_PEM" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))")"
  HAIP_CHAIN_JSON="$(printf '%s' "$HAIP_CA_PEM" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))")"
  ATTESTATION_FIELDS="${ATTESTATION_FIELDS},\"issuance_leaf_pem\":${HAIP_LEAF_JSON},\"issuance_chain_pem\":${HAIP_CHAIN_JSON}"
  HAIP_CA_PEM_EXPORTED="$HAIP_CA_PEM"
  HAIP_LEAF_DER_B64_EXPORTED="$HAIP_LEAF_DER_B64"
  HAIP_ISSUER_XY_EXPORTED="$(echo "$HAIP_ISSUANCE_JSON" | python3 -c "import json,sys; d=json.load(sys.stdin); print(d['kid'], d['x'], d['y'])")"
  # The RICAL (Annex F.3.2) - std-base64 COSE_Sign1. The spec pins it
  # as client.rical (the suite's RegisterRical reads it from the
  # Client section; base64-decoded to bytes).
  HAIP_RICAL_B64_EXPORTED="$(echo "$HAIP_ISSUANCE_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin).get('rical_b64',''))")"
fi
PROFILE_PUT_OUT="$(ccall auth PUT /v1/security-profile --env "$ENV_ID" --body "{
    \"scope\":\"env\",
    \"org_id\":\"$ORG_ID\",
    \"env_id\":\"$ENV_ID\",
    \"profile\":\"$PROFILE\",
    $FLAGS,
    \"require_pkce\":true,
    \"signing_alg\":\"$ALG\",
    \"refresh_rotation\":$ROTATION
    $ATTESTATION_FIELDS
  }")"
if [ -z "$PROFILE_PUT_OUT" ]; then
  log "FATAL: the security-profile PUT FAILED for profile=$PROFILE env=$ENV_ID - fix the API error (the seed must never pass-1 silently: a missed profile row makes every module of the family run against the WRONG posture)"
  exit 1
fi
log "profile=$PROFILE set ({$FLAGS}, $ALG, rotation=$ROTATION)"

# ── 2b-vp. The OID4VP verifier connection (DESIGN 9a.27): the vp env
# carries a `eudi_wallet` enterprise connection whose trusted-issuer
# set = the SUITE's wallet (the conformance host's credential issuer).
# The suite mints credentials signed with credential.signing_jwk (the
# seed-out xy key) - our verifier accepts presentations from the
# suite's wallet by trusting that issuer. The re-seed's issuance chain
# is FRESH each run (a new CA) - the stale row is deleted so the new
# anchor lands (the name-409 path would keep the old key forever).
if [ "$PROFILE" == "vp" ] && [ -n "${HAIP_ISSUER_XY_EXPORTED:-}" ]; then
  # The trust-entry issuer = the suite's TEST-INSTANCE base (the
  # credential's `iss` - the suite mints credentials there). The
  # spec's own registration refreshes this entry with the campaign's
  # fresh wallet key (the seed's entry is the idempotent bootstrap).
  WALLET_TRUST="$(printf '%s' "{\"issuer\":\"https://localhost.emobix.co.uk:8443/test/a/$ALIAS\",\"jwks\":{\"keys\":[{\"kty\":\"EC\",\"crv\":\"P-256\",\"alg\":\"ES256\",\"x\":\"$(echo "$HAIP_ISSUER_XY_EXPORTED" | cut -d' ' -f2)\",\"y\":\"$(echo "$HAIP_ISSUER_XY_EXPORTED" | cut -d' ' -f3)\"}]}}" | python3 -c "import json,sys; print(json.dumps(sys.stdin.read()))")"
  CONN_LIST="$(ccall auth GET /v1/admin/enterprise-connections --env "$ENV_ID" 2>/dev/null || echo '[]')"
  OLD_CONN_ID="$(echo "$CONN_LIST" | python3 -c "
import json,sys
try:
    rows = json.load(sys.stdin)
except Exception:
    rows = []
for r in rows if isinstance(rows, list) else []:
    if r.get('strategy') == 'eudi_wallet':
        print(r.get('id', ''))
        break
" 2>/dev/null)"
  if [ -n "$OLD_CONN_ID" ]; then
    ccall auth DELETE "/v1/admin/enterprise-connections/$OLD_CONN_ID" --env "$ENV_ID" >/dev/null 2>&1 || true
    log "stale eudi_wallet connection removed (fresh issuance-chain anchor lands)"
  fi
  ccall auth POST /v1/admin/enterprise-connections --env "$ENV_ID" --body "{
    \"name\":\"eudi-wallet-conformance\",
    \"strategy\":\"eudi_wallet\",
    \"status\":\"active\",
    \"config\":{\"trusted_issuers\":[$WALLET_TRUST],\"min_level_of_assurance\":\"low\"}
  }" >/dev/null || { log "FATAL: the eudi_wallet connection POST failed - the OID4VP verifier modules will 404 (auth DESIGN 9a.27: the request creator gates on the connection)"; exit 1; }
  log "eudi_wallet connection ensured for the verifier family"
fi

# ── 2c. TLS warm-up (runbook §5): the suite's Java client makes
# single-shot fetches with a short socket timeout; a cold auth instance
# must first fetch the tenant's leaf from Acme on-demand (~100ms when
# Acme is warm, seconds when its own boot races). One warm-up request
# lands the cert in the auth instance's resolver BEFORE ANY other call
# (the sign-up + DCR go to the SAME host - a cold leaf would fail them).
log "warming TLS cert for $CERT_AUTH_HOST"
curl -sk -m 20 -o /dev/null --retry 3 --retry-delay 2 \
  "$CERT_AUTH_HOST/.well-known/openid-configuration" \
  && log "TLS cert warm"

# ── 3. Certification user (idempotent sign-up in the target TENANT) ──
# The suite drives the user's sign-in through the browser UI; the
# sign-up itself provisions into the tenant resolved from the env's own
# auth hostname (the signup path reads the tenant from the hostname,
# matching browser behavior). One user email per env .
log "ensuring certification user $USER_EMAIL ($ENV_SLUG tenant)"
SUP_RC=0
"$CLI" signup --sentin8-auth-url "$CERT_AUTH_HOST" \
  --email "$USER_EMAIL" --password "$USER_PASSWORD" \
  --first-name "Conformance" --last-name "Certification" || SUP_RC=$?
# The 'exists' case continues (409/40x from a prior seed); a CONNECT/
# transport error (the CLI's 'error sending request' form) = FATAL - a
# silent continue left envs without a user and the whole family's
# modules failing later (the cert-ciba seed + 401 chain).
if [ "$SUP_RC" != "0" ]; then
  # Classify by the CLI's OWN error text: a 409 CONFLICT surfaces as
  # 'email already registered: <email>' (CLI src/auth.rs). Retry once
  # with the output CAPTURED - the message plane, not the exit-1 plane,
  # decides exists vs FATAL (a transport error's text has no such line).
  SUP_RETRY_OUT="$($CLI signup --sentin8-auth-url "$CERT_AUTH_HOST" \
    --email "$USER_EMAIL" --password "$USER_PASSWORD" \
    --first-name "Conformance" --last-name "Certification" 2>&1 || true)"
  if echo "$SUP_RETRY_OUT" | grep -q 'email already registered'; then
    log "sign-up says exists - continuing"
  elif echo "$SUP_RETRY_OUT" | grep -q 'email already registered\|Account created'; then
    log "sign-up retry resolved - continuing"
  else
    log "FATAL: cert user sign-up failed (rc=$SUP_RC: $(echo "$SUP_RETRY_OUT" | head -2 | tr '\n' ' '))"
    exit 1
  fi
fi

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
  local grants=",\"grant_types\":[\"authorization_code\",\"refresh_token\"]"
  if [[ "$extra" == *'"grant_types"'* ]]; then grants=""; fi
  # Same rule for redirect_uris: the extra may supply its own array
  # (e.g. the happy-flow client2's query-parameter variant).
  # Duplicate-field rules: the extras may override the base members, so
  # the base fragment drops out when the extra supplies the same key.
  local parts=()
  parts+=("\"client_name\":\"$name\"")
  if [[ "$extra" != *'"redirect_uris"'* ]]; then parts+=("\"redirect_uris\":[\"$CALLBACK\"]"); fi
  if [[ "$extra" != *'"grant_types"'* ]]; then parts+=("\"grant_types\":[\"authorization_code\",\"refresh_token\"]"); fi
  # Same duplicate-field rule for response_types (the hybrid/formpost
  # families register their own multi-type arrays).
  if [[ "$extra" != *'"response_types"'* ]]; then parts+=("\"response_types\":[\"code\"]"); fi
  if [[ "$extra" != *'"scope"'* ]]; then parts+=("\"scope\":\"openid profile email phone address offline_access\""); fi
  parts+=("\"code_challenge_method\":\"S256\"")
  if [[ "$extra" != *'"consent_required"'* ]]; then parts+=("\"consent_required\":$CONSENT_REQUIRED"); fi
  # Join with commas into the final body.
  local body
  body=$(printf '%s\n' "${parts[@]}" | paste -sd, -)
  if [[ -n "$extra" ]]; then body="$body,$extra"; fi
  body="{$body}"
  # Banner-strip not needed (curl output); parse client fields with jget.
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
# The family's response_types: the standard families certify `code`;
# the implicit/hybrid/formpost families' clients register the FULL
# OIDC Core matrix (OIDC Core 3.1.2.1 - the authorize endpoint rejects
# an unregistered response_type; the suite's implicit cells request
# id_token / id_token token and the hybrid cells request
# code id_token / code token / code id_token token against the SAME
# static client, and the formpost plan family re-uses the same cells
# under the form_post response mode). Double-quoted with escapes: the
# value embeds into the dcr extra's escaped-JSON context as literal
# double quotes (a single-quoted \" would land backslashes in the
# body and the DCR rejects the malformed JSON).
HYBRID_RESPONSE_TYPES="\"response_types\":[\"code\",\"code id_token\",\"code token\",\"code id_token token\",\"id_token\",\"id_token token\"]"
case "$PROFILE" in
  implicit|hybrid|formpost) : ;;
  *) HYBRID_RESPONSE_TYPES="\"response_types\":[\"code\"]" ;;
esac
BASIC_JSON="$(dcr "cert-basic-basic" "\"token_endpoint_auth_method\":\"client_secret_basic\",$HYBRID_RESPONSE_TYPES,\"post_logout_redirect_uris\":[\"${CALLBACK%/callback}/post_logout_redirect\"]")"
POSTC_JSON="$(dcr "cert-basic-post" "\"token_endpoint_auth_method\":\"client_secret_post\",$HYBRID_RESPONSE_TYPES,\"post_logout_redirect_uris\":[\"${CALLBACK%/callback}/post_logout_redirect\"]")"
PKCE_JSON="$(dcr "cert-public-pkce" "\"token_endpoint_auth_method\":\"none\",$HYBRID_RESPONSE_TYPES")"

# RFC 8628 device-flow client - the rotate-keys module's operator grant
# (the platform key rotation - see runner.ts's device block). It rides a
# DEDICATED public client in the SAME cert env as every other suite
# client: the device endpoint resolves its client row under the cert
# env's RLS context, so a platform client (sentin8-cli lives in the
# system env) answers 401 invalid_client here. Grant-type opt-in
# (oauth grant gate), public auth method, and admin:write in the scope
# (the approving cert-user's role union carries the rest).
DEVICE_JSON="$(dcr "cert-device" "\"grant_types\":[\"urn:ietf:params:oauth:grant-type:device_code\"],\"token_endpoint_auth_method\":\"none\",\"scope\":\"openid profile email sentin8:auth:admin:write\"")"

# CIBA client: ping delivery points at the suite callback (poll + ping).
# Single-line JSON (curl -d with embedded newlines inside quoted values
# broke the body in the shell heredoc shape).
# The fapi_ciba posture REQUIRES private_key_jwt client auth (the
# bc-authorize gate rejects the secret methods) - the client carries its
# OWN EC P-256 key (the suite signs client assertions with the private
# jwks; the assertion audience = the backchannel endpoint).
#
# CIBA client key = RSA-PS256 (the fapi2 cells' shape - auth DESIGN
# 9a.16 (i)): the suite's FAPICIBAID1 RS256-negative modules gate on
# keys[0].alg == 'PS256' of the plan config's client.jwks (suite source
# JWKUtil.getAlgFromClientJwks reads ONLY the first key), and the server
# verifies RSA+PS256 assertions (verify_with_jwk's ('RSA','PS256') arm).
# An EC/ES256 client key makes those two modules SKIP - the 9a.10 no-skip
# rule treats every skip as failed coverage. A two-key jwks cannot serve
# both families: the suite's signer errors on >1 signature-use key, and
# FAPICheckKeyAlgInClientJWKs fails setup for any sig key without an alg.
# CIBA ID1 emits NO DPoP proofs (plain_fapi pre-authorization is empty),
# so the client key only signs request objects + client assertions.
CIBA_KEYS="$(python3 - <<'PYGEN'
import base64, json
from cryptography.hazmat.primitives.asymmetric import rsa

key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
rn = key.public_key().public_numbers()
def _bn(v): return base64.urlsafe_b64encode(v.to_bytes((v.bit_length()+7)//8, 'big')).rstrip(b'=').decode()
kid = 'ciba-key'
private = {"kty": "RSA", "kid": kid, "n": _bn(rn.n), "e": _bn(rn.e), "d": _bn(key.private_numbers().d), "alg": "PS256"}
public = {"keys": [{"kty": "RSA", "kid": kid, "use": "sig", "alg": "PS256", "n": _bn(rn.n), "e": _bn(rn.e)}]}
print(json.dumps({"private": private, "public": public}))
PYGEN
)"
CIBA_PUB=$(echo "$CIBA_KEYS" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['public']))")
CIBA_PRIV=$(echo "$CIBA_KEYS" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['private']))")
CIBA_PING_URL="${CALLBACK%/callback}/ciba-notification-endpoint"
CIBA_JSON="$(dcr "cert-ciba" "\"grant_types\":[\"urn:openid:params:grant-type:ciba\",\"refresh_token\"],\"token_endpoint_auth_method\":\"private_key_jwt\",\"jwks\":$CIBA_PUB,\"backchannel_client_notification_endpoint\":\"$CIBA_PING_URL\"")"

# Client ids/secrets print AND persist (the SEED_OUT path resolved at
# the env-slug block above - the OIDF automation harness reads it for
# the suite plan configs).
echo "private_jwks(vciatt)=$VCIATT_PRIV" >> "$SEED_OUT"
echo "public_jwks(vciatt)=$VCIATT_PUB" >> "$SEED_OUT"
echo "attester_pem(vciatt)=$VCIATT_PEM" >> "$SEED_OUT"
[ -n "${HAIP_CA_PEM_EXPORTED:-}" ] && echo "haip_issuer_ca_pem(haip)=$HAIP_CA_PEM_EXPORTED" >> "$SEED_OUT"
[ -n "${HAIP_LEAF_DER_B64_EXPORTED:-}" ] && echo "haip_issuer_leaf_der_b64(haip)=$HAIP_LEAF_DER_B64_EXPORTED" >> "$SEED_OUT"
[ -n "${HAIP_ISSUER_XY_EXPORTED:-}" ] && echo "haip_issuer_xy(haip)=$HAIP_ISSUER_XY_EXPORTED" >> "$SEED_OUT"
# The RICAL rides the seed-out as ONE std-base64 line (the COSE_Sign1
# bytes - no newlines; the spec regex reads it whole).
[ -n "${HAIP_RICAL_B64_EXPORTED:-}" ] && echo "rical_b64(rical)=$HAIP_RICAL_B64_EXPORTED" >> "$SEED_OUT"
echo "attestation_issuer(vciatt)=${ATTESTATION_ISSUER:-https://vci-attester.conformance-local}" >> "$SEED_OUT"
emit_client() { # emit_client <name> <json>
  echo "client_id($1)=$(jget "$2" client_id)" | tee -a "$SEED_OUT"
  echo "client_secret($1)=$(jget "$2" client_secret)" | tee -a "$SEED_OUT"
  # RFC 7592 client-config token - the harness's registration
  # surface for STATIC clients (the Back-Channel OP plan's
  # backchannel_logout_uri PUT rides this; auth DESIGN 9a.26).
  echo "registration_access_token($1)=$(jget "$2" registration_access_token)" | tee -a "$SEED_OUT"
}
# CIBA second client - the suite's AbstractFAPICIBAID1MultipleClient
# family (signed-by-other-client / bad-iss / multiple hints) drives a
# SECOND registered client: a distinct id + its OWN keypair (the
# signed-by-other-client negative only fails when the two clients
# actually differ).
CIBA2_KEYS="$(python3 - <<'PYGEN2'
import base64, json
from cryptography.hazmat.primitives.asymmetric import rsa

key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
rn = key.public_key().public_numbers()
def _bn(v): return base64.urlsafe_b64encode(v.to_bytes((v.bit_length()+7)//8, 'big')).rstrip(b'=').decode()
kid = 'ciba2-key'
private = {"kty": "RSA", "kid": kid, "n": _bn(rn.n), "e": _bn(rn.e), "d": _bn(key.private_numbers().d), "alg": "PS256"}
public = {"keys": [{"kty": "RSA", "kid": kid, "use": "sig", "alg": "PS256", "n": _bn(rn.n), "e": _bn(rn.e)}]}
print(json.dumps({"private": private, "public": public}))
PYGEN2
)"
CIBA2_PUB="$(echo "$CIBA2_KEYS" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['public']))")"
CIBA2_PRIV="$(echo "$CIBA2_KEYS" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['private']))")"
CIBA2_JSON="$(dcr "cert-ciba-2" "\"grant_types\":[\"urn:openid:params:grant-type:ciba\",\"refresh_token\"],\"token_endpoint_auth_method\":\"private_key_jwt\",\"jwks\":$CIBA2_PUB,\"backchannel_client_notification_endpoint\":\"$CIBA_PING_URL\"")"
emit_client basic "$BASIC_JSON"
emit_client post "$POSTC_JSON"
emit_client pkce "$PKCE_JSON"
emit_client ciba "$CIBA_JSON"
emit_client ciba2 "$CIBA2_JSON"
emit_client device "$DEVICE_JSON"

# OID4VCI issuer static client (the plan's happy-flow family runs
# client_registration=static_client): private_key_jwt + its own EC jwks
# (the same private-to-suite pattern as the CIBA clients - the suite
# signs the DPoP-less credential proofs + client assertions with the
# handed keys). The scope carries BOTH credential types (the suite
# requests one configuration id per flow; the scope is the consent).
VCI_KEYS="$(python3 - <<'PYGENVCI'
import base64, json
from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

def mk(kid):
    key = ec.generate_private_key(ec.SECP256R1())
    pub = key.public_key().public_bytes(Encoding.X962, PublicFormat.UncompressedPoint)
    x = base64.urlsafe_b64encode(pub[1:33]).rstrip(b'=').decode()
    y = base64.urlsafe_b64encode(pub[33:65]).rstrip(b'=').decode()
    d = key.private_numbers().private_value.to_bytes(32, 'big')
    d_b64 = base64.urlsafe_b64encode(d).rstrip(b'=').decode()
    private = {"kty": "EC", "kid": kid, "crv": "P-256", "x": x, "y": y, "d": d_b64, "alg": "ES256"}
    public = {"keys": [{"kty": "EC", "kid": kid, "use": "sig", "alg": "ES256", "crv": "P-256", "x": x, "y": y}]}
    return private, public

p1, pub1 = mk('vci-key')
p2, pub2 = mk('vci-key2')
print(json.dumps({"p1": p1, "pub1": pub1, "p2": p2, "pub2": pub2}))
PYGENVCI
)"
VCI_PUB1=$(echo "$VCI_KEYS" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['pub1']))")
VCI_PUB2=$(echo "$VCI_KEYS" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['pub2']))")
VCI_PRIV1=$(echo "$VCI_KEYS" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['p1']))")
VCI_PRIV2=$(echo "$VCI_KEYS" | python3 -c "import json,sys; print(json.dumps(json.load(sys.stdin)['p2']))")
VCI_SCOPE='openid profile email offline_access credential:VerifiedPersonCredential credential:VerifiedEmployeeCredential eudi.pid.1 eudi.pid.1.nobinding eudi.pid.1.attestation eudi.pid.1.jwt.keyattest eudi.pid.1.attestation.keyattest eudi.pid.1.jwt_and_attestation.keyattest openid.example.cert.1'
VCI_JSON="$(dcr "cert-vci" "\"token_endpoint_auth_method\":\"private_key_jwt\",\"jwks\":$VCI_PUB1,\"scope\":\"$VCI_SCOPE\",\"consent_required\":true")"
# client2 registers BOTH forms: the AddRedirectUriQuerySuffix cell presents
# <callback>?dummy1=lorem&dummy2=ipsum and the suite asserts the suffixed uri
# IS registered ("the redirect url, including this suffix, must be registered
# for the client") - the exact-match rule rejects any query-bearing
# variant that is not itself registered.
VCI2_JSON="$(dcr "cert-vci-2" "\"token_endpoint_auth_method\":\"private_key_jwt\",\"jwks\":$VCI_PUB2,\"scope\":\"$VCI_SCOPE\",\"consent_required\":true,\"redirect_uris\":[\"$CALLBACK?dummy1=lorem&dummy2=ipsum\",\"$CALLBACK\"]")"
emit_client vci "$VCI_JSON"
emit_client vci2 "$VCI2_JSON"
echo "private_jwks(vci)=$VCI_PRIV1" >> "$SEED_OUT"
echo "private_jwks(vci2)=$VCI_PRIV2" >> "$SEED_OUT"


echo "private_jwks(ciba)=$CIBA_PRIV" >> "$SEED_OUT"
echo "private_jwks(ciba2)=$CIBA2_PRIV" >> "$SEED_OUT"
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
from cryptography.hazmat.primitives.asymmetric import ec, rsa
from cryptography.hazmat.primitives.serialization import Encoding, PublicFormat

# FAPI2 client key = RSA-PS256 (auth DESIGN 9a.16 (i)): the FAPI2-BSA
# signs client assertions/request objects with ES256/PS256; the suite's
# alg-gated negatives (ensure-signed-...-with-RS256-fails) run ONLY
# against a PS256-keyed client (JWKUtil.getAlgFromClientJwks == 'PS256')
# - the RS256 re-signing (ChangeClientJwksAlgToRS256) then resolves with
# the AS's reject (the alg mandate).
key = rsa.generate_private_key(public_exponent=65537, key_size=2048)
rn = key.public_key().public_numbers()
def _bn(v): return base64.urlsafe_b64encode(v.to_bytes((v.bit_length()+7)//8, 'big')).rstrip(b'=').decode()
kid = 'fapi2-key'
private = {"kty": "RSA", "kid": kid, "n": _bn(rn.n), "e": _bn(rn.e), "d": _bn(key.private_numbers().d), "alg": "PS256"}
public = {"keys": [{"kty": "RSA", "kid": kid, "use": "sig", "alg": "PS256", "n": _bn(rn.n), "e": _bn(rn.e)}]}
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
        # registered (not a prefix match). The request_uri-bound-
        # to-client NEGATIVE sends client2 with the PLAIN callback
        # (the suite's config.client2.redirect_uri) and expects the
        # error redirect THERE - client2 registers BOTH (exact-string
        # match per entry; the dummy preserves the happy-flow
        # verbatim requirement, the plain callback is the negative's
        # error target).
        FJSON2="$(dcr "cert-fapi2-$cell-2" "\"token_endpoint_auth_method\":\"private_key_jwt\",\"jwks\":$PUBJWKS,\"redirect_uris\":[\"$CALLBACK?dummy1=lorem&dummy2=ipsum\",\"$CALLBACK\"]")"
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
from cryptography.hazmat.primitives.asymmetric import ec, rsa as rsa_mod
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
# The mtls cell's signing jwks = RSA-PS256 as well (auth DESIGN 9a.16
# (i)); the client CERTIFICATE stays the EC P-256 self-signed leaf.
rsig = rsa_mod.generate_private_key(public_exponent=65537, key_size=2048)
rsn = rsig.public_key().public_numbers()
def _bn2(v): return base64.urlsafe_b64encode(v.to_bytes((v.bit_length()+7)//8, 'big')).rstrip(b'=').decode()
private_jwks = {"kty": "RSA", "kid": "fapi2-mtls-key", "n": _bn2(rsn.n), "e": _bn2(rsn.e), "d": _bn2(rsig.private_numbers().d), "alg": "PS256"}
public_jwks = {"keys": [{"kty": "RSA", "kid": "fapi2-mtls-key", "use": "sig", "alg": "PS256", "n": _bn2(rsn.n), "e": _bn2(rsn.e)}]}
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
      MJSON2="$(dcr "cert-fapi2-mtls-2" "\"token_endpoint_auth_method\":\"self_signed_tls_client_auth\",\"self_signed_tls_client_auth_thumbprint\":\"$THUMB\",\"jwks\":$PUBJWKS,\"redirect_uris\":[\"$CALLBACK?dummy1=lorem&dummy2=ipsum\",\"$CALLBACK\"]")"
      emit_client "fapi2-second-mtls" "$MJSON2"
    fi
    echo "mtls_cert_pem($cl)=$CERT_PEM" >> "$SEED_OUT"
    echo "mtls_key_pem($cl)=$KEY_PEM" >> "$SEED_OUT"
    echo "mtls_cert_der_b64($cl)=$DER64" >> "$SEED_OUT"
    echo "mtls_thumbprint($cl)=$THUMB" >> "$SEED_OUT"
    echo "private_jwks(fapi2-mtls-$cl)=$PRIVJWKS" >> "$SEED_OUT"
  done
fi


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

# ── 3b. Cert user's operator role (the rotate-keys module's grant) ──
# The RFC 8628 device-flow key rotation (the rig's operator action)
# needs the sentin8:auth:admin:write scope - carried by the env's
# sentin8:auth:admin role. The device token's scope = the client's
# registered scopes ∩ the approving user's LIVE role scopes, so the
# CERT USER (not the device client) must hold the role. Assigned
# through the admin API (no direct SQL - E2E rule); idempotent (the
# endpoint inserts ON CONFLICT DO NOTHING).
if [ -n "$USER_ID" ]; then
  AUTH_ADMIN_ROLE_ID="$(ccall auth GET "/v1/admin/roles" --env "$ENV_ID" | python3 -c "
import json,sys
try:
    items=json.load(sys.stdin)
except Exception:
    sys.exit(0)
items = items.get('roles', items) if isinstance(items, dict) else items
print(next((r.get('id','') for r in items if r.get('name')=='sentin8:auth:admin'), ''))
")"
  if [ -n "$AUTH_ADMIN_ROLE_ID" ] && [ -n "$USER_ID" ]; then
    ccall auth POST "/v1/admin/roles/$AUTH_ADMIN_ROLE_ID/members" --env "$ENV_ID" --body "{\"user_id\":\"$USER_ID\"}" >/dev/null \
      && log "sentin8:auth:admin role granted to the cert user ($AUTH_ADMIN_ROLE_ID -> $USER_ID)" \
      || log "WARN: role grant failed (may already exist - continuing)"
  else
    log "WARN: sentin8:auth:admin role not found in the env - grant skipped"
  fi
  # The ORG-ADMINS group membership (the org-scoped access model):
  # the admin API's cross-org probe (auth sentin8or_auth) checks the
  # org groups `sentin8:org:{org_id}:admins` at SYSTEM_ENV_ID - a user
  # with ONLY env roles fails the probe with 'not a member of this
  # organization' (the OID4VP wallet-trust registration drives the
  # admin API as the cert user). The group lives in the SYSTEM env -
  # the lookup + grant target it (no direct SQL - the E2E rule).
  ORG_ADMINS_GROUP_ID="$(ccall auth GET "/v1/admin/groups?page_size=200" --env "$SYSTEM_ENV_ID" | python3 -c "
import json,sys
try:
    items=json.load(sys.stdin)
except Exception:
    sys.exit(0)
items = items.get('groups', items) if isinstance(items, dict) else items
print(next((g.get('id','') for g in items if g.get('name')=='sentin8:org:$ORG_ID:admins'), ''))
")"
  if [ -n "$ORG_ADMINS_GROUP_ID" ]; then
    ccall auth POST "/v1/admin/groups/$ORG_ADMINS_GROUP_ID/members" --env "$SYSTEM_ENV_ID" --body "{\"user_id\":\"$USER_ID\"}" >/dev/null \
      && log "org-admins group membership granted to the cert user ($ORG_ADMINS_GROUP_ID -> $USER_ID)" \
      || log "WARN: org-admins group grant failed (may already exist - continuing)"
  else
    log "WARN: the org-admins group sentin8:org:$ORG_ID:admins not found - the cert user's admin API access may be org-probe-gated"
  fi
fi

# ── 4. Persist the suite configuration inputs ─────────────────────────
cat > "$CERT_USER_ENV" <<EOF
# OIDF conformance suite - certification tenant inputs (generated)
CONFORMANCE_ENV_SLUG=$ENV_SLUG
CONFORMANCE_ALIAS=$ALIAS
CONFORMANCE_CALLBACK=$CALLBACK
CONFORMANCE_USER_EMAIL=$USER_EMAIL
CONFORMANCE_USER_PASSWORD=$USER_PASSWORD
CONFORMANCE_ORG_ID=$ORG_ID
CONFORMANCE_ENV_ID=$ENV_ID
EOF
chmod 600 "$CERT_USER_ENV"
log "wrote $CERT_USER_ENV"
log "next: open https://localhost.emobix.co.uk:8443/ and create the test plans (runbook §4)"