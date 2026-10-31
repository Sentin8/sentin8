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

# 3. The binaries: /usr/bin - the installed-package shape. The appliance
# runs RELEASE-ONLY (group DESIGN.md §3.3): the mounted trees are
# {repo}/target/release (core-up builds RELEASE), the captain resolves
# spawns from the single dir /usr/bin, and every binary is linked there
# by name (sentin8-acme, sentin8-auth, ...) - a host rebuild swaps the
# mounted content in place (upgrade-instance works verbatim; the LINK
# target is the mounted path, never a copied file).
PREFIX=/usr/bin
for svc in acme ai app auth bff bus captain cron db flow func post proxy \
           secrets sign stat storage sys web; do
    bin="/opt/sentin8/sentin8-${svc}/target/release/sentin8-${svc}"
    if [ -x "$bin" ]; then
        ln -sf "$bin" "$PREFIX/sentin8-${svc}"
    else
        echo "[appliance] WARN: missing release binary $bin - build the platform group first (make core-up)." >&2
    fi
done
export SENTIN8_CAPTAIN_BINARY_PREFIX="$PREFIX"

# The auth-ui web bundle mount (the auth service serves it read-only).
export SENTIN8_AUTH_UI_DIR=/opt/sentin8/auth-ui-web
# Remap the SPA app-dir registry keys to the container paths: the enroll
# pass wrote the HOST paths (captain:app_dir:{slug}); inside the appliance
# the same trees live under /opt/sentin8/{repo}. The web static server
# serves the apps straight from these keys - a host-shaped value is a
# guaranteed 404 for the dash UI (the dash.ops.* route). Rewrites ONLY the
# leading host tree - any other shape passes untouched.
# The split-plane path remap contract (SDK `remap_app_dir` - web reads
# the app-dir keys through it): HOST prefix = this tree's mount root on
# the writer side, LOCAL prefix = where the same trees live HERE.
export SENTIN8_APP_DIR_HOST_PREFIX=${TREE_ROOT}/sentin8
export SENTIN8_APP_DIR_LOCAL_PREFIX=/opt/sentin8
# The auth-ui web bundle mount (the auth service serves it read-only).
export SENTIN8_AUTH_UI_DIR=/opt/sentin8/auth-ui-web

# 4. The appliance boot knobs (the flap-wave lesson, group DESIGN §3.3):
#    SENTIN8_PG_POOL_MAX + a generous PG acquire timeout so a respawn
#    wave's pool builds ride out contention inside ONE spawn instead of
#    parking (give-up) and re-storming on the next last-resort tick.
export SENTIN8_PG_POOL_MAX=${SENTIN8_PG_POOL_MAX_OVERRIDE:-8}
export SENTIN8_PG_ACQUIRE_TIMEOUT_S=${SENTIN8_PG_ACQUIRE_TIMEOUT_S:-30}
#    The respawner staggers its spawns (captain-side); give it a shorter
#    heartbeat so convergence is minutes, not the 300s default wave.
export SENTIN8_CAPTAIN_LAST_RESORT_RESPAWN_S=${SENTIN8_CAPTAIN_LAST_RESORT_RESPAWN_S:-30}

# 5. The captain boot.
#
# OS TRUST STORE FIRST: install the platform CA as ROOT (a root-only
# write), then drop to the runtime uid for the exec. Every native-roots
# reqwest client in the fleet (captain's health probes, every outbound
# m2m/B HTTPS call) verifies server leaves against the OS trust store -
# without this install the store lacks the platform CA, EVERY probe
# fails cert verification, and captain kills every "unresponsive"
# service in a never-ending flap (the 68x EPERM loop acme's own install
# hit when it ran sandboxed).
APPLIANCE_UID="$(id -u)"
CAPTAIN="$PREFIX/sentin8-captain"
if [ ! -x "$CAPTAIN" ]; then
    echo "ERROR: $CAPTAIN not found - build the release fleet first (make core-up)." >&2
    exit 1
fi
if [ "$APPLIANCE_UID" = "0" ] && [ -f "$SENTIN8_TLS_CA_PEM" ]; then
    mkdir -p /usr/local/share/ca-certificates
    cp -f "$SENTIN8_TLS_CA_PEM" /usr/local/share/ca-certificates/sentin8-platform-ca.crt
    if update-ca-certificates >/dev/null 2>&1; then
        echo "[appliance] platform CA installed into the OS trust store"
    else
        echo "[appliance] WARN: update-ca-certificates failed - probes may fail cert verification" >&2
    fi
    chown -R 1000:1000 /var/lib/sentin8/run /mnt/host-sock 2>/dev/null || true
    # Drop to the runtime uid for the captain exec (tini stays pid 1).
    # --init-groups needs a resolvable NAME; the slim image has no user
    # with uid 1000, so group/init-groups resolution is done by hand
    # (numeric ids only).
    exec setpriv --reuid=1000 --regid=1000 --clear-groups \
        /usr/bin/tini -- "$CAPTAIN"
fi
# Non-root paths (user: 1000 or a UID mismatch): boot straight away.
exec tini -- "$CAPTAIN"