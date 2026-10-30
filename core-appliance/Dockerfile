# SPDX-FileCopyrightText: Copyright Logically Magic Inc. <hello@logicallymagic.com>
# SPDX-FileCopyrightText: Copyright Hamid Jahanzad <Hamid@Jahanzad.com>
# SPDX-FileCopyrightText: Copyright Contributors to the Sentin8
# SPDX-License-Identifier: Apache-2.0

# The core appliance runtime image (group DESIGN.md §3.3) - THIN by design:
# the platform binaries are bind-mounted (never baked), so this image
# carries only what the binaries need to run: glibc matching the host
# toolchain, plus the small tool surface the entrypoint and health probe
# need. A host rebuild is the upgrade path (upgrade-instance against the
# mounted paths) - the image itself is built once and rarely changes.
FROM debian:13-slim

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        ca-certificates \
        curl \
        procps \
        tini \
    && rm -rf /var/lib/apt/lists/*

# The appliance's writable state (captain.sock, logs) lives on a named
# volume; the entrypoint owns this directory.
RUN mkdir -p /var/lib/sentin8/run && chown -R 1000:1000 /var/lib/sentin8

# Pre-create EVERY bind-mount target (group DESIGN.md §3.3): mounting into
# a path whose parents do not exist in the image leaves a placeholder
# directory instead of the bind on some storage drivers (observed:
# gRPC-FUSE/WSL created an empty root-owned /opt/sentin8/... tree and the
# entrypoint's exec hit "No such file or directory" on a binary that
# provably existed on the host). The mount points exist; the binds then
# propagate reliably.
RUN for repo in sentin8-acme sentin8-auth sentin8-bff sentin8-bus \
                 sentin8-captain sentin8-cron sentin8-db sentin8-flow \
                 sentin8-func sentin8-post sentin8-proxy sentin8-secrets \
                 sentin8-sign sentin8-stat sentin8-storage sentin8-sys \
                 sentin8-web sentin8-cli; do \
        mkdir -p "/opt/sentin8/$repo/target" "/opt/sentin8/$repo/target/debug" "/opt/sentin8/$repo/target/release"; \
    done \
    && mkdir -p /mnt/host-secrets /etc/sentin8 /opt/sentin8/auth-ui-web \
    && chown -R 1000:1000 /opt/sentin8

COPY entrypoint.sh /usr/local/bin/sentin8-core-entrypoint
RUN chmod +x /usr/local/bin/sentin8-core-entrypoint

USER 1000:1000
WORKDIR /var/lib/sentin8

ENTRYPOINT ["/usr/bin/tini", "--", "/usr/local/bin/sentin8-core-entrypoint"]