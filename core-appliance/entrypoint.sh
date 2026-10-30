#!/usr/bin/env bash
# SPDX-FileCopyrightText: Copyright Logically Magic Inc. <hello@logicallymagic.com>
# SPDX-FileCopyrightText: Copyright Hamid Jahanzad <Hamid@Jahanzad.com>
# SPDX-FileCopyrightText: Copyright Contributors to the Sentin8
# SPDX-License-Identifier: Apache-2.0
#
# The core appliance entrypoint (group DESIGN.md §3.3, captain DESIGN
# §11.11): boot the appliance captain against the shared infra and let it
# spawn the 17 platform services from the bind-mounted target trees. The
# appliance identity is 127.0.0.1 (compose sets
# SENTIN8_CAPTAIN_LOCAL_IP) - the loopback truth model.
#
# NETNS MODEL: postgres + valkey run as sibling containers on the
# appliance's bridge network; the services inside dial them BY COMPOSE
# SERVICE NAME (the operator env's localhost URLs are rewritten below -
# they describe the HOST view). The server leaves carry the compose
# names as SANs (make core-up passes INFRA_SANS to infra-tls). The
# PUBLISHED ports (host loopback 443/5432/6379/18000) give the host the
# same plane - the host's localhost DSNs keep working for verticals.

set -euo pipefail

# 1. Operator env (read-only mount) - the shared contract. Every absolute
# HOST path it names (secrets, acme data dir, ...) is remapped by the
# overrides below; its URLs need no remap (the shared-netns model).
set -a
# shellcheck disable=SC1091
source /etc/sentin8/sentin8.env
set +a

# 2. The appliance overrides - HOST paths do not exist inside the
# container; the mounted tree does.
export SENTIN8_RUN_DIR=/var/lib/sentin8/run
export SENTIN8_LOG_DIR=/var/lib/sentin8/run/logs
mkdir -p "$SENTIN8_LOG_DIR"
export SENTIN8_SECRETS_DIR=/mnt/host-secrets
# The UDS control socket lives on the HOST-BIND-MOUNTED dir so the host
# CLI reaches this captain over the socket (peer-cred authorized -
# §6.1.2; no device-flow bearer). The operator env names the HOST path
# ({run}/captain.sock) which is not this container's tree.
export SENTIN8_CAPTAIN_SOCK=/mnt/host-sock/captain.sock
# The platform Acme data dir: the operator .env names the HOST path -
# inside the appliance it is the mounted copy (writable; the CA keys stay
# on the host, so an appliance rebuild never rotates the platform
# identity). The appliance's acme instance IS the platform CA.
if [ -n "${SENTIN8_ACME_DATA_DIR:-}" ] && [ -d /mnt/host-acme ]; then
    export SENTIN8_ACME_DATA_DIR=/mnt/host-acme
fi
# The m2m workload-credential dir: the operator .env names the HOST path
# (absolute) - inside the appliance it is the mounted secrets tree's
# m2m-credentials/ subdir (writable mount: the mint loop converges pairs
# here, exactly like the host plane).
export SENTIN8_M2M_CREDENTIALS_DIR=/mnt/host-secrets/m2m-credentials
# The platform CA for outbound m2m TLS (the PUBLIC chain - the acme data
# dir with the CA PRIVATE keys is never mounted here, by design). The
# host flow defaults this to $SENTIN8_ACME_DATA_DIR/ca/root-ca.crt; the
# appliance uses the same public chain published under the secrets tree
# (infra-tls materializes acme-ca/root-ca.crt = root + intermediate).
export SENTIN8_TLS_CA_PEM=${SENTIN8_TLS_CA_PEM:-/mnt/host-secrets/acme-ca/root-ca.crt}
export SENTIN8_TLS_CLIENT_CA_PEM=${SENTIN8_TLS_CLIENT_CA_PEM:-/mnt/host-secrets/acme-ca/root-ca.crt}
# Registry + DB coordinates: inside the appliance's bridge netns the infra
# services are dialed BY COMPOSE SERVICE NAME (sentin8core-valkey,
# sentin8core-postgres). The operator env's localhost URLs describe the
# HOST view (published loopback ports) and do not apply inside; the
# server leaves carry these names as SANs via `make core-up`'s
# INFRA_SANS (the infra-tls re-mint is SAN-coverage aware, so the leaves
# are fresh whenever the names change).
export SENTIN8_VALKEY_HOST=sentin8core-valkey
export VALKEY_URL=valkeys://sentin8core-valkey:6379/0
# The PG host knob (service_database_url derives {SERVICE}_DATABASE_URL
# from it when the operator env has no explicit per-service override -
# the default `localhost` is the HOST view, unreachable in this netns).
export SENTIN8_PG_HOST=sentin8core-postgres
# Platform per-service DSNs: several platform services resolve their DSN
# as `{SERVICE}_DATABASE_URL` → `default_database_url()` (a hardcoded
# `sentin8_app@localhost` fallback the SDK pins per release tag). Inside
# the appliance the loopback host is wrong, so the entrypoint exports the
# derived form for every platform service (idempotent - an operator-set
# value in the env file wins because this loop only fills UNSET vars).
PG_PORT="${SENTIN8_PG_PORT:-5432}"
for svc in acme ai app auth bff bus captain cron db flow func post proxy \
           secrets sign stat storage sys web; do
    # Main DSN: fill only when UNSET (an operator-set value wins).
    var="SENTIN8_${svc^^}_DATABASE_URL"
    if [ -z "${!var:-}" ]; then
        export "$var=postgres://sentin8_${svc}_service@sentin8core-postgres:${PG_PORT}/sentin8"
    fi
    # Policy-workload DSN: same fill-only-when-unset rule (the Shield boot
    # pool rides the service's own role).
    var="SENTIN8_${svc^^}_POLICY_DATABASE_URL"
    if [ -z "${!var:-}" ]; then
        export "$var=postgres://sentin8_${svc}_service@sentin8core-postgres:${PG_PORT}/sentin8"
    fi
