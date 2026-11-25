# SPDX-FileCopyrightText: Copyright Logically Magic Inc. <hello@logicallymagic.com>
# SPDX-FileCopyrightText: Copyright Hamid Jahanzad <Hamid@Jahanzad.com>
# SPDX-FileCopyrightText: Copyright Contributors to the Sentin8
# SPDX-License-Identifier: Apache-2.0

# Derived OIDF conformance-suite server image (DESIGN §9a.2).
#
# The suite's Java client calls the Sentin8 OP over TLS; the JVM does NOT
# pick up bind-mounted .crt files on its own - the platform's Acme root
# CA must be IMPORTED into the JVM truststore with keytool. The root CA
# is copied next to this Dockerfile by `make conformance-up` (root-ca.crt,
# from ../../.run/secrets/acme-ca/root-ca.crt) so the build context stays
# self-contained.

ARG IMAGE_TAG=latest
FROM registry.gitlab.com/openid/conformance-suite:${IMAGE_TAG}

USER root
COPY root-ca.crt /tmp/sentin8-root-ca.crt
# Import into the JVM's bundled truststore (cacerts). The base image
# ships Temurin; JAVA_HOME/lib/security/cacerts is the canonical path.
RUN keytool -importcert \
      -noprompt \
      -alias sentin8-root-ca \
      -file /tmp/sentin8-root-ca.crt \
      -keystore "$JAVA_HOME/lib/security/cacerts" \
      -storepass changeit \
 && rm /tmp/sentin8-root-ca.crt
# CERTPLANE-1: a SECOND anchor for the upstream CA that signed the tenant
# auth hosts, when the fleet relays to a public directory. Let's Encrypt
# STAGING chains to a test root that is not in the OS store, so without
# this the suite's Java client rejects every staging-signed SUT with
# "unable to find valid certification path". The file is harvested from
# the chain acme actually stored (`sentin8-acme/scripts/harvest-staging-ca.sh`)
# rather than hardcoded, because the staging roots rotate.
#
# An intermediate is a valid JVM trust anchor, so importing just the issuer
# is enough - no root needed. An absent/empty file (no upstream leaf minted
# yet, or a platform-CA-only run) is a no-op, not a build failure.
COPY staging-ca.crt /tmp/sentin8-staging-ca.crt
RUN if [ -s /tmp/sentin8-staging-ca.crt ]; then \
      keytool -importcert \
        -noprompt \
        -alias sentin8-upstream-ca \
        -file /tmp/sentin8-staging-ca.crt \
        -keystore "$JAVA_HOME/lib/security/cacerts" \
        -storepass changeit ; \
    else \
      echo "no upstream CA to import (platform-CA-only run)"; \
    fi \
 && rm -f /tmp/sentin8-staging-ca.crt
USER 1000