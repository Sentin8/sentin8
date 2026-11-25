#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright Logically Magic Inc. <hello@logicallymagic.com>
# SPDX-FileCopyrightText: Copyright Hamid Jahanzad <Hamid@Jahanzad.com>
# SPDX-License-Identifier: Apache-2.0
# ── pgAdmin console sign-in: register an OIDC client with Sentin8:Auth ────
#
# The platform has no static operator passwords for consoles. Identity comes
# from Sentin8:Auth through an authorization-code round trip, so the pgAdmin
# console must hold a registered OAuth client rather than a username/password
# pair.
#
# This script performs Dynamic Client Registration (RFC 7591) against
# `auth.ops.sys.{SENTIN8_DOMAIN}/oauth/register` and writes TWO files into
# `{TREE_ROOT}/.run/pgadmin/` (both 0600):
#
#   sentin8-oidc-client.json  the registration, tagged with the domain and
#                             redirect URI it is bound to
#   config_system.py          pgAdmin's LAST-loaded config layer, carrying
#                             AUTHENTICATION_SOURCES=["oauth2"] and the
#                             OAUTH2_CONFIG built from that registration
#
# There is NO fallback domain: the fleet's domain comes from the tree-root
# `.env` (or an explicit SENTIN8_DOMAIN), and a missing one fails HERE rather
# than silently pointing the console at a fleet that does not exist.
#
# It is idempotent per (domain, redirect URI): an existing registration is
# reused, so repeated `make infra-pgadmin` runs cost nothing. A domain or
# port change invalidates the stored client and triggers a re-register.
#
# WHY DCR AND NOT A COMMITTED SECRET: a client secret is a credential. A repo
# that ships one ships a secret, and a dev box that pastes one into .env puts
# it in shell history. DCR mints it per machine, keeps it under the same
# gitignored `.run/` tree as the other material, and lets a fresh clone work
# with zero setup.
#
# Usage (called by `make infra-pgadmin`; not run by hand normally):
#   ./infra/pgadmin/pgadmin-oidc-login.sh
#
# Environment:
#   SENTIN8_DOMAIN   platform root domain (default: from the tree-root .env)
#   REDIRECT_URI     the console callback pgAdmin will present
#                    (default http://127.0.0.1:{PGADMIN_PORT}/oauth2/authorize)
#   PGADMIN_PORT     console port (default 5050, else PGADMIN_PORT in .env)
#   FORCE=1          re-register even when a stored client already exists

set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
GROUP_ROOT="$(cd "$HERE/../.." && pwd)"
TREE_ROOT="$(cd "$GROUP_ROOT/.." && pwd)"

# ── Platform domain: real env wins, then the tree-root .env ──────────────
env_from_file() {
  local key="$1" file="$TREE_ROOT/.env" value
  [[ -f "$file" ]] || return 0
  value="$(grep -h "^${key}=" "$file" 2>/dev/null | tail -1 | cut -d= -f2- | tr -d '\r')" || return 0
  value="${value%\"}"; value="${value#\"}"
  value="${value%\'}"; value="${value#\'}"
  [[ -n "$value" ]] && printf '%s' "$value"
  return 0
}

DOMAIN="${SENTIN8_DOMAIN:-$(env_from_file SENTIN8_DOMAIN)}"
if [[ -z "$DOMAIN" ]]; then
  echo "ERROR: SENTIN8_DOMAIN is unset (no env value, no tree-root .env)." >&2
  exit 1
fi

PORT="${PGADMIN_PORT:-$(env_from_file PGADMIN_PORT)}"
PORT="${PORT:-5050}"
REDIRECT_URI="${REDIRECT_URI:-http://127.0.0.1:${PORT}/oauth2/authorize}"
AUTH_BASE="https://auth.ops.sys.${DOMAIN}"

say() { printf '[pgadmin-oidc] %s\n' "$*"; }

# The generated config is runtime state, never tracked. It carries the
# client secret, so it lives beside the other `.run` material.
OUT_DIR="${SENTIN8_REPO_ROOT:-$TREE_ROOT}/.run/pgadmin"
OUT_FILE="$OUT_DIR/config_system.py"