done
if [ -n "${DATABASE_URL:-}" ]; then
    export DATABASE_URL="${DATABASE_URL/\/\/sentin8@localhost:5432/\/\/sentin8@sentin8core-postgres:5432}"
    export DATABASE_URL="${DATABASE_URL/\/\/localhost:5432/\/\/sentin8core-postgres:5432}"
    export DATABASE_URL="${DATABASE_URL/\/\/127.0.0.1:5432/\/\/sentin8core-postgres:5432}"
fi
if [ -n "${SENTIN8_OPS_DATABASE_URL:-}" ]; then
    export SENTIN8_OPS_DATABASE_URL="${SENTIN8_OPS_DATABASE_URL/\/\/sentin8@localhost:5432/\/\/sentin8@sentin8core-postgres:5432}"
    export SENTIN8_OPS_DATABASE_URL="${SENTIN8_OPS_DATABASE_URL/\/\/localhost:5432/\/\/sentin8core-postgres:5432}"
    export SENTIN8_OPS_DATABASE_URL="${SENTIN8_OPS_DATABASE_URL/\/\/127.0.0.1:5432/\/\/sentin8core-postgres:5432}"
fi
# Per-service DSN overrides (only when the operator set them - any other
# host than the loopback forms passes through untouched).
for var in $(grep -oE '^[A-Z0-9_]+_DATABASE_URL=' /etc/sentin8/sentin8.env | tr -d '='); do
    val="${!var}"
    val="${val/\/\/sentin8@localhost:5432/\/\/sentin8@sentin8core-postgres:5432}"
    val="${val/\/\/localhost:5432/\/\/sentin8core-postgres:5432}"
    val="${val/\/\/127.0.0.1:5432/\/\/sentin8core-postgres:5432}"
    export "$var=$val"
done

# 3. The binary prefix: every mounted {repo}/target dir. The captain
# resolves binaries through it; a host rebuild swaps the mounted content
# in place, so upgrade-instance works against appliance keys verbatim.
# The runtime profile matches the make core-up profile (debug by default -
# the dev convention; SENTIN8_CORE_PROFILE=release for release).
profile="${SENTIN8_CORE_PROFILE:-debug}"
PREFIX=""
for d in /opt/sentin8/*/target; do
    [ -d "$d/$profile" ] && PREFIX="${PREFIX}${d}/${profile}:"
done
PREFIX="${PREFIX%:}"
export SENTIN8_CAPTAIN_BINARY_PREFIX="$PREFIX"

# The auth-ui web bundle mount (the auth service serves it read-only).
export SENTIN8_AUTH_UI_DIR=/opt/sentin8/auth-ui-web

# 4. The captain boot (foreground under tini - SIGTERM drains cleanly and
# compose stop has a bounded wait). The unset SENTIN8_SERVICES default is
# platform-only, exactly the appliance's scope.
CAPTAIN="/opt/sentin8/sentin8-captain/target/${profile}/sentin8-captain"
if [ ! -x "$CAPTAIN" ]; then
    echo "ERROR: $CAPTAIN not found - build the platform group first (make build)." >&2
    exit 1
fi
exec "$CAPTAIN"