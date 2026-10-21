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

# ── 1. Certification user (idempotent sign-up; NO device sign-in) ──
# The cert user never needs CLI credentials - the OIDF suite drives its
# sign-in through the browser UI during the test runs. Org/env/DCR calls
# below ride the OPERATOR's stored CLI credentials (auto-refreshed by
# `call`), which must hold org-admin scopes (the user who bootstrapped
# the platform / runs the rig).
log "ensuring certification user $USER_EMAIL"
"$CLI" signup --email "$USER_EMAIL" --password "$USER_PASSWORD" \
  --first-name "Conformance" --last-name "Certification" \
  || log "sign-up says exists - continuing"

# Credential gate: `call` auto-refreshes the operator's stored tokens;
# without them (fresh machine) the operator must sign in once - that is
# the interactive device flow, deliberately not automated here.
if ! "$CLI" call sys GET /v1/o >/dev/null 2>&1; then
  log "no valid CLI credentials for the operator identity."
  log "run once interactively: sentin8-cli signin"
  exit 1
fi

# ── 2. Organization + env (idempotent via slug lookup) ───────────────
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

# ── 3. Conformance clients (DCR endpoint - same path Dynamic OP runs) ─
# Registered via DCR so the exact registration surface under test is the
# one the suite exercises. Each client gets the suite callback.
dcr() { # dcr <name> <json-extra>
  local name="$1" extra="${2:-}"
  local body="{
    \"client_name\":\"$name\",
    \"redirect_uris\":[\"$CALLBACK\"],
    \"grant_types\":[\"authorization_code\",\"refresh_token\"],
    \"response_types\":[\"code\"],
    \"scope\":\"openid profile email offline_access\",
    \"code_challenge_method\":\"S256\",
    \"consent_required\":false${extra:+,$extra}
  }"
  ccall auth POST /oauth/register --body "$body" --env "$ENV_ID"
}

log "registering suite clients (DCR)"
BASIC_JSON="$(dcr "cert-basic-basic" '"token_endpoint_auth_method":"client_secret_basic"')"
POSTC_JSON="$(dcr "cert-basic-post" '"token_endpoint_auth_method":"client_secret_post"')"
PKCE_JSON="$(dcr "cert-public-pkce" '"token_endpoint_auth_method":"none"')"

# CIBA client: ping delivery points at the suite callback (poll + ping).
CIBA_JSON="$(dcr "cert-ciba" "\"token_endpoint_auth_method\":\"client_secret_post\",
    \"grant_types\":[\"urn:openid:params:grant-type:ciba\",\"refresh_token\"],
    \"backchannel_client_notification_endpoint\":\"$CALLBACK\"")"

echo "client_id(basic)=$(jget "$BASIC_JSON" client_id)"
echo "client_secret(basic)=$(jget "$BASIC_JSON" client_secret)"
echo "client_id(post)=$(jget "$POSTC_JSON" client_id)"
echo "client_secret(post)=$(jget "$POSTC_JSON" client_secret)"
echo "client_id(pkce)=$(jget "$PKCE_JSON" client_id)"
echo "client_id(ciba)=$(jget "$CIBA_JSON" client_id)"
echo "client_secret(ciba)=$(jget "$CIBA_JSON" client_secret)"

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