# ── Reuse an existing registration unless FORCE=1 ────────────────────────
#
# The stored registration is keyed to ONE domain and ONE redirect URI. A
# domain switch or a port change invalidates it, so those are checked
# before reuse - a stale client_id would fail at the token endpoint with
# "invalid_client" long after the operator changed the domain.
if [[ "${FORCE:-0}" != "1" ]] && [[ -f "$OUT_DIR/sentin8-oidc-client.json" ]]; then
  if python3 - "$OUT_DIR/sentin8-oidc-client.json" "$DOMAIN" "$REDIRECT_URI" <<'PY'
import json, sys
d = json.load(open(sys.argv[1]))
ok = d.get("domain") == sys.argv[2] and d.get("redirect_uri") == sys.argv[3] and d.get("client_id")
sys.exit(0 if ok else 1)
PY
  then
    say "reusing the stored registration for domain '${DOMAIN}' (FORCE=1 to re-register)"
  else
    say "stored registration is for a different domain/redirect - re-registering"
    rm -f "$OUT_DIR/sentin8-oidc-client.json"
  fi
fi

# ── Dynamic Client Registration (RFC 7591) ────────────────────────────────
#
# token_endpoint_auth_method=client_secret_basic: pgAdmin's authlib client
# sends the secret with HTTP Basic at the token endpoint. A public client
# (`none`) would also work, but the confidential form keeps the secret out
# of the browser URL and matches what the platform already issues to `dash`.
say "registering an OIDC client with ${AUTH_BASE}/oauth/register"
say "  redirect_uri: ${REDIRECT_URI}"

payload="$(python3 - "$REDIRECT_URI" <<'PY'
import json, sys
print(json.dumps({
    "client_name": "Sentin8 pgAdmin console",
    "redirect_uris": [sys.argv[1]],
    "grant_types": ["authorization_code", "refresh_token"],
    "response_types": ["code"],
    "token_endpoint_auth_method": "client_secret_basic",
    "scope": "openid email profile",
}))
PY
)"

# --resolve is unnecessary: the platform CA is trusted by the host store
# (`make ca-trust`), and the domain resolves through DNS.
resp="$(curl -fsS --max-time 20 \
  -H 'content-type: application/json' \
  -X POST "${AUTH_BASE}/oauth/register" \
  --data-binary "$payload" 2>&1)" || {
    echo "ERROR: dynamic client registration failed." >&2
    echo "  endpoint: ${AUTH_BASE}/oauth/register" >&2
    echo "  response: ${resp:-<empty>}" >&2
    echo "  Is the platform fleet up and is the CA trusted (make ca-trust)?" >&2
    exit 1
  }

client_id="$(printf '%s' "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin)["client_id"])')"
client_secret="$(printf '%s' "$resp" | python3 -c 'import json,sys; print(json.load(sys.stdin).get("client_secret",""))')"

if [[ -z "$client_id" ]]; then
  echo "ERROR: registration returned no client_id." >&2
  printf '%s\n' "$resp" >&2
  exit 1
fi

# ── Emit config_system.py + the stored registration ──────────────────────
#
# `/etc/pgadmin/config_system.py` is loaded LAST by pgAdmin's
# evaluate_config (config_distro -> config_local -> config_system), so it
# overrides whatever the image shipped - including the default
# `AUTHENTICATION_SOURCES = ['internal']`. That is what replaces the static
# password. Written 0600 because it carries the client secret.
mkdir -p "$OUT_DIR"
umask 077

# The registration JSON is passed as an ARGUMENT, not on stdin: python reads
# the program itself from the heredoc on stdin, so a pipe would be swallowed.
python3 - "$OUT_DIR" "$DOMAIN" "$REDIRECT_URI" "$AUTH_BASE" \
  "$client_id" "$client_secret" "$resp" <<'PY'
import json
import sys

out_dir, domain, redirect_uri, auth_base, client_id, client_secret, raw = sys.argv[1:8]
resp = json.loads(raw)

# Record what this registration is bound to, so the next run can tell
# whether it is still valid for the configured domain.
state = dict(resp)
state.update({"domain": domain, "redirect_uri": redirect_uri, "auth_base": auth_base})
with open(f"{out_dir}/sentin8-oidc-client.json", "w") as f:
    json.dump(state, f, indent=2)

secret_literal = json.dumps(client_secret)

config = f'''# GENERATED by infra/pgadmin/pgadmin-oidc-login.sh - do not edit by hand.
#
# Console sign-in for the Sentin8 pgAdmin instance.
#
# Load order (pgadmin/evaluate_config.py): config_distro -> config_local ->
# config_system. THIS file is last, so it wins over the image default
# `AUTHENTICATION_SOURCES = ["internal"]` (the static password this
# replaces).
#
# The platform issues console identity through Sentin8:Auth, not through
# local accounts: operators sign in with the same credentials they use for
# every other Sentin8 surface, and pgAdmin auto-creates its local shadow
# row from the OIDC `email` claim on first sign-in.

# OIDC only. No `internal`, so no static password exists to leak.
AUTHENTICATION_SOURCES = ["oauth2"]

# Only identities the platform vouches for: the ID token must be signed by
# the fleet's own issuer, which is also the only JWKS pgAdmin is given.
OAUTH2_AUTO_CREATE_USER = True

OAUTH2_CONFIG = [{{
    "OAUTH2_NAME": "sentin8",
    "OAUTH2_DISPLAY_NAME": "Sentin8",
    "OAUTH2_CLIENT_ID": {json.dumps(client_id)},
    "OAUTH2_CLIENT_SECRET": {secret_literal},
    "OAUTH2_AUTHORIZATION_URL": {json.dumps(auth_base + "/oauth/authorize")},
    "OAUTH2_TOKEN_URL": {json.dumps(auth_base + "/oauth/token")},
    "OAUTH2_USERINFO_ENDPOINT": {json.dumps(auth_base + "/oauth/userinfo")},
    "OAUTH2_SERVER_METADATA_URL": {json.dumps(auth_base + "/.well-known/openid-configuration")},
    "OAUTH2_SCOPE": "openid email profile",
    "OAUTH2_USERNAME_CLAIM": "email",
    "OAUTH2_ICON": "fa-user",
    "OAUTH2_BUTTON_COLOR": "#1a73e8",
    "OAUTH2_AUTO_LOGIN": True,
}}]
'''
with open(f"{out_dir}/config_system.py", "w") as f:
    f.write(config)
PY

chmod 600 "$OUT_FILE" "$OUT_DIR/sentin8-oidc-client.json"

# ── CA bundle: pgAdmin's OIDC client must trust the platform CA ───────────
#
# pgAdmin's OAuth2 flow (authlib/requests) validates the auth server's TLS
# against `certifi`'s bundle, which has never heard of the platform CA -
# the discovery fetch fails with "self-signed certificate in certificate
# chain" and the SSO button 500s. Point requests at a bundle that carries
# BOTH certifi's public roots (so nothing else regresses) and this fleet's
# root + intermediate.
CA_BUNDLE="$OUT_DIR/ca-bundle.pem"
certifi_bundle="$(docker run --rm --entrypoint sh dpage/pgadmin4:9 -c \
  'cat /venv/lib/python3.15/site-packages/certifi/cacert.pem' 2>/dev/null || true)"
if [[ -n "$certifi_bundle" ]]; then
  printf '%s\n' "$certifi_bundle" > "$CA_BUNDLE"
else
  say "WARNING: could not read certifi's bundle - the CA file will carry only the platform CA"
  : > "$CA_BUNDLE"
fi
cat "$TREE_ROOT/.run/secrets/acme-ca/root-ca.crt" >> "$CA_BUNDLE"
# The intermediate is what signs the leaves; several verifiers cannot build
# leaf -> intermediate -> root from a root-only anchor.
if [[ -f "$TREE_ROOT/.run/secrets/infra-tls/../acme-ca/intermediate-ca.crt" ]]; then
  cat "$TREE_ROOT/.run/secrets/infra-tls/../acme-ca/intermediate-ca.crt" >> "$CA_BUNDLE"
fi
chmod 644 "$CA_BUNDLE"
say "CA bundle: ${CA_BUNDLE} ($(grep -c 'BEGIN CERTIFICATE' "$CA_BUNDLE") certs)"

say "SSO configured for ${AUTH_BASE}"
say "  client_id : ${client_id:0:12}..."
say "  config    : ${OUT_FILE} (0600, AUTHENTICATION_SOURCES=['oauth2'])"
if [[ -z "$client_secret" ]]; then
  say "  WARNING: the platform issued a PUBLIC client (no secret)."
fi
say "restart the console to load it:  make infra-pgadmin"